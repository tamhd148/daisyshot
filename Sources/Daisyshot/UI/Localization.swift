import AppKit
import SwiftUI

// Localization: English UI strings are the keys. Translations live in Localization/<lang>/*.strings, which
// scripts/build-app.sh merges into <lang>.lproj/Localizable.strings. SwiftUI `Text("literal")`, `Button("…")`,
// `Toggle("…")`, `.help("…")` look keys up on their own; everything that takes a `String` uses `.loc`.
// Shared components (DSRow, DSSectionHeader, ClosureMenuItem, Toast, ActionBanner, Warnings) already apply it.

extension String {
    /// This English UI string in the app's language; untranslated strings stay English.
    var loc: String { Bundle.main.localizedString(forKey: self, value: self, table: nil) }

    /// Translated format string filled in, e.g. `"Copied %d characters".loc(n)`.
    func loc(_ args: CVarArg...) -> String { String(format: loc, locale: .current, arguments: args) }
}

extension NSAlert {
    /// Translates the message, informative text and button titles (call after adding buttons).
    func localize() {
        messageText = messageText.loc
        informativeText = informativeText.loc
        for b in buttons { b.title = b.title.loc }
        suppressionButton?.title = suppressionButton?.title.loc ?? ""
    }
}

/// Settings › General › Language. Stored as the app's own `AppleLanguages`, which macOS reads at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, vi, ko, ja, zhHans = "zh-Hans"
    var id: String { rawValue }

    /// Native names, so each is readable whatever the current language is.
    var title: String {
        switch self {
        case .system: return "Same as macOS".loc
        case .en: return "English"
        case .vi: return "Tiếng Việt"
        case .ko: return "한국어"
        case .ja: return "日本語"
        case .zhHans: return "简体中文"
        }
    }

    static var current: AppLanguage {
        guard let first = Prefs.d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String] else { return .system }
        guard let code = first.first else { return .system }
        return allCases.first { $0 != .system && (code == $0.rawValue || code.hasPrefix($0.rawValue + "-")) } ?? .system
    }

    @MainActor
    static func select(_ lang: AppLanguage) {
        guard lang != current else { return }
        if lang == .system { Prefs.d.removeObject(forKey: "AppleLanguages") } else { Prefs.d.set([lang.rawValue], forKey: "AppleLanguages") }
        let a = NSAlert()
        a.messageText = "Relaunch Daisyshot to change the language?"
        a.informativeText = "The new language is used after Daisyshot restarts."
        a.addButton(withTitle: "Relaunch Now")
        a.addButton(withTitle: "Later")
        a.localize()
        if a.runModal() == .alertFirstButtonReturn { Permissions.relaunch() }
    }
}

struct LanguagePicker: View {
    @State private var lang = AppLanguage.current

    var body: some View {
        Picker("Language", selection: Binding(get: { lang }, set: { lang = $0; AppLanguage.select($0) })) {
            ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden().fixedSize()
    }
}
