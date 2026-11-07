import AppKit
import SwiftUI

private typealias K = Prefs.Key

// MARK: Quick Access

struct QuickAccessSettingsPane: View {
    @AppStorage(K.qaPosition) var position: String
    @AppStorage(K.qaMoveToActiveScreen) var followCursor: Bool
    @AppStorage(K.qaSize) var size: Double
    @AppStorage(K.qaAutoClose) var autoClose: Bool
    @AppStorage(K.qaAutoCloseMode) var autoCloseMode: String
    @AppStorage(K.qaAutoCloseSeconds) var seconds: Int
    @AppStorage(K.qaCloseAfterDragging) var closeAfterDragging: Bool
    @AppStorage(K.qaAskForDestination) var askForDestination: Bool
    // Stored as `suppressWarning.<id>` (inverted) so Settings › Advanced › Reset All Warning Dialogs re-enables them.
    @AppStorage("suppressWarning.qaVideoDelete") var suppressVideoDelete = false
    @AppStorage("suppressWarning.qaCloseAll") var suppressCloseAll = false

    var body: some View {
        DSSections {
            DSCard {
                DSRow("Position on screen") {
                    DSSegmented(selection: $position, options: [.init(value: "left", title: "Left"), .init(value: "right", title: "Right")])
                }
                DSToggleRow("Move to active screen", subtitle: "Follows the display your pointer is on.", isOn: $followCursor)
                DSRow("Overlay size") {
                    HStack(spacing: 12) {
                        Image(systemName: "photo").font(.system(size: 12))
                        Slider(value: $size, in: 0.7...1.6, step: 0.1).frame(width: 300)
                        Image(systemName: "photo").font(.system(size: 18))
                    }
                    .foregroundStyle(DS.inkSecondary)
                }
            }

            DSCard {
                Toggle("Auto-close", isOn: $autoClose)
                DSRow("Action") {
                    Picker("Action", selection: $autoCloseMode) {
                        Text("Close").tag("close")
                        Text("Save and Close").tag("saveAndClose")
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!autoClose)
                }
                DSRow("Interval") {
                    Picker("Interval", selection: $seconds) {
                        ForEach(QuickAccess.autoCloseIntervals, id: \.seconds) { Text($0.title.loc).tag($0.seconds) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!autoClose)
                }
                if autoClose { SettingsNote("Hovering an overlay pauses its timer.") }
            }

            DSCard {
                DSToggleRow("Close after dragging",
                            subtitle: closeAfterDragging ? "Hold ⌥ (option) to keep the item on Overlay after dragging."
                                                         : "Hold ⌥ (option) to close the item from Overlay after dragging.",
                            isOn: $closeAfterDragging)
                DSRow("Save button behavior",
                      subtitle: askForDestination ? "Hold ⌥ (option) to save to the export location instead."
                                                  : "Hold ⌥ (option) to choose the destination instead.") {
                    Picker("Save button behavior", selection: $askForDestination) {
                        Text("Save to \u{201C}Export location\u{201D}").tag(false)
                        Text("Ask for destination").tag(true)
                    }
                    .labelsHidden().fixedSize()
                }
            }

            DSSectionHeader("Confirmations")
            DSCard {
                Toggle("Ask before moving recordings to the Trash", isOn: !$suppressVideoDelete)
                Toggle("Ask before closing all overlays", isOn: !$suppressCloseAll)
            }

            DSCard {
                chips("Shortcuts on a hovered overlay", [("⌘C", "Copy"), ("⌘S", "Save"), ("⌘E", "Edit"), ("⌘P", "Pin"),
                                                         ("Space", "Quick Look"), ("⌘⌫", "Trash"), ("Esc", "Close")])
                chips("Gestures", [("←→", "Swipe sideways to close"), ("↓", "Swipe down to hide all"), ("2×", "Double-click to edit")])
                HStack(spacing: 10) {
                    Button("Restore Recently Closed") { QuickAccess.shared.restoreRecentlyClosed() }
                    Button("Close All Overlays") { QuickAccess.shared.closeAll() }
                }
                .frame(minHeight: DS.Metric.rowMinHeight)
            }
        }
    }

    /// Title over wrapped keycap + label pairs.
    private func chips(_ title: String, _ items: [(key: String, label: String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.loc).font(DS.Font.body).foregroundStyle(DS.ink)
            FlowLayout(spacing: 14, lineSpacing: 8) {
                ForEach(items, id: \.key) { i in
                    HStack(spacing: 6) {
                        DSKeycap(i.key)
                        Text(i.label.loc).font(DS.Font.sub).foregroundStyle(DS.inkSecondary)
                    }
                }
            }
        }
        .padding(.vertical, 14)
    }
}

/// Lays children out left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (s, p) in zip(subviews, arrange(bounds.width, subviews).points) {
            s.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > maxWidth { x = 0; y += lineH + lineSpacing; lineH = 0 }
            points.append(CGPoint(x: x, y: y))
            width = max(width, x + sz.width)
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
        return (points, CGSize(width: width, height: y + lineH))
    }
}

// MARK: Wallpaper

