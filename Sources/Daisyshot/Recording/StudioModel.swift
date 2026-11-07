import AVFoundation
import CoreGraphics
import Foundation

// MARK: - Recorder output (events.json)

/// Mouse / keyboard track written by the recorder next to `video.mp4` in a `.daisyshotvideo` package.
/// x/y are points relative to the video's top-left corner.
struct StudioEvents: Codable, Equatable {
    struct Region: Codable, Equatable { var x = 0.0, y = 0.0, width = 0.0, height = 0.0 }
    struct Event: Codable, Equatable {
        var t: Double
        var type: String          // move | down | up | rightDown | rightUp | scroll | key | typing | cursor
        var x: Double?
        var y: Double?
        var key: String?
        var cursor: String?       // cursor events: id of the shape shown from here on
        var isClick: Bool { type == "down" || type == "rightDown" }
        var hasPosition: Bool { x != nil && y != nil && type != "key" && type != "typing" && type != "marker" }
    }
    var version = 1
    var region = Region()
    var scale = 1.0
    var duration = 0.0
    var cursorVisibleInVideo = false
    var events: [Event] = []
    /// Kind of each audio track in video order ("system" | "mic"); absent in older recordings.
    var audioTracks: [String]?
    /// Video time at which camera.mov starts (it starts a little after the screen); absent in older recordings.
    var cameraOffset: Double?
    /// Name of the iPhone / iPad this was recorded from; nil for screen recordings.
    var device: String?

    var hasKeys: Bool { events.contains { $0.type == "key" } }
    /// Recording markers (source seconds).
    var markers: [Double] { events.filter { $0.type == "marker" }.map(\.t) }

    /// Stretches of typing, source seconds. Every key counts as activity (⌫, arrows and shortcuts while editing don't
    /// break a stretch) and pauses under 2 s are thinking time; a stretch runs from its first to its last typed character,
    /// lasts ≥ 1.5 s, is mostly characters and averages ≥ 1.5 keys/s. Characters are the content-free "typing" marks the
    /// recorder logs, or keys that aren't shown on their own.
    var typingBursts: [ClosedRange<Double>] {
        let keys = events.filter { $0.type == "typing" || $0.type == "key" }
            .map { e in (t: e.t, char: e.type == "typing" || e.key.map { !KeyBadge.classify($0).standalone } == true) }
            .sorted { $0.t < $1.t }
        var out: [ClosedRange<Double>] = []
        var start = 0
        for i in keys.indices where i == keys.count - 1 || keys[i + 1].t - keys[i].t >= 2 {
            let group = keys[start...i]
            start = i + 1
            guard let a = group.first(where: \.char)?.t, let b = group.last(where: \.char)?.t, b - a >= 1.5 else { continue }
            let inside = group.filter { $0.t >= a && $0.t <= b }
            let chars = inside.filter(\.char).count
            if chars >= 4, Double(chars) >= Double(inside.count) * 0.5, Double(inside.count) / (b - a) >= 1.5 { out.append(a...b) }
        }
        return out
    }
    var hasPointer: Bool { events.contains { $0.hasPosition } }
}

// MARK: - Editor document (project.json)

enum CursorStyle: String, Codable, CaseIterable, Identifiable {
    case macOS, modern, inverted, bold, color, touch, dot, ring
    var id: String { rawValue }
    /// Arrow styles show the recorded shape (I-beam, hand…) when the pointer wasn't an arrow; touch, dot and ring never change.
    var showsShapes: Bool { [.macOS, .modern, .inverted, .bold, .color].contains(self) }
    var title: String {
        switch self {
        case .macOS: return "macOS"
        case .modern: return "Modern"
        case .inverted: return "Inverted"
        case .bold: return "Bold"
        case .color: return "Color"
        case .ring: return "Ring"
        case .touch: return "Touch"
        case .dot: return "Dot"
        }
    }
}

enum ClickColor: String, Codable, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, gray
    var id: String { rawValue }
    var hex: String {
        switch self {
        case .blue: return "#0A84FF"
        case .purple: return "#BF5AF2"
        case .pink: return "#FF375F"
        case .red: return "#FF453A"
        case .orange: return "#FF9F0A"
        case .yellow: return "#FFD60A"
        case .green: return "#30D158"
        case .gray: return "#98989D"
        }
    }
}

enum StudioCameraShape: String, Codable, CaseIterable, Identifiable {
    case circle, rounded, square, rectangle, vertical
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// width / height
    var aspect: CGFloat {
        switch self {
        case .circle, .rounded, .square: return 1
        case .rectangle: return 16.0 / 9
        case .vertical: return 9.0 / 16
        }
    }
}

enum BackgroundKind: String, Codable, CaseIterable {
    case none, gradient, color, wallpaper, blurredWallpaper, image
}

enum StudioAspect: String, Codable, CaseIterable, Identifiable {
    case auto, wide, classic, square, vertical, portrait, p45, w1610, ultrawide
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .wide: return "16:9 · YouTube"
        case .classic: return "4:3"
        case .square: return "1:1 · Instagram"
        case .vertical: return "9:16 · TikTok, Reels"
        case .portrait: return "3:4"
        case .p45: return "4:5 · Instagram portrait"
        case .w1610: return "16:10"
        case .ultrawide: return "21:9"
        }
    }
    /// "9:16" — the ratio part of the title (file names, compact labels).
    var ratioText: String { String(title.split(separator: " ").first ?? Substring(rawValue)) }

    /// width / height, nil = follow the recording.
    var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .wide: return 16.0 / 9
        case .classic: return 4.0 / 3
        case .square: return 1
        case .vertical: return 9.0 / 16
        case .portrait: return 3.0 / 4
        case .p45: return 4.0 / 5
        case .w1610: return 16.0 / 10
        case .ultrawide: return 21.0 / 9
        }
    }
}

enum ZoomStyle: String, Codable, CaseIterable { case smooth, dynamic, custom }
/// What a camera layout shows instead of the screen + camera bubble.
enum CameraLayoutKind: String, Codable, CaseIterable { case cameraOnly, custom, screenOnly }
/// Manual zooms can drift slowly across the recording while they're on.
enum ZoomGlide: String, Codable, CaseIterable { case none, left, right, up, down }
enum MaskKind: String, Codable, CaseIterable { case blur, highlight }
enum MotionBlur: String, Codable, CaseIterable {
    case off, low, medium, high
    var amount: CGFloat { [0, 0.5, 1, 1.7][MotionBlur.allCases.firstIndex(of: self)!] }
}

