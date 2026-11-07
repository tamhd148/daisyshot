import AppKit
import SwiftUI

extension Prefs.Key {
    static let settingsTab = Prefs.Key("settingsTab", "general")
}

/// The Settings window: fixed-width, colored sidebar on the left, the selected pane (a grouped Form) on the right.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    static let model = SettingsModel()

    /// `tab` accepts these ids (`general`, `shortcuts`, `quickAccess`, `wallpaper`, `screenshots`,
    /// `screenRecording`, `annotate`, `advanced`, `about`) in any case, with or without dashes.
    @discardableResult
    static func show(tab: String? = nil) -> NSWindow? {
        if let tab, let t = SettingsTab(loose: tab) { model.tab = t }
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Daisyshot Settings".loc
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.toolbar = NSToolbar(identifier: "DaisyshotSettings")
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.contentMinSize = CGSize(width: width, height: 440)
            w.contentMaxSize = CGSize(width: width, height: 2000)
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            w.setFrameAutosaveName("DaisyshotSettings")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        return window
    }

    private static let width = DS.Metric.windowWidth
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, quickAccess, wallpaper, screenshots, screenRecording, annotate, advanced, about
    var id: String { rawValue }

    init?(loose s: String) {
        let norm = { (x: String) in x.lowercased().filter { $0.isLetter } }
        let aliases = ["recording": Self.screenRecording, "video": .screenRecording, "hotkeys": .shortcuts, "quickaccessoverlay": .quickAccess]
        guard let t = Self.allCases.first(where: { norm($0.rawValue) == norm(s) }) ?? aliases[norm(s)] else { return nil }
        self = t
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .quickAccess: return "Quick Access Overlay"
        case .wallpaper: return "Wallpaper"
        case .screenshots: return "Screenshots"
        case .screenRecording: return "Screen Recording"
        case .annotate: return "Annotate"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .quickAccess: return "rectangle.stack.fill"
        case .wallpaper: return "photo.fill"
        case .screenshots: return "viewfinder"
        case .screenRecording: return "record.circle"
        case .annotate: return "arrow.up.right"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info"
        }
    }

    /// Sidebar tile colour (DESIGN_SPEC §5). Tiles keep their light-mode colours in dark mode, except the ink one.
    var color: Color {
        switch self {
        case .general, .screenshots: return Color(nsColor: NSColor(hex: "#3E7BFA"))
        case .shortcuts: return Color(nsColor: NSColor(hex: "#2B5FE0"))
        case .quickAccess, .advanced: return Color(nsColor: NSColor(hex: "#55617A"))
        case .wallpaper: return Color(nsColor: NSColor(hex: "#2FA57A"))
        case .screenRecording: return DS.center
        case .annotate: return DS.ink   // inverts in dark mode so the tile stays visible
        case .about: return DS.skyLight
        }
    }

    /// Glyph colour on the tile: ink on the yellow and light-sky tiles, white elsewhere.
    var glyphColor: Color {
        switch self {
        case .screenRecording, .about: return Color(nsColor: NSColor(hex: "#101A33"))
        case .annotate: return DS.windowBg
        default: return .white
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var tab = SettingsTab(rawValue: Prefs.string(.settingsTab)) ?? .general {
        didSet { Prefs.set(tab.rawValue, .settingsTab) }
    }
}

/// Colored rounded-square icon used in the sidebar and section headers.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22
    var glyph: Color = .white

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.58, weight: .semibold))
            .foregroundStyle(glyph)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// false = the whole page at its natural height (debug snapshots can't capture scroll views).
    var scrolls = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(DS.separator).frame(width: 1)
            Group {
                if scrolls {
                    ScrollView { page }.id(model.tab)   // each pane starts at the top
                } else {
                    page.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .background(DS.windowBg)
            .toggleStyle(DSRowToggleStyle())
            .buttonStyle(DSButtonStyle())
            .tint(DS.accent)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minHeight: 440)
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: DS.Metric.sectionGap) {
            if model.tab != .about { Text(model.tab.title.loc).font(DS.Font.pageTitle).foregroundStyle(DS.ink).padding(.bottom, 4) }
            pane
        }
        .padding(EdgeInsets(top: DS.Metric.contentPaddingTop, leading: DS.Metric.contentPaddingH,
                            bottom: DS.Metric.contentPaddingBottom, trailing: DS.Metric.contentPaddingH))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsTab.allCases) { t in
                let on = t == model.tab
                Button { model.tab = t } label: {
                    HStack(spacing: 10) {
                        SettingsIcon(symbol: t.symbol, color: t.color, size: DS.Metric.sidebarTile, glyph: t.glyphColor)
                        Text(t.title.loc).font(.system(size: 14, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? DS.accentText : DS.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .background(on ? DS.accentTint : .clear, in: RoundedRectangle(cornerRadius: DS.Metric.sidebarRowRadius, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.top, 52)   // clears the traffic lights
        .padding(.horizontal, 12)
        .frame(width: DS.Metric.sidebarWidth)
        .background(DS.sidebarBg)
    }

    @ViewBuilder private var pane: some View {
        switch model.tab {
        case .general: GeneralPane()
        case .shortcuts: ShortcutsPane()
        case .quickAccess: QuickAccessSettingsPane()
        case .wallpaper: WallpaperSettingsPane()
        case .screenshots: ScreenshotsSettingsPane()
        case .screenRecording: RecordingSettingsPane()
        case .annotate: AnnotateSettingsPane()
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Secondary explanatory text under a setting.
struct SettingsNote: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(DS.inkSecondary).lineSpacing(2).tint(DS.accentStrong)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12).padding(.bottom, 14)
    }
}

// MARK: Warning dialogs

/// "Don't show again" bookkeeping. Every suppressible dialog stores `suppressWarning.<id>`, so Settings › Advanced ›
/// Reset All Warning Dialogs can re-enable them all. Other modules: use `Warnings.run("myId", alert)`.
@MainActor
enum Warnings {
    static let prefix = "suppressWarning."

    static func isSuppressed(_ id: String) -> Bool { Prefs.d.bool(forKey: prefix + id) }

    /// Runs `alert` with a "Don't show again" checkbox unless the user suppressed it; returns `.alertFirstButtonReturn` when skipped.
    @discardableResult
    static func run(_ id: String, _ alert: NSAlert) -> NSApplication.ModalResponse {
        guard !isSuppressed(id) else { return .alertFirstButtonReturn }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show again"
        alert.localize()
        NSApp.activate(ignoringOtherApps: true)
        let r = alert.runModal()
        if alert.suppressionButton?.state == .on { Prefs.d.set(true, forKey: prefix + id) }
        return r
    }

    static func resetAll() {
        Prefs.d.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.forEach(Prefs.d.removeObject(forKey:))
    }
}
