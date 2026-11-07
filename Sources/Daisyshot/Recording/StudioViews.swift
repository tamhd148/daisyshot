import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum StudioTheme {
    static let windowNS = NSColor(hex: "#1B1B1D")
    static let timelineNS = NSColor(hex: "#151517")
    static let accentNS = NSColor(hex: "#FFC53D")
    static let zoomNS = NSColor(hex: "#7B61FF")
    static let maskNS = NSColor(hex: "#E5487A")
    static let typingNS = NSColor(hex: "#4A86FF")      // Daisyshot accent (sky)
    static let cameraNS = NSColor(hex: "#2FA57A")      // Daisyshot leaf
    static let camera = Color(nsColor: cameraNS)
    static let typing = Color(nsColor: typingNS)
    static let window = Color(nsColor: windowNS)
    static let sidebar = Color(nsColor: NSColor(hex: "#222225"))
    static let stage = Color(nsColor: NSColor(hex: "#111113"))
    static let accent = Color(nsColor: accentNS)
    static let zoom = Color(nsColor: zoomNS)
    static let mask = Color(nsColor: maskNS)
    static let control = Color.white.opacity(0.07)

    static let scissorsCursor: NSCursor = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        guard let sym = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return .crosshair }
        let img = NSImage(size: CGSize(width: 22, height: 22), flipped: false) { r in
            let s = sym.size
            let rect = CGRect(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2, width: s.width, height: s.height)
            NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 2, color: NSColor.black.cgColor)
            sym.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return NSCursor(image: img, hotSpot: CGPoint(x: 11, y: 11))
    }()
}

private func hexColor(_ hex: String) -> Color { Color(nsColor: NSColor(hex: hex)) }

// MARK: - Root

struct StudioEditorView: View {
    @ObservedObject var editor: StudioEditor
    let clock: StudioClock
    // Timeline track visibility (the View menu): read here so the timeline's height follows them.
    @AppStorage(Prefs.Key.studioShowTyping) private var showTyping: Bool
    @AppStorage(Prefs.Key.studioShowZooms) private var showZooms: Bool
    @AppStorage(Prefs.Key.studioShowMasks) private var showMasks: Bool
    @AppStorage(Prefs.Key.studioShowLayouts) private var showLayouts: Bool
    @AppStorage(Prefs.Key.studioShowKeys) private var showKeys: Bool

    var body: some View {
        VStack(spacing: 0) {
            StudioTopBar(editor: editor)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ViewHost(view: editor.preview)
                        .background(StudioTheme.stage)
                        .overlay { status }
                    StudioTransportBar(editor: editor, clock: clock)
                }
                if !editor.previewOnly, !editor.hideSidebar {
                    Rectangle().fill(Color.black.opacity(0.5)).frame(width: 1)
                    StudioSidebar(editor: editor)
                        .frame(width: 300)
                        .background(StudioTheme.sidebar)
                }
            }
            if !editor.previewOnly, !editor.hideTimeline {
                Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1)
                ViewHost(view: editor.timeline)
                    .frame(height: timelineHeight)
            }
        }
        .background(StudioTheme.window)
        .ignoresSafeArea()
        .sheet(isPresented: $editor.showExport) { StudioExportSheet(editor: editor) }
        .sheet(isPresented: $editor.showShortcutsGuide) { ShortcutsGuide(editor: editor) }
        .sheet(isPresented: $editor.showCrop) { CropSheet(editor: editor) }
    }

    /// Reads the track switches so a change re-lays out the timeline.
    private var timelineHeight: CGFloat {
        _ = (showTyping, showZooms, showMasks, showLayouts, showKeys, editor.doc.keystrokes.show)
        return editor.timeline.preferredHeight
    }

    @ViewBuilder private var status: some View {
        if editor.sources == nil {
            ProgressView().controlSize(.large)
        }
    }
}

/// Hosts an existing AppKit view (the editor owns the instances so it can poke them directly).
struct ViewHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Top bar

struct StudioTopBar: View {
    @ObservedObject var editor: StudioEditor

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                Image(systemName: editor.isStudio ? "film.stack" : "film").foregroundStyle(.secondary)
                Menu {
                    if editor.isStudio {
                        Button("Rename…") { editor.renameProject() }
                        Button("Save a Copy As…") { editor.saveCopyAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                        Button("Copy and Zip Project…") { editor.zipProject() }
                        Button("Extract Raw Recording Files…") { StudioProjects.extractRawFiles(editor.package.url) }
                        Divider()
                    }
                    Button("Show in Finder") { editor.showInFinder() }.keyboardShortcut("o", modifiers: [.command, .shift])
                    if !editor.isStudio {
                        Button("Create Project from This Video") { StudioProjects.createProject(from: editor.package.videoURL) }
                            .help("A Studio project around a copy of this video: background, zooms, camera layouts, music, saved as you go")
                    }
                    let recent = StudioEditor.clipboardExports
                    if !recent.isEmpty {
                        Menu("Recent Clipboard Exports") {
                            ForEach(recent, id: \.self) { url in
                                Menu(url.lastPathComponent) {
                                    Button("Copy Again") { Exporter.copyFile(url); Toast.show("Copied to clipboard") }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                            }
                        }
                    }
                    if editor.isStudio {
                        Divider()
                        Button("Delete Project…") { editor.removeProject() }
                    }
                } label: {
                    Text(editor.package.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Project")
                if editor.dirty, !editor.isStudio {
                    Text("Edited").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.1))).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 420)
            HStack(spacing: 4) {
                StudioIconButton(symbol: "folder", help: "Show in Finder (⇧⌘O)", action: editor.showInFinder)
                if editor.isStudio {
                    StudioIconButton(symbol: "trash", help: "Delete Project", action: editor.removeProject)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Spacer()
                StudioIconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", action: editor.undo).disabled(!editor.canUndo)
                StudioIconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: editor.redo).disabled(!editor.canRedo)
                StudioIconButton(symbol: "camera.viewfinder", help: EditorShortcuts.help("Export Current Frame as Image", "video.exportFrame"), action: editor.exportCurrentFrame)
                    .disabled(editor.sources == nil)
                PresetsMenu(editor: editor).disabled(editor.sources == nil)
                Button { editor.showExport = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(StudioTheme.accent))
                        .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .disabled(editor.sources == nil)
                .overlay(alignment: .topTrailing) {
                    // Exporting in the background: a small ring on the button (clicking it shows the progress).
                    if let p = editor.exportProgress, !editor.showExport {
                        ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini).offset(x: 6, y: -6)
                    }
                }
                .help(EditorShortcuts.help("Export", "video.export"))
            }
            .padding(.trailing, 12)
        }
        .frame(height: 44)
        .padding(.leading, 80)
        .background(StudioTheme.window)
        .gesture(WindowDragGesture())
    }
}

struct StudioIconButton: View {
    let symbol: String
    var help = ""
    var active = false
    var size: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.white.opacity(0.16) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.white : Color.white.opacity(0.75))
        .help(help.loc)
    }
}

// MARK: - Transport

struct StudioTransportBar: View {
    @ObservedObject var editor: StudioEditor
    @ObservedObject var clock: StudioClock

    private func fmt(_ t: Double) -> String {
        let m = Int(t) / 60, s = t - Double(m * 60)
        return String(format: "%d:%05.2f", m, s)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("\(fmt(clock.time)) / \(fmt(editor.duration))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Spacer()
            StudioIconButton(symbol: "backward.end.fill", help: EditorShortcuts.help("Previous Clip Edge", "video.previousEdge")) { editor.jumpEdge(forward: false) }
            StudioIconButton(symbol: "chevron.left", help: EditorShortcuts.help("Previous Frame", "video.previousFrame")) { editor.step(-1) }
            Button(action: editor.togglePlay) {
                Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15))
                    .frame(width: 36, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain).help(EditorShortcuts.help("Play / Pause", "video.playPause"))
            StudioIconButton(symbol: "chevron.right", help: EditorShortcuts.help("Next Frame", "video.nextFrame")) { editor.step(1) }
            StudioIconButton(symbol: "forward.end.fill", help: EditorShortcuts.help("Next Clip Edge", "video.nextEdge")) { editor.jumpEdge(forward: true) }
            StudioIconButton(symbol: "repeat", help: EditorShortcuts.help("Loop Playback", "video.loop"), active: editor.loopPlayback) { editor.loopPlayback.toggle() }
            Spacer()
            HStack(spacing: 2) {
                StudioIconButton(symbol: "cursorarrow", help: EditorShortcuts.help("Selection Tool", "video.selectionTool"), active: editor.tool == .select) { editor.tool = .select }
                StudioIconButton(symbol: "scissors", help: EditorShortcuts.help("Cut Tool", "video.cutTool"), active: editor.tool == .cut) { editor.tool = .cut }
            }
            .padding(2).background(RoundedRectangle(cornerRadius: 8).fill(StudioTheme.control))
            StudioIconButton(symbol: "square.split.2x1", help: EditorShortcuts.help("Split Clip at Playhead", "video.splitClip"), action: editor.splitAtPlayhead)
            StudioIconButton(symbol: "trash", help: "Delete Selection (⌫)", action: editor.deleteSelection).disabled(editor.selection == nil)
            Divider().frame(height: 18).padding(.horizontal, 4)
            StudioIconButton(symbol: "minus.magnifyingglass", help: EditorShortcuts.help("Zoom Timeline Out", "video.zoomOut")) { editor.timeline.zoom(by: 1 / 1.5) }
            StudioIconButton(symbol: "plus.magnifyingglass", help: EditorShortcuts.help("Zoom Timeline In", "video.zoomIn")) { editor.timeline.zoom(by: 1.5) }
            StudioIconButton(symbol: "arrow.left.and.right", help: EditorShortcuts.help("Fit Timeline to View", "video.fitTimeline")) { editor.timeline.zoomToFit() }
            TimelineViewMenu(editor: editor)
            StudioIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: EditorShortcuts.help("Toggle Full Screen", "video.fullScreen")) { editor.preview.window?.toggleFullScreen(nil) }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(StudioTheme.window)
        .disabled(editor.sources == nil)
    }
}

/// Style presets: apply one, save the current look, import / export / delete preset files.
private struct PresetsMenu: View {
    @ObservedObject var editor: StudioEditor

