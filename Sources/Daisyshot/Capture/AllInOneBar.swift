import AppKit
import SwiftUI

extension Prefs.Key {
    static let rememberAllInOneArea = Prefs.Key("rememberAllInOneArea", true)
    /// [displayID: rect] of the last All-In-One selection on each display (JSON).
    static let allInOneAreas = Prefs.Key("allInOneAreas", "")
    static let allInOneRatio = Prefs.Key("allInOneRatio", "free")
}

/// Aspect-ratio presets of the All-In-One size control.
struct AspectPreset: Identifiable {
    let id: String
    let title: String
    let value: CGFloat?

    static let all: [AspectPreset] = [
        .init(id: "free", title: "Freeform", value: nil),
        .init(id: "1:1", title: "1 : 1 (Square)", value: 1),
        .init(id: "5:4", title: "5 : 4 (10 : 8)", value: 5.0 / 4),
        .init(id: "4:3", title: "4 : 3", value: 4.0 / 3),
        .init(id: "3:2", title: "3 : 2 (6 : 4)", value: 3.0 / 2),
        .init(id: "16:9", title: "16 : 9", value: 16.0 / 9),
        .init(id: "16:10", title: "16 : 10", value: 16.0 / 10),
        .init(id: "1.85:1", title: "1.85 : 1", value: 1.85),
        .init(id: "2.35:1", title: "2.35 : 1", value: 2.35),
        .init(id: "7:5", title: "7 : 5", value: 7.0 / 5),
        .init(id: "4:5", title: "4 : 5", value: 4.0 / 5),
        .init(id: "3:4", title: "3 : 4", value: 3.0 / 4),
        .init(id: "9:16", title: "9 : 16", value: 9.0 / 16),
    ]
}

/// Fixed-size presets (points).
let fixedSizePresets: [(w: Int, h: Int, title: String)] = [
    (640, 480, "640 × 480"), (800, 600, "800 × 600"), (1024, 768, "1024 × 768"), (1280, 720, "1280 × 720 (HD)"),
    (1280, 800, "1280 × 800"), (1440, 900, "1440 × 900"), (1920, 1080, "1920 × 1080 (Full HD)"),
    (1080, 1080, "1080 × 1080 (Square post)"), (1080, 1350, "1080 × 1350 (Portrait post)"), (1080, 1920, "1080 × 1920 (Story)"),
    (1200, 630, "1200 × 630 (Link preview)"), (1500, 500, "1500 × 500 (Header)"),
]

/// State shared between the overlay and the All-In-One HUD.
@MainActor
final class AIOModel: ObservableObject {
    /// The W × H fields, published separately: they change on every drag event and only the fields need redrawing.
    final class Size: ObservableObject {
        @Published var width = 0
        @Published var height = 0
    }
    let size = Size()
    var width: Int { get { size.width } set { size.width = newValue } }
    var height: Int { get { size.height } set { size.height = newValue } }
    @Published var hasSelection = false
    @Published var windowMode = false
    @Published var ratioID = Prefs.string(.allInOneRatio) {
        didSet { Prefs.set(ratioID, .allInOneRatio); onRatioChange() }
    }

    var ratio: CGFloat? { AspectPreset.all.first { $0.id == ratioID }?.value }
    var ratioTitle: String { ratioID == "free" ? "Freeform" : ratioID.replacingOccurrences(of: ":", with: " : ") }

    var perform: (OverlayAction) -> Void = { _ in }
    var setSize: (CGFloat, CGFloat) -> Void = { _, _ in }
    var fullscreen: () -> Void = {}
    var toggleWindowMode: () -> Void = {}
    var cancel: () -> Void = {}
    var onRatioChange: () -> Void = {}
    /// Gives keyboard focus back to the overlay after editing a size field.
    var endEditing: () -> Void = {}

    func commitSize() { setSize(CGFloat(max(1, width)), CGFloat(max(1, height))); endEditing() }
}

/// The All-In-One HUD: size box (W × H, ratio, presets) and the capture-mode / action box.
struct AIOToolbar: View {
    @ObservedObject var model: AIOModel

    var body: some View {
        HStack(spacing: 8) {
            sizeBox
            modesBox
        }
        .padding(10) // room for the boxes' shadows
        .environment(\.colorScheme, .dark)
    }

