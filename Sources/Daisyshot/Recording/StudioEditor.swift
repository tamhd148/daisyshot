import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers

extension Prefs.Key {
    /// Look of the last edited Studio project (a document with no clips/zooms), reused for new projects.
    static let studioLastStyle = Prefs.Key("studioLastStyle", Data())
    static let studioExportFormat = Prefs.Key("studioExportFormat", "mp4")
    static let studioExportResolution = Prefs.Key("studioExportResolution", 0)
    static let studioExportQuality = Prefs.Key("studioExportQuality", 3)
    static let studioExportAudio = Prefs.Key("studioExportAudio", true)
    static let studioSnap = Prefs.Key("studioSnap", true)
    static let studioExportFPS = Prefs.Key("studioExportFPS", 0)              // 0 = the recording's frame rate
    static let studioExportCopy = Prefs.Key("studioExportCopy", false)
    static let studioExportGIFLoop = Prefs.Key("studioExportGIFLoop", true)
    static let studioExportAlso = Prefs.Key("studioExportAlso", "")      // extra versions, StudioAspect raw values joined by ","
    static let studioQuickExportKeep = Prefs.Key("studioQuickExportKeep", true)       // false: ask to keep or delete the project after a Quick Export
    static let studioClipboardExports = Prefs.Key("studioClipboardExports", "")     // newest first, one path per line
    // Timeline view options.
    static let studioShowTyping = Prefs.Key("studioShowTyping", true)
    static let studioShowZooms = Prefs.Key("studioShowZooms", true)
    static let studioShowMasks = Prefs.Key("studioShowMasks", true)
    static let studioShowLayouts = Prefs.Key("studioShowLayouts", true)
    static let studioShowKeys = Prefs.Key("studioShowKeys", true)
    static let studioShowWaveform = Prefs.Key("studioShowWaveform", true)
    static let studioAudioScrub = Prefs.Key("studioAudioScrub", false)
    static let studioPreviewQuality = Prefs.Key("studioPreviewQuality", 0)      // 0 full, 1 balanced, 2 power saving
    static let studioFavoriteBackgrounds = Prefs.Key("studioFavoriteBackgrounds", "")  // image paths, one per line
    static let studioLastProject = Prefs.Key("studioLastProject", "")       // path of the Studio project opened last
    static let studioDefaultPreset = Prefs.Key("studioDefaultPreset", "")   // preset name for new projects; empty = last used style
}

/// How a plain video was opened: what "Replace original" overwrites and the export defaults (GIF re-editing).
struct StudioOpenOptions {
    var original: URL?                    // file "Replace original" overwrites (plain video, or the GIF being re-edited)
    var name: String?                     // default export name
    var format: StudioExportFormat?       // preset export format (GIF re-editing)
    var replace = false                   // default destination is "Replace original"
    var saved = true                      // Quick Access "saved" state to give the replaced file
    var tempFolder: URL?                  // deleted on close (GIF converted to a temporary video)
}

/// Playhead time, published separately so 60 Hz updates only touch the views that show it.
@MainActor
final class StudioClock: ObservableObject {
    @Published var time = 0.0
}