    var body: some View {
        let presets = StudioPresets.all()
        Menu {
            if presets.isEmpty {
                Text("No presets yet")
            } else {
                // ✓ marks a preset the project's look matches exactly.
                ForEach(presets, id: \.url) { p in
                    let matches = StudioPresets.load(p.url).map { StudioPresets.apply($0, to: editor.doc) == editor.doc } ?? false
                    Toggle(p.name, isOn: Binding(get: { matches }, set: { _ in editor.applyPreset(p.url) }))
                }
            }
            Divider()
            Button("Save Style as Preset…") { editor.savePreset() }
            Button("Import Preset…") { editor.importPreset() }
            if !presets.isEmpty {
                Menu("Update Preset to This Style") { ForEach(presets, id: \.url) { p in Button(p.name) { editor.updatePreset(p.url) } } }
                Menu("Default for New Projects") {
                    let current = Prefs.string(.studioDefaultPreset)
                    Toggle("Last Used Style", isOn: Binding(get: { current.isEmpty }, set: { _ in Prefs.set("", .studioDefaultPreset) }))
                    ForEach(presets, id: \.url) { p in
                        Toggle(p.name, isOn: Binding(get: { current == p.name }, set: { _ in Prefs.set(p.name, .studioDefaultPreset) }))
                    }
                }
                Menu("Export Preset") { ForEach(presets, id: \.url) { p in Button(p.name) { editor.exportPreset(p.url) } } }
                Menu("Delete Preset") { ForEach(presets, id: \.url) { p in Button(p.name) { editor.deletePreset(p.url) } } }
            }
            Divider()
            Button("Show Presets in Finder") { NSWorkspace.shared.open(StudioPresets.folder) }
        } label: {
            Image(systemName: "swatchpalette").font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 30, height: 28)
        .help("Style Presets")
    }
}

/// Crop the recording: drag the frame (or its corners) over a frame from the playhead; ratio presets.
private struct CropSheet: View {
    @ObservedObject var editor: StudioEditor
    @State private var crop = StudioDocument.Crop()
    @State private var image: CGImage?
    @State private var ratio: Double?            // nil = free
    @State private var drag: (start: StudioDocument.Crop, corner: Int?)?
    @State private var custom = false
    @State private var customW = 3.0
    @State private var customH = 2.0

    private static let ratios: [(String, Double?)] = [("Free", nil), ("16:9", 16 / 9), ("4:3", 4 / 3), ("1:1", 1), ("4:5", 4 / 5), ("9:16", 9 / 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crop Recording").font(.headline)
            GeometryReader { g in
                let s = g.size
                let r = CGRect(x: crop.x * s.width, y: crop.y * s.height, width: crop.width * s.width, height: crop.height * s.height)
                ZStack(alignment: .topLeading) {
                    if let image { Image(decorative: image, scale: 1).resizable() } else { Color.white.opacity(0.06) }
                    Color.black.opacity(0.5)
                        .mask(Rectangle().overlay(Rectangle().frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY).blendMode(.destinationOut)).compositingGroup())
                    Rectangle().strokeBorder(Color.white, lineWidth: 1.5).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(.white).frame(width: 10, height: 10)
                            .position(x: i % 2 == 0 ? r.minX : r.maxX, y: i < 2 ? r.minY : r.maxY)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    if drag == nil {
                        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
                        let c = corners.firstIndex { hypot($0.x - v.startLocation.x, $0.y - v.startLocation.y) < 14 }
                        drag = (crop, c)
                    }
                    guard let d = drag else { return }
                    let dx = v.translation.width / s.width, dy = v.translation.height / s.height
                    var c = d.start
                    if let corner = d.corner {
                        var x0 = c.x, y0 = c.y, x1 = c.x + c.width, y1 = c.y + c.height
                        if corner % 2 == 0 { x0 += dx } else { x1 += dx }
                        if corner < 2 { y0 += dy } else { y1 += dy }
                        x0 = max(0, min(x0, x1 - 0.05)); x1 = min(1, max(x1, x0 + 0.05))
                        y0 = max(0, min(y0, y1 - 0.05)); y1 = min(1, max(y1, y0 + 0.05))
                        c = .init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                        if let ratio { c = fit(c, ratio: ratio, anchor: corner, size: s) }
                    } else {
                        c.x = min(max(0, d.start.x + dx), 1 - c.width)
                        c.y = min(max(0, d.start.y + dy), 1 - c.height)
                    }
                    crop = c
                }.onEnded { _ in drag = nil })
            }
            .aspectRatio(editor.sourceAspect, contentMode: .fit)
            .frame(maxWidth: 640, maxHeight: 420)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Picker("Ratio", selection: Binding(get: { custom ? Self.ratios.count : Self.ratios.firstIndex { $0.1 == ratio } ?? 0 }, set: { i in
                    custom = i == Self.ratios.count
                    setRatio(custom ? customW / customH : Self.ratios[i].1)
                })) {
                    ForEach(Self.ratios.indices, id: \.self) { i in Text(Self.ratios[i].0.loc).tag(i) }
                    Text("Custom").tag(Self.ratios.count)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if custom {
                    number($customW, width: 38) { _ in setRatio(customW / customH) }
                    Text(verbatim: ":")
                    number($customH, width: 38) { _ in setRatio(customW / customH) }
                }
                Spacer()
            }
            // Exact position and size, in the recording's pixels.
            HStack(spacing: 6) {
                ForEach(Array(["X", "Y", "W", "H"].enumerated()), id: \.offset) { i, label in
                    Text(verbatim: label).font(.system(size: 11)).foregroundStyle(.secondary)
                    number(pixelBinding(i), width: 58) { _ in }
                }
                Spacer()
                Text(pixels).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Button("Reset") { crop = .init(); ratio = nil; custom = false }
                Spacer()
                Button("Cancel") { editor.showCrop = false }.keyboardShortcut(.cancelAction)
                Button("Crop") {
                    editor.edit { $0.crop = crop }
                    editor.showCrop = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680)
        .onAppear {
            crop = editor.doc.crop
            image = editor.thumbnail(atSource: editor.doc.sourceTime(editor.clock.time))
            Task { if let f = await editor.sourceFrame(at: editor.doc.sourceTime(editor.clock.time)) { image = f } }
        }
    }

    private func setRatio(_ r: Double?) {
        ratio = r.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let ratio { crop = fit(crop, ratio: ratio, anchor: 0, size: CGSize(width: editor.sourceAspect, height: 1)) }
    }

    private func number(_ value: Binding<Double>, width: CGFloat, changed: @escaping (Double) -> Void) -> some View {
        TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder).frame(width: width).monospacedDigit()
            .onSubmit { changed(value.wrappedValue) }
    }

    /// X, Y, W, H (index 0…3) in source pixels; typing one keeps the crop inside the picture (W / H follow the ratio).
    private func pixelBinding(_ i: Int) -> Binding<Double> {
        let s = editor.sources?.size ?? CGSize(width: 1, height: 1)
        return Binding(get: {
            [crop.x * s.width, crop.y * s.height, crop.width * s.width, crop.height * s.height][i].rounded()
        }, set: { v in
            var c = crop
            switch i {
            case 0: c.x = v / s.width
            case 1: c.y = v / s.height
            case 2: c.width = v / s.width; if let ratio { c.height = c.width * s.width / ratio / s.height }
            default: c.height = v / s.height; if let ratio { c.width = c.height * s.height * ratio / s.width }
            }
            c.width = min(1, max(0.05, c.width)); c.height = min(1, max(0.05, c.height))
            c.x = min(max(0, c.x), 1 - c.width); c.y = min(max(0, c.y), 1 - c.height)
            crop = c
        })
    }

    private var pixels: String {
        let s = editor.sources?.size ?? .zero
        return "\(Int(crop.width * s.width)) × \(Int(crop.height * s.height))"
    }

    /// Reshapes `c` to `ratio` (width / height in pixels), keeping the corner opposite `anchor` in place, inside the picture.
    private func fit(_ c: StudioDocument.Crop, ratio: Double, anchor: Int, size: CGSize) -> StudioDocument.Crop {
        let aspect = size.width / max(1, size.height)           // picture width / height
        var w = c.width, h = w * aspect / ratio                  // normalized height that gives `ratio`
        if h > 1 { h = 1; w = h * ratio / aspect }
        var x = anchor % 2 == 0 ? c.x + c.width - w : c.x
        var y = anchor < 2 ? c.y + c.height - h : c.y
        x = min(max(0, x), 1 - w); y = min(max(0, y), 1 - h)
        return .init(x: x, y: y, width: w, height: h)
    }
}

/// ⌘/: every editor shortcut, searchable — the remappable ones with their current keys, and the fixed ones.
private struct ShortcutsGuide: View {
    @ObservedObject var editor: StudioEditor
    @State private var query = ""

