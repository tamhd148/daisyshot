import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Studio Mode capture: the screen is recorded without the cursor while mouse/keyboard events are logged, so the
/// video editor can draw its own cursor, clicks, zooms and keystrokes. Output is a package directory:
///
///     <name>.daisyshotvideo/
///         video.mp4     screen (+ audio), cursor not visible
///         camera.mov    optional, webcam recorded separately
///         events.json   StudioEventsFile (schema below)
///         cursors/      one PNG per cursor shape seen + cursors.json (CursorShapeFile)
enum StudioCaptureLayout {
    static let ext = MediaKind.projectExtension
    static let video = "video.mp4"
    static let camera = "camera.mov"
    static let events = "events.json"
    static let cursors = "cursors"
}

/// events.json, version 1. Points; positions relative to the recorded region's top-left; `t` in seconds of video time.
struct StudioEventsFile: Codable, Equatable {
    struct Region: Codable, Equatable { var x, y, width, height: Double }
    struct Event: Codable, Equatable {
        var t: Double
        var type: String        // move | down | up | rightDown | rightUp | scroll | key | typing | cursor
        var x: Double
        var y: Double
        var key: String?        // "⌘C" for key events
        var cursor: String?     // shape id for cursor events (the pointer changed shape here)
    }

    var version = 1
    var region: Region          // display-local top-left points
    var scale: Double           // video pixels per point
    var duration: Double
    var cursorVisibleInVideo = false
    var events: [Event]
    var audioTracks: [String]? = nil   // track order when written separately, e.g. ["system", "mic"]
    var cameraOffset: Double? = nil    // video time at which camera.mov starts
    var device: String? = nil          // iPhone / iPad recordings: the device's name (no pointer, region = its pixels)

    func write(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }

    static func selfTest() {
        let s = StudioEventsFile(region: Region(x: 10, y: 20, width: 300, height: 200), scale: 2, duration: 1.5,
                             events: [Event(t: 0.016, type: "move", x: 1, y: 2), Event(t: 1, type: "key", x: 0, y: 0, key: "⌘C")])
        let data = try! JSONEncoder().encode(s)
        let json = String(decoding: data, as: UTF8.self)
        assert(json.contains("\"version\":1") && json.contains("\"cursorVisibleInVideo\":false"))
        assert(!json.contains("\"key\":null"), "key omitted when absent")
        assert(try! JSONDecoder().decode(StudioEventsFile.self, from: data) == s)
        var log = StudioEventLog(region: CGRect(x: 100, y: 100, width: 400, height: 300), screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let p = log.local(CGPoint(x: 150, y: 650))     // AppKit point → 50 right, 50 below the region's top (800-100-650)
        assert(p.x == 50 && p.y == 50)
        log.add(t: 0, type: "move", at: CGPoint(x: 150, y: 650))
        log.add(t: 0.005, type: "move", at: CGPoint(x: 151, y: 650))
        assert(log.events.count == 1, "moves are throttled to 60 Hz")
        log.add(t: 0.006, type: "down", at: CGPoint(x: 151, y: 650))
        assert(log.events.count == 2, "clicks are never dropped")
        // A mouse event goes through the monitor handler's field reading without raising.
        if let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) {
            let f = MainActor.assumeIsolated { StudioEventLogger.fields(click) }
            assert(f.type == .leftMouseDown && f.code == 0 && f.chars == nil)
        }
    }
}

/// Pure event bookkeeping (coordinate conversion, 60 Hz move throttle).
struct StudioEventLog {
    var region: CGRect          // display-local top-left points (moves with a followed window)
    let screenFrame: CGRect     // AppKit global frame of the display
    private(set) var events: [StudioEventsFile.Event] = []
    private var lastMove: (t: Double, x: Double, y: Double)?

    init(region: CGRect, screenFrame: CGRect) {
        self.region = region
        self.screenFrame = screenFrame
    }

    /// AppKit global point → region-relative top-left points.
    func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - screenFrame.minX - region.minX, y: screenFrame.maxY - p.y - region.minY)
    }

    mutating func add(t: Double, type: String, at global: CGPoint, key: String? = nil, cursor: String? = nil) {
        let p = local(global)
        let x = Double((p.x * 10).rounded() / 10), y = Double((p.y * 10).rounded() / 10)
        if type == "move" {
            if let m = lastMove, (m.x == x && m.y == y) || t - m.t < 1.0 / 60 - 1e-4 { return }
            lastMove = (t, x, y)
        }
        events.append(.init(t: (t * 1000).rounded() / 1000, type: type, x: x, y: y, key: key, cursor: cursor))
    }

    mutating func reset() {
        events.removeAll()
        lastMove = nil
    }
}

