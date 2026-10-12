import Foundation

struct CodexUsageProvider: UsageProvider {
    let id: ProviderID = .codex
    let root: URL
    let quotaClient: CodexQuotaClient

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"), quotaClient: CodexQuotaClient = CodexQuotaClient()) {
        self.root = root
        self.quotaClient = quotaClient
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        try await fetchSnapshot(now: now, onUpdate: { _ in })
    }

    func fetchSnapshot(now: Date, onUpdate: @Sendable (UsageSnapshot) async -> Void) async throws -> UsageSnapshot {
        let quota = await quotaClient.fetchLimits()
        var snapshot = UsageSnapshot()
        snapshot.isLocalUsageLoading = true
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
        await onUpdate(snapshot)

        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" } ?? []
        snapshot = JSONLUsageParser.aggregate(files: files, now: now)
        if files.isEmpty { snapshot.localUsageError = "No Codex usage logs found" }
        snapshot.sessionLimit = quota.session
        snapshot.weekLimit = quota.week
        return snapshot
    }
}
