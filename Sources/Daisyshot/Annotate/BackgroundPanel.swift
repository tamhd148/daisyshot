import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Background tool: a left sidebar with presets, every background source and the frame controls.
struct BackgroundPanel: View {
    let editor: AnnotateEditor
    let state: BackgroundState
    @ObservedObject var fillState: FillState
    @ObservedObject private var store = PresetStore.shared
    @AppStorage(Prefs.Key.annotateShowMoreWallpapers) private var showMore: Bool
    @State private var custom = Backgrounds.customNames()
    @State private var presetID: String?
    @State private var dropTarget = false

    private var bg: BackgroundSettings { editor.doc.background }
    private var fill: Binding<BackgroundSettings.Fill> { editor.background(\.fill) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    presets
                    section("Background") { specials }
                    section("Wallpapers") { wallpapers }
                    section("Gradients") { gradients }
                    section("Colors") { colors }
                    section("Your Images") { customImages }
                    Divider()
                    BackgroundControls(editor: editor, state: state)
                }
                .padding(12)
            }
        }
        .frame(width: 286)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1) }
        .controlSize(.small)
        .clipped()
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            Text("Background").font(.headline)
            Spacer()
            IconButton(symbol: "xmark", help: "Close (B)".loc, size: 11) { editor.toggleBackground() }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.loc.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Presets

    private var presets: some View {
        HStack(spacing: 6) {
            Menu {
                if store.presets.isEmpty { Text("No presets yet") }
                ForEach(store.presets) { p in
                    Button { apply(p) } label: {
                        Label { Text(p.name) } icon: { Image(nsImage: BackgroundPresets.thumbnail(p.settings, height: 16)) }
                    }
                }
                Divider()
                Button("Apply Previous Settings") { applySettings(Prefs.codable(.annotateLastBackground, BackgroundSettings.self) ?? BackgroundSettings()) }
                Button("Default Settings") { var d = BackgroundSettings(); d.fill = bg.fill; applySettings(d) }
            } label: {
                Text(store.presets.first { $0.id == presetID }?.name ?? "Presets".loc)
            }
            .fixedSize(horizontal: false, vertical: true)
            IconButton(symbol: "plus", help: "Save as new preset…".loc, size: 12) { newPreset() }
            IconButton(symbol: "square.and.arrow.down", help: "Save changes to the preset".loc, size: 12) {
                if let id = presetID { BackgroundPresets.update(id, settings: bg); Toast.show("Preset saved") }
            }
            .disabled(presetID == nil)
            Menu {
                Button("Rename…") { renamePreset() }
                Button("Delete", role: .destructive) { if let id = presetID { BackgroundPresets.delete(id); presetID = nil } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(presetID == nil)
        }
    }

    private func apply(_ p: BackgroundPreset) {
        presetID = p.id
        applySettings(p.settings)
    }

    private func applySettings(_ s: BackgroundSettings) {
        editor.mutate { $0.background = s }
    }

    private func ask(_ title: String, _ value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.localize()
        let field = NSTextField(string: value)
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func newPreset() {
        guard let name = ask("Name this preset:", "Preset %d".loc(store.presets.count + 1)) else { return }
        presetID = BackgroundPresets.add(name, bg).id
    }

    private func renamePreset() {
        guard let id = presetID, let p = BackgroundPresets.preset(id), let name = ask("Rename preset:", p.name) else { return }
        BackgroundPresets.update(id, name: name)
    }

    // MARK: Sources

    private let grid3 = [GridItem](repeating: GridItem(.flexible(), spacing: 6), count: 3)
    private let grid5 = [GridItem](repeating: GridItem(.flexible(), spacing: 5), count: 5)

    private var specials: some View {
        LazyVGrid(columns: grid3, spacing: 6) {
            tile(.none, "None") {
                ZStack {
                    Checkerboard(cell: 6)
                    Image(systemName: "nosign").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            imageTile(.wallpaper, "Desktop wallpaper")
            imageTile(.blurredWallpaper, "Blurred desktop wallpaper")
            imageTile(.blurredScreenshot, "Blurred screenshot")
        }
    }

    private var wallpapers: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: grid3, spacing: 6) {
                ForEach(0 ..< (showMore ? Backgrounds.wallpapers.count : 9), id: \.self) { i in
                    imageTile(.builtin(i), Backgrounds.wallpapers[i].name)
                }
            }
            Button((showMore ? "Show less" : "Show more").loc) { withAnimation(.easeOut(duration: 0.2)) { showMore.toggle() } }
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private var gradients: some View {
        LazyVGrid(columns: grid5, spacing: 5) {
            ForEach(BackgroundSettings.gradients.indices, id: \.self) { i in
                let g = BackgroundSettings.gradients[i]
                tile(.gradient(i), "Gradient", height: 30) {
                    LinearGradient(colors: g.map { Color(nsColor: NSColor(hex: $0)) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
    }

    private var colors: some View {
        LazyVGrid(columns: grid5, spacing: 5) {
            ForEach(BackgroundSettings.solids, id: \.self) { hex in
                tile(.solid(hex), hex, height: 30) { Color(nsColor: NSColor(hex: hex)) }
            }
            customColorTile
        }
    }

    /// A colour well tile: selected when the current fill is a solid colour not in the list.
    private var customColorTile: some View {
        let current: String? = { if case .solid(let h) = bg.fill, !BackgroundSettings.solids.contains(h) { return h }; return nil }()
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
            if let current { RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: NSColor(hex: current))).padding(5) }
            ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hex: current ?? "#FFFFFF")) },
                                               set: { fill.wrappedValue = .solid(NSColor($0).hexString) }), supportsOpacity: false)
                .labelsHidden()
                .opacity(0.02)
        }
        .frame(height: 30)
        .overlay(selection(current != nil))
        .help("Custom color")
    }

    private var customImages: some View {
        LazyVGrid(columns: grid3, spacing: 6) {
            ForEach(custom, id: \.self) { name in
                imageTile(.custom(name), "Your image")
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            if bg.fill == .custom(name) { fill.wrappedValue = .builtin(0) }
                            Backgrounds.removeCustom(name)
                            custom = Backgrounds.customNames()
                        }
                    }
            }
            Button { addCustom() } label: {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    .foregroundStyle(dropTarget ? Color.accentColor : Color.secondary.opacity(0.6))
                    .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                    .frame(height: 54)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add an image… (or drop one here)")
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTarget) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        DispatchQueue.main.async { addImages([url]) }
                    }
                }
                return true
            }
        }
    }

    private func addCustom() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addImages(panel.urls)
    }

    private func addImages(_ urls: [URL]) {
        let names = Backgrounds.addCustom(urls)
        custom = Backgrounds.customNames()
        if let last = names.last { fill.wrappedValue = .custom(last) }
    }

    // MARK: Tiles

    private func selection(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-2).opacity(on ? 1 : 0)
    }

    private func tile<V: View>(_ f: BackgroundSettings.Fill, _ help: String, height: CGFloat = 54, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            .overlay(selection(bg.fill == f))
            .contentShape(Rectangle())
            .onTapGesture { presetID = nil; fill.wrappedValue = f }
            .help(help.loc)
    }

    private func imageTile(_ f: BackgroundSettings.Fill, _ help: String) -> some View {
        tile(f, help) {
            if let img = Backgrounds.thumbnail(f, screenshot: editor.doc.image) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.2).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
    }


}