/// Everything the user edits. Clip and zoom times are in SOURCE seconds, so zooms stay glued to the content
/// they were placed on when clips are split, cut or trimmed (clips are never reordered, so the mapping is monotonic).
struct StudioDocument: Codable, Equatable {
    struct Clip: Codable, Equatable, Identifiable {
        var id = UUID()
        var start: Double
        var duration: Double      // source seconds
        var speed = 1.0
        var volume = 1.0          // multiplies every audio track while this clip plays
        var trackVolumes: [Double] = []   // per audio track on top of `volume` (missing = 1)
        var hideCursor = false
        var smoothCursor = true   // off: the raw pointer path here (precise menus)
        func trackVolume(_ i: Int) -> Double { i < trackVolumes.count ? trackVolumes[i] : 1 }
        mutating func setTrackVolume(_ v: Double, _ i: Int) {
            while trackVolumes.count <= i { trackVolumes.append(1) }
            trackVolumes[i] = v
        }
        var end: Double { start + duration }
        var length: Double { duration / speed }   // output seconds

        init(id: UUID = UUID(), start: Double, duration: Double, speed: Double = 1) {
            self.id = id; self.start = start; self.duration = duration; self.speed = speed
        }

        /// Array elements don't get `StudioJSON`'s defaults: keys added later (speed…) must be optional here.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            start = try c.decode(Double.self, forKey: .start)
            duration = try c.decode(Double.self, forKey: .duration)
            speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
            volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
            hideCursor = try c.decodeIfPresent(Bool.self, forKey: .hideCursor) ?? false
            trackVolumes = try c.decodeIfPresent([Double].self, forKey: .trackVolumes) ?? []
            smoothCursor = try c.decodeIfPresent(Bool.self, forKey: .smoothCursor) ?? true
        }

        /// The part of this clip from source `s` to its end, as a new clip with the same settings.
        func tail(from s: Double) -> Clip {
            var c = self
            c.id = UUID()
            c.start = s
            c.duration = end - s
            return c
        }

