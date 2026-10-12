import Foundation

struct CodexUsageProvider: UsageProvider {
    let id: ProviderID = .codex
    private let backend: CodexUsageBackend

    init(root: URL? = nil, quotaClient: CodexQuotaClient = CodexQuotaClient()) {
        backend = CodexUsageBackend(roots: root.map { [$0] } ?? CodexLogStore.defaultRoots(), quotaClient: quotaClient)
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        try await fetchSnapshot(now: now, onUpdate: { _ in })
    }

    func fetchSnapshot(now: Date, onUpdate: @Sendable (UsageSnapshot) async -> Void) async throws -> UsageSnapshot {
        await backend.fetch(now: now, onUpdate: onUpdate)
    }
}

/// Serializes scans and coalesces quota requests across overview and detail refreshes.
private actor CodexUsageBackend {
    private let store: CodexLogStore
    private let quotaClient: CodexQuotaClient
    private var quota = CodexQuotaClient.Reading()
    private var quotaUpdatedAt: Date?
    private var lastAttempt = Date.distantPast
    private var request: Task<CodexQuotaClient.Reading, Never>?
    private var lastSnapshot: UsageSnapshot?

    init(roots: [URL], quotaClient: CodexQuotaClient) {
        store = CodexLogStore(roots: roots)
        self.quotaClient = quotaClient
    }

    private func receivedQuota(_ reading: CodexQuotaClient.Reading, at date: Date) {
        if reading.session != nil || reading.week != nil {
            quota = reading
            quotaUpdatedAt = date
        }
        request = nil
    }

    func fetch(now: Date, onUpdate: @Sendable (UsageSnapshot) async -> Void) async -> UsageSnapshot {
        let expired = [quota.session, quota.week].compactMap { $0?.resetsAt }.contains {
            $0 <= now && $0 > lastAttempt
        }
        let refreshQuota = now.timeIntervalSince(lastAttempt) >= 60 || expired
        if refreshQuota && request == nil {
            lastAttempt = now
            let client = quotaClient
            request = Task {
                let reading = await client.fetchReading()
                self.receivedQuota(reading, at: now)
                return reading
            }
        }
        // A slow quota endpoint must not hold up live local counters after the first load.
        if lastSnapshot == nil, let pending = request { _ = await pending.value }
        func decorate(_ snapshot: UsageSnapshot) -> UsageSnapshot {
            var snapshot = snapshot
            snapshot.sessionLimit = quota.session
            snapshot.weekLimit = quota.week
            snapshot.plan = quota.plan ?? snapshot.plan
            snapshot.quotaUpdatedAt = quotaUpdatedAt
            snapshot.quotaIsStale = quotaUpdatedAt == nil || (quotaUpdatedAt ?? .distantPast) < lastAttempt
                || [quota.session, quota.week].compactMap { $0?.resetsAt }.contains { $0 <= now }
            return snapshot
        }
        var initial = decorate(lastSnapshot ?? UsageSnapshot())
        initial.isLocalUsageLoading = lastSnapshot == nil
        await onUpdate(initial)
        let snapshot = decorate(store.snapshot(now: now, rediscover: refreshQuota))
        lastSnapshot = snapshot
        return snapshot
    }
}