struct WallpaperSettingsPane: View {
    @AppStorage(K.wallpaperSource) var source: String
    @AppStorage(K.wallpaperColor) var colorHex: String
    @AppStorage(K.customWallpaperFileName) var customName: String
    @AppStorage(K.wallpaperUpdateOnSpaceChange) var updateOnSpaces: Bool
    @State private var preview: NSImage?
    @State private var iconsHidden = DesktopIcons.shared.isHidden

    private static let swatches = ["#FFFFFF", "#F5F8FF", "#3E7BFA", "#2FA57A", "#FFC633", "#101A33"]

    var body: some View {
        DSSections {
            DSCard {
                Text("Choose the backdrop that covers desktop icons and sits behind window screenshots.")
                    .font(DS.Font.body).foregroundStyle(DS.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: DS.Metric.rowMinHeight).padding(.vertical, 4)
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Wallpaper").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.ink)
                        Picker("Wallpaper", selection: $source) {
                            Text("Desktop wallpaper").tag("wallpaper")
                            Text("Custom wallpaper").tag("custom")
                            Text("Plain color").tag("color")
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                        .font(DS.Font.body)
                        // Whole row dimmed and inert until "Plain color" is chosen; then unselected swatches dim.
                        DSSwatches(hex: $colorHex, swatches: Self.swatches, dimUnselected: source == "color")
                            .padding(.leading, 20)
                            .opacity(source == "color" ? 1 : 0.45)
                            .disabled(source != "color")
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        previewView
                        Text((source == "custom" ? "Preview · custom wallpaper" : source == "color" ? "Preview · plain color" : "Preview · current desktop wallpaper").loc)
                            .font(DS.Font.caption).foregroundStyle(DS.inkSecondary)
                    }
                }
                .padding(.vertical, 16)
                if source == "custom" {
                    DSRow("Wallpaper image") {
                        HStack {
                            Text(customName.isEmpty ? "None".loc : customName).foregroundStyle(DS.inkSecondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { WallpaperProvider.chooseCustomWallpaper() }
                        }
                    }
                }
                Toggle("Follow the wallpaper of the current Space", isOn: $updateOnSpaces)
            }
            DSCard {
                DSRow("Desktop icons") {
                    Button {
                        DesktopIcons.shared.toggle()
                        iconsHidden = DesktopIcons.shared.isHidden
                    } label: {
                        Label(iconsHidden ? "Show Desktop Icons".loc : "Hide Desktop Icons".loc, systemImage: iconsHidden ? "eye" : "eye.slash")
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: source) {
            if source == "custom", customName.isEmpty { WallpaperProvider.chooseCustomWallpaper() }
            WallpaperProvider.invalidate()
        }
        .onChange(of: colorHex) { WallpaperProvider.invalidate() }
        .onReceive(NotificationCenter.default.publisher(for: WallpaperProvider.didChange)) { _ in refresh() }
    }

    private var previewView: some View {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let ratio = screen.frame.width / max(screen.frame.height, 1)
        return ZStack {
            if let preview { Image(nsImage: preview).resizable().interpolation(.high) } else { DS.separator }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(width: 300)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.ink.opacity(0.08)))
    }

    private func refresh() {
        iconsHidden = DesktopIcons.shared.isHidden
        Task { preview = await WallpaperProvider.load(for: NSScreen.main ?? NSScreen.screens[0]) }
    }
}

/// Sections shown in Settings › Advanced that belong to the library (pinned screenshots, capture history).
struct LibraryAdvancedSections: View {
    @AppStorage(K.pinRounded) var pinRounded: Bool
    @AppStorage(K.pinShadow) var pinShadow: Bool
    @AppStorage(K.pinBorder) var pinBorder: Bool
    @AppStorage(K.historyCapacity) var capacity: Int
    @AppStorage("suppressWarning.historyDelete") var suppressDelete = false

    // A plain Group with no modifiers so the headers and cards flatten into AdvancedPane's DSSections.
    var body: some View {
        Group {
            DSSectionHeader("Pinned Screenshots")
            DSCard {
                Toggle("Rounded corners", isOn: $pinRounded)
                Toggle("Shadow", isOn: $pinShadow)
                Toggle("Border", isOn: $pinBorder)
                HStack(spacing: 10) {
                    Button("Choose and Pin an Image…") { PinWindow.chooseAndPin() }
                    Button("Close All Pins") { PinWindow.closeAll() }
                }
                .frame(minHeight: DS.Metric.rowMinHeight)
            }
            DSSectionHeader("Capture History")
            DSCard {
                DSRow("Keep history") {
                    Picker("Keep history", selection: $capacity) {
                        ForEach(History.capacityOptions, id: \.days) { Text($0.title.loc).tag($0.days) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: capacity) { History.shared.prune() }
                }
                if capacity == 0 { SettingsNote("Capture History is off.") }
                Toggle("Ask before deleting from history", isOn: !$suppressDelete)
                HStack(spacing: 10) {
                    Button("Open Capture History") { History.showWindow() }
                    Button("Clear History…") { History.shared.confirmAndDelete(History.shared.entries) }
                        .buttonStyle(.dsDestructive)
                        .disabled(History.shared.entries.isEmpty)
                }
                .frame(minHeight: DS.Metric.rowMinHeight)
            }
        }
    }
}

private prefix func ! (b: Binding<Bool>) -> Binding<Bool> {
    Binding(get: { !b.wrappedValue }, set: { b.wrappedValue = !$0 })
}