        static let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 3, 4, 8]
        static func speedTitle(_ s: Double) -> String { (s == s.rounded() ? String(Int(s)) : String(s)) + "×" }
    }

    struct Zoom: Codable, Equatable, Identifiable {
        var id = UUID()
        var start: Double
        var end: Double
        var scale = 2.0
        var followCursor = true
        var focusX = 0.5          // manual focus, normalized, top-left origin
        var focusY = 0.5
        var glide = ZoomGlide.none
        var glideAmount = 0.3     // how far the view drifts over the zoom, in view widths / heights
        var disabled = false      // kept on the timeline but not applied
    }

    struct Cursor: Codable, Equatable {
        var show = true
        var style = CursorStyle.macOS
        var size = 1.5
        var smoothing = 0.6       // 0 = natural (raw movement)
        var hideWhenIdle = false
        var hideWhenTyping = false
        var pressEffect = true
        var ripple = true
        var rippleColor = ClickColor.blue
        var rippleFilled = false
        var removeJumps = true    // drop isolated far-away samples (accessibility tools, remote control)
        var tilt = 0.0            // 0…1: leans into horizontal movement
        var loopToStart = false   // glides back to the first position in the last second (seamless GIF loops)
        var freezeAtEnd = 0.0     // seconds at the end with a still cursor (hides the trip to Stop)
        var realShapes = true     // draw recorded I-beam / hand / resize… cursors instead of the arrow everywhere
        var motionBlur = MotionBlur.low   // streaks the pointer when it moves fast
        var idleDelay = 1.5       // "hide when not moving" after this many seconds
        var jumpLimit = 500.0     // "remove jumps": a sample this far (points) from the next two is dropped
        var loopDuration = 1.0    // "return to start": over the last … seconds
        var steadyShapes = true   // ignore cursor shapes shown for less than 0.2 s (flicker over buttons and edges)
        var clickSound = false
        var clickVolume = 0.6
    }

    /// Background music, looped under the whole video.
    struct Music: Codable, Equatable {
        var path = ""             // a file name inside the project, or an absolute path (plain videos)
        var volume = 0.15
        var fadeOut = true        // over the last 2 seconds
        var muted = false
    }

    struct Keystrokes: Codable, Equatable {
        var show = true
        var size = 1.0
        var light = false
        var position = 7          // 3×3 grid, row-major, top-left origin
        var allKeys = false
        var hidden: [String] = [] // shortcut labels not shown
        var hiddenAt: [Double] = [] // single badges not shown (their start, source seconds)

        func isHidden(_ b: KeyBadge) -> Bool { hiddenAt.contains { abs($0 - b.start) < 0.0005 } }
    }

    struct Audio: Codable, Equatable {
        var volumes: [Double] = []
        var muted: [Bool] = []
        var denoise: [Bool] = []      // Apple's voice isolation (microphone tracks)
        var normalize: [Bool] = []    // loudness to ≈ −16 LUFS
        var mono = false
        func volume(_ i: Int) -> Double { i < volumes.count ? volumes[i] : 1 }
        func isMuted(_ i: Int) -> Bool { i < muted.count ? muted[i] : false }
        func denoises(_ i: Int) -> Bool { i < denoise.count && denoise[i] }
        func normalizes(_ i: Int) -> Bool { i < normalize.count && normalize[i] }
        func effectiveVolume(_ i: Int) -> Float { isMuted(i) ? 0 : Float(volume(i)) }
        mutating func setVolume(_ v: Double, _ i: Int) {
            while volumes.count <= i { volumes.append(1) }
            volumes[i] = v
        }
        mutating func setMuted(_ m: Bool, _ i: Int) { Self.set(&muted, i, m) }
        mutating func setDenoise(_ on: Bool, _ i: Int) { Self.set(&denoise, i, on) }
        mutating func setNormalize(_ on: Bool, _ i: Int) { Self.set(&normalize, i, on) }
        private static func set(_ a: inout [Bool], _ i: Int, _ v: Bool) {
            while a.count <= i { a.append(false) }
            a[i] = v
        }
    }

    struct Camera: Codable, Equatable {
        var show = true
        var size = 0.24           // fraction of the canvas' short side
        var shape = StudioCameraShape.circle
        var x = 0.88              // normalized center, top-left origin
        var y = 0.82
        var mirror = true
        var shrinkOnZoom = true
        var zoomSize = 0.65       // size while zoomed in, relative (with shrinkOnZoom)
        var roundness = -1.0      // 0 square … 1 fully round; −1 = the shape's own

        /// The shape's corner roundness when none is set (0…1 of half the short side).
        static func defaultRoundness(_ s: StudioCameraShape) -> Double {
            switch s {
            case .circle: return 1
            case .rounded: return 0.44
            case .square: return 0.08
            case .rectangle, .vertical: return 0.2
            }
        }
        var effectiveRoundness: Double { roundness >= 0 ? roundness : Self.defaultRoundness(shape) }
    }

    struct Background: Codable, Equatable {
        var kind = BackgroundKind.gradient
        var gradient = 0
        var color = "#1C1C1E"
        var imagePath = ""
        var padding = 0.08        // fraction of the canvas' short side
        var cornerRadius = 12.0   // canvas points (1080p reference)
        var shadow = 0.5
        var inset = 0.0
        var aspect = StudioAspect.auto
        var fillFrame = false     // a set aspect: the recording fills the frame (cropped) and the view follows the cursor
        var deviceFrame = true    // iPhone / iPad recordings: draw a device bezel around the screen
        var blur = 0.0            // wallpaper / image backgrounds, 0…1
        // Shadow, advanced: direction (degrees, −90 = straight down), distance (× its blur) and softness (× the default blur).
        var shadowAngle = -90.0
        var shadowDistance = 0.35
        var shadowSoftness = 1.0
        var insetSides: [Double] = []   // top, right, bottom, left (points); empty = `inset` on every side
        var insetColor = ""       // hex; empty = picked from the recording's corner
        var insetOpacity = 1.0
        var isVisible: Bool { kind != .none }
        /// Inset per side (top, right, bottom, left) in points.
        var sides: [Double] { insetSides.count == 4 ? insetSides : [inset, inset, inset, inset] }
    }

    struct Animation: Codable, Equatable {
        var zoomStyle = ZoomStyle.smooth
        var zoomDuration = 0.8    // seconds for a zoom in / out
        var motionBlur = MotionBlur.medium      // while zooming in / out; on by default: motion reads smoother
        var panBlur: MotionBlur?                // while the zoomed view moves; nil = same as `motionBlur`
        // Custom zoom spring: stiffness, damping and mass; the defaults move like the Smooth style.
        var rigidity = 200.0      // stiffness, 5…600
        var smoothness = 40.0     // damping, 5…200
        var momentum = 2.25       // mass, 0.1…15
        var keepZoomedIn = false  // fill the gaps between zooms with a zoom that follows the cursor (vertical video)
        var keepZoomScale = 1.5
        var snapToEdges = 0.25    // a pointer within this share of the view from an edge pins the view to it (0 = off)
    }

    /// Blurs regions (sensitive data) or dims everything around them (highlight) for a time span. Regions are
    /// normalized to the recording (top-left origin), so masks move with the content when it zooms.
    struct Mask: Codable, Equatable, Identifiable {
        struct Region: Codable, Equatable { var x, y, width, height: Double }
        var id = UUID()
        var start: Double         // source seconds
        var end: Double
        var kind = MaskKind.blur
        var strength = 0.7        // blur radius / dimming, 0…1
        var regions: [Region] = []
        var disabled = false
    }

    /// A stretch where the camera fills the frame (over the blurred screen) or is hidden; elsewhere both show.
    struct CameraLayout: Codable, Equatable, Identifiable {
        var id = UUID()
        var start: Double         // source seconds
        var end: Double
        var kind = CameraLayoutKind.cameraOnly
        var disabled = false
        // Custom camera: its own size and position (normalized, top-left) while this layout is on.
        var size = 0.24
        var x = 0.88
        var y = 0.82
    }

    var version = 1
    var clips: [Clip] = []
    var zooms: [Zoom] = []
    var masks: [Mask] = []
    var layouts: [CameraLayout] = []
    var music = Music()
    var crop = Crop()

    /// Part of the recording kept (normalized, top-left origin); everything else in the editor treats it as the recording.
    struct Crop: Codable, Equatable {
        var x = 0.0, y = 0.0, width = 1.0, height = 1.0
        var isFull: Bool { x <= 0.0005 && y <= 0.0005 && width >= 0.999 && height >= 0.999 }
        /// Normalized point on the recording → normalized point on the cropped picture.
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - x) / max(0.01, width), y: (p.y - y) / max(0.01, height)) }
    }
    /// Start (source seconds) of typing stretches whose "speed up" suggestion was removed.
    var typingDismissed: [Double] = []
    var cursor = Cursor()
    var keystrokes = Keystrokes()
    var audio = Audio()
    var camera = Camera()
    var background = Background()
    var animation = Animation()

    static let gradients: [(String, String)] = [
        ("#5B5FEF", "#C86DD7"), ("#FF7A59", "#FFC56E"), ("#1FA2FF", "#12D8FA"), ("#0F9B8E", "#7CE38B"),
        ("#E2537A", "#7B5CFA"), ("#232526", "#5B6470"), ("#F7797D", "#FBD786"), ("#3A1C71", "#D76D77"),
        ("#00467F", "#A5CC82"), ("#FC5C7D", "#6A82FB"), ("#134E5E", "#71B280"), ("#E0EAFC", "#B8C6DB"),
    ]
    static let colors = ["#1C1C1E", "#3A3A3C", "#FFFFFF", "#F2F2F7", "#0A84FF", "#5E5CE6", "#FF375F", "#FF9F0A", "#FFD60A", "#30D158"]

    static let minClip = 1.0 / 30
    static let minZoom = 0.3

    // MARK: Clip timeline (output time = edited timeline)

    var duration: Double { clips.reduce(0) { $0 + $1.length } }

    /// Output-time start of each clip.
    var clipStarts: [Double] {
        var acc = 0.0
        return clips.map { c in defer { acc += c.length }; return acc }
    }

    /// Output time → source time. At an exact cut, `preferEnd` returns the end of the earlier clip.
    func sourceTime(_ t: Double, preferEnd: Bool = false) -> Double {
        var acc = 0.0
        for c in clips {
            if t < acc + c.length || (preferEnd && t <= acc + c.length) { return c.start + max(0, t - acc) * c.speed }
            acc += c.length
        }
        return clips.last?.end ?? t
    }

    /// Source time → output time; times inside removed parts snap to the next kept frame.
    func outputTime(source s: Double) -> Double {
        var acc = 0.0
        for c in clips {
            if s < c.start { return acc }
            if s <= c.end { return acc + (s - c.start) / c.speed }
            acc += c.length
        }
        return acc
    }

    func clipIndex(at t: Double) -> Int? {
        var acc = 0.0
        for (i, c) in clips.enumerated() {
            if t < acc + c.length { return i }
            acc += c.length
        }
        return clips.isEmpty ? nil : clips.count - 1
    }

    /// Splits the clip under output time `t`. Returns false when too close to an existing edge.
    @discardableResult
    mutating func split(at t: Double) -> Bool {
        guard let i = clipIndex(at: t) else { return false }
        let local = t - clipStarts[i]
        let c = clips[i]
        guard local > Self.minClip, c.length - local > Self.minClip else { return false }
        clips[i].duration = local * c.speed
        clips.insert(c.tail(from: c.start + local * c.speed), at: i + 1)
        return true
    }

    /// Back to the clip's widest extent: its edges move out to the neighbouring clips (or the media's ends).
    mutating func resetTrim(_ id: UUID, sourceDuration: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let lo = i > 0 ? clips[i - 1].end : 0, hi = i + 1 < clips.count ? clips[i + 1].start : sourceDuration
        clips[i].start = lo
        clips[i].duration = max(Self.minClip, hi - lo)
    }

    /// Removes from output time `t` back to the previous cut (ripple delete of the part before the playhead).
    @discardableResult
    mutating func deleteToPreviousCut(at t: Double) -> Bool {
        guard let i = clipIndex(at: t), t - clipStarts[i] > Self.minClip else { return false }
        if split(at: t) { clips.remove(at: i); return true }
        guard clips.count > 1 else { return false }
        clips.remove(at: i)       // the playhead is at the clip's end: the whole clip goes
        return true
    }

    /// Joins a clip with the next one: one clip from its start to the next one's end (a part cut out between them comes
    /// back), with the first clip's speed, volume and cursor setting.
    @discardableResult
    mutating func mergeWithNext(_ id: UUID) -> Bool {
        guard let i = clips.firstIndex(where: { $0.id == id }), i + 1 < clips.count else { return false }
        clips[i].duration = clips[i + 1].end - clips[i].start
        clips.remove(at: i + 1)
        return true
    }

    /// Plays source `range` at `speed`: clips are split at its ends (where they cross them) and the parts inside retimed.
    mutating func setSpeed(_ speed: Double, source range: ClosedRange<Double>) {
        for s in [range.lowerBound, range.upperBound] {
            if let i = clips.firstIndex(where: { $0.start + Self.minClip < s && s < $0.end - Self.minClip }) {
                let c = clips[i]
                clips[i].duration = s - c.start
                clips.insert(c.tail(from: s), at: i + 1)
            }
        }
        for i in clips.indices where clips[i].start >= range.lowerBound - 1e-6 && clips[i].end <= range.upperBound + 1e-6 {
            clips[i].speed = speed
        }
    }

    /// Typing stretches still playing at normal speed (source seconds), for the "speed up typing" suggestions.
    func typingSuggestions(_ bursts: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        bursts.filter { r in !isDismissed(r) && clips.contains { $0.speed == 1 && $0.start < r.upperBound && r.lowerBound < $0.end } }
    }

    func isDismissed(_ r: ClosedRange<Double>) -> Bool { typingDismissed.contains { abs($0 - r.lowerBound) < 0.01 } }

    /// Speed the stretch plays at (its clips' speed when they agree, else 1).
    func speed(of r: ClosedRange<Double>) -> Double {
        let inside = clips.filter { $0.start < r.upperBound - 1e-6 && r.lowerBound + 1e-6 < $0.end }
        guard let first = inside.first?.speed, inside.allSatisfy({ $0.speed == first }) else { return 1 }
        return first
    }

    /// Removes a clip (ripple delete). The last remaining clip can't be removed.
    @discardableResult
    mutating func removeClip(_ id: UUID) -> Bool {
        guard clips.count > 1, let i = clips.firstIndex(where: { $0.id == id }) else { return false }
        clips.remove(at: i)
        return true
    }

    /// Allowed source-time range for dragging a clip edge: up to the neighbouring clips (or the media bounds).
    func trimBounds(_ i: Int, leading: Bool, sourceDuration: Double) -> ClosedRange<Double> {
        let c = clips[i]
        if leading {
            let lo = i > 0 ? clips[i - 1].end : 0
            return lo...max(lo, c.end - Self.minClip)
        }
        let hi = i + 1 < clips.count ? clips[i + 1].start : sourceDuration
        return min(hi, c.start + Self.minClip)...hi
    }

    mutating func trim(_ i: Int, leading: Bool, to source: Double, sourceDuration: Double) {
        guard clips.indices.contains(i) else { return }
        let s = min(max(source, trimBounds(i, leading: leading, sourceDuration: sourceDuration).lowerBound),
                    trimBounds(i, leading: leading, sourceDuration: sourceDuration).upperBound)
        if leading {
            clips[i].duration = clips[i].end - s
            clips[i].start = s
        } else {
            clips[i].duration = s - clips[i].start
        }
    }

    // MARK: Zooms

    /// Zoom interval on the output timeline (zero length when its content was cut away).
    func outputRange(_ z: Zoom) -> ClosedRange<Double> {
        let a = outputTime(source: z.start), b = outputTime(source: z.end)
        return a...max(a, b)
    }

    var sortedZooms: [Zoom] { zooms.sorted { $0.start < $1.start } }

    /// Free output-time gap around `t` on the zoom lane (excluding `ignoring`).
    func zoomGap(around t: Double, ignoring: UUID? = nil) -> ClosedRange<Double>? {
        freeGap(around: t, zooms.filter { $0.id != ignoring }.map(outputRange))
    }

    /// Free output-time gap around `t` between `ranges` (nil when `t` is inside one).
    func freeGap(around t: Double, _ ranges: [ClosedRange<Double>]) -> ClosedRange<Double>? {
        var lo = 0.0, hi = duration
        for r in ranges {
            guard r.upperBound - r.lowerBound > 0.001 else { continue }
            if r.contains(t), r.lowerBound < t, t < r.upperBound { return nil }
            if r.upperBound <= t { lo = max(lo, r.upperBound) }
            if r.lowerBound >= t { hi = min(hi, r.lowerBound) }
        }
        return lo...hi
    }

    /// Adds a zoom covering output `range`, clamped into the free gap. Returns its id.
    @discardableResult
    mutating func addZoom(_ range: ClosedRange<Double>, template: Zoom? = nil) -> UUID? {
        guard let gap = zoomGap(around: range.lowerBound) ?? zoomGap(around: min(duration, range.lowerBound + 0.01)) else { return nil }
        var a = max(gap.lowerBound, range.lowerBound), b = min(gap.upperBound, range.upperBound)
        if b - a < Self.minZoom {   // too short: grow inside the gap
            b = min(gap.upperBound, a + max(Self.minZoom, range.upperBound - range.lowerBound))
            a = max(gap.lowerBound, b - max(Self.minZoom, range.upperBound - range.lowerBound))
        }
        guard b - a >= Self.minZoom else { return nil }
        var z = template ?? Zoom(start: 0, end: 0)
        z.id = UUID()
        z.start = sourceTime(a)
        z.end = sourceTime(b, preferEnd: true)
        zooms.append(z)
        return z.id
    }

    /// Moves / resizes a zoom to output `range` (already clamped by the caller).
    mutating func setZoom(_ id: UUID, output range: ClosedRange<Double>) {
        guard let i = zooms.firstIndex(where: { $0.id == id }) else { return }
        zooms[i].start = sourceTime(range.lowerBound)
        zooms[i].end = sourceTime(range.upperBound, preferEnd: true)
    }

    @discardableResult
    mutating func splitZoom(at t: Double) -> Bool {
        guard let i = zooms.firstIndex(where: { let r = outputRange($0); return r.lowerBound + Self.minZoom <= t && t <= r.upperBound - Self.minZoom })
        else { return false }
        var second = zooms[i]
        second.id = UUID()
        second.start = sourceTime(t)
        zooms[i].end = sourceTime(t, preferEnd: true)
        zooms.insert(second, at: i + 1)
        return true
    }

    // MARK: Masks

    func outputRange(_ m: Mask) -> ClosedRange<Double> {
        let a = outputTime(source: m.start), b = outputTime(source: m.end)
        return a...max(a, b)
    }

    func maskGap(around t: Double, ignoring: UUID? = nil) -> ClosedRange<Double>? {
        freeGap(around: t, masks.filter { $0.id != ignoring }.map(outputRange))
    }

    /// Adds a mask covering output `range` (clamped into the free gap) with one centered region. Returns its id.
    @discardableResult
    mutating func addMask(_ range: ClosedRange<Double>, kind: MaskKind = .blur) -> UUID? {
        guard let gap = maskGap(around: range.lowerBound) ?? maskGap(around: min(duration, range.lowerBound + 0.01)) else { return nil }
        let a = max(gap.lowerBound, range.lowerBound), b = min(gap.upperBound, max(range.upperBound, a + Self.minZoom))
        guard b - a >= Self.minZoom else { return nil }
        let m = Mask(start: sourceTime(a), end: sourceTime(b, preferEnd: true), kind: kind,
                     regions: [.init(x: 0.35, y: 0.4, width: 0.3, height: 0.2)])
        masks.append(m)
        return m.id
    }

    mutating func setMask(_ id: UUID, output range: ClosedRange<Double>) {
        guard let i = masks.firstIndex(where: { $0.id == id }) else { return }
        masks[i].start = sourceTime(range.lowerBound)
        masks[i].end = sourceTime(range.upperBound, preferEnd: true)
    }

    // MARK: Camera layouts

    func outputRange(_ l: CameraLayout) -> ClosedRange<Double> {
        let a = outputTime(source: l.start), b = outputTime(source: l.end)
        return a...max(a, b)
    }

    func layoutGap(around t: Double, ignoring: UUID? = nil) -> ClosedRange<Double>? {
        freeGap(around: t, layouts.filter { $0.id != ignoring }.map(outputRange))
    }

    @discardableResult
    mutating func addLayout(_ range: ClosedRange<Double>, kind: CameraLayoutKind = .cameraOnly) -> UUID? {
        guard let gap = layoutGap(around: range.lowerBound) ?? layoutGap(around: min(duration, range.lowerBound + 0.01)) else { return nil }
        let a = max(gap.lowerBound, range.lowerBound), b = min(gap.upperBound, max(range.upperBound, a + Self.minZoom))
        guard b - a >= Self.minZoom else { return nil }
        let l = CameraLayout(start: sourceTime(a), end: sourceTime(b, preferEnd: true), kind: kind)
        layouts.append(l)
        return l.id
    }

    @discardableResult
    mutating func splitLayout(at t: Double) -> Bool {
        guard let i = layouts.firstIndex(where: { let r = outputRange($0); return r.lowerBound + Self.minZoom <= t && t <= r.upperBound - Self.minZoom })
        else { return false }
        var second = layouts[i]
        second.id = UUID()
        second.start = sourceTime(t)
        layouts[i].end = sourceTime(t, preferEnd: true)
        layouts.insert(second, at: i + 1)
        return true
    }

    /// Moves a custom layout's camera one step on the 3×3 position grid (dx / dy: -1, 0, 1).
    mutating func stepLayoutCamera(_ id: UUID, dx: Int, dy: Int) {
        guard let i = layouts.firstIndex(where: { $0.id == id }), layouts[i].kind == .custom else { return }
        func step(_ v: Double, _ grid: [Double], _ d: Int) -> Double {
            let near = grid.indices.min { abs(grid[$0] - v) < abs(grid[$1] - v) } ?? 1
            return grid[min(grid.count - 1, max(0, near + d))]
        }
        layouts[i].x = step(layouts[i].x, Self.cameraXs, dx)
        layouts[i].y = step(layouts[i].y, Self.cameraYs, dy)
    }

    /// The camera position grid (the sidebar's 3×3 picker).
    static let cameraXs = [0.12, 0.5, 0.88], cameraYs = [0.15, 0.5, 0.82]

    /// Back to one uncut clip of the whole recording (zooms, masks and layouts stay where they are in the recording).
    mutating func removeAllCuts(sourceDuration: Double) {
        clips = [Clip(start: 0, duration: sourceDuration)]
    }

    mutating func setLayout(_ id: UUID, output range: ClosedRange<Double>) {
        guard let i = layouts.firstIndex(where: { $0.id == id }) else { return }
        layouts[i].start = sourceTime(range.lowerBound)
        layouts[i].end = sourceTime(range.upperBound, preferEnd: true)
    }

    /// The camera at output time `t`: the default one, moved / resized toward a "custom camera" layout as it comes in.
    func camera(at t: Double) -> Camera {
        var c = camera
        let best = layouts.filter { $0.kind == .custom && !$0.disabled }.map { l -> (Double, CameraLayout) in
            let r = outputRange(l)
            return (StudioTracks.smoothstep(r.lowerBound - 0.2, r.lowerBound + 0.2, t) * (1 - StudioTracks.smoothstep(r.upperBound - 0.2, r.upperBound + 0.2, t)), l)
        }.max { $0.0 < $1.0 }
        if let (a, l) = best, a > 0 {
            c.size += (l.size - c.size) * a
            c.x += (l.x - c.x) * a
            c.y += (l.y - c.y) * a
        }
        return c
    }

    /// 0…1: how far layout `kind` is in at output time `t` (0.4 s transitions centred on its edges).
    func layoutAmount(_ kind: CameraLayoutKind, at t: Double) -> Double {
        layouts.filter { $0.kind == kind && !$0.disabled }.map { l in
            let r = outputRange(l)
            return StudioTracks.smoothstep(r.lowerBound - 0.2, r.lowerBound + 0.2, t) * (1 - StudioTracks.smoothstep(r.upperBound - 0.2, r.upperBound + 0.2, t))
        }.max() ?? 0
    }

    /// 0…1 visibility of a mask at source time `s`: fully on from start to end, fading in over the 0.2 s before
    /// (so nothing shows unmasked at the start) and out over the 0.2 s after.
    static func maskAlpha(_ m: Mask, at s: Double) -> Double {
        if s < m.start { return StudioTracks.smoothstep(m.start - 0.2, m.start, s) }
        if s > m.end { return 1 - StudioTracks.smoothstep(m.end, m.end + 0.2, s) }
        return 1
    }

    /// Auto zooms (source time): each click asks for a zoom from 0.3 s before to 2.5 s
    /// after it, clicks in the last second are ignored, and requests less than 2.5 s apart merge into one zoom. Where the
    /// camera looks within a zoom (following click groups) is the zoom track's job.
    static func autoZooms(_ ev: StudioEvents, duration: Double) -> [Zoom] {
        let end = duration > 0 && duration.isFinite ? duration : .infinity
        let clicks = ev.events.filter { $0.isClick && $0.hasPosition && $0.t < end - 1 }.map(\.t).sorted()
        var out: [Zoom] = []
        for t in clicks {
            let a = max(0, t - 0.3), b = min(end - 0.8, t + 2.5)
            guard b - a >= minZoom else { continue }
            if var last = out.last, a <= last.end + 2.5 {
                last.end = max(last.end, b)
                out[out.count - 1] = last
            } else {
                out.append(Zoom(start: a, end: b, scale: 2, followCursor: true))
            }
        }
        return out
    }
}

