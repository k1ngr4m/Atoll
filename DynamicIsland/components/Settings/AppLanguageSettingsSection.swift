import SwiftUI

/// Uses the same per-app language preference as macOS Language & Region.
struct AppLanguageSettingsSection: View {
    @State private var selectedLanguage = savedLanguage

    private static var savedLanguage: String {
        guard let identifier = Bundle.main.bundleIdentifier else { return "" }
        // Read only the app domain: the merged defaults also contain the system's
        // AppleLanguages, which must not be mistaken for an app override.
        let domain = UserDefaults.standard.persistentDomain(forName: identifier)
        return (domain?["AppleLanguages"] as? [String])?.first ?? ""
    }

    private var languages: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }.sorted {
            languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
        }
    }

    private func languageName(_ code: String) -> String {
        Locale(identifier: code).localizedString(forIdentifier: code) ?? code
    }

    var body: some View {
        Section {
            Picker("Language", selection: $selectedLanguage) {
                Text("Follow System").tag("")
                ForEach(languages, id: \.self) { code in
                    Text(verbatim: languageName(code)).tag(code)
                }
            }
            .onChange(of: selectedLanguage) { _, language in
                if language.isEmpty {
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                } else {
                    UserDefaults.standard.set([language], forKey: "AppleLanguages")
                }
            }
            .onAppear {
                selectedLanguage = Self.savedLanguage
            }
        } header: {
            Text("Language")
        } footer: {
            Text("Quit and reopen Atoll to apply language changes.")
        }
    }
}
