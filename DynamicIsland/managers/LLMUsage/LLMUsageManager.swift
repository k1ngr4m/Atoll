import Foundation
import SwiftUI
import Defaults
import Combine

@MainActor
final class LLMUsageManager: ObservableObject {
    static let shared = LLMUsageManager()

    @Published var results: [ProviderID: UsageResult] = [:]
    @Published var isRefreshing = false

    private let injectedProviders: [UsageProvider]? // overrides the flag-based default when non-nil
    private var cancellables = Set<AnyCancellable>()
    private var providerVersions: [ProviderID: Int] = [:]
    private var codexRefresh: Task<Void, Never>?
    private var lastRefresh: Date = .distantPast
    private static let minRefreshInterval: TimeInterval = 60

    init(providers: [UsageProvider]? = nil) {
        self.injectedProviders = providers
        if providers == nil {
            Defaults.publisher(.enableLLMUsageFeature, options: [])
                .receive(on: RunLoop.main)
                .sink { [weak self] change in
                    guard let self else { return }
                    for id in ProviderID.allCases { self.discardResult(for: id) }
                    self.lastRefresh = .distantPast
                    if change.newValue { self.refreshAll() }
                }
                .store(in: &cancellables)
            for id in ProviderID.allCases {
                Defaults.publisher(id.enabledKey, options: [])
                    .receive(on: RunLoop.main)
                    .sink { [weak self] change in
                        guard let self else { return }
                        self.discardResult(for: id)
                        self.lastRefresh = .distantPast
                        if change.newValue && Defaults[.enableLLMUsageFeature] { self.refreshAll() }
                    }
                    .store(in: &cancellables)
            }
        }
    }

    private static let allProviders: [UsageProvider] = [ClaudeUsageProvider(), CodexUsageProvider(), CursorUsageProvider(), AntigravityUsageProvider(), NewAPIUsageProvider()]

    private var enabledProviders: [UsageProvider] {
        if let injectedProviders { return injectedProviders }
        return Self.allProviders.filter { Defaults[$0.id.enabledKey] }
    }

    func refreshAll(force: Bool = false) {
        guard !isRefreshing else { return }
        guard force || Date().timeIntervalSince(lastRefresh) >= Self.minRefreshInterval else { return }
        lastRefresh = Date()
        isRefreshing = true
        let providers = enabledProviders
        let enabledIDs = Set(providers.map { $0.id })
        results = results.filter { enabledIDs.contains($0.key) } // drop disabled providers' stale results
        for p in providers where results[p.id] == nil { results[p.id] = .loading }
        Task { await runRefresh(providers: providers) }
    }

    /// Invalidate in-flight publications as well as the currently displayed result.
    func discardResult(for id: ProviderID) {
        providerVersions[id, default: 0] += 1
        results.removeValue(forKey: id)
    }

    private func accepts(_ id: ProviderID, version: Int) -> Bool {
        (injectedProviders != nil || (Defaults[.enableLLMUsageFeature] && Defaults[id.enabledKey])) && providerVersions[id, default: 0] == version
    }

    /// Called by the detail view's cancellable task. Overview refreshes keep their existing cadence.
    func refreshCodexDetail() async {
        if let codexRefresh { await codexRefresh.value; return }
        guard !isRefreshing, Defaults[.enableLLMUsageFeature],
              let provider = enabledProviders.first(where: { $0.id == .codex }) else { return }
        let version = providerVersions[.codex, default: 0]
        let task = Task { [weak self] in
            do {
                let snapshot = try await provider.fetchSnapshot(now: Date())
                guard let self, self.accepts(.codex, version: version), Defaults[.enableLLMUsageFeature] else { return }
                self.results[.codex] = .success(snapshot)
            } catch {
                guard let self, self.accepts(.codex, version: version) else { return }
                if self.results[.codex] == nil { self.results[.codex] = .failure(error.localizedDescription) }
            }
        }
        codexRefresh = task
        await task.value
        codexRefresh = nil
    }

    private func runRefresh(providers: [UsageProvider]) async {
        let now = Date()
        let versions = providerVersions
        await withTaskGroup(of: (ProviderID, UsageResult).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let snapshot = try await provider.fetchSnapshot(now: now) { snapshot in
                            await MainActor.run {
                                if self.accepts(provider.id, version: versions[provider.id, default: 0]) {
                                    self.results[provider.id] = .success(snapshot)
                                }
                            }
                        }
                        return (provider.id, .success(snapshot))
                    }
                    catch { return (provider.id, .failure(error.localizedDescription)) }
                }
            }
            for await (id, result) in group {
                if accepts(id, version: versions[id, default: 0]) { results[id] = result }
            }
        }
        isRefreshing = false
        if lastRefresh == .distantPast && Defaults[.enableLLMUsageFeature] { refreshAll() }
    }
}
