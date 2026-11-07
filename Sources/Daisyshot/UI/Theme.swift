import AppKit
import SwiftUI

/// Daisyshot design tokens (design/daisyshot/DESIGN_SPEC.md §2–§4). Brand surfaces use these; plain text and window
/// chrome keep the semantic system colours.
enum DS {
    static let accent        = Color(nsColor: .ds("#3E7BFA", "#4A86FF"))
    static let accentStrong  = Color(nsColor: .ds("#2B5FE0", "#5B93FF"))
    static let accentText    = Color(nsColor: .ds("#1A3FA8", "#A9C7FF"))
    static let accentTint    = Color(nsColor: .ds("#DCE7FF", "#23365F"))
    static let skyLight      = Color(nsColor: NSColor(hex: "#7FB8FF"))
    static let center        = Color(nsColor: NSColor(hex: "#FFC633"))
    static let centerDeep    = Color(nsColor: NSColor(hex: "#F5A21B"))
    static let leaf          = Color(nsColor: .ds("#2FA57A", "#3DBB8C"))
    static let leafTint      = Color(nsColor: .ds("#E3F4EC", "#173A2E"))
    static let leafText      = Color(nsColor: .ds("#1F6E52", "#8FDCBC"))
    static let ink           = Color(nsColor: .ds("#101A33", "#F2F3F7"))
    static let inkSecondary  = Color(nsColor: .ds("#55617A", "#AEB9D3"))
    static let inkTertiary   = Color(nsColor: .ds("#8A93A8", "#7D879D"))
    static let windowBg      = Color(nsColor: .ds("#FFFFFF", "#1B2133"))
    static let sidebarBg     = Color(nsColor: .ds("#EEF2F8", "#151B2B"))
    static let cardBg        = Color(nsColor: .ds("#F5F7FB", "#222A3D"))
    static let separator     = Color(nsColor: .ds("#E6EAF1", "#2E374D"))
    static let controlBorder = Color(nsColor: .ds("#DDE2EB", "#3A4560"))
    static let toggleOff     = Color(nsColor: .ds("#D5DBE5", "#3A4560"))
    static let destructive   = Color(nsColor: .ds("#B42318", "#FF7A6E"))
    /// Control surface (buttons, pop-ups, keycaps, segmented thumb).
    static let controlBg     = Color(nsColor: .ds("#FFFFFF", "#2A3349"))

    enum Metric {
        static let windowWidth: CGFloat = 1040
        static let sidebarWidth: CGFloat = 250
        static let contentPaddingH: CGFloat = 36
        static let contentPaddingTop: CGFloat = 22
        static let contentPaddingBottom: CGFloat = 32
        static let sectionGap: CGFloat = 16
        static let cardRadius: CGFloat = 12
        static let cardPaddingH: CGFloat = 16
        static let rowMinHeight: CGFloat = 48
        static let shortcutRowMinHeight: CGFloat = 42
        static let sidebarRowRadius: CGFloat = 9
        static let sidebarTile: CGFloat = 26
        static let sidebarTileRadius: CGFloat = 7
        static let buttonRadius: CGFloat = 8
        static let popupRadius: CGFloat = 7
        static let keycapWidth: CGFloat = 140
    }

    enum Font {
        static let pageTitle = SwiftUI.Font.system(size: 20, weight: .bold)
        static let section   = SwiftUI.Font.system(size: 15, weight: .bold)
        static let body      = SwiftUI.Font.system(size: 14)
        static let sub       = SwiftUI.Font.system(size: 12.5)
        static let caption   = SwiftUI.Font.system(size: 12)
        static let keycap    = SwiftUI.Font.system(size: 13, design: .monospaced)
    }

    /// Bundled artwork from `Assets/` (copied into Contents/Resources by scripts/build-app.sh), e.g.
    /// `DS.image("MenuBar/menubar-black.svg")`. Debug runs from `.build` read the repo's Assets folder instead.
    @MainActor
    static func image(_ path: String) -> NSImage? {
        if let hit = images[path] { return hit }
        var url = Bundle.main.resourceURL?.appendingPathComponent(path)
        #if DEBUG
        if url.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/" + path)
        }
        #endif
        let img = url.flatMap(NSImage.init(contentsOf:))
        images[path] = img
        return img
    }

    @MainActor private static var images: [String: NSImage?] = [:]
}

extension NSColor {
    /// Light/dark pair that follows the appearance it's drawn in.
    static func ds(_ light: String, _ dark: String) -> NSColor {
        let l = NSColor(hex: light), d = NSColor(hex: dark)
        return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l }
    }
}