    private var rows: [(String, String)] {
        let mapped = EditorShortcuts.video.map { ($0.title.loc, EditorShortcuts.shortcut($0.id)?.display ?? "—") }
        let fixed: [(String, String)] = [
            ("Undo".loc, "⌘Z"), ("Redo".loc, "⇧⌘Z"), ("Delete Selection".loc, "⌫"), ("Deselect / Leave Cut Tool / Leave Preview Only".loc, "Esc"),
            ("Copy (Current Frame When Nothing Is Selected)".loc, "⌘C"), ("Cut".loc, "⌘X"), ("Paste".loc, "⌘V"), ("Duplicate".loc, "⌘D"),
            ("Open Sidebar Tabs".loc, "⌘1 … ⌘7"), ("Zoom Timeline".loc, "⌘ / ⌥ + scroll, pinch"), ("Keyboard Shortcuts".loc, "⌘/"),
        ]
        let all = mapped + fixed
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.0.lowercased().contains(q) || $0.1.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard Shortcuts").font(.headline)
                Spacer()
                Button("Edit in Settings…") { SettingsWindow.show(tab: "shortcuts"); editor.showShortcutsGuide = false }
            }
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            List(rows, id: \.0) { r in
                HStack {
                    Text(r.0)
                    Spacer()
                    Text(r.1).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 380)
            HStack {
                Spacer()
                Button("Done") { editor.showShortcutsGuide = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Which timeline tracks show, the waveform, and audio while scrubbing.
private struct TimelineViewMenu: View {
    @ObservedObject var editor: StudioEditor
    @AppStorage(Prefs.Key.studioShowTyping) private var typing: Bool
    @AppStorage(Prefs.Key.studioShowZooms) private var zooms: Bool
    @AppStorage(Prefs.Key.studioShowMasks) private var masks: Bool
    @AppStorage(Prefs.Key.studioShowLayouts) private var layouts: Bool
    @AppStorage(Prefs.Key.studioShowKeys) private var keys: Bool
    @AppStorage(Prefs.Key.studioShowWaveform) private var waveform: Bool
    @AppStorage(Prefs.Key.studioAudioScrub) private var scrub: Bool

    var body: some View {
        Menu {
            Section("Tracks") {
                Toggle("Typing", isOn: redraw($typing))
                if editor.hasKeys { Toggle("Keystrokes", isOn: redraw($keys)) }
                Toggle("Zooms", isOn: redraw($zooms))
                Toggle("Masks", isOn: redraw($masks))
                if editor.hasCamera { Toggle("Camera Layouts", isOn: redraw($layouts)) }
            }
            Toggle("Waveform", isOn: redraw($waveform))
            Toggle("Audio While Scrubbing", isOn: $scrub)
            Divider()
            Picker("Preview Quality", selection: Binding(get: { Prefs.int(.studioPreviewQuality) }, set: { editor.setPreviewQuality($0) })) {
                Text("Full").tag(0)
                Text("Balanced").tag(1)
                Text("Power Saving").tag(2)
            }
            Toggle("Sidebar", isOn: Binding(get: { !editor.hideSidebar }, set: { editor.hideSidebar = !$0 }))
            Toggle("Timeline", isOn: Binding(get: { !editor.hideTimeline }, set: { editor.hideTimeline = !$0 }))
            Toggle("Preview Only", isOn: $editor.previewOnly)
            Divider()
            Button("Keyboard Shortcuts…") { editor.showShortcutsGuide = true }
        } label: {
            Image(systemName: "rectangle.split.3x1").font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 28)
        .help("Timeline View")
    }

    private func redraw(_ b: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { b.wrappedValue }, set: { b.wrappedValue = $0; editor.timeline.needsDisplay = true })
    }
}

// MARK: - Sidebar

struct StudioSidebar: View {
    @ObservedObject var editor: StudioEditor

    var body: some View {
        VStack(spacing: 0) {
            if let layout = editor.selectedLayout {
                CameraLayoutInspector(editor: editor, layout: layout)
            } else if let zoom = editor.selectedZoom {
                ZoomInspector(editor: editor, zoom: zoom)
            } else if let mask = editor.selectedMask {
                MaskInspector(editor: editor, mask: mask).id(mask.id)
            } else if let clip = editor.selectedClip {
                ClipInspector(editor: editor, clip: clip)
            } else {
                HStack(spacing: 2) {
                    ForEach(StudioEditor.Tab.allCases) { tab in
                        StudioIconButton(symbol: tab.symbol, help: tab.title, active: editor.tab == tab, size: 14) { editor.tab = tab }
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 9).fill(StudioTheme.control))
                .padding(12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { pane }
                        .padding(.horizontal, 16).padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .controlSize(.small)
        .disabled(editor.sources == nil)
    }

    @ViewBuilder private var pane: some View {
        switch editor.tab {
        case .cursor: CursorPane(editor: editor)
        case .keystrokes: KeystrokesPane(editor: editor)
        case .audio: AudioPane(editor: editor)
        case .camera: CameraPane(editor: editor)
        case .background: BackgroundPane(editor: editor)
        case .animations: AnimationsPane(editor: editor)
        case .masks: MasksPane(editor: editor)
        }
    }
}

// MARK: Building blocks

private struct PaneHeader: View {
    let title: String
    var isOn: Binding<Bool>?
    var body: some View {
        HStack {
            Text(title.loc).font(.system(size: 15, weight: .bold))
            Spacer()
            if let isOn { Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden() }
        }
        .padding(.top, 2)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.loc).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
}

/// With `live`, a drag only previews (`live` gets each value, the slider keeps its own) and `value` is set once, on
/// release — so the editor isn't redrawn on every tick. Keyboard / accessibility changes set `value` directly.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var live: ((Double) -> Void)?
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    @State private var draft: Double?
    @State private var dragging = false

    var body: some View {
        let shown = draft ?? value
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Caption(title)
                Spacer()
                Text(format(shown)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { shown }, set: { v in
                if let live, dragging { draft = v; live(v) } else { value = v }
            }), in: range, onEditingChanged: { editing in
                dragging = editing
                if !editing, let d = draft {
                    draft = nil
                    value = d
                }
            })
        }
    }
}

private struct EmptyPane: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(title.loc).font(.system(size: 13, weight: .semibold))
            Text(message.loc).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 8)
    }
}

private let studioOnly = "Record with Studio Mode to edit the cursor, keystrokes and camera after recording."

/// 3×3 placement grid (row-major, top-left origin).
private struct PositionGrid: View {
    let selected: Int?
    let pick: (Int) -> Void
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { col in
                        let i = row * 3 + col
                        Button { pick(i) } label: {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selected == i ? StudioTheme.accent : Color.white.opacity(0.1))
                                .frame(width: 34, height: 22)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioTheme.control))
    }
}

private struct Swatch<Content: View>: View {
    let selected: Bool
    var help = ""
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? StudioTheme.accent : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(help.loc)
    }
}

// MARK: Cursor

private struct CursorPane: View {
    @ObservedObject var editor: StudioEditor
    static let movement = [("None", 0.0), ("Rapid", 0.3), ("Medium", 0.6), ("Smooth", 0.85)]

    var body: some View {
        if !editor.isStudio {
            EmptyPane(symbol: "cursorarrow.rays", title: "Cursor effects", message: studioOnly)
        } else if !editor.hasPointer {
            EmptyPane(symbol: "cursorarrow.slash", title: "No cursor data",
                      message: editor.events?.cursorVisibleInVideo == true ? "The cursor was recorded into the video, so it can't be restyled." : "No pointer movement was recorded.")
        } else {
            let c = editor.doc.cursor
            PaneHeader(title: "Cursor", isOn: editor.binding(\.cursor.show))
            if let i = editor.doc.clipIndex(at: editor.clock.time), editor.doc.clips[i].hideCursor {
                let id = editor.doc.clips[i].id
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The cursor is hidden in this clip, so changes here don't show at the playhead.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Show Cursor in This Clip") { editor.editClip(id) { $0.hideCursor = false } }
                    }
                } icon: {
                    Image(systemName: "eye.slash").foregroundStyle(.orange)
                }
                .font(.system(size: 11))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
            }
            Group {
                SliderRow(title: "Size", value: editor.binding(\.cursor.size), range: 0.5...4, live: editor.live(\.cursor.size)) { String(format: "%.1f×", $0) }
                Caption("Style")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
                    ForEach(CursorStyle.allCases) { s in
                        Swatch(selected: c.style == s, help: s.title, action: { editor.edit { $0.cursor.style = s } }) {
                            ZStack {
                                Color.white.opacity(0.85)
                                Image(nsImage: StudioSprites.cursorPreview(s)).resizable().aspectRatio(contentMode: .fit).padding(6)
                            }
                        }
                    }
                }
                if !(editor.sources?.cursorShapes.isEmpty ?? true) {
                    Toggle("Real cursor shapes", isOn: editor.binding(\.cursor.realShapes))
                        .disabled(!c.style.showsShapes)
                        .help("Shows the I-beam, pointing hand and other cursors as they appeared while recording.")
                    if c.realShapes, c.style.showsShapes {
                        Toggle("Steady cursor shapes", isOn: editor.binding(\.cursor.steadyShapes))
                            .help("Skips shapes shown for less than 0.2 s, so the cursor doesn't flicker passing over buttons and edges.")
                    }
                }
                Caption("Cursor animation")
                // Presets; the slider below fine-tunes (then no preset is highlighted).
                Picker("", selection: Binding(get: { Self.movement.first { abs($0.1 - c.smoothing) < 0.01 }?.1 ?? -1 },
                                              set: { v in editor.edit { $0.cursor.smoothing = v } })) {
                    ForEach(Self.movement, id: \.1) { Text($0.0.loc).tag($0.1) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("None follows the pointer exactly; Rapid to Smooth glide more and more")
                if c.smoothing > 0.001 {
                    SliderRow(title: "Smoothness", value: editor.binding(\.cursor.smoothing), range: 0.1...1, live: editor.live(\.cursor.smoothing)) { "\(Int($0 * 100))%" }
                }
                Caption("Click effect")
                Toggle("Press effect", isOn: editor.binding(\.cursor.pressEffect))
                Toggle("Ripple animation", isOn: editor.binding(\.cursor.ripple))
                if c.ripple {
                    HStack(spacing: 7) {
                        ForEach(ClickColor.allCases) { col in
                            Button { editor.edit { $0.cursor.rippleColor = col } } label: {
                                Circle().fill(hexColor(col.hex)).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color.white, lineWidth: c.rippleColor == col ? 2 : 0))
                            }
                            .buttonStyle(.plain).help(col.rawValue.capitalized.loc)
                        }
                    }
                    Picker("", selection: editor.binding(\.cursor.rippleFilled)) {
                        Text("Outline").tag(false)
                        Text("Filled").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                Divider()
                Toggle("Hide cursor when not moving", isOn: editor.binding(\.cursor.hideWhenIdle))
                if c.hideWhenIdle {
                    SliderRow(title: "Hide after", value: editor.binding(\.cursor.idleDelay), range: 0.5...5, live: editor.live(\.cursor.idleDelay)) { "%.1f s".loc($0) }
                }
                Toggle("Hide cursor when typing", isOn: editor.binding(\.cursor.hideWhenTyping)).disabled(!editor.hasKeys)
                Divider()
                SliderRow(title: "Tilt while moving", value: editor.binding(\.cursor.tilt), range: 0...1, live: editor.live(\.cursor.tilt)) { $0 < 0.01 ? "Off".loc : "\(Int($0 * 100))%" }
                HStack {
                    Toggle("Click sounds", isOn: editor.binding(\.cursor.clickSound))
                        .help("Plays a soft click sound at every click (not in parts sped up past 2×)")
                    Spacer()
                    Button { Self.playClick(c.clickVolume) } label: { Image(systemName: "speaker.wave.2") }
                        .buttonStyle(.borderless).help("Play the click sound")
                }
                if editor.doc.cursor.clickSound {
                    SliderRow(title: "Click volume", value: editor.binding(\.cursor.clickVolume), range: 0...1.5, live: editor.live(\.cursor.clickVolume)) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                }
                Caption("Motion blur")
                Picker("", selection: editor.binding(\.cursor.motionBlur)) {
                    ForEach(MotionBlur.allCases, id: \.self) { Text($0.rawValue.capitalized.loc).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("Streaks the cursor when it moves fast")
                Toggle("Remove cursor jumps", isOn: editor.binding(\.cursor.removeJumps))
                    .help("Ignores a cursor that briefly jumps far away and back, as some accessibility and remote-control apps cause.")
                if c.removeJumps {
                    SliderRow(title: "Jump distance", value: editor.binding(\.cursor.jumpLimit), range: 100...1500, live: editor.live(\.cursor.jumpLimit)) { "\(Int($0)) pt" }
                }
                Toggle("Return to start at the end", isOn: editor.binding(\.cursor.loopToStart))
                    .help("At the end the cursor glides back to where it started, so a looping GIF doesn't jump.")
                if c.loopToStart {
                    SliderRow(title: "Over the last", value: editor.binding(\.cursor.loopDuration), range: 0.5...3, live: editor.live(\.cursor.loopDuration)) { "%.1f s".loc($0) }
                }
                SliderRow(title: "Hold still at the end", value: editor.binding(\.cursor.freezeAtEnd), range: 0...3, live: editor.live(\.cursor.freezeAtEnd)) {
                    $0 < 0.05 ? "Off".loc : "%.1f s".loc($0)
                }
                .help("Keeps the cursor from heading to the Stop button at the end of the recording.")
            }
            .disabled(!c.show)
            .opacity(c.show ? 1 : 0.45)
        }
    }
}

// MARK: Keystrokes

private struct KeystrokesPane: View {
    @ObservedObject var editor: StudioEditor