/// State + commands of one editor window. The same render model drives preview, frame grabs and export.
@MainActor
final class StudioEditor: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case cursor, keystrokes, audio, camera, background, animations, masks
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .cursor: return "cursorarrow"
            case .keystrokes: return "keyboard"
            case .audio: return "speaker.wave.2"
            case .camera: return "web.camera"
            case .background: return "photo"
            case .animations: return "sparkles"
            case .masks: return "eye.slash"
            }
        }
    }
    enum Tool { case select, cut }
    enum Selection: Equatable { case clip(UUID), zoom(UUID), mask(UUID), layout(UUID) }

    let package: StudioPackage
    let openOptions: StudioOpenOptions
    let clock = StudioClock()
    let player = AVPlayer()
    lazy var timeline = StudioTimelineView(editor: self)
    lazy var preview = StudioPreviewView(editor: self)

    @Published private(set) var sources: StudioSources?
    @Published var doc = StudioDocument() {
        didSet {
            liveDoc = nil
            if doc != oldValue { changed(from: oldValue) }
        }
    }
    /// An edit in progress (slider or camera drag), rendered but not yet in `doc`: publishing `doc` on every tick would
    /// make SwiftUI redraw the whole editor each time. It lands in `doc` once, when the drag ends.
    private var liveDoc: StudioDocument?
    @Published var selection: Selection? { didSet { timeline.needsDisplay = true } }
    @Published var tool = Tool.select { didSet { timeline.window?.invalidateCursorRects(for: timeline) } }
    @Published var tab = Tab.cursor
    @Published private(set) var isPlaying = false
    @Published private(set) var dirty = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var showExport = false
    @Published var exportProgress: Double?
    @Published var replaceOriginal: Bool
    @Published var exportFormat: StudioExportFormat {
        didSet { if openOptions.format == nil { Prefs.set(exportFormat.rawValue, .studioExportFormat) } }
    }
    /// Timeline strip (drawn by the AppKit timeline only; not published, so loading 160 frames doesn't re-render the editor UI 160 times).
    private(set) var thumbnails: [CGImage?] = []
    /// Peaks per audio track (each scaled to its own loudest moment), and of the background music file.
    private(set) var waveforms: [[Float]] = []
    private(set) var musicWaveform: [Float] = []

    private(set) var model: StudioRenderModel?
    private var comp: AVMutableComposition?
    private var cursorTrack: CursorTrack?
    private var rawCursorTrack: CursorTrack?
    private var wallpaper: CGImage?
    private var customImage: (String, CGImage?)?
    private var insetColor = CGColor(gray: 1, alpha: 1)
    private var undoStack: [StudioDocument] = []
    private var redoStack: [StudioDocument] = []
    private var lastCoalesce: (key: AnyHashable, at: Date)?
    private var tracking = false
    private var baseline = StudioDocument()
    private var refreshPending: Bool?            // true = rebuild the composition
    private var lastRebuild = 0.0                // CACurrentMediaTime of the last composition rebuild
    private var saveWork: DispatchWorkItem?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var seekTarget: CMTime?
    private var seeking = false
    private var exportJob: StudioExportJob?
    private var exportTask: Task<Void, Never>?
    /// Playback starts over at the end.
    @Published var loopPlayback = false
    private var endObserver: NSObjectProtocol?
    var isExporting: Bool { exportTask != nil }

    /// Preview render size; lower settings save battery on long or 4K+ recordings.
    static var previewMaxSide: CGFloat { [1920, 1280, 720][min(2, max(0, Prefs.int(.studioPreviewQuality)))] }
    /// Preview only: the sidebar and the timeline are hidden.
    @Published var previewOnly = false
    @Published var hideSidebar = false
    @Published var hideTimeline = false

    /// Keystroke badges as the video shows them, plus the single ones hidden on the timeline (cached per keystroke settings).
    var keyBadges: [KeyBadge] {
        let k = doc.keystrokes
        if let c = badgeCache, c.allKeys == k.allKeys, c.hidden == k.hidden { return c.badges }
        let b = events.map { KeyBadge.build($0, allKeys: k.allKeys, hidden: Set(k.hidden)) } ?? []
        badgeCache = (k.allKeys, k.hidden, b)
        return b
    }
    private var badgeCache: (allKeys: Bool, hidden: [String], badges: [KeyBadge])?

    func toggleBadgeHidden(_ b: KeyBadge) {
        edit { d in
            if let i = d.keystrokes.hiddenAt.firstIndex(where: { abs($0 - b.start) < 0.0005 }) { d.keystrokes.hiddenAt.remove(at: i) }
            else { d.keystrokes.hiddenAt.append(b.start) }
        }
    }

    func hideEveryBadge(_ label: String) {
        edit { d in if !d.keystrokes.hidden.contains(label) { d.keystrokes.hidden.append(label) } }
    }
    @Published var showShortcutsGuide = false
    @Published var showCrop = false

    func setPreviewQuality(_ q: Int) {
        Prefs.set(q, .studioPreviewQuality)
        refresh(rebuild: true)
    }

    var isStudio: Bool { package.isStudio }
    var events: StudioEvents? { package.events }
    var isDevice: Bool { events?.device != nil }
    /// Recording markers on the output timeline (ones inside cut parts are gone).
    var markers: [Double] {
        (events?.markers ?? []).filter { s in doc.clips.contains { $0.start <= s && s < $0.end } }.map { doc.outputTime(source: $0) }
    }
    var hasPointer: Bool { events?.hasPointer == true && events?.cursorVisibleInVideo == false }
    var hasKeys: Bool { events?.hasKeys == true }
    var hasCamera: Bool { sources?.camera != nil }
    var duration: Double { doc.duration }
    var fps: Double { sources?.fps ?? 30 }
    var canvasSize: CGSize { model?.canvasSize ?? sources?.size ?? CGSize(width: 16, height: 9) }
    var sourceAspect: CGFloat { sources.map { $0.size.width / max(1, $0.size.height) } ?? 16 / 9 }
    var selectedMask: StudioDocument.Mask? {
        if case .mask(let id) = selection { return doc.masks.first { $0.id == id } }
        return nil
    }
    var selectedClip: StudioDocument.Clip? {
        if case .clip(let id) = selection { return doc.clips.first { $0.id == id } }
        return nil
    }
    var selectedLayout: StudioDocument.CameraLayout? {
        if case .layout(let id) = selection { return doc.layouts.first { $0.id == id } }
        return nil
    }

    var selectedZoom: StudioDocument.Zoom? {
        if case .zoom(let id) = selection { return doc.zooms.first { $0.id == id } }
        return nil
    }

    init(package: StudioPackage, options: StudioOpenOptions = .init()) {
        self.package = package
        openOptions = options
        replaceOriginal = options.replace && options.original != nil
        exportFormat = options.format ?? StudioExportFormat(rawValue: Prefs.string(.studioExportFormat)) ?? .mp4
        if !package.isStudio { tab = .background }
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, self.seekTarget == nil else { return }
                self.clock.time = min(t.seconds, self.duration)
                self.timeline.updatePlayhead(follow: true)
            }
        }
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            DispatchQueue.main.async {
                self?.isPlaying = playing
                if playing { self?.preview.showStill(nil) }
            }
        })
        wallpaper = Self.loadWallpaper()
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, self.loopPlayback, n.object as? AVPlayerItem === self.player.currentItem else { return }
                self.seek(to: 0)
                self.play(rate: 1)
            }
        }
    }

    func close() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.pause()
        exportJob?.cancel()
        exportTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        observations.removeAll()
        if isStudio { saveWork?.perform() }
        player.replaceCurrentItem(with: nil)
        if let tmp = openOptions.tempFolder { try? FileManager.default.removeItem(at: tmp) }
        if !isStudio { try? FileManager.default.removeItem(at: plainAudioFolder) }
    }

    // MARK: Loading

    /// `src` is loaded by `VideoEditor.open` first, so broken files get an alert instead of an editor.
    func load(_ src: StudioSources) {
        var d = package.loadDocument() ?? newDocument()
        if d.clips.isEmpty { d.clips = [.init(start: 0, duration: src.duration)] }
        tracking = false
        var src = src
        src.clickTimes = events?.events.filter { $0.type == "down" }.map(\.t) ?? []
        sources = src
        doc = d
        baseline = d
        tracking = true
        refresh(rebuild: true)
        Task { await prepareAudio() }
        if !doc.masks.isEmpty { checkMasks() }
        Task { await loadThumbnails(src) }
        Task { [weak self] in
            let peaks = await Task.detached(priority: .utility) {
                var all: [[Float]] = []
                for t in src.audio { all.append(await StudioWaveform.peaks(asset: src.asset, tracks: [t])) }
                return all
            }.value
            self?.waveforms = peaks
            self?.timeline.needsDisplay = true
        }
    }

    /// New projects start with the last used look (Studio) and smart zooms generated from the clicks.
    private func newDocument() -> StudioDocument {
        var d = StudioDocument()
        if !isStudio { d.background.kind = .none }
        let preset = Prefs.string(.studioDefaultPreset)
        if isStudio, !preset.isEmpty, let style = StudioPresets.load(StudioPresets.folder.appendingPathComponent(preset).appendingPathExtension(StudioPresets.ext)) {
            d = StudioPresets.style(of: style)
        } else if isStudio, let data = Prefs.d.data(forKey: Prefs.Key.studioLastStyle.rawValue), !data.isEmpty,
           let style = StudioJSON.decode(StudioDocument.self, from: data, defaults: StudioDocument()) {
            d = StudioPresets.style(of: style)
        }
        if Prefs.bool(.studioAutoZoom), let ev = events, ev.duration > 0 || !ev.events.isEmpty {
            d.zooms = StudioDocument.autoZooms(ev, duration: ev.duration > 0 ? ev.duration : .infinity)
        }
        if isDevice { d.background.deviceFrame = Prefs.bool(.recDeviceFrame) }
        return d
    }

    private func loadThumbnails(_ src: StudioSources) async {
        let count = Int(min(160, max(12, src.duration * 2)))
        thumbnails = Array(repeating: nil, count: count)
        let gen = AVAssetImageGenerator(asset: src.asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 320)
        let tol = CMTime(seconds: src.duration / Double(count) / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * src.duration / Double(count), preferredTimescale: 600) }
        for await r in gen.images(for: times) {
            guard let i = times.firstIndex(of: r.requestedTime), let img = try? r.image else { continue }
            thumbnails[i] = img
            if i == 0 { insetColor = Self.cornerColor(img) ?? insetColor }
            timeline.needsDisplay = true
        }
    }

    func thumbnail(atSource s: Double) -> CGImage? {
        guard let src = sources, src.duration > 0, !thumbnails.isEmpty else { return nil }
        let i = min(thumbnails.count - 1, max(0, Int(s / src.duration * Double(thumbnails.count))))
        return thumbnails[i] ?? thumbnails.first { $0 != nil } ?? nil
    }

    private static func cornerColor(_ img: CGImage) -> CGColor? {
        guard let ctx = StudioSprites.context(1, 1), let corner = img.cropping(to: CGRect(x: 2, y: 2, width: 1, height: 1)) else { return nil }
        ctx.draw(corner, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return CGColor(srgbRed: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
    }

    private static func loadWallpaper() -> CGImage? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return loadImage(url, maxSide: 2560)
    }

    static func loadImage(_ url: URL, maxSide: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary)
    }

    var wallpaperPreview: CGImage? { wallpaper }

    // MARK: Editing + undo

    /// Applies a change. Edits sharing `coalesce` within a second (slider drags) form one undo step.
    func edit(coalesce: AnyHashable? = nil, _ change: (inout StudioDocument) -> Void) {
        var d = doc
        change(&d)
        guard d != doc else { return }
        let now = Date()
        let continuing = coalesce != nil && lastCoalesce?.key == coalesce && now.timeIntervalSince(lastCoalesce!.at) < 1
        if !continuing { pushUndo() }
        lastCoalesce = coalesce.map { ($0, now) }
        doc = d
    }

    /// For continuous gestures: record one undo step up front, then `apply` without recording.
    func pushUndo() {
        undoStack.append(doc)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastCoalesce = nil
        canUndo = true
        canRedo = false
    }

    func apply(_ change: (inout StudioDocument) -> Void) { change(&doc) }

    /// Shows `change` in the preview without touching `doc` (see `liveDoc`).
    func previewEdit(_ change: (inout StudioDocument) -> Void) {
        var d = liveDoc ?? doc
        change(&d)
        liveDoc = d
        refresh(rebuild: false)
    }

    /// `previewEdit` for a slider bound to `kp`.
    func live(_ kp: WritableKeyPath<StudioDocument, Double>) -> (Double) -> Void {
        { [weak self] v in self?.previewEdit { $0[keyPath: kp] = v } }
    }

    /// Lands the previewed edit in `doc` (the caller recorded the undo step when the drag began).
    func commitLive() {
        guard let d = liveDoc else { return }
        doc = d
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(doc)
        lastCoalesce = nil
        doc = prev
        fixSelection()
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(doc)
        lastCoalesce = nil
        doc = next
        fixSelection()
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    private func fixSelection() {
        switch selection {
        case .clip(let id)? where !doc.clips.contains(where: { $0.id == id }): selection = nil
        case .zoom(let id)? where !doc.zooms.contains(where: { $0.id == id }): selection = nil
        case .mask(let id)? where !doc.masks.contains(where: { $0.id == id }): selection = nil
        case .layout(let id)? where !doc.layouts.contains(where: { $0.id == id }): selection = nil
        default: break
        }
    }

    func binding<T>(_ kp: WritableKeyPath<StudioDocument, T>) -> Binding<T> {
        Binding(get: { self.doc[keyPath: kp] }, set: { v in self.edit(coalesce: kp) { $0[keyPath: kp] = v } })
    }

    private func changed(from old: StudioDocument) {
        guard tracking else { return }
        dirty = doc != baseline
        let extras = old.music.path != doc.music.path || old.cursor.clickSound != doc.cursor.clickSound
        refresh(rebuild: old.clips != doc.clips || old.audio.denoise != doc.audio.denoise || extras)
        if old.audio != doc.audio || extras { Task { await prepareAudio() } }
        if old.masks != doc.masks { checkMasks() }
        timeline.needsDisplay = true
        if isStudio { scheduleSave() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.package.save(self.doc)
            Prefs.set(StudioJSON.encode(StudioPresets.style(of: self.doc)), .studioLastStyle)
            self.saveWork = nil
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    // MARK: Preview pipeline

    func makeModel(_ d: StudioDocument? = nil) -> StudioRenderModel? {
        guard let src = sources else { return nil }
        let d = d ?? liveDoc ?? doc
        let c = d.cursor
        if let ev = events, hasPointer, cursorTrack?.smoothing != c.smoothing || cursorTrack?.removeJumps != c.removeJumps
            || cursorTrack?.jumpLimit != c.jumpLimit || cursorTrack?.steadyShapes != c.steadyShapes {
            cursorTrack = CursorTrack(ev, smoothing: c.smoothing, removeJumps: c.removeJumps, jumpLimit: c.jumpLimit, steadyShapes: c.steadyShapes)
        }
        if d.background.kind == .image, customImage?.0 != d.background.imagePath {
            customImage = (d.background.imagePath, Self.loadImage(URL(fileURLWithPath: d.background.imagePath), maxSide: 3840))
        }
        if let ev = events, hasPointer, d.clips.contains(where: { !$0.smoothCursor }),
           rawCursorTrack?.removeJumps != c.removeJumps || rawCursorTrack?.jumpLimit != c.jumpLimit || rawCursorTrack?.steadyShapes != c.steadyShapes {
            rawCursorTrack = CursorTrack(ev, smoothing: 0, removeJumps: c.removeJumps, jumpLimit: c.jumpLimit, steadyShapes: c.steadyShapes)
        }
        return StudioRenderModel(doc: d, sources: src, events: events, cursor: hasPointer ? cursorTrack : nil, wallpaper: wallpaper,
                                 customImage: d.background.kind == .image ? customImage?.1 : nil, insetColor: insetColor,
                                 rawCursor: hasPointer && d.clips.contains(where: { !$0.smoothCursor }) ? rawCursorTrack : nil)
    }

    /// Coalesces doc changes into one preview update per run-loop turn.
    private func refresh(rebuild: Bool) {
        if refreshPending == nil {
            DispatchQueue.main.async { [weak self] in self?.applyRefresh() }
        }
        refreshPending = (refreshPending ?? false) || rebuild
    }

    private func applyRefresh() {
        let rebuild = refreshPending ?? false
        // A trim drag changes the clips on every mouse event; a new composition + player item each time swamps the
        // player. Rebuild at most every 80 ms while that goes on (the latest document always lands).
        let wait = lastRebuild + 0.08 - CACurrentMediaTime()
        if rebuild, comp != nil, wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.applyRefresh() }
            return
        }
        refreshPending = nil
        guard let src = sources, let model = makeModel() else { return }
        model.reuseBackgrounds(from: self.model)
        self.model = model
        if rebuild || comp == nil || player.currentItem == nil {
            lastRebuild = CACurrentMediaTime()
            guard let c = try? StudioComposer.composition(src, doc: doc) else { return }
            comp = c
            let item = AVPlayerItem(asset: c)
            item.audioTimePitchAlgorithm = .spectral      // sped-up clips keep their pitch
            item.videoComposition = StudioComposer.videoComposition(c, model: model, renderSize: model.renderSize(maxSide: Self.previewMaxSide), fps: src.fps)
            item.audioMix = StudioComposer.audioMix(c, doc: doc, sources: src)
            item.seekingWaitsForVideoCompositionRendering = true
            player.replaceCurrentItem(with: item)
            seek(to: min(clock.time, max(0, duration - 1 / fps)))
        } else if let item = player.currentItem, let comp {
            item.videoComposition = StudioComposer.videoComposition(comp, model: model, renderSize: model.renderSize(maxSide: Self.previewMaxSide), fps: src.fps)
            item.audioMix = StudioComposer.audioMix(comp, doc: liveDoc ?? doc, sources: src)
            if !isPlaying, !renderStill() { seek(to: clock.time) }
        }
        preview.needsLayout = true
    }

    // MARK: Audio clean-up

    /// Audio tracks whose noise reduction is being rendered.
    @Published private(set) var audioWork: Set<Int> = []
    private lazy var plainAudioFolder = FileManager.default.temporaryDirectory.appendingPathComponent("DaisyshotAudio-\(UUID().uuidString)")

    /// Studio projects keep the clean copy inside the package (rendered once); plain videos get a temporary one.
    private func cleanAudioURL(_ i: Int) -> URL {
        isStudio ? package.url.appendingPathComponent("audio-\(i)-clean.m4a") : plainAudioFolder.appendingPathComponent("audio-\(i)-clean.m4a")
    }

    /// Renders the noise-reduced copies and measures the loudness the document asks for, then rebuilds the player.
    func prepareAudio() async {
        guard let src = sources else { return }
        // Background music and the click sound, loaded when the document asks for them.
        let music = musicURL
        if src.music?.url != music {
            sources?.music = await Self.loadExtra(music)
            if music != nil, sources?.music == nil { Toast.show("Couldn't read the music file.", isError: true) }
            if let m = sources?.music {
                musicWaveform = await Task.detached(priority: .utility) { await StudioWaveform.peaks(asset: m.asset, tracks: [m.track]) }.value
            } else {
                musicWaveform = []
            }
            timeline.needsDisplay = true
            refresh(rebuild: true)
        }
        if doc.cursor.clickSound, src.click == nil {
            sources?.click = await Self.loadExtra(StudioClickSound.url)
            refresh(rebuild: true)
        }
        let a = doc.audio
        for i in src.audio.indices {
            if a.denoises(i), sources?.cleanAudio[i] == nil, !audioWork.contains(i) {
                audioWork.insert(i)
                defer { audioWork.remove(i) }
                let url = cleanAudioURL(i), track = src.audio[i], asset = src.asset
                do {
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try await Task.detached(priority: .userInitiated) { try await StudioAudioFX.denoise(track, of: asset, to: url) }.value
                    }
                    let ca = AVURLAsset(url: url)
                    guard let ct = try await ca.loadTracks(withMediaType: .audio).first else { throw StudioError("Couldn't reduce the noise.") }
                    sources?.cleanAudio[i] = .init(asset: ca, track: ct, range: try await ct.load(.timeRange))
                    refresh(rebuild: true)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    Toast.show("Couldn't reduce the noise: %@".loc(error.localizedDescription), isError: true)
                }
            }
            let clean = sources?.cleanAudio[i]
            let key = StudioSources.gainKey(i, clean: a.denoises(i) && clean != nil)
            if a.normalizes(i), sources?.gains[key] == nil {
                let (track, asset): (AVAssetTrack, AVAsset) = clean.map { ($0.track, $0.asset) } ?? (src.audio[i], src.asset)
                let measure = Task.detached(priority: .userInitiated) { try await StudioAudioFX.normalizingGain(track, of: asset) }
                guard let g = try? await measure.value else { continue }
                sources?.gains[key] = g
                refresh(rebuild: false)
            }
        }
    }

    // MARK: Project

    /// Save a Copy As: the project as it is now (saved first), somewhere else.
    func saveCopyAs() {
        guard isStudio else { return }
        saveWork?.perform()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = package.url.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: StudioPackage.fileExtension) ?? .folder]
        guard panel.runModal() == .OK, let dst = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: package.url, to: dst)
            NSWorkspace.shared.activateFileViewerSelecting([dst])
        } catch { Toast.show(error.localizedDescription, isError: true) }
    }

    /// A .zip of the project (to send it or keep it), made with ditto like Finder's Compress.
    func zipProject() {
        guard isStudio else { return }
        saveWork?.perform()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = package.displayName + ".zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let dst = panel.url else { return }
        let src = package.url
        Task.detached {
            try? FileManager.default.removeItem(at: dst)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, dst.path]
            try? p.run()
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            await MainActor.run {
                if ok { NSWorkspace.shared.activateFileViewerSelecting([dst]) } else { Toast.show("Couldn't zip the project.", isError: true) }
            }
        }
    }

    func showInFinder() { NSWorkspace.shared.activateFileViewerSelecting([openOptions.original ?? package.url]) }

    /// Closes the editor and deletes the project for good (not the Trash); it leaves History too.
    /// Always confirmed: there's no "Don't show again" for something that can't be undone.
    func removeProject() {
        guard isStudio else { return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Delete “%@”?".loc(package.displayName)
        a.informativeText = "The project and its recording are deleted for good, not moved to the Trash. This can't be undone."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        a.localize()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        cancelExport()
        let url = package.url
        VideoEditor.close(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            do { try FileManager.default.removeItem(at: url) } catch {
                Toast.show(error.localizedDescription, isError: true)
                return
            }
            History.shared.forget(fileURL: url)
            if Prefs.string(.studioLastProject) == url.path { Prefs.reset(.studioLastProject) }
            Toast.show("Project deleted")
        }
    }

    /// Renames the project (and its History entry); the editor reopens under the new name.
    func renameProject() {
        guard isStudio else { return }
        let a = NSAlert()
        a.messageText = "Rename Project"
        let field = NSTextField(string: package.displayName)
        field.frame = CGRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.localize()
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        guard !name.isEmpty, name != package.displayName else { return }
        saveWork?.perform()
        let old = package.url
        VideoEditor.close(old)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            do {
                let dst = try History.shared.rename(old, to: name)
                VideoEditor.open(dst)
            } catch { Toast.show(error.localizedDescription, isError: true) }
        }
    }

    // MARK: Background images

    /// Favourite background images (macOS wallpapers or your own), newest first.
    var favoriteBackgrounds: [String] { Prefs.string(.studioFavoriteBackgrounds).split(separator: "\n").map(String.init) }

    func toggleFavoriteBackground(_ path: String) {
        var f = favoriteBackgrounds
        if let i = f.firstIndex(of: path) { f.remove(at: i) } else { f.insert(path, at: 0) }
        Prefs.set(f.joined(separator: "\n"), .studioFavoriteBackgrounds)
        objectWillChange.send()
    }

    func setBackgroundImage(_ path: String) {
        edit { $0.background.kind = .image; $0.background.imagePath = path }
    }

    func randomWallpaper() {
        let others = MacWallpapers.all.filter { $0.file.path != doc.background.imagePath }
        guard let w = others.randomElement() else { return }
        setBackgroundImage(w.file.path)
    }

    /// An image from the clipboard (pasted or dropped data), kept in Application Support › Backgrounds.
    @discardableResult
    func setBackgroundImage(from image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        let dir = Prefs.supportFolder.appendingPathComponent("Backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        guard (try? png.write(to: url)) != nil else { return false }
        setBackgroundImage(url.path)
        return true
    }

    func pasteBackgroundImage() {
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL])?.first {
            setBackgroundImage(url.path)
        } else if let img = NSImage(pasteboard: pb) {
            setBackgroundImage(from: img)
        } else {
            Toast.show("No image on the clipboard", isError: true)
        }
    }

    // MARK: Background music

    /// The music file: inside the project for Studio projects (copied there when chosen), else wherever it was picked.
    var musicURL: URL? {
        let p = doc.music.path
        guard !p.isEmpty else { return nil }
        return p.hasPrefix("/") ? URL(fileURLWithPath: p) : package.url.appendingPathComponent(p)
    }

    private static func loadExtra(_ url: URL?) async -> StudioSources.ExtraAudio? {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let range = try? await track.load(.timeRange) else { return nil }
        return .init(url: url, asset: asset, track: track, range: range)
    }

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose music to play under the video (it loops).".loc
        guard panel.runModal() == .OK, let src = panel.url else { return }
        setMusic(src)
    }

    /// Music from an audio file (chosen, or dropped on the Audio tab).
    func setMusic(_ src: URL) {
        guard UTType(filenameExtension: src.pathExtension)?.conforms(to: .audio) == true else { NSSound.beep(); return }
        var path = src.path
        if isStudio {
            // Copied into the project, so it moves (and is backed up) with it.
            let name = "music." + src.pathExtension.lowercased()
            let dst = package.url.appendingPathComponent(name)
            do {
                if let old = musicURL, old.deletingLastPathComponent() == package.url { try? FileManager.default.removeItem(at: old) }
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: src, to: dst)
                path = name
            } catch {
                Toast.show(error.localizedDescription, isError: true)
                return
            }
        }
        edit { $0.music.path = path; $0.music.muted = false }
    }

    func removeMusic() {
        edit { $0.music.path = "" }
    }

    // MARK: Still preview

    private let stillQueue = DispatchQueue(label: "app.daisyshot.studio.still", qos: .userInteractive)
    private var stillBusy = false
    private var stillPending = false

    /// A look change while paused (slider drags, camera dragging) is drawn straight from the frame the player already
    /// decoded, over the player, instead of seeking (which decodes again from the last keyframe). The newest model
    /// always wins; renders never queue up. Returns false when there's no matching frame (the caller seeks instead).
    private func renderStill() -> Bool {
        guard let model, let f = StudioCompositor.lastFrame, f.screen != nil, abs(f.time - clock.time) < 0.5 / fps,
              f.size == model.renderSize(maxSide: Self.previewMaxSide) else { return false }
        if stillBusy { stillPending = true; return true }
        stillBusy = true
        stillQueue.async { [weak self] in
            let img = model.render(outputTime: f.time, screen: f.screen.map { CIImage(cvPixelBuffer: $0) },
                                   camera: f.camera.map { CIImage(cvPixelBuffer: $0) }, size: f.size)
            let cg = StudioCompositor.context.createCGImage(img, from: CGRect(origin: .zero, size: f.size), format: .RGBA8,
                                                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            DispatchQueue.main.async {
                guard let self else { return }
                self.stillBusy = false
                if !self.isPlaying, let cg { self.preview.showStill(cg) }
                if self.stillPending {
                    self.stillPending = false
                    if !self.renderStill() { self.seek(to: self.clock.time) }
                }
            }
        }
        return true
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying { player.pause(); return }
        if clock.time >= duration - 0.5 / fps { seek(to: 0) }
        player.rate = 1
    }

    func play(rate: Float) {
        if rate < 0, player.currentItem?.canPlayReverse != true { step(-Int(fps / 2)); return }
        player.rate = rate
    }

    func pause() { player.pause() }

    /// Exact seek that never queues: while one is in flight, only the latest target is kept ("chase" seeking).
    /// Timeline scrubbing: seeks, and with "Audio while scrubbing" plays a tenth of a second at each spot.
    func scrub(to t: Double) {
        seek(to: t)
        guard Prefs.bool(.studioAudioScrub) else { return }
        scrubStop?.cancel()
        player.rate = 1
        let stop = DispatchWorkItem { [weak self] in self?.player.pause() }
        scrubStop = stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: stop)
    }
    private var scrubStop: DispatchWorkItem?

    /// Display name of audio track `i` (recorder order: system audio, then microphone, unless events.json says otherwise).
    func audioTrackName(_ i: Int) -> String {
        let n = sources?.audio.count ?? 0
        if n == 1 { return "Audio".loc }
        let kinds = events?.audioTracks ?? (isStudio && n == 2 ? ["system", "mic"] : [])
        switch kinds.indices.contains(i) ? kinds[i] : "" {
        case "system": return "System Audio".loc
        case "mic": return "Microphone".loc
        case "device": return "Device Audio".loc
        default: return "Track %d".loc(i + 1)
        }
    }

    func seek(to t: Double) {
        preview.showStill(nil)
        let t = min(max(0, t), max(0, duration))
        clock.time = t
        timeline.updatePlayhead(follow: true)
        seekTarget = CMTime(seconds: t, preferredTimescale: 60_000)
        if !seeking { chaseSeek() }
    }

    private func chaseSeek() {
        guard let target = seekTarget else { return }
        seekTarget = nil
        seeking = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seeking = false
                self.chaseSeek()
            }
        }
    }

    func step(_ frames: Int) {
        pause()
        let f = (clock.time * fps).rounded() + Double(frames)
        seek(to: min(f / fps, duration))
    }

    var clipEdges: [Double] { doc.clipStarts + [duration] }

    func jumpEdge(forward: Bool) {
        pause()
        let t = clock.time
        let e = forward ? clipEdges.first { $0 > t + 1e-3 } : clipEdges.last { $0 < t - 1e-3 }
        seek(to: e ?? (forward ? duration : 0))
    }

    // MARK: Timeline commands

    func splitAtPlayhead() {
        edit { _ = $0.split(at: clock.time) }
    }

    func splitZoomAtPlayhead() {
        edit { _ = $0.splitZoom(at: clock.time) }
    }

    func splitLayoutAtPlayhead() {
        edit { if !$0.splitLayout(at: clock.time) { NSSound.beep() } }
    }

    func removeAllLayouts() {
        edit { $0.layouts.removeAll() }
        if case .layout? = selection { selection = nil }
    }

    func setAllLayoutsDisabled(_ off: Bool) { edit { d in for i in d.layouts.indices { d.layouts[i].disabled = off } } }

    /// Every cut and trim undone: one clip of the whole recording.
    func removeAllCuts() {
        guard let src = sources else { return }
        edit { $0.removeAllCuts(sourceDuration: src.duration) }
        selection = nil
    }

    func stepLayoutCamera(_ id: UUID, dx: Int, dy: Int) {
        edit(coalesce: "pos-\(id)") { $0.stepLayoutCamera(id, dx: dx, dy: dy) }
    }

    /// One mask's blur amount / dimming on every mask of the same kind.
    func applyMaskStrengthToAll(_ m: StudioDocument.Mask) {
        edit { d in for i in d.masks.indices where d.masks[i].kind == m.kind { d.masks[i].strength = m.strength } }
    }

    func deleteSelection() {
        switch selection {
        case .clip(let id)?:
            guard doc.clips.count > 1 else { NSSound.beep(); return }
            edit { _ = $0.removeClip(id) }
            selection = nil
            seek(to: min(clock.time, duration))
        case .zoom(let id)?:
            edit { $0.zooms.removeAll { $0.id == id } }
            selection = nil
        case .mask(let id)?:
            edit { $0.masks.removeAll { $0.id == id } }
            selection = nil
        case .layout(let id)?:
            edit { $0.layouts.removeAll { $0.id == id } }
            selection = nil
        case nil:
            break
        }
    }

    @discardableResult
    func addZoom(_ range: ClosedRange<Double>) -> UUID? {
        var template = StudioDocument.Zoom(start: 0, end: 0)
        template.followCursor = hasPointer
        if let last = doc.zooms.last { template.scale = last.scale }
        var d = doc
        guard let id = d.addZoom(range, template: template) else { NSSound.beep(); return nil }
        pushUndo()
        doc = d
        selection = .zoom(id)
        return id
    }

    func autoZoom() {
        guard let ev = events else { return }
        let new = StudioDocument.autoZooms(ev, duration: sources?.duration ?? .infinity)
        guard !new.isEmpty else { Toast.show("No clicks to zoom on"); return }
        edit { $0.zooms = new }
        selection = nil
    }

    // MARK: Masks

    @Published private(set) var maskScanProgress: Double?
    private var maskScan: Task<Void, Never>?

    @discardableResult
    func addMask(_ range: ClosedRange<Double>, kind: MaskKind = .blur) -> UUID? {
        var d = doc
        guard let id = d.addMask(range, kind: kind) else { NSSound.beep(); return nil }
        pushUndo()
        doc = d
        selection = .mask(id)
        return id
    }

    func addMaskAtPlayhead(_ kind: MaskKind) {
        addMask(clock.time...min(duration, clock.time + 3), kind: kind)
    }

    func editMask(_ id: UUID, coalesce: String, _ change: (inout StudioDocument.Mask) -> Void) {
        edit(coalesce: "\(coalesce)-\(id)") { d in
            if let i = d.masks.firstIndex(where: { $0.id == id }) { change(&d.masks[i]) }
        }
    }

    /// A sharp frame of the recording (for drawing mask regions on).
    // MARK: Mask check

    /// Blur masks whose content seems to move (scroll) while they're on.
    @Published private(set) var maskWarnings: Set<UUID> = []
    private var maskCheck: Task<Void, Never>?

    /// Re-checks every blur mask a moment after masks change: frames every 0.5 s (at most 24) through each mask.
    func checkMasks() {
        maskCheck?.cancel()
        let masks = doc.masks.filter { $0.kind == .blur && !$0.regions.isEmpty }
        maskCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            var warn = Set<UUID>()
            for m in masks {
                let step = max(0.5, (m.end - m.start) / 24)
                var frames: [CGImage] = []
                for s in stride(from: m.start, through: m.end, by: step) {
                    guard !Task.isCancelled, let f = await self?.sourceFrame(at: s) else { return }
                    frames.append(f)
                }
                let regions = m.regions
                if await Task.detached(priority: .utility, operation: { StudioMaskFinder.contentMoves(frames, regions: regions) }).value { warn.insert(m.id) }
            }
            guard !Task.isCancelled, let self else { return }
            self.maskWarnings = warn
            self.timeline.needsDisplay = true
        }
    }

    func sourceFrame(at s: Double) async -> CGImage? {
        guard let src = sources else { return nil }
        let gen = AVAssetImageGenerator(asset: src.asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1200, height: 1200)
        return try? await gen.image(at: CMTime(seconds: min(max(0, s), src.duration), preferredTimescale: 600)).image
    }

    /// OCR pass over the recording; adds blur masks where sensitive text shows (skipping spans that already have one).
    func findSensitiveInfo() {
        guard let src = sources, maskScan == nil else { return }
        maskScanProgress = 0
        maskScan = Task { [weak self] in
            let found = await StudioMaskFinder.find(src.asset, duration: src.duration) { p in self?.maskScanProgress = p }
            guard let self else { return }
            defer { maskScan = nil; maskScanProgress = nil }
            guard !Task.isCancelled else { return }
            var d = doc, added = 0
            for m in found {
                let r = d.outputRange(m)
                guard r.upperBound - r.lowerBound > 0.05, d.masks.allSatisfy({ let o = d.outputRange($0); return o.upperBound <= r.lowerBound || o.lowerBound >= r.upperBound })
                else { continue }
                d.masks.append(m)
                added += 1
            }
            if added > 0 { pushUndo(); doc = d }
            Toast.show(added == 0 ? "No sensitive info found".loc : added == 1 ? "Added 1 blur mask".loc : "Added %d blur masks".loc(added))
        }
    }

    func cancelMaskScan() { maskScan?.cancel() }

    nonisolated static let typingSpeed = 3.0

    /// Typing stretches still playing at normal speed (source seconds).
    var typingSuggestions: [ClosedRange<Double>] { doc.typingSuggestions(typingBursts) }
    private lazy var typingBursts = events?.typingBursts ?? []

    func speedUpTyping(_ ranges: [ClosedRange<Double>], speed: Double = typingSpeed) {
        guard !ranges.isEmpty else { return }
        edit { d in for r in ranges { d.setSpeed(speed, source: r) } }
    }

    /// Typing stretches shown on the timeline (all detected ones whose suggestion wasn't removed), with their speed.
    var typingStretches: [(range: ClosedRange<Double>, speed: Double)] {
        typingBursts.filter { !doc.isDismissed($0) }.map { ($0, doc.speed(of: $0)) }
    }

    /// "Remove suggestion": the stretch plays at normal speed again and is no longer marked.
    func removeTypingSuggestion(_ r: ClosedRange<Double>) {
        edit { d in
            d.setSpeed(1, source: r)
            d.typingDismissed.append((r.lowerBound * 1000).rounded() / 1000)
        }
    }

    func setClipSpeed(_ id: UUID, _ speed: Double) {
        edit { d in if let i = d.clips.firstIndex(where: { $0.id == id }) { d.clips[i].speed = speed } }
    }

    func editClip(_ id: UUID, coalesce: String? = nil, _ change: @escaping (inout StudioDocument.Clip) -> Void) {
        edit(coalesce: coalesce.map { "\($0)\(id)" }) { d in if let i = d.clips.firstIndex(where: { $0.id == id }) { change(&d.clips[i]) } }
    }

    // MARK: Presets

    func applyPreset(_ url: URL) {
        guard let p = StudioPresets.load(url) else { NSSound.beep(); return }
        edit { $0 = StudioPresets.apply(p, to: $0) }
    }

    func savePreset() {
        let a = NSAlert()
        a.messageText = "Save Style as Preset"
        a.informativeText = "Cursor, keystrokes, camera, background and animation settings are saved under this name."
        let field = NSTextField(string: "")
        field.placeholderString = "Preset name".loc
        field.frame = CGRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.localize()
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        guard !name.isEmpty else { return }
        do {
            try StudioPresets.save(doc, name: name)
            Toast.show("Saved preset “%@”".loc(name))
        } catch { Toast.show(error.localizedDescription, isError: true) }
    }

    func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [StudioPresets.type]
        guard panel.runModal() == .OK, let src = panel.url else { return }
        do {
            let dst = try StudioPresets.importPreset(src)
            applyPreset(dst)
        } catch { Toast.show(error.localizedDescription, isError: true) }
    }

    /// Writes the preset with its custom background image inside, so it works on another Mac.
    func exportPreset(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [StudioPresets.type]
        guard panel.runModal() == .OK, let dst = panel.url else { return }
        do { try StudioPresets.exportPreset(url, to: dst) } catch { Toast.show(error.localizedDescription, isError: true) }
    }

    /// Overwrites a preset with the current look.
    func updatePreset(_ url: URL) {
        do {
            try StudioPresets.save(doc, name: url.deletingPathExtension().lastPathComponent)
            Toast.show("Updated preset “%@”".loc(url.deletingPathExtension().lastPathComponent))
        } catch { Toast.show(error.localizedDescription, isError: true) }
    }

    func deletePreset(_ url: URL) {
        NSWorkspace.shared.recycle([url])
    }

    @discardableResult
    func addLayout(_ range: ClosedRange<Double>) -> UUID? {
        offerToShowCamera()
        var id: UUID?
        edit { id = $0.addLayout(range) }
        if let id { selection = .layout(id) } else { NSSound.beep() }
        return id
    }

    /// Layouts do nothing while the camera is switched off for the project: offer to switch it back on.
    private func offerToShowCamera() {
        guard hasCamera, !doc.camera.show else { return }
        let a = NSAlert()
        a.messageText = "The camera is hidden in this project"
        a.informativeText = "Camera layouts only show while the camera is on. Show the camera?"
        a.addButton(withTitle: "Show Camera")
        a.addButton(withTitle: "Keep Hidden")
        a.localize()
        if a.runModal() == .alertFirstButtonReturn { edit { $0.camera.show = true } }
    }

    func setLayoutKind(_ id: UUID, _ kind: CameraLayoutKind) {
        edit { d in
            guard let i = d.layouts.firstIndex(where: { $0.id == id }) else { return }
            // A new custom layout starts from the camera as it is, so only what's then changed differs.
            if kind == .custom, d.layouts[i].kind != .custom {
                d.layouts[i].size = d.camera.size; d.layouts[i].x = d.camera.x; d.layouts[i].y = d.camera.y
            }
            d.layouts[i].kind = kind
        }
    }

    func editLayout(_ id: UUID, coalesce: String, _ change: @escaping (inout StudioDocument.CameraLayout) -> Void) {
        edit(coalesce: "\(coalesce)-\(id)") { d in if let i = d.layouts.firstIndex(where: { $0.id == id }) { change(&d.layouts[i]) } }
    }

    func mergeClipWithPrevious(_ id: UUID) {
        guard let i = doc.clips.firstIndex(where: { $0.id == id }), i > 0 else { NSSound.beep(); return }
        mergeClipWithNext(doc.clips[i - 1].id)
    }

    func resetTrim(_ id: UUID) {
        guard let src = sources else { return }
        edit { $0.resetTrim(id, sourceDuration: src.duration) }
    }

    /// Removes everything from the playhead back to the previous cut.
    func deleteToPreviousCut() {
        let t = clock.time
        let start = doc.clipIndex(at: t).map { doc.clipStarts[$0] } ?? 0
        edit { if !$0.deleteToPreviousCut(at: t) { NSSound.beep() } }
        seek(to: min(start, max(0, duration - 1 / fps)))
    }

    /// Turns the selected zoom, mask or camera layout off (kept on the timeline) or back on.
    func toggleSelectionDisabled() {
        edit { d in
            switch selection {
            case .zoom(let id)?: if let i = d.zooms.firstIndex(where: { $0.id == id }) { d.zooms[i].disabled.toggle() }
            case .mask(let id)?: if let i = d.masks.firstIndex(where: { $0.id == id }) { d.masks[i].disabled.toggle() }
            case .layout(let id)?: if let i = d.layouts.firstIndex(where: { $0.id == id }) { d.layouts[i].disabled.toggle() }
            default: NSSound.beep()
            }
        }
    }

    func setAllZoomsDisabled(_ off: Bool) { edit { d in for i in d.zooms.indices { d.zooms[i].disabled = off } } }
    func setAllMasksDisabled(_ off: Bool) { edit { d in for i in d.masks.indices { d.masks[i].disabled = off } } }

    /// A / M: the selected zoom follows the cursor, or stays where it's put.
    func setSelectedZoomFollows(_ follow: Bool) {
        guard case .zoom(let id)? = selection, hasPointer || !follow else { return }
        editZoom(id, coalesce: "mode") { $0.followCursor = follow }
    }

    func mergeClipWithNext(_ id: UUID) {
        edit { if !$0.mergeWithNext(id) { NSSound.beep() } }
    }

    func removeAllZooms() {
        edit { $0.zooms.removeAll() }
        selection = nil
    }

    func editZoom(_ id: UUID, coalesce: String, _ change: (inout StudioDocument.Zoom) -> Void) {
        edit(coalesce: "\(coalesce)-\(id)") { d in
            if let i = d.zooms.firstIndex(where: { $0.id == id }) { change(&d.zooms[i]) }
        }
    }

    // MARK: Export

    var baseName: String { isStudio ? package.displayName : package.displayName + " (edited)" }

    // MARK: Copy / paste

    /// What ⌘C took from the timeline: an item's settings (and its length, for pasting it as a new item).
    enum Copied {
        case clip(StudioDocument.Clip)
        case zoom(StudioDocument.Zoom, length: Double)
        case mask(StudioDocument.Mask, length: Double)
        case layout(StudioDocument.CameraLayout, length: Double)
    }
    private(set) var copied: Copied?

    /// ⌘C: the selected item's settings; with nothing selected, the current frame as an image.
    func copy() {
        switch selection {
        case .clip(let id)?: if let c = doc.clips.first(where: { $0.id == id }) { copied = .clip(c) }
        case .zoom(let id)?: if let z = doc.zooms.first(where: { $0.id == id }) { let r = doc.outputRange(z); copied = .zoom(z, length: r.upperBound - r.lowerBound) }
        case .mask(let id)?: if let m = doc.masks.first(where: { $0.id == id }) { let r = doc.outputRange(m); copied = .mask(m, length: r.upperBound - r.lowerBound) }
        case .layout(let id)?: if let l = doc.layouts.first(where: { $0.id == id }) { let r = doc.outputRange(l); copied = .layout(l, length: r.upperBound - r.lowerBound) }
        case nil: copyCurrentFrame()
        }
    }

    /// ⌘X: copy, then delete (clips are never cut this way: that's the cut tool's job).
    func cut() {
        guard let s = selection else { return }
        if case .clip = s { copy(); return }
        copy()
        deleteSelection()
    }

    /// ⌘V: the copied settings onto the selected item of the same kind, or a new item at the playhead.
    func paste() {
        guard let c = copied else { NSSound.beep(); return }
        switch (c, selection) {
        case (.clip(let src), .clip(let id)?):
            editClip(id) { $0.speed = src.speed; $0.volume = src.volume; $0.trackVolumes = src.trackVolumes; $0.hideCursor = src.hideCursor; $0.smoothCursor = src.smoothCursor }
        case (.zoom(let z, _), .zoom(let id)?):
            editZoom(id, coalesce: "paste") { $0.scale = z.scale; $0.followCursor = z.followCursor; $0.focusX = z.focusX; $0.focusY = z.focusY; $0.glide = z.glide; $0.glideAmount = z.glideAmount }
        case (.mask(let m, _), .mask(let id)?):
            editMask(id, coalesce: "paste") { $0.kind = m.kind; $0.strength = m.strength; $0.regions = m.regions }
        case (.layout(let l, _), .layout(let id)?):
            editLayout(id, coalesce: "paste") { $0.kind = l.kind; $0.size = l.size; $0.x = l.x; $0.y = l.y }
        default:
            let t = clock.time
            insert(c, at: t)
        }
    }

    /// ⌘D: a copy of the selected zoom, mask or layout right after it.
    func duplicateSelection() {
        let saved = copied
        defer { copied = saved }
        copy()
        guard let c = copied else { return }
        let end: Double
        switch selection {
        case .zoom(let id)?: end = doc.zooms.first { $0.id == id }.map { doc.outputRange($0).upperBound } ?? clock.time
        case .mask(let id)?: end = doc.masks.first { $0.id == id }.map { doc.outputRange($0).upperBound } ?? clock.time
        case .layout(let id)?: end = doc.layouts.first { $0.id == id }.map { doc.outputRange($0).upperBound } ?? clock.time
        default: NSSound.beep(); return
        }
        insert(c, at: end)
    }

    /// A copied zoom / mask / layout as a new item starting at output time `t` (clamped into the free gap there).
    private func insert(_ c: Copied, at t: Double) {
        var d = doc
        var added: Selection?
        switch c {
        case .clip: NSSound.beep(); return
        case let .zoom(z, len):
            if let id = d.addZoom(t...(t + len), template: z) { added = .zoom(id) }
        case let .mask(m, len):
            if let id = d.addMask(t...(t + len), kind: m.kind), let i = d.masks.firstIndex(where: { $0.id == id }) {
                d.masks[i].strength = m.strength
                d.masks[i].regions = m.regions
                added = .mask(id)
            }
        case let .layout(l, len):
            if let id = d.addLayout(t...(t + len), kind: l.kind) { added = .layout(id) }
        }
        guard let added else { NSSound.beep(); return }
        pushUndo()
        doc = d
        selection = added
    }

    /// The frame under the playhead, rendered like an export, onto the clipboard.
    func copyCurrentFrame() {
        guard let src = sources, let model = makeModel(), let comp else { return }
        let t = clock.time
        Task {
            do {
                let vc = StudioComposer.videoComposition(comp, model: model, renderSize: model.renderSize(maxSide: 8192), fps: src.fps)
                let img = try await StudioExportJob.frame(comp, video: vc, at: t)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([NSImage(cgImage: img, size: CGSize(width: img.width, height: img.height))])
                Toast.show("Copied the current frame")
            } catch {
                Toast.show("Couldn't export the frame: %@".loc(error.localizedDescription), isError: true)
            }
        }
    }

    func exportCurrentFrame() {
        guard let src = sources, let model = makeModel(), let comp else { return }
        let t = clock.time
        let scale = CGFloat(events?.scale ?? 1)
        Task {
            do {
                let vc = StudioComposer.videoComposition(comp, model: model, renderSize: model.renderSize(maxSide: 8192), fps: src.fps)
                let img = try await StudioExportJob.frame(comp, video: vc, at: t)
                let shot = Shot(image: img, scale: max(1, scale))
                let url = try Exporter.save(shot, name: Exporter.fileName(type: "Screenshot"))
                Sounds.done()
                QuickAccess.shared.add(.image(shot, fileURL: url, saved: true))
            } catch {
                Toast.show("Couldn't export the frame: %@".loc(error.localizedDescription), isError: true)
            }
        }
    }

    /// Format "Replace original" must write: the original's kind (GIF or video).
    var replaceFormat: StudioExportFormat? {
        openOptions.original.map { $0.pathExtension.lowercased() == "gif" ? .gif : .mp4 }
    }

    /// Exports waiting for the running one (started one after another).
    private var exportQueue: [StudioExportOptions] = []
    /// When the running export started (for the time-left estimate).
    private(set) var exportStarted: Date?

    /// ⌥⌘S / ⌥⌘C: export with the export sheet's last settings, to a file or the clipboard.
    func exportWithLastSettings(copy: Bool) {
        guard sources != nil else { return }
        export(.last(format: exportFormat, mono: doc.audio.mono, copy: copy))
    }

    /// Seconds left, from the progress so far (nil until there's enough to tell).
    var exportTimeLeft: Double? {
        guard let p = exportProgress, p > 0.03, let s = exportStarted else { return nil }
        let elapsed = Date().timeIntervalSince(s)
        return elapsed / p * (1 - p)
    }

    func export(_ options: StudioExportOptions) {
        if exportTask != nil {
            exportQueue.append(options)
            Toast.show("Export queued (%d waiting)".loc(exportQueue.count))
            return
        }
        // An extra version (Export › Also export): the same edit in another frame shape, filling it and following the cursor.
        var renderDoc = doc
        var suffix = ""
        if let a = options.aspect {
            renderDoc.background.aspect = a
            renderDoc.background.fillFrame = true
            suffix = " (" + a.ratioText + ")"
        }
        guard let src = sources, let model = makeModel(renderDoc) else { return }
        pause()
        var options = options
        let target = options.replaceOriginal && options.aspect == nil ? openOptions.original : nil
        if target != nil, let f = replaceFormat { options.format = f }
        let size = options.resolution.size(for: model.canvasSize)
        let folder = Prefs.exportFolder
        let dst: URL
        if let target {   // render next to the original (same volume), then swap it in
            do {
                let tmp = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
                dst = tmp.appendingPathComponent(target.lastPathComponent)
            } catch {
                Toast.show("Couldn't replace the original: %@".loc(error.localizedDescription), isError: true)
                return
            }
        } else {
            dst = Exporter.uniqueURL(in: folder, name: (openOptions.name ?? baseName) + suffix.replacingOccurrences(of: ":", with: "x"), ext: options.format.rawValue)
        }
        let job = StudioExportJob()
        exportJob = job
        exportProgress = 0
        exportStarted = Date()
        NotificationCenter.default.post(name: .daisyshotBusyDidChange, object: true)
        let doc = renderDoc
        exportTask = Task {
            defer {
                exportTask = nil; exportJob = nil; exportProgress = nil; exportStarted = nil
                if target != nil { try? FileManager.default.removeItem(at: dst.deletingLastPathComponent()) }
                NotificationCenter.default.post(name: .daisyshotBusyDidChange, object: false)
                if !exportQueue.isEmpty { export(exportQueue.removeFirst()) }
            }
            do {
                if target == nil { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
                await prepareAudio()
                let src = sources ?? src
                let comp = try StudioComposer.composition(src, doc: doc, audio: options.format == .mp4 && options.includeAudio)
                let fps = options.format == .gif ? Double(options.quality.gifFPS) : options.frameRate(source: src.fps)
                let vc = StudioComposer.videoComposition(comp, model: model, renderSize: size, fps: fps)
                if options.format == .gif {
                    // Same encoder and Settings › GIF quality / optimization as recorded GIFs.
                    try await GIFEncoder.convert(comp, videoComposition: vc, to: dst, fps: options.quality.gifFPS, maxWidth: Int(size.width),
                                                 quality: Prefs.int(.recGIFQuality), optimize: Prefs.bool(.recGIFOptimize), loop: options.gifLoop) { [weak self] p in
                        Task { @MainActor in if self?.exportProgress != nil { self?.exportProgress = p } }
                    }
                } else {
                    try await job.writeMP4(comp, video: vc, audioMix: StudioComposer.audioMix(comp, doc: doc, sources: src), options: options, fps: fps, to: dst) { [weak self] p in
                        Task { @MainActor in if self?.exportProgress != nil { self?.exportProgress = p } }
                    }
                }
                if let target {
                    try FileManager.default.replaceRemovingBackup(target, with: dst)
                }
                showExport = false
                baseline = doc
                dirty = false
                Sounds.done()
                QuickAccess.shared.add(.video(target ?? dst, saved: target == nil || openOptions.saved))
                if !NSApp.isActive { Self.notify("Export finished".loc, (target ?? dst).lastPathComponent) }
                if options.copyToClipboard {
                    Exporter.copyFile(target ?? dst)
                    Toast.show("Copied to clipboard")
                    Self.rememberClipboardExport(target ?? dst)
                }
                // The editor's clips refer to the old media, so a replaced file closes the editor.
                if target != nil { preview.window?.close() }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: dst)
            } catch {
                try? FileManager.default.removeItem(at: dst)
                Toast.show("Export failed: %@".loc(error.localizedDescription), isError: true)
            }
        }
    }

    /// Exports that went to the clipboard, newest first (files still on disk).
    static var clipboardExports: [URL] {
        Prefs.string(.studioClipboardExports).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func rememberClipboardExport(_ url: URL) {
        let list = [url] + clipboardExports.filter { $0 != url }
        Prefs.set(list.prefix(10).map(\.path).joined(separator: "\n"), .studioClipboardExports)
    }

    func cancelExport() {
        exportQueue.removeAll()
        exportJob?.cancel()
        exportTask?.cancel()
    }

    /// A system notification (exports finishing while you're in another app). Skipped in unbundled debug runs.
    private static func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}