/// Zooms are array elements, which don't get `StudioJSON`'s defaults: keys added later must be optional here. In an
/// extension, so the memberwise initializer stays.
extension StudioDocument.Zoom {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 2
        followCursor = try c.decodeIfPresent(Bool.self, forKey: .followCursor) ?? true
        focusX = try c.decodeIfPresent(Double.self, forKey: .focusX) ?? 0.5
        focusY = try c.decodeIfPresent(Double.self, forKey: .focusY) ?? 0.5
        glide = try c.decodeIfPresent(ZoomGlide.self, forKey: .glide) ?? .none
        glideAmount = try c.decodeIfPresent(Double.self, forKey: .glideAmount) ?? 0.3
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

extension StudioDocument.Mask {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        kind = try c.decodeIfPresent(MaskKind.self, forKey: .kind) ?? .blur
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? 0.7
        regions = try c.decodeIfPresent([Region].self, forKey: .regions) ?? []
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
    }
}

extension StudioDocument.CameraLayout {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        kind = try c.decodeIfPresent(CameraLayoutKind.self, forKey: .kind) ?? .cameraOnly
        disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.24
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.88
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.82
    }
}

// MARK: - Forward-compatible JSON

enum StudioJSON {
    /// Decodes `data` over the encoded `defaults`, so files missing newer keys still load.
    static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T) -> T? {
        guard let saved = try? JSONSerialization.jsonObject(with: data),
              let base = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)),
              let merged = try? JSONSerialization.data(withJSONObject: merge(base, saved))
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: merged)
    }

    private static func merge(_ a: Any, _ b: Any) -> Any {
        guard let da = a as? [String: Any], let db = b as? [String: Any] else { return b }
        return da.merging(db) { merge($0, $1) }
    }

    static func encode<T: Encodable>(_ v: T) -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(v)
    }
}