    var body: some View {
        if !editor.isStudio {
            EmptyPane(symbol: "keyboard", title: "Keystrokes", message: studioOnly)
        } else if !editor.hasKeys {
            EmptyPane(symbol: "keyboard.badge.ellipsis", title: "No keystrokes recorded",
                      message: "No keys were logged while recording. Daisyshot needs Accessibility access (System Settings › Privacy & Security › Accessibility) to see keystrokes — that's also how it finds typing to speed up.")
        } else {
            let k = editor.doc.keystrokes
            PaneHeader(title: "Keystrokes", isOn: editor.binding(\.keystrokes.show))
            Group {
                SliderRow(title: "Size", value: editor.binding(\.keystrokes.size), range: 0.5...2.5, live: editor.live(\.keystrokes.size)) { String(format: "%.1f×", $0) }
                Caption("Style")
                Picker("", selection: editor.binding(\.keystrokes.light)) {
                    Text("Dark").tag(false)
                    Text("Light").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                Caption("Position")
                PositionGrid(selected: k.position) { i in editor.edit { $0.keystrokes.position = i } }
                Caption("Display")
                Picker("", selection: editor.binding(\.keystrokes.allKeys)) {
                    Text("Shortcuts only (⌘ ⌃ ⌥)").tag(false)
                    Text("All keys").tag(true)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                let shortcuts = editor.events.map(KeyBadge.shortcuts) ?? []
                if !shortcuts.isEmpty {
                    Caption("Click a shortcut to hide it")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(shortcuts, id: \.self) { key in
                            let hidden = k.hidden.contains(key)
                            Button {
                                editor.edit { d in
                                    if let i = d.keystrokes.hidden.firstIndex(of: key) { d.keystrokes.hidden.remove(at: i) } else { d.keystrokes.hidden.append(key) }
                                }
                            } label: {
                                Text(verbatim: key).font(.system(size: 11, weight: .medium)).strikethrough(hidden).lineLimit(1)
                                    .frame(maxWidth: .infinity).frame(height: 22)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(StudioTheme.control))
                                    .opacity(hidden ? 0.4 : 1)
                            }
                            .buttonStyle(.plain)
                            .help((hidden ? "Show this shortcut" : "Hide this shortcut").loc)
                        }
                    }
                }
            }
            .disabled(!k.show)
            .opacity(k.show ? 1 : 0.45)
        }
    }
}

// MARK: Audio

private struct AudioPane: View {
    @ObservedObject var editor: StudioEditor

    /// Recorder order: system audio first, microphone second (events.json may say so explicitly).
    private func kind(_ i: Int, of n: Int) -> String {
        let kinds = editor.events?.audioTracks ?? (editor.isStudio && n == 2 ? ["system", "mic"] : [])
        return kinds.indices.contains(i) ? kinds[i] : ""
    }

    private func name(_ i: Int, of n: Int) -> String {
        if n == 1 { return "Audio".loc }
        switch kind(i, of: n) {
        case "system": return "System Audio".loc
        case "mic": return "Microphone".loc
        case "device": return "Device Audio".loc
        default: return "Track %d".loc(i + 1)
        }
    }