/// Logs mouse and keyboard while recording. `clock` returns the current video time, or nil while paused.
@MainActor
final class StudioEventLogger {
    private(set) var log: StudioEventLog
    let shapes = CursorShapeRecorder()
    private var lastShape: String?
    private let window: (id: CGWindowID, display: CGDirectDisplayID)?
    private let clock: () -> Double?
    private var monitors: [Any] = []
    private var timer: Timer?

    /// With `window`, positions are relative to that window wherever it moves (the video follows it).
    init(region: CGRect, screen: NSScreen, window: (id: CGWindowID, display: CGDirectDisplayID)? = nil, clock: @escaping () -> Double?) {
        log = StudioEventLog(region: region, screenFrame: screen.frame)
        self.window = window
        self.clock = clock
    }

    func start() {
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]
        let handler: (NSEvent) -> Void = { [weak self] e in
            let f = Self.fields(e)
            MainActor.assumeIsolated { self?.record(f.type, code: f.code, chars: f.chars, flags: f.flags) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mouse.union(.keyDown), handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { handler($0); return $0 }) { monitors.append(l) }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleMove() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// keyCode / characters exist only on key events: asking a mouse event raises, and AppKit swallows the exception
    /// and drops the event — every click in the app (even the Stop button) did nothing while recording.
    nonisolated static func fields(_ e: NSEvent) -> (type: NSEvent.EventType, code: UInt16, chars: String?, flags: NSEvent.ModifierFlags) {
        let key = e.type == .keyDown || e.type == .keyUp
        return (e.type, key ? e.keyCode : 0, key ? e.characters : nil, e.modifierFlags)
    }

    func reset() { log.reset() }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func sampleMove() {
        guard let t = clock() else { return }
        // ponytail: follows moves, not resizes (the video scales a resized window to the first size; positions would drift)
        if let window, let f = CaptureService.windowFrame(window.id) {
            let d = CGDisplayBounds(window.display)
            log.region.origin = CGPoint(x: f.minX - d.minX, y: f.minY - d.minY)
        }
        let p = NSEvent.mouseLocation
        log.add(t: t, type: "move", at: p)
        if let id = shapes.current(), id != lastShape {
            lastShape = id
            log.add(t: t, type: "cursor", at: p, cursor: id)
        }
    }

    private func record(_ type: NSEvent.EventType, code: UInt16, chars: String?, flags: NSEvent.ModifierFlags) {
        guard let t = clock() else { return }
        let p = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown: log.add(t: t, type: "down", at: p)
        case .leftMouseUp: log.add(t: t, type: "up", at: p)
        case .rightMouseDown: log.add(t: t, type: "rightDown", at: p)
        case .rightMouseUp: log.add(t: t, type: "rightUp", at: p)
        case .scrollWheel: log.add(t: t, type: "scroll", at: p)
        case .keyDown:
            // Keys that aren't shown are logged as a content-free "typing" mark (for speed-up suggestions and hiding the cursor).
            guard let label = KeystrokeFormatter.label(keyCode: code, characters: chars, flags: flags, all: Prefs.bool(.recKeysAll)) else {
                log.add(t: t, type: "typing", at: p)
                return
            }
            log.add(t: t, type: "key", at: p, key: label)
        default: break
        }
    }
}

/// cursors/cursors.json: size and hotspot (points, top-left origin) of each `<id>.png`; `scale` = PNG pixels per point.
struct CursorShapeFile: Codable, Equatable {
    struct Shape: Codable, Equatable { var id: String; var width, height, hotX, hotY, scale: Double }
    var version = 1
    var shapes: [Shape] = []
}

/// Identifies the system-wide cursor (arrow, I-beam, hand, resize, an app's own cursor…) by a small fingerprint of its
/// image, and keeps one high-resolution image per distinct shape. Standard shapes get their name as id ("iBeam").
@MainActor
final class CursorShapeRecorder {
    struct Shape { let image: CGImage; let size: CGSize; let hotspot: CGPoint }
    private(set) var shapes: [String: Shape] = [:]
    private var ids: [Int: String] = [:]          // fingerprint → id
    private var customCount = 0
    private static let pixelsPerPoint: CGFloat = 4

    private static let standard: [(String, NSCursor)] = {
        var list: [(String, NSCursor)] = [
            ("arrow", .arrow), ("iBeam", .iBeam), ("iBeamVertical", .iBeamCursorForVerticalLayout), ("pointingHand", .pointingHand),
            ("openHand", .openHand), ("closedHand", .closedHand), ("crosshair", .crosshair), ("contextualMenu", .contextualMenu),
            ("dragLink", .dragLink), ("dragCopy", .dragCopy), ("disappearingItem", .disappearingItem), ("notAllowed", .operationNotAllowed),
            ("resizeLeft", .resizeLeft), ("resizeRight", .resizeRight), ("resizeLeftRight", .resizeLeftRight),
            ("resizeUp", .resizeUp), ("resizeDown", .resizeDown), ("resizeUpDown", .resizeUpDown),
        ]
        list += [("columnResize", NSCursor.columnResize), ("rowResize", NSCursor.rowResize), ("zoomIn", NSCursor.zoomIn), ("zoomOut", NSCursor.zoomOut)]
        return list
    }()
    private lazy var standardIDs: [Int: String] = Dictionary(Self.standard.map { (Self.fingerprint($0.1), $0.0) }, uniquingKeysWith: { a, _ in a })