// MARK: - Package

/// A Studio project (`Name.daisyshotvideo/` with video.mp4, optional camera.mov, events.json, project.json)
/// or a plain video file opened in simple mode.
struct StudioPackage {
    static let fileExtension = MediaKind.projectExtension

    let url: URL
    let videoURL: URL
    let cameraURL: URL?
    let events: StudioEvents?

    var isStudio: Bool { events != nil }
    var projectURL: URL? { isStudio ? url.appendingPathComponent("project.json") : nil }
    var displayName: String { url.deletingPathExtension().lastPathComponent }

    /// Accepts a package directory, a file inside one, or a plain video.
    static func open(_ input: URL) throws -> StudioPackage {
        var url = input.standardizedFileURL
        if url.deletingLastPathComponent().pathExtension.lowercased() == fileExtension { url = url.deletingLastPathComponent() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw StudioError("“%@” couldn't be found.".loc(url.lastPathComponent))
        }
        guard isDir.boolValue else { return StudioPackage(url: url, videoURL: url, cameraURL: nil, events: nil) }
        let fm = FileManager.default
        guard let video = ["video.mp4", "video.mov"].map({ url.appendingPathComponent($0) }).first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw StudioError("The project has no video.")
        }
        let camera = ["camera.mov", "camera.mp4"].map { url.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        var events = StudioEvents()
        if let data = try? Data(contentsOf: url.appendingPathComponent("events.json")) {
            events = StudioJSON.decode(StudioEvents.self, from: data, defaults: StudioEvents()) ?? StudioEvents()
        }
        return StudioPackage(url: url, videoURL: video, cameraURL: camera, events: events)
    }