    var body: some View {
        let tracks = editor.sources?.audio.count ?? 0
        if tracks == 0 {
            EmptyPane(symbol: "speaker.slash", title: "No audio", message: "This recording has no audio tracks.")
            MusicSection(editor: editor)
        } else {
            PaneHeader(title: "Audio")
            ForEach(0..<tracks, id: \.self) { i in
                let a = editor.doc.audio
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: a.isMuted(i) ? "speaker.slash.fill" : "waveform").frame(width: 18).foregroundStyle(.secondary)
                        Text(name(i, of: tracks)).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Toggle("", isOn: Binding(get: { !a.isMuted(i) }, set: { v in editor.edit { $0.audio.setMuted(!v, i) } }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    if !a.isMuted(i) {
                        HStack {
                            Slider(value: Binding(get: { a.volume(i) }, set: { v in editor.edit(coalesce: "vol\(i)") { $0.audio.setVolume(v, i) } }), in: 0...2)
                            Text("\(Int(a.volume(i) * 100))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                        if kind(i, of: tracks) != "system" {   // voice isolation would strip music and app sounds
                            HStack {
                                Toggle("Reduce background noise", isOn: Binding(get: { a.denoises(i) }, set: { v in editor.edit { $0.audio.setDenoise(v, i) } }))
                                if editor.audioWork.contains(i) { ProgressView().controlSize(.mini) }
                            }
                        }
                        Toggle("Even out loudness", isOn: Binding(get: { a.normalizes(i) }, set: { v in editor.edit { $0.audio.setNormalize(v, i) } }))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(StudioTheme.control))
            }
            MusicSection(editor: editor)
            Toggle("Export audio in mono", isOn: editor.binding(\.audio.mono))
            Text("Mixes every track into a single channel, so a one-sided microphone plays from both speakers.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Background music: add / replace / remove a file, its volume and a fade-out at the end.
private struct MusicSection: View {
    @ObservedObject var editor: StudioEditor

    var body: some View {
        let m = editor.doc.music
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "music.note").frame(width: 18).foregroundStyle(.secondary)
                Text("Background Music").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !m.path.isEmpty {
                    Button { editor.edit { $0.music.muted.toggle() } } label: { Image(systemName: m.muted ? "speaker.slash.fill" : "speaker.wave.2") }
                        .buttonStyle(.plain).foregroundStyle(m.muted ? Color.orange : .secondary).help(m.muted ? "Unmute Music" : "Mute Music")
                    Button { editor.removeMusic() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove Music")
                }
            }
            if m.path.isEmpty {
                Button("Add Music…") { editor.chooseMusic() }
                Text("Loops under the whole video. Use music you have the rights to. You can also drop an audio file here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Button { editor.chooseMusic() } label: {
                    Text(editor.musicURL?.lastPathComponent ?? m.path).lineLimit(1).truncationMode(.middle)
                }
                .help("Choose Another File…")
                SliderRow(title: "Volume", value: editor.binding(\.music.volume), range: 0...1, live: editor.live(\.music.volume)) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                Toggle("Fade out at the end", isOn: editor.binding(\.music.fadeOut))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(StudioTheme.control))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first, p.canLoadObject(ofClass: URL.self) else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { editor.setMusic(url) }
            }
            return true
        }
    }
}

// MARK: Camera

private struct ShapeIcon: View {
    let shape: StudioCameraShape
    var body: some View {
        let a = shape.aspect
        let w: CGFloat = a >= 1 ? 22 : 22 * a, h: CGFloat = a >= 1 ? 22 / a : 22
        Group {
            switch shape {
            case .circle: Circle().frame(width: 20, height: 20)
            case .rounded: RoundedRectangle(cornerRadius: 6).frame(width: 20, height: 20)
            case .square: RoundedRectangle(cornerRadius: 1.5).frame(width: 20, height: 20)
            case .rectangle, .vertical: RoundedRectangle(cornerRadius: 3).frame(width: w, height: h)
            }
        }
        .foregroundStyle(Color.white.opacity(0.85))
    }
}

private struct CameraPane: View {
    @ObservedObject var editor: StudioEditor
    private let xs = [0.12, 0.5, 0.88], ys = [0.15, 0.5, 0.82]

    var body: some View {
        if !editor.isStudio {
            EmptyPane(symbol: "web.camera", title: "Camera", message: studioOnly)
        } else if !editor.hasCamera {
            EmptyPane(symbol: "video.slash", title: "No camera recorded", message: "Turn on the camera before recording in Studio Mode to show it here.")
        } else {
            let c = editor.doc.camera
            PaneHeader(title: "Camera", isOn: editor.binding(\.camera.show))
            Group {
                SliderRow(title: "Size", value: editor.binding(\.camera.size), range: 0.1...0.6, live: editor.live(\.camera.size)) { "\(Int($0 * 100))%" }
                Caption("Shape")
                HStack(spacing: 6) {
                    ForEach(StudioCameraShape.allCases) { s in
                        Swatch(selected: c.shape == s, help: s.title, action: { editor.edit { $0.camera.shape = s; $0.camera.roundness = -1 } }) {
                            ZStack { Color.white.opacity(0.06); ShapeIcon(shape: s) }
                        }
                    }
                }
                SliderRow(title: "Roundness", value: Binding(get: { c.effectiveRoundness }, set: { v in editor.edit(coalesce: "camRound") { $0.camera.roundness = v } }),
                          range: 0...1, live: { v in editor.previewEdit { $0.camera.roundness = v } }, format: { "\(Int(($0 * 100).rounded()))%" })
                Caption("Position")
                let sel = (0..<9).first { abs(xs[$0 % 3] - c.x) < 0.02 && abs(ys[$0 / 3] - c.y) < 0.02 }
                HStack(alignment: .top) {
                    PositionGrid(selected: sel) { i in editor.edit { $0.camera.x = xs[i % 3]; $0.camera.y = ys[i / 3] } }
                    Text(sel == nil ? "Custom position. Drag the camera in the preview to move it.".loc : "Or drag the camera in the preview.".loc)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Toggle("Mirror camera", isOn: editor.binding(\.camera.mirror))
                Caption("Camera layouts")
                Text("Show only the camera, only the screen, or the camera somewhere else for part of the video: click or drag on the camera track.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { editor.addLayout(editor.clock.time...(editor.clock.time + 3)) } label: { Label("Add at Playhead", systemImage: "plus") }
                    if !editor.doc.layouts.isEmpty {
                        let allOff = editor.doc.layouts.allSatisfy(\.disabled)
                        Button(allOff ? "Turn All On" : "Turn All Off") { editor.setAllLayoutsDisabled(!allOff) }
                        Button("Remove All", role: .destructive) { editor.removeAllLayouts() }
                    }
                }
                Toggle("Shrink camera on zoom", isOn: editor.binding(\.camera.shrinkOnZoom))
                if c.shrinkOnZoom {
                    SliderRow(title: "Size during zoom", value: editor.binding(\.camera.zoomSize), range: 0.3...1, live: editor.live(\.camera.zoomSize)) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                }
            }
            .disabled(!c.show)
            .opacity(c.show ? 1 : 0.45)
        }
    }
}

extension CursorPane {
    private static var clickPlayer: NSSound?
    static func playClick(_ volume: Double) {
        clickPlayer = NSSound(contentsOf: StudioClickSound.url, byReference: true)
        clickPlayer?.volume = Float(min(1, volume))
        clickPlayer?.play()
    }
}

// MARK: Background

private struct BackgroundPane: View {
    @ObservedObject var editor: StudioEditor
    private let cols = Array(repeating: GridItem(.fixed(38), spacing: 8), count: 6)

    private func set(_ change: @escaping (inout StudioDocument.Background) -> Void) { editor.edit { change(&$0.background) } }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a background image".loc
        guard panel.runModal() == .OK, let url = panel.url else { return }
        set { $0.kind = .image; $0.imagePath = url.path }
    }

    var body: some View {
        let b = editor.doc.background
        PaneHeader(title: "Background")
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            Swatch(selected: b.kind == .none, help: "None", action: { set { $0.kind = .none } }) {
                ZStack { Color.white.opacity(0.06); Image(systemName: "nosign").foregroundStyle(.secondary) }
            }
            Swatch(selected: b.kind == .wallpaper, help: "Desktop wallpaper", action: { set { $0.kind = .wallpaper } }) { wallpaper(blur: false) }
            Swatch(selected: b.kind == .blurredWallpaper, help: "Blurred wallpaper", action: { set { $0.kind = .blurredWallpaper } }) { wallpaper(blur: true) }
            let custom = b.kind == .image && !MacWallpapers.isMacWallpaper(b.imagePath)
            Swatch(selected: custom, help: "Custom image…", action: chooseImage) {
                ZStack {
                    Color.white.opacity(0.06)
                    if custom, let img = MacWallpapers.thumbnail(URL(fileURLWithPath: b.imagePath)) {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "plus").foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu {
                if custom {
                    let fav = editor.favoriteBackgrounds.contains(b.imagePath)
                    Button(fav ? "Remove from Favourites" : "Add to Favourites") { editor.toggleFavoriteBackground(b.imagePath) }
                }
            }
        }
        HStack(spacing: 8) {
            Button { editor.pasteBackgroundImage() } label: { Label("Paste Image", systemImage: "doc.on.clipboard") }
                .help("Use the image on the clipboard as the background (or drop an image file here)")
            Button { editor.randomWallpaper() } label: { Label("Random", systemImage: "shuffle") }
                .help("Pick a random macOS wallpaper")
                .disabled(MacWallpapers.all.isEmpty)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            if p.canLoadObject(ofClass: URL.self) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, NSImage(contentsOf: url) != nil else { return }
                    DispatchQueue.main.async { editor.setBackgroundImage(url.path) }
                }
                return true
            }
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage else { return }
                    DispatchQueue.main.async { editor.setBackgroundImage(from: img) }
                }
                return true
            }
            return false
        }
        if [.wallpaper, .blurredWallpaper, .image].contains(b.kind) {
            SliderRow(title: "Blur", value: editor.binding(\.background.blur), range: 0...1, live: editor.live(\.background.blur)) {
                $0 < 0.01 ? "Off".loc : "\(Int(($0 * 100).rounded()))%"
            }
        }
        FavoriteBackgrounds(editor: editor)
        MacWallpaperGrid(editor: editor)
        Caption("Gradients")
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(StudioDocument.gradients.indices, id: \.self) { i in
                let g = StudioDocument.gradients[i]
                Swatch(selected: b.kind == .gradient && b.gradient == i, action: { set { $0.kind = .gradient; $0.gradient = i } }) {
                    LinearGradient(colors: [hexColor(g.0), hexColor(g.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        Caption("Colors")
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(StudioDocument.colors, id: \.self) { hex in
                Swatch(selected: b.kind == .color && b.color == hex, action: { set { $0.kind = .color; $0.color = hex } }) { hexColor(hex) }
            }
            ColorPicker("", selection: Binding(get: { hexColor(b.color) }, set: { c in
                editor.edit(coalesce: "bgColor") { $0.background.kind = .color; $0.background.color = NSColor(c).hexString }
            }), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 38, height: 38)
            .help("Custom color")
        }
        Group {
            SliderRow(title: "Padding", value: editor.binding(\.background.padding), range: 0...0.3, live: editor.live(\.background.padding)) { "\(Int(($0 * 100).rounded()))%" }
            SliderRow(title: "Corner radius", value: editor.binding(\.background.cornerRadius), range: 0...60, live: editor.live(\.background.cornerRadius)) { "\(Int($0))" }
            SliderRow(title: "Shadow", value: editor.binding(\.background.shadow), range: 0...1, live: editor.live(\.background.shadow)) { "\(Int($0 * 100))%" }
            DisclosureGroup("Shadow options") {
                SliderRow(title: "Direction", value: editor.binding(\.background.shadowAngle), range: -180...180, live: editor.live(\.background.shadowAngle)) {
                    "\(Int($0))°"
                }
                SliderRow(title: "Distance", value: editor.binding(\.background.shadowDistance), range: 0...1.5, live: editor.live(\.background.shadowDistance)) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                SliderRow(title: "Softness", value: editor.binding(\.background.shadowSoftness), range: 0.2...2, live: editor.live(\.background.shadowSoftness)) {
                    "\(Int(($0 * 100).rounded()))%"
                }
            }
            .font(.system(size: 11))
            InsetControls(editor: editor)
        }
        .disabled(!b.isVisible)
        .opacity(b.isVisible ? 1 : 0.45)
        if editor.isDevice {
            Toggle("Device frame", isOn: editor.binding(\.background.deviceFrame))
        }
        Caption("Aspect ratio")
        Picker("", selection: editor.binding(\.background.aspect)) {
            ForEach(StudioAspect.allCases) { Text($0.title.loc).tag($0) }
        }
        .labelsHidden()
        if editor.doc.background.aspect != .auto {
            Toggle("Fill the frame and follow the cursor", isOn: editor.binding(\.background.fillFrame))
                .help("The recording fills the whole frame (its sides are cropped) and the view moves with the cursor — for vertical or square video")
        }
        HStack {
            Button { editor.showCrop = true } label: { Label("Crop Recording…", systemImage: "crop") }
            if !editor.doc.crop.isFull {
                Button("Reset Crop") { editor.edit { $0.crop = .init() } }
            }
        }
    }

    @ViewBuilder private func wallpaper(blur: Bool) -> some View {
        if let cg = editor.wallpaperPreview {
            Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill).blur(radius: blur ? 4 : 0)
        } else {
            ZStack { Color.white.opacity(0.06); Image(systemName: "photo").foregroundStyle(.secondary) }
        }
    }
}

/// Inset: one value or one per side, its colour (auto = the recording's corner) and opacity.
private struct InsetControls: View {
    @ObservedObject var editor: StudioEditor

    var body: some View {
        let b = editor.doc.background
        let perSide = b.insetSides.count == 4
        if perSide {
            Caption("Inset")
            ForEach(0..<4, id: \.self) { i in
                SliderRow(title: ["Top", "Right", "Bottom", "Left"][i],
                          value: Binding(get: { b.sides[i] }, set: { v in editor.edit(coalesce: "inset\(i)") { var s = $0.background.sides; s[i] = v; $0.background.insetSides = s } }),
                          range: 0...40,
                          live: { v in editor.previewEdit { var s = $0.background.sides; s[i] = v; $0.background.insetSides = s } },
                          format: { "\(Int($0))" })
            }
        } else {
            SliderRow(title: "Inset", value: editor.binding(\.background.inset), range: 0...40, live: editor.live(\.background.inset)) { "\(Int($0))" }
        }
        HStack {
            Toggle("Per side", isOn: Binding(get: { perSide }, set: { on in
                editor.edit { $0.background.insetSides = on ? $0.background.sides : [] }
            }))
            Spacer()
            if b.sides.contains(where: { $0 > 0 }) {
                ColorPicker("", selection: Binding(get: { b.insetColor.isEmpty ? Color.white : hexColor(b.insetColor) }, set: { c in
                    editor.edit(coalesce: "insetColor") { $0.background.insetColor = NSColor(c).hexString }
                }), supportsOpacity: false)
                .labelsHidden()
                .help("Inset color")
                Button("Auto") { editor.edit { $0.background.insetColor = "" } }
                    .disabled(b.insetColor.isEmpty)
                    .help("Use the color at the recording's corner")
            }
        }
        if b.sides.contains(where: { $0 > 0 }) {
            SliderRow(title: "Inset opacity", value: editor.binding(\.background.insetOpacity), range: 0...1, live: editor.live(\.background.insetOpacity)) {
                "\(Int(($0 * 100).rounded()))%"
            }
        }
    }
}

/// Favourite backgrounds (right-click a wallpaper to add one).
private struct FavoriteBackgrounds: View {
    @ObservedObject var editor: StudioEditor
    private let cols = Array(repeating: GridItem(.fixed(61), spacing: 8), count: 4)

    var body: some View {
        let favs = editor.favoriteBackgrounds.filter { FileManager.default.fileExists(atPath: $0) }
        if !favs.isEmpty {
            let b = editor.doc.background
            Caption("Favourites")
            LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                ForEach(favs, id: \.self) { path in
                    let selected = b.kind == .image && b.imagePath == path
                    Button { editor.setBackgroundImage(path) } label: {
                        Group {
                            if let img = MacWallpapers.thumbnail(URL(fileURLWithPath: path)) {
                                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            } else { Color.white.opacity(0.06) }
                        }
                        .frame(width: 61, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? StudioTheme.accent : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Remove from Favourites") { editor.toggleFavoriteBackground(path) } }
                }
            }
        }
    }
}

/// The macOS desktop pictures installed on this Mac.
private struct MacWallpaperGrid: View {
    @ObservedObject var editor: StudioEditor
    private let cols = Array(repeating: GridItem(.fixed(61), spacing: 8), count: 4)

    var body: some View {
        if !MacWallpapers.all.isEmpty {
            let b = editor.doc.background
            Caption("macOS wallpapers")
            LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                ForEach(MacWallpapers.all) { item in
                    let selected = b.kind == .image && b.imagePath == item.file.path
                    Button { editor.edit { $0.background.kind = .image; $0.background.imagePath = item.file.path } } label: {
                        Group {
                            if let img = MacWallpapers.thumbnail(item.thumbnail) {
                                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.white.opacity(0.06)
                            }
                        }
                        .frame(width: 61, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? StudioTheme.accent : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(item.id)
                    .contextMenu {
                        let fav = editor.favoriteBackgrounds.contains(item.file.path)
                        Button(fav ? "Remove from Favourites" : "Add to Favourites") { editor.toggleFavoriteBackground(item.file.path) }
                    }
                }
            }
        }
    }
}

// MARK: Animations

private struct AnimationsPane: View {
    @ObservedObject var editor: StudioEditor

    var body: some View {
        let a = editor.doc.animation
        PaneHeader(title: "Animations")
        Caption("Zoom animation")
        Picker("", selection: editor.binding(\.animation.zoomStyle)) {
            Text("Smooth").tag(ZoomStyle.smooth)
            Text("Dynamic").tag(ZoomStyle.dynamic)
            Text("Custom").tag(ZoomStyle.custom)
        }
        .pickerStyle(.segmented).labelsHidden()
        if a.zoomStyle == .custom {
            // The spring: stiffness, damping, mass.
            SliderRow(title: "Stiffness", value: editor.binding(\.animation.rigidity), range: 5...600, live: editor.live(\.animation.rigidity)) { "\(Int($0))" }
            SliderRow(title: "Damping", value: editor.binding(\.animation.smoothness), range: 5...200, live: editor.live(\.animation.smoothness)) { "\(Int($0))" }
            SliderRow(title: "Weight", value: editor.binding(\.animation.momentum), range: 0.1...15, live: editor.live(\.animation.momentum)) { String(format: "%.1f", $0) }
            Button("Reset Spring") {
                editor.edit { d in
                    let def = StudioDocument.Animation()
                    d.animation.rigidity = def.rigidity; d.animation.smoothness = def.smoothness; d.animation.momentum = def.momentum
                }
            }
        } else {
            // Speed slider runs slow → fast, stored as the zoom duration (1.4 s … 0.3 s).
            SliderRow(title: "Zoom speed", value: Binding(get: { 1.7 - a.zoomDuration }, set: { v in editor.edit(coalesce: "zoomSpeed") { $0.animation.zoomDuration = 1.7 - v } }),
                      range: 0.3...1.4, live: { v in editor.previewEdit { $0.animation.zoomDuration = 1.7 - v } }) { v in v < 0.6 ? "Slow".loc : v < 1.05 ? "Medium".loc : "Fast".loc }
        }
        Caption("Motion blur while zooming")
        Picker("", selection: editor.binding(\.animation.motionBlur)) {
            ForEach(MotionBlur.allCases, id: \.self) { Text($0.rawValue.capitalized.loc).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .help("Blurs the screen while it zooms in or out")
        Caption("Motion blur while moving")
        Picker("", selection: Binding(get: { a.panBlur ?? a.motionBlur }, set: { v in editor.edit { $0.animation.panBlur = v } })) {
            ForEach(MotionBlur.allCases, id: \.self) { Text($0.rawValue.capitalized.loc).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .help("Blurs the screen while a zoomed-in view moves without zooming. Cursor motion blur is in the Cursor tab.")
        Divider()
        Caption("Zooms")
        Text("Click or drag on the zoom track under the clips to add a zoom. Select a zoom to change its level and focus.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button { editor.autoZoom() } label: { Label("Auto Zoom", systemImage: "wand.and.stars") }
                .disabled(!editor.hasPointer)
                .help("Create zooms from the clicks in the recording")
            Button("Remove All Zooms", role: .destructive) { editor.removeAllZooms() }
                .disabled(editor.doc.zooms.isEmpty)
        }
        if !editor.doc.zooms.isEmpty {
            let allOff = editor.doc.zooms.allSatisfy(\.disabled)
            Button(allOff ? "Turn All Zooms On" : "Turn All Zooms Off") { editor.setAllZoomsDisabled(!allOff) }
        }
        SliderRow(title: "Snap to edges", value: editor.binding(\.animation.snapToEdges), range: 0...0.4, live: editor.live(\.animation.snapToEdges)) {
            $0 < 0.01 ? "Off".loc : "\(Int(($0 * 100).rounded()))%"
        }
        .disabled(!editor.hasPointer)
        .help("When the pointer comes this close to an edge, a following zoom pins the view to that edge instead of showing the background")
        Toggle("Always keep zoomed in", isOn: editor.binding(\.animation.keepZoomedIn))
            .disabled(!editor.hasPointer)
        Text("Between zooms the video stays zoomed and follows the cursor — made for vertical video.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if a.keepZoomedIn {
            SliderRow(title: "Zoom level between zooms", value: editor.binding(\.animation.keepZoomScale), range: 1.1...3,
                      live: editor.live(\.animation.keepZoomScale)) { String(format: "%.1f×", $0) }
        }
        TypingSuggestions(editor: editor)
    }
}

// MARK: - Masks

private struct MasksPane: View {
    @ObservedObject var editor: StudioEditor

    var body: some View {
        PaneHeader(title: "Masks")
        Text("Blur passwords, emails and other private details, or highlight one area by dimming the rest. Masks stay on the content when the video zooms.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button { editor.addMaskAtPlayhead(.blur) } label: { Label("Add Blur", systemImage: "eye.slash") }
            Button { editor.addMaskAtPlayhead(.highlight) } label: { Label("Add Highlight", systemImage: "rectangle.dashed") }
        }
        if !editor.doc.masks.isEmpty {
            let allOff = editor.doc.masks.allSatisfy(\.disabled)
            Button(allOff ? "Turn All Masks On" : "Turn All Masks Off") { editor.setAllMasksDisabled(!allOff) }
        }
        Divider()
        Caption("Find sensitive info")
        Text("Reads the text in the recording and blurs emails, phone numbers, API keys, passwords and the other kinds turned on for Auto Redact.")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let p = editor.maskScanProgress {
            HStack {
                ProgressView(value: p)
                Button("Cancel") { editor.cancelMaskScan() }
            }
        } else {
            Button { editor.findSensitiveInfo() } label: { Label("Find Sensitive Info", systemImage: "text.viewfinder") }
        }
        if !editor.doc.masks.isEmpty {
            Divider()
            Button("Remove All Masks", role: .destructive) {
                editor.edit { $0.masks.removeAll() }
                editor.selection = nil
            }
        }
    }
}

private struct MaskInspector: View {
    @ObservedObject var editor: StudioEditor
    let mask: StudioDocument.Mask
    @State private var selected: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "eye.slash").foregroundStyle(StudioTheme.mask)
                Text("Mask").font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Done") { editor.selection = nil }
            }
            Picker("", selection: Binding(get: { mask.kind }, set: { k in editor.editMask(mask.id, coalesce: "kind") { $0.kind = k } })) {
                Text("Blur").tag(MaskKind.blur)
                Text("Highlight").tag(MaskKind.highlight)
            }
            .pickerStyle(.segmented).labelsHidden()
            SliderRow(title: mask.kind == .blur ? "Blur amount" : "Dimming", value: Binding(get: { mask.strength }, set: { v in
                editor.editMask(mask.id, coalesce: "strength") { $0.strength = v }
            }), range: 0.1...1, live: { v in
                editor.previewEdit { d in if let i = d.masks.firstIndex(where: { $0.id == mask.id }) { d.masks[i].strength = v } }
            }) { "\(Int($0 * 100))%" }
            Button(mask.kind == .blur ? "Apply Blur Amount to All Blur Masks" : "Apply Dimming to All Highlight Masks") { editor.applyMaskStrengthToAll(mask) }
                .disabled(editor.doc.masks.filter { $0.kind == mask.kind }.count < 2)
            if editor.maskWarnings.contains(mask.id) {
                Label {
                    Text("Data may be visible: the content under this mask moves (scrolls) while it's on. Split the mask where it moves, or cover the whole area.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.system(size: 11))
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
            }
            Toggle("Mask on", isOn: Binding(get: { !mask.disabled }, set: { v in editor.editMask(mask.id, coalesce: "disabled") { $0.disabled = !v } }))
                .help(EditorShortcuts.help("Turn Selected Zoom, Mask or Layout Off / On", "video.toggleDisabled"))
            Caption("Regions")
            MaskRegionEditor(editor: editor, mask: mask, selected: $selected)
            Text("Drag on the picture to add a region. Drag a region to move it, or its corner to resize it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Delete Region") {
                    guard let i = selected else { return }
                    editor.editMask(mask.id, coalesce: "regions") { if $0.regions.indices.contains(i) { $0.regions.remove(at: i) } }
                    selected = nil
                }
                .disabled(selected == nil || mask.regions.count < 2)
                Spacer()
                Button("Delete", role: .destructive) { editor.deleteSelection() }
            }
            Spacer()
        }
        .padding(16)
    }
}

/// The recording at the mask's start with its regions on top: drag empty space to add one, drag a region to move it,
/// drag its bottom-right corner to resize.
private struct MaskRegionEditor: View {
    @ObservedObject var editor: StudioEditor
    let mask: StudioDocument.Mask
    @Binding var selected: Int?
    @State private var frame: CGImage?
    @State private var gesture: (index: Int, origin: StudioDocument.Mask.Region, resize: Bool)?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                if let img = frame ?? editor.thumbnail(atSource: mask.start) {
                    Image(decorative: img, scale: 1).resizable()
                } else {
                    Color.white.opacity(0.06)
                }
                ForEach(Array(mask.regions.enumerated()), id: \.offset) { i, r in
                    let rect = CGRect(x: r.x * size.width, y: r.y * size.height, width: r.width * size.width, height: r.height * size.height)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(StudioTheme.mask.opacity(0.25))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected == i ? Color.white : StudioTheme.mask, lineWidth: 2))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    if selected == i {
                        Circle().fill(Color.white).frame(width: 9, height: 9).position(x: rect.maxX, y: rect.maxY)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in drag(g, size) }.onEnded { _ in end() })
        }
        .aspectRatio(editor.sourceAspect, contentMode: .fit)
        .task(id: mask.start) { frame = await editor.sourceFrame(at: mask.start) }
    }

    private func drag(_ g: DragGesture.Value, _ size: CGSize) {
        let p = CGPoint(x: g.startLocation.x / size.width, y: g.startLocation.y / size.height)
        let dx = (g.location.x - g.startLocation.x) / size.width, dy = (g.location.y - g.startLocation.y) / size.height
        if gesture == nil {
            let corner = mask.regions.indices.last { i in
                let r = mask.regions[i]
                return abs((r.x + r.width) * size.width - g.startLocation.x) < 10 && abs((r.y + r.height) * size.height - g.startLocation.y) < 10
            }
            if let i = corner ?? mask.regions.indices.last(where: { i in
                let r = mask.regions[i]
                return p.x >= r.x && p.x <= r.x + r.width && p.y >= r.y && p.y <= r.y + r.height
            }) {
                gesture = (i, mask.regions[i], corner != nil)
            } else {
                let new = StudioDocument.Mask.Region(x: p.x, y: p.y, width: 0, height: 0)
                editor.editMask(mask.id, coalesce: "regions") { $0.regions.append(new) }
                gesture = (mask.regions.count, new, true)
            }
            selected = gesture?.index
        }
        guard let (i, o, resize) = gesture else { return }
        editor.editMask(mask.id, coalesce: "regions") { m in
            guard m.regions.indices.contains(i) else { return }
            if resize {
                m.regions[i].width = min(max(0.005, o.width + dx), 1 - o.x)
                m.regions[i].height = min(max(0.005, o.height + dy), 1 - o.y)
            } else {
                m.regions[i].x = min(max(0, o.x + dx), 1 - o.width)
                m.regions[i].y = min(max(0, o.y + dy), 1 - o.height)
            }
        }
    }

    private func end() {
        // A click on empty space makes a region too small to see: drop it.
        if let (i, _, _) = gesture, let r = mask.regions.indices.contains(i) ? mask.regions[i] : nil, r.width < 0.01 || r.height < 0.01, mask.regions.count > 1 {
            editor.editMask(mask.id, coalesce: "regions") { $0.regions.remove(at: i) }
            selected = nil
        }
        gesture = nil
    }
}

// MARK: - Clip inspector

private struct ClipInspector: View {
    @ObservedObject var editor: StudioEditor
    let clip: StudioDocument.Clip

    private func fmt(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t) / 60, t - Double(Int(t) / 60 * 60)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "film").foregroundStyle(StudioTheme.accent)
                Text("Clip").font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Done") { editor.selection = nil }
            }
            Caption("Speed")
            Picker("", selection: Binding(get: { clip.speed }, set: { editor.setClipSpeed(clip.id, $0) })) {
                ForEach(StudioDocument.Clip.speeds, id: \.self) { Text(verbatim: StudioDocument.Clip.speedTitle($0)).tag($0) }
            }
            .labelsHidden()
            Text("%@ of the recording plays in %@.".loc(fmt(clip.duration), fmt(clip.length)))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            SliderRow(title: "Volume", value: Binding(get: { clip.volume }, set: { v in editor.editClip(clip.id, coalesce: "vol") { $0.volume = v } }),
                      range: 0...2, live: { v in editor.previewEdit { d in if let i = d.clips.firstIndex(where: { $0.id == clip.id }) { d.clips[i].volume = v } } },
                      format: { "\(Int(($0 * 100).rounded()))%" })
            if (editor.sources?.audio.count ?? 0) > 1 {
                ForEach(0..<(editor.sources?.audio.count ?? 0), id: \.self) { i in
                    SliderRow(title: editor.audioTrackName(i),
                              value: Binding(get: { clip.trackVolume(i) }, set: { v in editor.editClip(clip.id, coalesce: "tvol\(i)") { $0.setTrackVolume(v, i) } }),
                              range: 0...2,
                              live: { v in editor.previewEdit { d in if let k = d.clips.firstIndex(where: { $0.id == clip.id }) { d.clips[k].setTrackVolume(v, i) } } },
                              format: { "\(Int(($0 * 100).rounded()))%" })
                }
            }
            Toggle("Hide cursor in this clip", isOn: Binding(get: { clip.hideCursor }, set: { v in editor.editClip(clip.id) { $0.hideCursor = v } }))
                .disabled(!editor.hasPointer)
            Toggle("Smooth cursor movement", isOn: Binding(get: { clip.smoothCursor }, set: { v in editor.editClip(clip.id) { $0.smoothCursor = v } }))
                .disabled(!editor.hasPointer || clip.hideCursor)
                .help("Turn off where the pointer must be exact, e.g. while picking from menus")
            TypingSuggestions(editor: editor)
            HStack {
                Button("Split at Playhead") { editor.splitAtPlayhead() }.help(EditorShortcuts.help("Split Clip at Playhead", "video.splitClip"))
                Menu("More") {
                    Button("Merge with Previous") { editor.mergeClipWithPrevious(clip.id) }
                        .disabled(editor.doc.clips.first?.id == clip.id)
                    Button("Merge with Next") { editor.mergeClipWithNext(clip.id) }
                        .disabled(editor.doc.clips.last?.id == clip.id)
                    Button("Reset Trim") { editor.resetTrim(clip.id) }
                    Button("Delete Back to Previous Cut") { editor.deleteToPreviousCut() }
                }
                .fixedSize()
                .help("Merge with a neighbour (anything cut out between them comes back), undo this clip's trims, or delete up to the playhead")
                Spacer()
                Button("Delete", role: .destructive) { editor.deleteSelection() }.disabled(editor.doc.clips.count < 2)
            }
            Spacer()
        }
        .padding(16)
    }
}

