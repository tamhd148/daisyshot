// DaisyshotTheme.swift — starter design tokens from the Daisyshot design hand-off.
// Values mirror DESIGN_SPEC.md §2–§4. Adapt names to the project's conventions.

import SwiftUI
import AppKit

extension NSColor {
    /// Light/dark dynamic colour from two hex values.
    static func ds(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

enum DS {
    enum ColorToken {
        static let accent        = Color(nsColor: .ds(0x3E7BFA, 0x4A86FF))
        static let accentStrong  = Color(nsColor: .ds(0x2B5FE0, 0x5B93FF))
        static let accentText    = Color(nsColor: .ds(0x1A3FA8, 0xA9C7FF))
        static let accentTint    = Color(nsColor: .ds(0xDCE7FF, 0x23365F))
        static let skyLight      = Color(nsColor: .ds(0x7FB8FF, 0x7FB8FF))
        static let center        = Color(nsColor: .ds(0xFFC633, 0xFFC633))
        static let centerDeep    = Color(nsColor: .ds(0xF5A21B, 0xF5A21B))
        static let leaf          = Color(nsColor: .ds(0x2FA57A, 0x3DBB8C))
        static let leafTint      = Color(nsColor: .ds(0xE3F4EC, 0x173A2E))
        static let leafText      = Color(nsColor: .ds(0x1F6E52, 0x8FDCBC))
        static let ink           = Color(nsColor: .ds(0x101A33, 0xF2F3F7))
        static let inkSecondary  = Color(nsColor: .ds(0x55617A, 0xAEB9D3))
        static let inkTertiary   = Color(nsColor: .ds(0x8A93A8, 0x7D879D))
        static let windowBg      = Color(nsColor: .ds(0xFFFFFF, 0x1B2133))
        static let sidebarBg     = Color(nsColor: .ds(0xEEF2F8, 0x151B2B))
        static let cardBg        = Color(nsColor: .ds(0xF5F7FB, 0x222A3D))
        static let separator     = Color(nsColor: .ds(0xE6EAF1, 0x2E374D))
        static let controlBorder = Color(nsColor: .ds(0xDDE2EB, 0x3A4560))
        static let toggleOff     = Color(nsColor: .ds(0xD5DBE5, 0x3A4560))
        static let destructive   = Color(nsColor: .ds(0xB42318, 0xFF7A6E))
        static let annotateDefault = Color(nsColor: NSColor(hex: 0xE5484D))
    }

    enum Metric {
        static let sidebarWidth: CGFloat = 250
        static let contentPaddingH: CGFloat = 36
        static let contentPaddingTop: CGFloat = 22
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
        static let pageTitle = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let section   = SwiftUI.Font.system(size: 15, weight: .bold)
        static let body      = SwiftUI.Font.system(size: 14)
        static let sub       = SwiftUI.Font.system(size: 12.5)
        static let caption   = SwiftUI.Font.system(size: 12)
        static let keycap    = SwiftUI.Font.system(size: 13, design: .monospaced)
    }
}
