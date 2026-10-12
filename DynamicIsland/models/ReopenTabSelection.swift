enum ReopenTabSelection {
    static let lastPage = "last-page"

    static func resolve(
        preference: String, lastPage: String?, available: [String], explicitTarget: String? = nil
    ) -> String? {
        [explicitTarget, preference, lastPage]
            .compactMap { $0 }
            .first { available.contains($0) } ?? available.first
    }
}