    private var sizeBox: some View {
        HStack(spacing: 6) {
            VStack(spacing: 3) {
                SizeFields(size: model.size, enabled: model.hasSelection, commit: model.commitSize, cancel: model.endEditing)
                HStack(spacing: 2) {
                    Menu {
                        Picker("Aspect Ratio", selection: $model.ratioID) {
                            ForEach(AspectPreset.all) { Text($0.title.loc).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(model.ratioTitle.loc, systemImage: model.ratio == nil ? "lock.open" : "lock")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .help("Aspect ratio")
                    Menu {
                        ForEach(fixedSizePresets, id: \.title) { p in
                            Button(p.title.loc) { model.setSize(CGFloat(p.w), CGFloat(p.h)) }
                        }
                    } label: {
                        Image(systemName: "rectangle.3.group").font(.system(size: 10, weight: .medium))
                    }
                    .help("Fixed size")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            HUDIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Select the whole screen", action: model.fullscreen)
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .hudBox()
    }

    private var modesBox: some View {
        HStack(spacing: 1) {
            ModeButton(title: "Area", symbol: "rectangle.dashed", help: "Capture Area (A)", enabled: model.hasSelection) { model.perform(.screenshot) }
            ModeButton(title: "Fullscreen", symbol: "inset.filled.rectangle", help: "Capture Fullscreen (F)", action: model.fullscreen)
            ModeButton(title: "Window", symbol: "macwindow", help: "Capture Window (Space/W)", active: model.windowMode, action: model.toggleWindowMode)
            ModeButton(title: "Scrolling", symbol: "arrow.up.and.down.text.horizontal", help: "Scrolling Capture (S)", enabled: model.hasSelection) { model.perform(.scroll) }
            ModeButton(title: "Timer", symbol: "timer", help: "Self-Timer (T)", enabled: model.hasSelection) { model.perform(.timer) }
            ModeButton(title: "Text", symbol: "text.viewfinder", help: "Capture Text (O)", enabled: model.hasSelection) { model.perform(.text) }
            ModeButton(title: "Record", symbol: "record.circle", help: "Record Screen (R)", enabled: model.hasSelection) { model.perform(.video) }
            ModeButton(title: "GIF", glyph: "GIF", help: "Record GIF (G)", enabled: model.hasSelection) { model.perform(.gif) }
            Divider().frame(height: 34).padding(.horizontal, 4)
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    HUDIconButton(symbol: "doc.on.doc", help: "Copy to Clipboard (⌘C)", enabled: model.hasSelection) { model.perform(.copy) }
                    HUDIconButton(symbol: "square.and.arrow.down", help: "Save (⌘S)", enabled: model.hasSelection) { model.perform(.save) }
                }
                HStack(spacing: 2) {
                    HUDIconButton(symbol: "pencil.tip.crop.circle", help: "Annotate (E)", enabled: model.hasSelection) { model.perform(.annotate) }
                    HUDIconButton(symbol: "pin", help: "Pin to the Screen (P)", enabled: model.hasSelection) { model.perform(.pin) }
                }
            }
            Divider().frame(height: 34).padding(.horizontal, 4)
            HUDIconButton(symbol: "xmark", help: "Cancel (Esc)", action: model.cancel)
        }
        .padding(.horizontal, 6)
        .frame(height: 58)
        .hudBox()
    }
}

private struct SizeFields: View {
    @ObservedObject var size: AIOModel.Size
    let enabled: Bool
    let commit: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            DimensionField(value: $size.width, enabled: enabled, commit: commit, cancel: cancel)
            Text("×").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            DimensionField(value: $size.height, enabled: enabled, commit: commit, cancel: cancel)
        }
    }
}

private struct DimensionField: View {
    @Binding var value: Int
    let enabled: Bool
    let commit: () -> Void
    let cancel: () -> Void

    var body: some View {
        TextField("", value: $value, format: .number.grouping(.never))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .frame(width: 46, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.12)))
            .disabled(!enabled)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
    }
}

private struct ModeButton: View {
    let title: String
    var symbol: String? = nil
    var glyph: String? = nil
    let help: String
    var enabled = true
    var active = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 17))
                    } else if let glyph {
                        Text(glyph).font(.system(size: 9, weight: .heavy)).padding(.horizontal, 3).padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(lineWidth: 1.5))
                    }
                }
                .frame(height: 20)
                Text(title.loc).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .frame(width: 60, height: 48)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(active ? 0.22 : hover && enabled ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 1 : 0.35))
        .disabled(!enabled)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(help.loc)
    }
}

struct HUDIconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hover && enabled ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.95 : 0.35))
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help.loc)
    }
}

extension View {
    /// Dark translucent rounded box used by the capture HUDs.
    func hudBox(radius: CGFloat = 12) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
    }
}