/// "Speed up all typing", shown while there are typing stretches at normal speed.
private struct TypingSuggestions: View {
    @ObservedObject var editor: StudioEditor

    var body: some View {
        let typing = editor.typingSuggestions
        if editor.isStudio, !editor.isDevice, !editor.hasKeys {
            Divider()
            Caption("Typing")
            Text("No keystrokes were recorded, so typing can't be found and sped up. Allow Accessibility for Daisyshot before recording.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if !typing.isEmpty {
            Divider()
            Caption("Typing")
            Text("Stretches of typing are marked above the clips. Click one to choose its speed, or speed them all up at once.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button {
                editor.speedUpTyping(typing)
            } label: {
                Label("Speed Up All Typing (%@)".loc(StudioDocument.Clip.speedTitle(StudioEditor.typingSpeed)), systemImage: "hare")
            }
        }
    }
}

// MARK: - Typing popover

/// "Speed up typing" for one detected typing stretch (opened from the timeline's typing lane).
struct TypingPopover: View {
    @ObservedObject var editor: StudioEditor
    let range: ClosedRange<Double>
    let close: () -> Void
    @State private var speed: Double

    init(editor: StudioEditor, range: ClosedRange<Double>, close: @escaping () -> Void) {
        self.editor = editor
        self.range = range
        self.close = close
        let current = editor.doc.speed(of: range)
        _speed = State(initialValue: current == 1 ? StudioEditor.typingSpeed : current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 15, weight: .medium)).foregroundStyle(hexColor("#A9C7FF"))
                    .frame(width: 30, height: 30)
                    .background(StudioTheme.typing.opacity(0.24), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Speed up typing").font(.system(size: 14, weight: .semibold))
                    Text("%@ of typing".loc(Self.seconds(range.upperBound - range.lowerBound)))
                        .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text("You're typing during this part of the recording. Speed it up so viewers don't wait.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                // Half steps, without the tick marks a stepped slider draws.
                Slider(value: Binding(get: { speed }, set: { speed = ($0 * 2).rounded() / 2 }), in: 1...8).tint(StudioTheme.typing)
                Text(verbatim: StudioDocument.Clip.speedTitle(speed)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
                Button("Reset") { speed = StudioEditor.typingSpeed }
                    .buttonStyle(PopoverButton())
                    .disabled(speed == StudioEditor.typingSpeed)
                    .help("Back to %@".loc(StudioDocument.Clip.speedTitle(StudioEditor.typingSpeed)))
            }
            HStack(spacing: 8) {
                Button {
                    editor.speedUpTyping(editor.typingStretches.map(\.range), speed: speed)
                    close()
                } label: { label("Apply All Suggestions", key: "⌘↩") }
                .buttonStyle(PopoverButton())
                .keyboardShortcut(.return, modifiers: .command)
                Button {
                    editor.speedUpTyping([range], speed: speed)
                    close()
                } label: { label("Apply Suggestion", key: "↩") }
                .buttonStyle(PopoverButton(primary: true))
                .keyboardShortcut(.defaultAction)
            }
            Button {
                editor.removeTypingSuggestion(range)
                close()
            } label: { Text("Remove Suggestion").frame(maxWidth: .infinity) }
            .buttonStyle(PopoverButton())
            .help("Play this part at normal speed and stop marking it")
        }
        .padding(16)
        .frame(width: 420)
    }