    func loadDocument() -> StudioDocument? {
        guard let u = projectURL, let data = try? Data(contentsOf: u) else { return nil }
        return StudioJSON.decode(StudioDocument.self, from: data, defaults: StudioDocument())
    }

    func save(_ doc: StudioDocument) {
        guard let u = projectURL, let data = StudioJSON.encode(doc) else { return }
        try? data.write(to: u, options: .atomic)
    }
}

struct StudioError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s.loc }
}

// MARK: - Synthetic sample project (debugging / self-checks)

enum StudioSample {
    /// Writes a small `.daisyshotvideo` package: a 640×400 animated screen, a camera clip, a sine-tone audio track and
    /// an events.json with a circling cursor, a few clicks and keystrokes. Lets the editor be exercised without recording.
    /// `k` scales the video's pixel size (k = 4.725 ≈ a 3024×1890 Retina recording) for performance checks.
    static func make(in folder: URL, name: String = "Sample", seconds: Double = 4, camera: Bool = true, k: CGFloat = 1) async throws -> URL {
        let pkg = folder.appendingPathComponent(name).appendingPathExtension(StudioPackage.fileExtension)
        try? FileManager.default.removeItem(at: pkg)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let size = CGSize(width: (640 * k / 2).rounded() * 2, height: (400 * k / 2).rounded() * 2)   // pixels; 320×200 points
        try await writeVideo(to: pkg.appendingPathComponent("video.mp4"), size: size, seconds: seconds, audio: true) { ctx, t in
            ctx.scaleBy(x: k, y: k)
            ctx.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 40 + t * 80, y: 120, width: 160, height: 120))
            ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
            for row in 0..<6 { ctx.fill(CGRect(x: 380, y: 60 + Double(row) * 40, width: 200, height: 14)) }
        }
        if camera {
            try await writeVideo(to: pkg.appendingPathComponent("camera.mov"), size: CGSize(width: 320, height: 240), seconds: seconds, audio: false) { ctx, t in
                ctx.setFillColor(CGColor(red: 0.85, green: 0.6, blue: 0.45, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
                ctx.setFillColor(CGColor(red: 0.95, green: 0.8, blue: 0.65, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: 110 + sin(t * 3) * 10, y: 50, width: 100, height: 130))
            }
        }
        var ev = StudioEvents(version: 1, region: .init(x: 0, y: 0, width: 320, height: 200), scale: 2 * k, duration: seconds)
        var t = 0.0
        while t < seconds {
            ev.events.append(.init(t: t, type: "move", x: 160 + cos(t * 1.7) * 110, y: 100 + sin(t * 1.7) * 70))
            t += 1.0 / 60
        }
        for c in [1.0, 1.4, 2.9] {
            let p = (x: 160 + cos(c * 1.7) * 110, y: 100 + sin(c * 1.7) * 70)
            ev.events.append(.init(t: c, type: "down", x: p.x, y: p.y))
            ev.events.append(.init(t: c + 0.08, type: "up", x: p.x, y: p.y))
        }
        for (i, k) in ["⌘C", "h", "i", "⌘V"].enumerated() { ev.events.append(.init(t: 2.0 + Double(i) * 0.25, type: "key", key: k)) }
        if seconds > 6 { for i in 0..<16 { ev.events.append(.init(t: 4.0 + Double(i) * 0.15, type: "typing")) } }   // a typing stretch
        if seconds > 6 { ev.events.append(.init(t: 2.5, type: "marker", x: 0, y: 0)) }      // a recording marker
        ev.events.sort { $0.t < $1.t }
        try StudioJSON.encode(ev)?.write(to: pkg.appendingPathComponent("events.json"))
        return pkg
    }

    static func writeVideo(to url: URL, size: CGSize, seconds: Double, audio: Bool, draw: (CGContext, Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mov" ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        let rate = 44_100.0
        var audioInput: AVAssetWriterInput?
        if audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            ])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            audioInput = a
        }
        guard writer.startWriting() else { throw writer.error ?? StudioError("Couldn't write sample.") }
        writer.startSession(atSourceTime: .zero)
        let fps = 30, total = Int(seconds * rate)
        var written = 0
        for f in 0..<Int(seconds * Double(fps)) {
            // Interleave: the writer stalls video input until audio catches up.
            if let audioInput {
                let upTo = min(total, Int(Double(f + 1) / Double(fps) * rate))
                while written < upTo {
                    while !audioInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                    let n = min(4096, upTo - written)
                    if let sb = sineBuffer(start: written, count: n, rate: rate) { audioInput.append(sb) }
                    written += n
                }
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                draw(ctx, Double(f) / Double(fps))
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? StudioError("Couldn't write sample.") }
    }

    private static func sineBuffer(start: Int, count: Int, rate: Double) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var samples = (0..<count).map { i -> Int16 in
            let t = Double(start + i) / rate
            let env = 0.5 + 0.5 * sin(t * 4)        // pulsing so the waveform has shape
            return Int16(sin(t * 440 * 2 * .pi) * 12_000 * env)
        }
        var block: CMBlockBuffer?
        let bytes = count * 2
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block, let fmt else { return nil }
        samples.withUnsafeMutableBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: count,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return sb
    }
}