    /// Id of the cursor on screen now (nil if macOS doesn't report one).
    func current() -> String? {
        guard let c = NSCursor.currentSystem else { return nil }
        let fp = Self.fingerprint(c)
        if let id = ids[fp] { return id }
        let id: String
        if let named = standardIDs[fp] { id = named } else { customCount += 1; id = "custom-\(customCount)" }
        ids[fp] = id
        let size = c.image.size
        var rect = CGRect(origin: .zero, size: CGSize(width: size.width * Self.pixelsPerPoint, height: size.height * Self.pixelsPerPoint))
        if let img = c.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            shapes[id] = Shape(image: img, size: size, hotspot: c.hotSpot)
        }
        return id
    }

    /// Hotspot, size and a 16×16 rendering of the image: the same shape always matches, different shapes don't.
    static func fingerprint(_ c: NSCursor) -> Int {
        var h = Hasher()
        h.combine(Int(c.hotSpot.x * 4)); h.combine(Int(c.hotSpot.y * 4))
        h.combine(Int(c.image.size.width * 4)); h.combine(Int(c.image.size.height * 4))
        var rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        if let img = c.image.cgImage(forProposedRect: &rect, context: nil, hints: nil), let ctx = StudioSprites.context(16, 16) {
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            if let p = ctx.data { h.combine(bytes: UnsafeRawBufferPointer(start: p, count: ctx.bytesPerRow * 16)) }
        }
        return h.finalize()
    }

    /// Writes `cursors/<id>.png` and `cursors/cursors.json` into `dir` (nothing when no shape was seen).
    func write(to dir: URL) throws {
        guard !shapes.isEmpty else { return }
        let folder = dir.appendingPathComponent(StudioCaptureLayout.cursors, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var file = CursorShapeFile()
        for (id, s) in shapes.sorted(by: { $0.key < $1.key }) {
            guard let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent("\(id).png") as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(dest, s.image, nil)
            guard CGImageDestinationFinalize(dest) else { continue }
            file.shapes.append(.init(id: id, width: s.size.width, height: s.size.height, hotX: s.hotspot.x, hotY: s.hotspot.y,
                                     scale: Double(s.image.width) / max(1, s.size.width)))
        }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(file).write(to: folder.appendingPathComponent("cursors.json"), options: .atomic)
    }

    static func selfTest() {
        assert(fingerprint(.arrow) == fingerprint(.arrow), "stable")
        assert(fingerprint(.arrow) != fingerprint(.iBeam) && fingerprint(.arrow) != fingerprint(.pointingHand))
        // Whatever the cursor is now: saved, then loaded back by the editor with the same size and hotspot.
        let r = CursorShapeRecorder()
        if let id = r.current(), let shape = r.shapes[id] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-cursors-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            try? r.write(to: dir)
            let loaded = StudioCursorShape.load(dir)[id]
            assert(loaded?.size == shape.size && loaded?.hotspot == shape.hotspot && loaded?.image.width == shape.image.width, "cursor shape round trip")
        }
    }
}

/// Writes the webcam to its own movie file (Studio Mode), sharing the bubble's capture session.
final class CameraFileRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let output = AVCaptureMovieFileOutput()
    private let session: AVCaptureSession
    private var finished: CheckedContinuation<Void, Never>?
    private var recording = false
    private let lock = NSLock()
    private var firstFrame: CMTime?

    /// Host-clock time of the file's first frame (nil until the file has started).
    var startTime: CMTime? { lock.withLock { firstFrame } }

    init?(session: AVCaptureSession) {
        self.session = session
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
    }

    func start(to url: URL) {
        try? FileManager.default.removeItem(at: url)
        output.startRecording(to: url, recordingDelegate: self)
        recording = true
    }

    func pause() { if output.isRecording { output.pauseRecording() } }
    func resume() { if output.isRecording { output.resumeRecording() } }

    /// Stops and waits for the file to be finalized (bounded, so a stuck camera can't block the recording).
    @MainActor
    func stop() async {
        guard recording else { return }
        recording = false
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            output.stopRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in resumeOnce() }
        }
        session.removeOutput(output)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, startPTS: CMTime, from connections: [AVCaptureConnection]) {
        let t = session.synchronizationClock.map { CMSyncConvertTime(startPTS, from: $0, to: CMClockGetHostTimeClock()) } ?? startPTS
        lock.withLock { firstFrame = t }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { [self] in resumeOnce() }
    }

    private func resumeOnce() {
        finished?.resume()
        finished = nil
    }
}