    private func label(_ title: String, key: String) -> some View {
        HStack(spacing: 6) {
            Text(title.loc).lineLimit(1).minimumScaleFactor(0.8)
            Text(verbatim: key).opacity(0.6).fixedSize()
        }
        .frame(maxWidth: .infinity)
    }

    private static func seconds(_ s: Double) -> String { String(format: "%.1f s", s) }
}

/// Popover buttons: secondary (white wash + hairline) or primary (Daisyshot accentStrong).
private struct PopoverButton: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View { ButtonBody(configuration: configuration, primary: primary) }

    private struct ButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let primary: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            let fill: Color = primary
                ? hexColor(configuration.isPressed ? "#1F46AE" : hover ? "#2552C9" : "#2B5FE0")
                : .white.opacity(configuration.isPressed ? 0.14 : hover ? 0.1 : 0.06)
            configuration.label
                .font(.system(size: 13, weight: primary ? .semibold : .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .background(fill, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(primary ? 0.12 : 0.1)))
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hover = $0 }
        }
    }
}

// MARK: - Camera layout inspector

private struct CameraLayoutInspector: View {
    @ObservedObject var editor: StudioEditor
    let layout: StudioDocument.CameraLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "person.crop.rectangle").foregroundStyle(StudioTheme.camera)
                Text("Camera Layout").font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Done") { editor.selection = nil }
            }
            Caption("Show")
            Picker("", selection: Binding(get: { layout.kind }, set: { editor.setLayoutKind(layout.id, $0) })) {
                Text("Camera only").tag(CameraLayoutKind.cameraOnly)
                Text("Custom camera").tag(CameraLayoutKind.custom)
                Text("Screen only").tag(CameraLayoutKind.screenOnly)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(layout.kind == .cameraOnly ? "The camera fills the frame over the blurred screen — for talking to the viewer."
                 : layout.kind == .custom ? "The camera gets its own size and position here. Drag it in the preview while this layout is selected."
                 : "The camera bubble is hidden — for parts where it would cover something.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if layout.kind == .custom {
                SliderRow(title: "Size", value: Binding(get: { layout.size }, set: { v in editor.editLayout(layout.id, coalesce: "size") { $0.size = v } }),
                          range: 0.1...0.6,
                          live: { v in editor.previewEdit { d in if let i = d.layouts.firstIndex(where: { $0.id == layout.id }) { d.layouts[i].size = v } } },
                          format: { "\(Int($0 * 100))%" })
                Caption("Position")
                let xs = [0.12, 0.5, 0.88], ys = [0.15, 0.5, 0.82]
                PositionGrid(selected: (0..<9).first { abs(xs[$0 % 3] - layout.x) < 0.02 && abs(ys[$0 / 3] - layout.y) < 0.02 }) { i in
                    editor.editLayout(layout.id, coalesce: "pos") { $0.x = xs[i % 3]; $0.y = ys[i / 3] }
                }
                Button("Apply Size and Position to All Custom Layouts") {
                    editor.edit { d in for i in d.layouts.indices where d.layouts[i].kind == .custom { d.layouts[i].size = layout.size; d.layouts[i].x = layout.x; d.layouts[i].y = layout.y } }
                }
                .disabled(editor.doc.layouts.filter { $0.kind == .custom }.count < 2)
            }
            Toggle("Layout on", isOn: Binding(get: { !layout.disabled }, set: { _ in editor.toggleSelectionDisabled() }))
                .help(EditorShortcuts.help("Turn Selected Zoom, Mask or Layout Off / On", "video.toggleDisabled"))
            HStack {
                Button("Split at Playhead") { editor.splitLayoutAtPlayhead() }
                Spacer()
                Button("Delete", role: .destructive) { editor.deleteSelection() }
            }
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Zoom inspector

private struct ZoomInspector: View {
    @ObservedObject var editor: StudioEditor
    let zoom: StudioDocument.Zoom

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.zoom)
                Text("Zoom").font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Done") { editor.selection = nil }
            }
            SliderRow(title: "Zoom level", value: Binding(get: { zoom.scale }, set: { v in editor.editZoom(zoom.id, coalesce: "scale") { $0.scale = v } }),
                      range: 1.25...4, live: { v in
                editor.previewEdit { d in if let i = d.zooms.firstIndex(where: { $0.id == zoom.id }) { d.zooms[i].scale = v } }
            }) { String(format: "%.2f×", $0) }
            Caption("Mode")
            Picker("", selection: Binding(get: { zoom.followCursor && editor.hasPointer }, set: { v in editor.editZoom(zoom.id, coalesce: "mode") { $0.followCursor = v } })) {
                Text("Follow cursor").tag(true)
                Text("Manual").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(!editor.hasPointer)
            if !(zoom.followCursor && editor.hasPointer) {
                Caption("Focus")
                ZoomPositionControl(editor: editor, zoom: zoom)
                Caption("Glide")
                Picker("", selection: Binding(get: { zoom.glide }, set: { v in editor.editZoom(zoom.id, coalesce: "glide") { $0.glide = v } })) {
                    Text("None").tag(ZoomGlide.none)
                    Image(systemName: "arrow.left").tag(ZoomGlide.left)
                    Image(systemName: "arrow.right").tag(ZoomGlide.right)
                    Image(systemName: "arrow.up").tag(ZoomGlide.up)
                    Image(systemName: "arrow.down").tag(ZoomGlide.down)
                }
                .pickerStyle(.segmented).labelsHidden()
                .help("The view drifts slowly across the recording while this zoom is on")
                if zoom.glide != .none {
                    SliderRow(title: "Glide distance", value: Binding(get: { zoom.glideAmount }, set: { v in editor.editZoom(zoom.id, coalesce: "glideAmount") { $0.glideAmount = v } }),
                              range: 0.05...1, format: { "\(Int(($0 * 100).rounded()))%" })
                }
            }
            Toggle("Zoom on", isOn: Binding(get: { !zoom.disabled }, set: { v in editor.editZoom(zoom.id, coalesce: "disabled") { $0.disabled = !v } }))
                .help(EditorShortcuts.help("Turn Selected Zoom, Mask or Layout Off / On", "video.toggleDisabled"))
            Button("Apply Zoom Level to All") {
                editor.edit { d in for i in d.zooms.indices { d.zooms[i].scale = zoom.scale } }
            }
            .disabled(editor.doc.zooms.count < 2)
            HStack {
                Button("Split at Playhead") { editor.splitZoomAtPlayhead() }.help(EditorShortcuts.help("Split Zoom at Playhead", "video.splitZoom"))
                Spacer()
                Button("Delete", role: .destructive) { editor.deleteSelection() }
            }
            Spacer()
        }
        .padding(16)
    }
}