// MARK: - Self-check

extension StudioDocument {
    static func selfTest() {
        var d = StudioDocument(clips: [Clip(start: 0, duration: 10)])
        assert(d.split(at: 4))
        assert(d.clips.count == 2 && d.clips[1].start == 4)
        assert(!d.split(at: 4.001))                       // too close to the cut
        d.removeClip(d.clips[0].id)                       // keep 4…10
        assert(abs(d.duration - 6) < 1e-9 && d.sourceTime(1) == 5)
        assert(d.outputTime(source: 2) == 0)              // removed content snaps to the next frame
        d.trim(0, leading: true, to: 1, sourceDuration: 10)
        assert(d.clips[0].start == 1 && abs(d.duration - 9) < 1e-9)

        var e = StudioDocument(clips: [Clip(start: 0, duration: 4), Clip(start: 6, duration: 4)])
        assert(e.sourceTime(4) == 6 && e.sourceTime(4, preferEnd: true) == 4)
        assert(e.trimBounds(0, leading: false, sourceDuration: 10).upperBound == 6)
        let z = e.addZoom(1...5)!
        let r = e.outputRange(e.zooms[0])
        assert(abs(r.lowerBound - 1) < 1e-9 && abs(r.upperBound - 5) < 1e-9 && e.zooms[0].end == 7)
        assert(e.addZoom(2...3) == nil)                   // overlaps
        assert(e.splitZoom(at: 3) && e.zooms.count == 2)
        e.setZoom(z, output: 0.5...2)
        assert(abs(e.outputRange(e.zooms.first { $0.id == z }!).upperBound - 2) < 1e-9)

        let ev = StudioEvents(region: .init(width: 1000, height: 600), duration: 20, events: [
            .init(t: 1, type: "down", x: 100, y: 100), .init(t: 2, type: "down", x: 120, y: 110),
            .init(t: 10, type: "down", x: 900, y: 500),
        ])
        let zs = autoZooms(ev, duration: 20)
        assert(zs.count == 2 && abs(zs[0].start - 0.7) < 1e-9 && abs(zs[0].end - 4.5) < 1e-9 && abs(zs[1].start - 9.7) < 1e-9)
        assert(autoZooms(StudioEvents(events: [.init(t: 9.5, type: "down", x: 1, y: 1)]), duration: 10).isEmpty, "no zoom on the final click")

        // Speed: a 2× clip takes half the output time; mapping both ways stays consistent.
        var sp = StudioDocument(clips: [Clip(start: 0, duration: 10)])
        sp.setSpeed(2, source: 2...6)
        assert(sp.clips.map(\.speed) == [1, 2, 1] && abs(sp.duration - 8) < 1e-9)
        assert(abs(sp.sourceTime(3) - 4) < 1e-9 && abs(sp.outputTime(source: 4) - 3) < 1e-9 && abs(sp.outputTime(source: 8) - 6) < 1e-9)
        assert(sp.split(at: 3) && sp.clips[1].speed == 2 && sp.clips[2].speed == 2 && abs(sp.clips[2].start - 4) < 1e-9)
        let typing = StudioEvents(events: (0..<10).map { .init(t: 1 + Double($0) * 0.25, type: "typing") } + [.init(t: 9, type: "typing")])
        assert(typing.typingBursts.count == 1 && typing.typingBursts[0] == 1...3.25)
        // Typing with backspaces and a 1.5 s pause, then ⌘A ⌘C (a real recording): one stretch, typed characters only.
        let mixed = StudioEvents(events: [11.89, 11.95, 12.19, 12.33, 12.39, 12.56, 14.08, 14.2, 14.34, 14.52, 14.62, 14.71, 14.85, 14.97, 15.21, 15.45]
            .map { .init(t: $0, type: "typing") } + [12.18, 12.35, 14.59, 14.95, 15.19].map { .init(t: $0, type: "key", key: "⌫") }
            + [.init(t: 17.18, type: "key", key: "⌘A"), .init(t: 17.84, type: "key", key: "⌘C")])
        assert(mixed.typingBursts == [11.89...15.45], "typing with ⌫ and a short pause is one stretch")
        assert(KeyBadge.build(mixed, allKeys: false).map(\.text) == ["⌘A", "⌘C"], "no ⌫ badges inside typing")
        let shortcuts = StudioEvents(events: (0..<12).map { .init(t: Double($0) * 0.3, type: "key", key: "⌘Z") })
        assert(shortcuts.typingBursts.isEmpty, "shortcuts alone aren't typing")
        assert(StudioDocument(clips: [Clip(start: 0, duration: 10)]).typingSuggestions(typing.typingBursts).count == 1)
        // Markers are timeline flags, not pointer positions.
        let marked = StudioEvents(events: [.init(t: 2, type: "marker", x: 0, y: 0)])
        assert(marked.markers == [2] && !marked.hasPointer)
        // A custom-camera layout moves the camera while it's on (eased in), and only there.
        var cl = StudioDocument(clips: [Clip(start: 0, duration: 10)])
        cl.layouts = [CameraLayout(start: 3, end: 6, kind: .custom, size: 0.4, x: 0.2, y: 0.2)]
        assert(abs(cl.camera(at: 4.5).size - 0.4) < 1e-6 && abs(cl.camera(at: 1).size - cl.camera.size) < 1e-6 && cl.camera(at: 3).size < 0.4)
        // Reset trim reaches the neighbours; deleting back to the previous cut removes the part before the playhead.
        var rt = StudioDocument(clips: [Clip(start: 1, duration: 2), Clip(start: 5, duration: 2)])
        rt.resetTrim(rt.clips[0].id, sourceDuration: 10)
        assert(rt.clips[0].start == 0 && rt.clips[0].end == 5, "trim reset to 0…5")
        var dc = StudioDocument(clips: [Clip(start: 0, duration: 10)])
        assert(dc.deleteToPreviousCut(at: 4) && dc.clips.count == 1 && dc.clips[0].start == 4 && dc.duration == 6)
        // Splitting keeps a clip's settings; merging joins it with the next and brings back what was cut between them.
        var mv = StudioDocument(clips: [Clip(start: 0, duration: 10)])
        mv.clips[0].volume = 0.5
        mv.clips[0].hideCursor = true
        mv.split(at: 4)
        assert(mv.clips.count == 2 && mv.clips[1].volume == 0.5 && mv.clips[1].hideCursor, "split copies settings")
        mv.clips[1].start = 5; mv.clips[1].duration = 5          // 4…5 cut out
        assert(mv.mergeWithNext(mv.clips[0].id) && mv.clips.count == 1 && mv.clips[0].start == 0 && mv.clips[0].duration == 10)
        assert(!mv.mergeWithNext(mv.clips[0].id), "the last clip has no next")
        var ks = Keystrokes()
        ks.hiddenAt = [1.25]
        assert(ks.isHidden(KeyBadge(start: 1.25, end: 2, text: "⌘Z ×3")) && !ks.isHidden(KeyBadge(start: 3, end: 4, text: "⌘C")), "one badge hidden")
        assert(KeyBadge(start: 0, end: 1, text: "⌘Z ×3").label == "⌘Z")
        var lay = StudioDocument(clips: [Clip(start: 0, duration: 4), Clip(start: 6, duration: 4)])
        let lid = lay.addLayout(1...7, kind: .custom)!
        assert(lay.splitLayout(at: 3) && lay.layouts.count == 2 && lay.outputRange(lay.layouts[1]).lowerBound == 3, "layout split")
        lay.layouts[0].x = 0.5; lay.layouts[0].y = 0.5
        lay.stepLayoutCamera(lid, dx: 1, dy: -1)
        assert(lay.layouts[0].x == 0.88 && lay.layouts[0].y == 0.15, "camera steps on the grid")
        lay.stepLayoutCamera(lid, dx: 1, dy: 0)
        assert(lay.layouts[0].x == 0.88, "stays at the edge")
        lay.removeAllCuts(sourceDuration: 10)
        assert(lay.clips.count == 1 && lay.duration == 10 && lay.layouts.count == 2, "cuts gone, layouts kept")
        var typed = StudioDocument(clips: [Clip(start: 0, duration: 10)])
        typed.setSpeed(4, source: 1...3.25)
        assert(typed.speed(of: 1...3.25) == 4 && typed.typingSuggestions(typing.typingBursts).isEmpty, "applied: no longer suggested")
        typed.setSpeed(1, source: 1...3.25)
        typed.typingDismissed = [1]
        assert(typed.speed(of: 1...3.25) == 1 && typed.typingSuggestions(typing.typingBursts).isEmpty, "removed: not suggested again")
        assert(sp.typingSuggestions(StudioEvents(events: (0..<10).map { .init(t: 2.5 + Double($0) * 0.25, type: "typing") }).typingBursts).isEmpty)

        let json = Data(#"{"clips":[{"id":"6F1A7E3C-1111-4C1B-9A2E-000000000001","start":1,"duration":2}],"cursor":{"size":2}}"#.utf8)
        let loaded = StudioJSON.decode(StudioDocument.self, from: json, defaults: StudioDocument())!
        assert(loaded.clips.count == 1 && loaded.cursor.size == 2 && loaded.cursor.show && loaded.background.padding == 0.08)
        // Masks: added into the free gap, fully on over their span and fading only outside it.
        var mk = StudioDocument(clips: [Clip(start: 0, duration: 10)])
        let m1 = mk.addMask(2...4)!
        assert(mk.addMask(3...5) == nil && mk.maskGap(around: 5) == 4...10)
        mk.setMask(m1, output: 1...3)
        let mask = mk.masks[0]
        assert(mask.start == 1 && mask.end == 3 && maskAlpha(mask, at: 1) == 1 && maskAlpha(mask, at: 0.9) < 1 && maskAlpha(mask, at: 3.3) == 0)

        // Export never upscales: 1080p of a 1200×600 canvas stays 1200×600, and isn't offered.
        assert(StudioResolution.r1080.size(for: CGSize(width: 1200, height: 600)) == CGSize(width: 1200, height: 600))
        assert(StudioResolution.r480.size(for: CGSize(width: 1200, height: 600)) == CGSize(width: 960, height: 480))
        assert(StudioResolution.choices(for: CGSize(width: 1200, height: 600)) == [.original, .r480, .r360, .r240])
        StudioTracks.selfTest()
    }
}