/// Padding / inset / corners / shadow / alignment / ratio. Observes the background on its own, so dragging a slider
/// re-renders only these controls — not the thumbnail grids.
struct BackgroundControls: View {
    let editor: AnnotateEditor
    @ObservedObject var state: BackgroundState
    private var bg: BackgroundSettings { state.bg }

    var body: some View { controls }

    // MARK: Frame controls

    private func slider(_ title: String, _ kp: WritableKeyPath<BackgroundSettings, CGFloat>, _ range: ClosedRange<CGFloat>, percent: Bool = false) -> some View {
        let v = editor.background(kp)
        return HStack(spacing: 8) {
            Text(title.loc).frame(width: 58, alignment: .leading).foregroundStyle(.secondary)
            Slider(value: v, in: range)
            Text(percent ? "\(Int((v.wrappedValue * 100).rounded()))%" : "\(Int(v.wrappedValue.rounded()))")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider("Padding", \.padding, 0 ... 300)
            slider("Inset", \.inset, 0 ... 120)
            Toggle(isOn: editor.background(\.autoBalance)) {
                Text("Auto-balance")
                Text("Evens out the screenshot's own margins.")
            }
            .toggleStyle(.checkbox)
            slider("Corners", \.cornerRadius, 0 ... 60)
            slider("Shadow", \.shadow, 0 ... 1, percent: true)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Alignment").foregroundStyle(.secondary)
                    AlignmentGrid(selection: editor.background(\.alignment))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ratio").foregroundStyle(.secondary)
                    Picker("", selection: editor.background(\.ratio)) {
                        ForEach(AspectRatio.allCases, id: \.self) { Text($0.title.loc).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    if bg.ratio == .custom {
                        HStack(spacing: 4) {
                            ratioField(\.width)
                            Text(":")
                            ratioField(\.height)
                        }
                    }
                }
            }
            if !bg.isActive {
                Text("Pick a background to frame the screenshot.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .disabled(!bg.isActive)
    }

    private func ratioField(_ kp: WritableKeyPath<CGSize, CGFloat>) -> some View {
        let b = editor.background(\.customRatio)
        return TextField("", value: Binding(get: { Double(b.wrappedValue[keyPath: kp]) }, set: { var s = b.wrappedValue; s[keyPath: kp] = CGFloat(max(0.01, $0)); b.wrappedValue = s }),
                         format: .number.precision(.fractionLength(0 ... 2)))
            .frame(width: 40)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
    }
}

/// The document's background, published on its own so slider drags re-render only the background sidebar.
@MainActor
final class BackgroundState: ObservableObject {
    @Published var bg: BackgroundSettings
    /// Just the fill, for the thumbnail grids (selection highlight).
    let fill: FillState
    init(_ bg: BackgroundSettings) { self.bg = bg; fill = FillState(bg.fill) }
}

@MainActor
final class FillState: ObservableObject {
    @Published var fill: BackgroundSettings.Fill
    init(_ fill: BackgroundSettings.Fill) { self.fill = fill }
}