/// Thumbnail with the zoom window drawn on it; drag to set a manual zoom's focus.
private struct ZoomPositionControl: View {
    @ObservedObject var editor: StudioEditor
    let zoom: StudioDocument.Zoom

    var body: some View {
        let aspect = editor.sourceAspect
        GeometryReader { geo in
            let size = geo.size
            let w = size.width / zoom.scale, h = size.height / zoom.scale
            let cx = min(max(zoom.focusX * size.width, w / 2), size.width - w / 2)
            let cy = min(max(zoom.focusY * size.height, h / 2), size.height - h / 2)
            ZStack(alignment: .topLeading) {
                if let img = editor.thumbnail(atSource: zoom.start) {
                    Image(decorative: img, scale: 1).resizable()
                } else {
                    Color.white.opacity(0.06)
                }
                Color.black.opacity(0.45)
                    .mask(Rectangle().overlay(Rectangle().frame(width: w, height: h).position(x: cx, y: cy).blendMode(.destinationOut)).compositingGroup())
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white, lineWidth: 2).frame(width: w, height: h).position(x: cx, y: cy)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                var fx = min(max(g.location.x / size.width, 0), 1), fy = min(max(g.location.y / size.height, 0), 1)
                if abs(fx - 0.5) < 0.03 { fx = 0.5 }
                if abs(fy - 0.5) < 0.03 { fy = 0.5 }
                editor.editZoom(zoom.id, coalesce: "focus") { $0.focusX = fx; $0.focusY = fy }
            })
        }
        .aspectRatio(aspect, contentMode: .fit)
    }
}

// MARK: - Export sheet

struct StudioExportSheet: View {
    @ObservedObject var editor: StudioEditor
    @AppStorage(Prefs.Key.studioExportResolution) private var resolution: Int
    @AppStorage(Prefs.Key.studioExportQuality) private var quality: Int
    @AppStorage(Prefs.Key.studioExportAudio) private var includeAudio: Bool
    @AppStorage(Prefs.Key.studioExportFPS) private var fps: Int
    @AppStorage(Prefs.Key.studioExportCopy) private var copyToClipboard: Bool
    @AppStorage(Prefs.Key.studioExportGIFLoop) private var gifLoop: Bool
    @AppStorage(Prefs.Key.studioExportAlso) private var also: String

    /// Extra versions offered: the social shapes the project isn't already in.
    private var extraAspects: [StudioAspect] { [.vertical, .square, .p45, .wide].filter { $0 != editor.doc.background.aspect } }
    private func alsoBinding(_ a: StudioAspect) -> Binding<Bool> {
        Binding(get: { also.split(separator: ",").contains(Substring(a.rawValue)) }, set: { on in
            var set = also.split(separator: ",").map(String.init).filter { $0 != a.rawValue }
            if on { set.append(a.rawValue) }
            also = set.joined(separator: ",")
        })
    }
    private func exportAll() {
        editor.export(options)
        guard !options.replaceOriginal else { return }
        for a in extraAspects where alsoBinding(a).wrappedValue {
            var o = options
            o.aspect = a
            o.copyToClipboard = false
            editor.export(o)
        }
    }

    private var options: StudioExportOptions {
        let replace = editor.replaceOriginal && editor.replaceFormat != nil
        return StudioExportOptions(format: replace ? editor.replaceFormat! : editor.exportFormat, resolution: StudioResolution(rawValue: resolution) ?? .original,
                                   quality: StudioQuality(rawValue: quality) ?? .high, includeAudio: includeAudio, mono: editor.doc.audio.mono,
                                   replaceOriginal: replace, fps: fpsChoices.contains(fps) ? fps : 0, copyToClipboard: copyToClipboard, gifLoop: gifLoop)
    }
    /// Frame rates below the recording's (exporting above it only duplicates frames).
    private var fpsChoices: [Int] { StudioExportOptions.fpsChoices.filter { Double($0) < editor.fps } }
    private var resolutions: [StudioResolution] { StudioResolution.choices(for: editor.canvasSize) }
    private var hasAudio: Bool { !(editor.sources?.audio.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let p = editor.exportProgress {
                Text("Exporting…").font(.headline)
                ProgressView(value: p)
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("\(Int(p * 100))%" + (editor.exportTimeLeft.map { "  ·  " + "About %@ left".loc(Self.duration($0)) } ?? ""))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Continue in Background") { editor.showExport = false }
                        .help("Keep editing; you're notified when the export is done")
                    Button("Cancel") { editor.cancelExport() }.keyboardShortcut(.cancelAction)
                }
            } else {
                Text("Export").font(.headline)
                Form {
                    if let original = editor.openOptions.original {
                        Picker("Save", selection: $editor.replaceOriginal) {
                            Text("As a new file").tag(false)
                            Text("Replace “\(original.lastPathComponent)”").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                    }
                    Picker("Format", selection: Binding(get: { options.format }, set: { editor.exportFormat = $0 })) {
                        Text("MP4").tag(StudioExportFormat.mp4)
                        Text("GIF").tag(StudioExportFormat.gif)
                    }
                    .pickerStyle(.segmented)
                    .disabled(options.replaceOriginal)
                    Picker("Resolution", selection: Binding(get: { resolutions.contains { $0.rawValue == resolution } ? resolution : 0 },
                                                            set: { resolution = $0 })) {
                        ForEach(resolutions) { r in
                            let s = r.size(for: editor.canvasSize)
                            Text(verbatim: "\(r.title.loc)  —  \(Int(s.width)) × \(Int(s.height))").tag(r.rawValue)
                        }
                    }
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: Binding(get: { Double(quality) }, set: { quality = Int($0.rounded()) }), in: 0...4, step: 1)
                            Text(options.quality.title.loc).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        }
                    }
                    if options.format == .mp4 {
                        Picker("Frame rate", selection: Binding(get: { fpsChoices.contains(fps) ? fps : 0 }, set: { fps = $0 })) {
                            Text("Same as recording (%d fps)".loc(Int(editor.fps))).tag(0)
                            ForEach(fpsChoices, id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
                        }
                        Toggle("Include audio", isOn: $includeAudio).disabled(!hasAudio)
                    } else {
                        Toggle("Loop forever", isOn: $gifLoop)
                            .help("Off: the GIF plays once and stops on its last frame")
                    }
                    Toggle("Copy to clipboard", isOn: $copyToClipboard)
                    if !options.replaceOriginal {
                        LabeledContent("Also export") {
                            HStack(spacing: 10) {
                                ForEach(extraAspects) { a in Toggle(a.ratioText, isOn: alsoBinding(a)).toggleStyle(.checkbox) }
                            }
                        }
                        .help("Each extra version fills its frame with the recording and follows the cursor. They're exported one after another.")
                    }
                    LabeledContent("Estimated size") {
                        Text("~" + ByteCountFormatter.string(fromByteCount: Int64(options.estimatedBytes(canvas: editor.canvasSize, duration: editor.duration,
                                                                                                        fps: editor.fps, hasAudio: hasAudio)), countStyle: .file))
                            .monospacedDigit()
                    }
                }
                .formStyle(.columns)
                HStack {
                    Spacer()
                    Button("Cancel") { editor.showExport = false }.keyboardShortcut(.cancelAction)
                    Button("Export") { exportAll() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t < 60 ? "%d s".loc(t) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