// MARK: - Preview

/// Player layer showing the live composition. Drag the camera bubble to place it; click to play / pause.
final class StudioPreviewView: NSView {
    private unowned let editor: StudioEditor
    let playerLayer = AVPlayerLayer()
    private let stillLayer = CALayer()      // a look change drawn while paused, over the player's frame
    private var dragOffset: CGPoint?
    private var pressedOnVideo = false

    init(editor: StudioEditor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        playerLayer.player = editor.player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        stillLayer.contentsGravity = .resizeAspect
        stillLayer.isHidden = true
        layer?.addSublayer(stillLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        stillLayer.frame = bounds
        CATransaction.commit()
    }

    /// Shows `image` over the player (nil hides it).
    func showStill(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stillLayer.contents = image
        stillLayer.isHidden = image == nil
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { false }

    private var renderSize: CGSize? { editor.model?.renderSize(maxSide: StudioEditor.previewMaxSide) }

    /// View point → render-space point (bottom-left origin) and the scale between them.
    private func toRender(_ p: CGPoint) -> (CGPoint, CGFloat)? {
        guard let size = renderSize else { return nil }
        var vr = playerLayer.videoRect
        if vr.width < 1 {   // before the first frame: assume aspect fit
            let k = min(bounds.width / size.width, bounds.height / size.height)
            vr = CGRect(x: (bounds.width - size.width * k) / 2, y: (bounds.height - size.height * k) / 2, width: size.width * k, height: size.height * k)
        }
        let k = size.width / vr.width
        return (CGPoint(x: (p.x - vr.minX) * k, y: (p.y - vr.minY) * k), k)
    }

    private func cameraRect() -> CGRect? {
        guard editor.hasCamera, editor.doc.camera.show, let model = editor.model, let size = renderSize else { return nil }
        return model.cameraRect(size, envelope: model.zoomState(at: editor.clock.time).envelope, at: editor.clock.time)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (rp, _) = toRender(p), let r = cameraRect(), r.insetBy(dx: -6, dy: -6).contains(rp) {
            dragOffset = CGPoint(x: rp.x - r.midX, y: rp.y - r.midY)
            editor.pushUndo()
            NSCursor.closedHand.set()
            return
        }
        pressedOnVideo = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let off = dragOffset, let size = renderSize, let (rp, _) = toRender(convert(event.locationInWindow, from: nil)) else { return }
        let c = CGPoint(x: rp.x - off.x, y: rp.y - off.y)
        let x = min(1, max(0, c.x / size.width)), y = min(1, max(0, 1 - c.y / size.height))
        // With a "custom camera" layout selected, dragging moves the camera of that layout only.
        if let l = editor.selectedLayout, l.kind == .custom {
            editor.previewEdit { d in if let i = d.layouts.firstIndex(where: { $0.id == l.id }) { d.layouts[i].x = x; d.layouts[i].y = y } }
        } else {
            editor.previewEdit { $0.camera.x = x; $0.camera.y = y }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragOffset != nil {
            dragOffset = nil
            editor.commitLive()
            NSCursor.openHand.set()
        } else if pressedOnVideo, event.clickCount == 1 {
            editor.togglePlay()
        }
        pressedOnVideo = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        if let (rp, _) = toRender(convert(event.locationInWindow, from: nil)), let r = cameraRect(), r.contains(rp) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

// MARK: - Window

@MainActor
final class StudioWindowController: NSObject, NSWindowDelegate {
    let editor: StudioEditor
    let window: NSWindow
    var onClose: (() -> Void)?
    private var keyMonitor: Any?

    init(package: StudioPackage, options: StudioOpenOptions = .init()) {
        editor = StudioEditor(package: package, options: options)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1240, height: 800),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = package.displayName
        window.representedURL = options.original ?? package.url
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = StudioTheme.windowNS
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = CGSize(width: 900, height: 600)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("DaisyshotStudioEditor")
        window.contentView = NSHostingView(rootView: StudioEditorView(editor: editor, clock: editor.clock))
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            return self.handleKey(e) ? nil : e
        }
    }

    func show(_ sources: StudioSources) {
        if !window.setFrameUsingName("DaisyshotStudioEditor") { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        #if DEBUG
        StudioDocument.selfTest()
        #endif
        editor.load(sources)
    }

    // MARK: Shortcuts

    /// ⌘1… open the sidebar's tabs in order.
    private static let tabKeys: [Int: Int] = [kVK_ANSI_1: 0, kVK_ANSI_2: 1, kVK_ANSI_3: 2, kVK_ANSI_4: 3, kVK_ANSI_5: 4, kVK_ANSI_6: 5, kVK_ANSI_7: 6]

    private func handleKey(_ e: NSEvent) -> Bool {
        if window.firstResponder is NSText || window.attachedSheet != nil || editor.showExport || editor.showShortcutsGuide { return false }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let ed = editor
        // Fixed keys: Esc, Delete, Home/End, undo/redo.
        switch (Int(e.keyCode), mods) {
        case (kVK_Delete, []), (kVK_ForwardDelete, []): ed.deleteSelection(); return true
        case (kVK_Escape, []):
            // Esc leaves preview-only, then the cut tool, then the selection.
            if ed.previewOnly { ed.previewOnly = false } else if ed.tool == .cut { ed.tool = .select } else { ed.selection = nil }
            return true
        case (kVK_ANSI_Slash, .command): ed.showShortcutsGuide = true; return true
        case let (code, .command) where Self.tabKeys[code] != nil:
            let i = Self.tabKeys[code]!
            if i < StudioEditor.Tab.allCases.count { ed.selection = nil; ed.previewOnly = false; ed.tab = StudioEditor.Tab.allCases[i] }
            return true
        case (kVK_Home, _): ed.pause(); ed.seek(to: 0); return true
        case (kVK_End, _): ed.pause(); ed.seek(to: ed.duration); return true
        case (kVK_ANSI_Z, .command): ed.undo(); return true
        case (kVK_ANSI_Z, [.command, .shift]): ed.redo(); return true
        case (kVK_ANSI_C, .command): ed.copy(); return true
        case (kVK_ANSI_X, .command): ed.cut(); return true
        case (kVK_ANSI_V, .command): ed.paste(); return true
        case (kVK_ANSI_D, .command): ed.duplicateSelection(); return true
        case (kVK_ANSI_S, [.command, .shift]): ed.saveCopyAs(); return true
        case (kVK_ANSI_O, [.command, .shift]): ed.showInFinder(); return true
        // ⌥ arrows: the selected custom layout's camera, one position over.
        case (kVK_LeftArrow, .option), (kVK_RightArrow, .option), (kVK_UpArrow, .option), (kVK_DownArrow, .option):
            guard case .layout(let id)? = ed.selection, ed.doc.layouts.first(where: { $0.id == id })?.kind == .custom else { return false }
            let d = [kVK_LeftArrow: (-1, 0), kVK_RightArrow: (1, 0), kVK_UpArrow: (0, -1), kVK_DownArrow: (0, 1)][Int(e.keyCode)]!
            ed.stepLayoutCamera(id, dx: d.0, dy: d.1)
            return true
        default: break
        }
        let actions: [(String, () -> Void)] = [
            ("video.playPause", ed.togglePlay),
            ("video.start", { ed.pause(); ed.seek(to: 0) }),
            ("video.end", { ed.pause(); ed.seek(to: ed.duration) }),
            ("video.nextEdge", { ed.jumpEdge(forward: true) }),
            ("video.previousEdge", { ed.jumpEdge(forward: false) }),
            ("video.nextFrame", { ed.step(1) }),
            ("video.previousFrame", { ed.step(-1) }),
            ("video.forward10", { ed.step(10) }),
            ("video.back10", { ed.step(-10) }),
            ("video.playReverse", { ed.play(rate: ed.isPlaying && ed.player.rate <= -1 ? max(-4, ed.player.rate * 2) : -1) }),
            ("video.pause", ed.pause),
            ("video.playForward", { ed.play(rate: ed.isPlaying && ed.player.rate >= 1 ? min(4, ed.player.rate * 2) : 1) }),
            ("video.splitClip", ed.splitAtPlayhead),
            ("video.splitZoom", ed.splitZoomAtPlayhead),
            ("video.zoomIn", { ed.timeline.zoom(by: 1.5) }),
            ("video.zoomOut", { ed.timeline.zoom(by: 1 / 1.5) }),
            ("video.fitTimeline", { ed.timeline.zoomToFit() }),
            ("video.fullScreen", { [window] in window.toggleFullScreen(nil) }),
            ("video.exportFrame", ed.exportCurrentFrame),
            ("video.export", { if ed.sources != nil, ed.exportProgress == nil { ed.showExport = true } }),
            ("video.cutTool", { ed.tool = .cut }),
            ("video.selectionTool", { ed.tool = .select }),
            ("video.loop", { ed.loopPlayback.toggle() }),
            ("video.toggleDisabled", ed.toggleSelectionDisabled),
            ("video.deleteToCut", ed.deleteToPreviousCut),
            ("video.zoomFollow", { ed.setSelectedZoomFollows(true) }),
            ("video.zoomManual", { ed.setSelectedZoomFollows(false) }),
            ("video.previewOnly", { ed.previewOnly.toggle() }),
            ("video.exportLast", { ed.exportWithLastSettings(copy: false) }),
            ("video.exportLastCopy", { ed.exportWithLastSettings(copy: true) }),
        ]
        guard let action = actions.first(where: { EditorShortcuts.matches(e, $0.0) }) else { return false }
        action.1()
        return true
    }

    // MARK: Close

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if editor.exportProgress != nil {
            let a = NSAlert()
            a.messageText = "Stop the export?"
            a.informativeText = "Closing the editor stops the export that's running."
            a.addButton(withTitle: "Keep Exporting")
            a.addButton(withTitle: "Stop and Close").hasDestructiveAction = true
            a.localize()
            a.beginSheetModal(for: window) { [weak self] r in
                guard r == .alertSecondButtonReturn, let self else { return }
                self.editor.cancelExport()
                DispatchQueue.main.async { self.window.performClose(nil) }
            }
            return false
        }
        guard !editor.isStudio, editor.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Export your changes before closing?"
        alert.informativeText = "Edits to “%@” are lost if you close without exporting.".loc(editor.package.url.lastPathComponent)
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Export").hasDestructiveAction = true
        alert.localize()
        alert.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            switch r {
            case .alertFirstButtonReturn: self.editor.showExport = true
            case .alertThirdButtonReturn: self.editor.markClean(); self.window.close()
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        editor.close()
        onClose?()
    }
}

extension StudioEditor {
    func markClean() {
        baseline = doc
        dirty = false
    }
}

// MARK: - Finding sensitive info

/// Reads the recording about once a second (identical frames reuse the previous result) and turns enabled kinds of
/// sensitive text (Settings › Auto Redact) into blur regions; runs of samples with findings become masks.
@MainActor
enum StudioMaskFinder {
    /// Gray 24 × 24 thumbnail of `r` (normalized, top-left origin) inside `img`.
    nonisolated private static func patch(_ img: CGImage, _ r: CGRect) -> [UInt8]? {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let px = CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h).integral
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard px.width >= 2, px.height >= 2, let crop = img.cropping(to: px),
              let ctx = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 24, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 24, height: 24))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 24 * 24))
    }

    /// Share of pixels that changed by more than 24 levels.
    nonisolated private static func change(_ a: [UInt8], _ b: [UInt8]) -> Double {
        Double(zip(a, b).filter { abs(Int($0) - Int($1)) > 24 }.count) / Double(max(1, a.count))
    }

    /// "Data may be visible": between consecutive frames both a region and the ring around it change a lot — the
    /// content scrolled or moved under the blur. (Typing in a masked field changes only the inside, so it doesn't count.)
    nonisolated static func contentMoves(_ frames: [CGImage], regions: [StudioDocument.Mask.Region]) -> Bool {
        for g in regions {
            let r = CGRect(x: g.x, y: g.y, width: g.width, height: g.height)
            let ring = r.insetBy(dx: -max(0.02, r.width * 0.5), dy: -max(0.02, r.height * 0.5))
            var last: (inside: [UInt8], around: [UInt8])?
            for f in frames {
                guard let i = patch(f, r), let a = patch(f, ring) else { continue }
                if let l = last, change(l.inside, i) > 0.3, change(l.around, a) > 0.3 { return true }
                last = (i, a)
            }
        }
        return false
    }

    static func find(_ asset: AVAsset, duration: Double, progress: @escaping (Double) -> Void) async -> [StudioDocument.Mask] {
        let step = max(1, duration / 600)
        let times = Array(stride(from: 0, to: duration, by: step))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 2560, height: 2560)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        let matcher = SensitiveMatcher(custom: Prefs.string(.autoRedactCustomPatterns))
        var samples: [(t: Double, regions: [StudioDocument.Mask.Region])] = []
        var lastPrint: [UInt8]?, lastRegions: [StudioDocument.Mask.Region] = []
        for (i, t) in times.enumerated() {
            if Task.isCancelled { return [] }
            guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            let print = fingerprint(img)
            if lastPrint.map({ !same($0, print) }) ?? true {
                let size = CGSize(width: img.width, height: img.height)
                let lines = await TextScan.lines(img, size: size)
                let found = await Task.detached(priority: .userInitiated) { SensitiveScanner.findings(in: lines, matcher) }.value
                lastRegions = found.filter { $0.kind != .face && $0.kind.isEnabled }.map { f in
                    let r = f.rect.insetBy(dx: -size.width * 0.004, dy: -size.height * 0.004)
                    return .init(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
                }
                lastPrint = print
            }
            samples.append((t, lastRegions))
            progress(Double(i + 1) / Double(times.count))
        }
        return masks(samples, step: step, duration: duration)
    }

    /// Consecutive samples with findings → one mask from half a step before the first to half a step after the last,
    /// covering every box seen (overlapping boxes merged).
    static func masks(_ samples: [(t: Double, regions: [StudioDocument.Mask.Region])], step: Double, duration: Double) -> [StudioDocument.Mask] {
        var out: [StudioDocument.Mask] = []
        var current: StudioDocument.Mask?
        for s in samples {
            guard !s.regions.isEmpty else {
                if let c = current { out.append(c); current = nil }
                continue
            }
            var m = current ?? StudioDocument.Mask(start: max(0, s.t - step / 2), end: 0, kind: .blur)
            m.end = min(duration, s.t + step / 2)
            for r in s.regions { merge(r, into: &m.regions) }
            current = m
        }
        if let c = current { out.append(c) }
        return out
    }

    private static func merge(_ r: StudioDocument.Mask.Region, into list: inout [StudioDocument.Mask.Region]) {
        func rect(_ g: StudioDocument.Mask.Region) -> CGRect { CGRect(x: g.x, y: g.y, width: g.width, height: g.height) }
        let a = rect(r)
        if let i = list.firstIndex(where: { let b = rect($0), o = a.intersection(b); return !o.isNull && o.width * o.height > 0.5 * min(a.width * a.height, b.width * b.height) }) {
            let u = a.union(rect(list[i]))
            list[i] = .init(x: u.minX, y: u.minY, width: u.width, height: u.height)
        } else {
            list.append(r)
        }
    }

    /// 128×72 grayscale thumbnail. Frames count as the same picture only when no thumbnail pixel changed visibly, so a
    /// short password appearing in a field still triggers a new scan (static screen video encodes without flicker).
    private static func fingerprint(_ img: CGImage) -> [UInt8] {
        let w = 128, h = 72
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data else { return [] }
        return Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: w * h))
    }

    private static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && !a.isEmpty && !zip(a, b).contains { abs(Int($0) - Int($1)) > 3 }
    }

    #if DEBUG
    /// A video showing an email address for its first 1.5 s gets one blur mask over the address, for that span.
    static func ocrSelfTest() async -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-ocr-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await StudioSample.writeVideo(to: url, size: CGSize(width: 1280, height: 720), seconds: 3, audio: false) { ctx, t in
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
                guard t < 1.5 else { return }
                let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Contact: an.nguyen@company.vn", attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
                ]))
                ctx.textPosition = CGPoint(x: 100, y: 500)     // bottom-left origin: near the top of the frame
                CTLineDraw(line, ctx)
            }
            let found = await find(AVURLAsset(url: url), duration: 3) { _ in }
            guard found.count == 1, let m = found.first, m.start == 0, abs(m.end - 1.5) < 0.01, m.regions.count == 1 else { return "masks \(found)" }
            let r = m.regions[0]
            // "an.nguyen@company.vn" starts right of "Contact: " (x ≈ 0.22) and sits around y ≈ 0.27 from the top.
            guard r.x > 0.15, r.x < 0.4, r.y > 0.15, r.y < 0.35, r.width < 0.5 else { return "region \(r)" }
            return nil
        } catch { return error.localizedDescription }
    }
    #endif

    static func selfTest() {
        // Scrolling (everything shifts) warns; typing inside the masked field (only the inside changes) doesn't.
        func page(shift: Int, fieldDark: Bool = false) -> CGImage {
            let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            ctx.setFillColor(gray: 0, alpha: 1)
            for k in 0..<12 { ctx.fill(CGRect(x: 10, y: (k * 17 + shift) % 200, width: 180, height: 7)) }
            if fieldDark { ctx.fill(CGRect(x: 80, y: 80, width: 40, height: 40)) }
            return ctx.makeImage()!
        }
        let field = [StudioDocument.Mask.Region(x: 0.4, y: 0.4, width: 0.2, height: 0.2)]
        assert(contentMoves([page(shift: 0), page(shift: 9)], regions: field), "scrolled content is detected")
        assert(!contentMoves([page(shift: 0), page(shift: 0, fieldDark: true)], regions: field), "typing inside the field isn't")
        let r = StudioDocument.Mask.Region(x: 0.1, y: 0.1, width: 0.2, height: 0.05)
        let far = StudioDocument.Mask.Region(x: 0.6, y: 0.7, width: 0.2, height: 0.05)
        let ms = masks([(0, []), (1, [r]), (2, [r, far]), (3, []), (4, [far])], step: 1, duration: 5)
        assert(ms.count == 2 && ms[0].start == 0.5 && ms[0].end == 2.5 && ms[0].regions.count == 2 && ms[1].start == 3.5 && ms[1].end == 4.5)
    }
}
