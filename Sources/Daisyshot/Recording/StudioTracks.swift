import CoreGraphics
import Foundation

/// Time-indexed data derived from events.json + the document, evaluated per frame by the compositor.
enum StudioTracks {
    static func easeInOut(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }

    /// Fast start, slight overshoot: the "Dynamic" zoom style.
    static func easeOutBack(_ u: Double) -> Double {
        let u = min(max(u, 0), 1), c1 = 1.1, c3 = c1 + 1
        return 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let u = min(max((x - a) / (b - a), 0), 1)
        return u * u * (3 - 2 * u)
    }

    static func selfTest() {
        // Cursor: critically damped spring converges to a resting target.
        let ev = StudioEvents(region: .init(width: 100, height: 100), duration: 3, events: [
            .init(t: 0, type: "move", x: 0, y: 0), .init(t: 0.5, type: "move", x: 100, y: 50),
        ])
        let c = CursorTrack(ev, smoothing: 0.6)
        assert(abs(c.position(at: 2.5).x - 100) < 0.5 && c.position(at: 0.5).x < 100)
        assert(CursorTrack(ev, smoothing: 0).position(at: 0.25).x == 50)
        assert(c.alpha(at: 2.9, hideIdle: true, hideTyping: false) < 0.01 && c.alpha(at: 0.6, hideIdle: true, hideTyping: false) == 1)

        // Zoom: full scale mid-segment, none before, and two adjacent zooms never dip back to 1×.
        let zt = ZoomTrack(segments: [.init(start: 1, end: 4, scale: 2, follow: false, focus: CGPoint(x: 0.3, y: 0.3)),
                                      .init(start: 4.2, end: 7, scale: 3, follow: false, focus: CGPoint(x: 0.6, y: 0.6))],
                           animation: 0.6, style: .smooth, length: 9) { _ in .zero }
        assert(zt.state(at: 0.5).scale == 1 && zt.state(at: 0.5).envelope == 0)
        assert(abs(zt.state(at: 2.5).scale - 2) < 0.01 && zt.state(at: 2.5).envelope > 0.99 && abs(zt.state(at: 2.5).focus.x - 0.3) < 0.01)
        assert(zt.state(at: 4.1).scale > 1.8)
        assert(abs(zt.state(at: 6.5).focus.x - 0.6) < 0.01 && abs(zt.state(at: 8.9).scale - 1) < 0.01)
        // The mapping: the middle stays in the middle, a point near an edge pins the view to that edge.
        assert(ZoomTrack.shift(point: CGPoint(x: 0.5, y: 0.5), scale: 2) == CGPoint(x: -0.5, y: -0.5))
        assert(ZoomTrack.shift(point: CGPoint(x: 0.2, y: 0.9), scale: 2) == CGPoint(x: 0, y: -1))
        // While zooming in, the zoomed point doesn't move on screen (the picture grows out of it).
        let still = ZoomTrack(segments: [.init(start: 1, end: 5, scale: 2, follow: true, focus: .zero)], animation: 0.8, style: .smooth,
                              length: 6) { _ in CGPoint(x: 0.4, y: 0.6) }
        for t in [1.05, 1.15, 1.3, 1.6, 3.0] {
            let z = still.state(at: t), u = (0.4 - 0.25) / 0.5            // the point after edge pinning
            let onScreen = u * z.scale + 0.5 - z.focus.x * z.scale
            assert(abs(onScreen - u) < 1e-6, "zoom anchor drifted at \(t): \(onScreen)")
        }
        assert(still.state(at: 1.15).scale > 1.1 && still.state(at: 1.15).scale < 1.9, "mid-animation")
        // Click groups: small moves stay in one group; a move across the screen starts the next.
        let groups = ZoomTrack.clickGroups(.init(start: 0, end: 4, scale: 2, follow: true, focus: .zero)) { t in
            t < 2 ? CGPoint(x: 0.4 + t * 0.02, y: 0.5) : CGPoint(x: 0.8, y: 0.6)
        }
        assert(groups.count == 2 && abs(groups[0].p.x - 0.42) < 0.01 && groups[1].p.x == 0.8 && abs(groups[1].t - 2) < 0.05)

        // Steady shapes skip a shape shown under 0.2 s; the idle delay is adjustable.
        let flicker = StudioEvents(events: [.init(t: 0, type: "cursor", cursor: "arrow"), .init(t: 1, type: "cursor", cursor: "hand"),
                                            .init(t: 1.1, type: "cursor", cursor: "arrow"), .init(t: 0, type: "move", x: 0, y: 0)])
        assert(CursorTrack(flicker, smoothing: 0).shape(at: 1.05) == "hand" && CursorTrack(flicker, smoothing: 0, steadyShapes: true).shape(at: 1.05) == "arrow")
        assert(c.alpha(at: 1.4, hideIdle: true, hideTyping: false, idleDelay: 0.5) < 0.01 && c.alpha(at: 1.4, hideIdle: true, hideTyping: false) == 1)
        // The custom spring at its defaults (k 200, c 40, m 2.25) is the Smooth spring.
        let focused = ZoomTrack.Spring(stiffness: 200, damping: 40, mass: 2.25), smooth = ZoomTrack.Spring(animation: 0.8, style: .smooth)
        assert(abs(focused.omega - smooth.omega) < 0.05 && abs(focused.zeta - smooth.zeta) < 0.01)
        // "Always keep zoomed in" fills the gaps around a zoom with cursor-following ones.
        let filled = ZoomTrack.filled([.init(start: 2, end: 4, scale: 2, follow: false, focus: .zero)], length: 10, scale: 1.5)
        assert(filled.map(\.start) == [0, 2, 4] && filled.map(\.end) == [2, 4, 10] && filled[0].follow && filled[2].scale == 1.5)
        // A gliding manual zoom drifts in its direction.
        let glide = ZoomTrack(segments: [.init(start: 0, end: 6, scale: 2, follow: false, focus: CGPoint(x: 0.5, y: 0.5), glide: CGVector(dx: 0.2, dy: 0))],
                              animation: 0.8, style: .smooth, length: 6) { _ in .zero }
        assert(glide.state(at: 5.5).focus.x - glide.state(at: 1.5).focus.x > 0.1, "glides right")

        // Keystrokes: typed letters merge into one badge, shortcuts stand alone.
        let keys = StudioEvents(events: [.init(t: 0, type: "key", key: "h"), .init(t: 0.2, type: "key", key: "i"),
                                         .init(t: 0.4, type: "key", key: "⌘S")])
        assert(KeyBadge.build(keys, allKeys: true).map(\.text) == ["hi", "⌘S"])
        assert(KeyBadge.build(keys, allKeys: false).map(\.text) == ["⌘S"])
        let again = StudioEvents(events: [.init(t: 0, type: "key", key: "⌘Z"), .init(t: 0.5, type: "key", key: "⌘Z"),
                                          .init(t: 1.5, type: "key", key: "⌘Z"), .init(t: 4, type: "key", key: "⌘Z"),
                                          .init(t: 4.2, type: "key", key: "←"), .init(t: 4.4, type: "key", key: "a")])
        assert(KeyBadge.build(again, allKeys: false).map(\.text) == ["⌘Z ×3", "⌘Z", "←"])
        assert(KeyBadge.build(again, allKeys: false, hidden: ["⌘Z"]).map(\.text) == ["←"])
        assert(KeyBadge.shortcuts(again) == ["⌘Z", "←"])

        let shaped = CursorTrack(StudioEvents(duration: 3, events: [
            .init(t: 0.5, type: "cursor", x: 1, y: 1, cursor: "arrow"), .init(t: 1, type: "cursor", x: 1, y: 1, cursor: "iBeam"),
        ]), smoothing: 0)
        assert(shaped.shape(at: 0) == "arrow" && shaped.shape(at: 0.9) == "arrow" && shaped.shape(at: 2) == "iBeam")

        // A lone far sample that comes right back is dropped; a real move to a new place is kept.
        let jumpy: [StudioEvents.Event] = [.init(t: 0, type: "move", x: 10, y: 10), .init(t: 0.02, type: "move", x: 900, y: 10),
                                           .init(t: 0.04, type: "move", x: 12, y: 10), .init(t: 0.06, type: "move", x: 14, y: 10),
                                           .init(t: 2, type: "move", x: 900, y: 600), .init(t: 2.02, type: "move", x: 902, y: 600)]
        assert(CursorTrack.withoutJumps(jumpy).map(\.x!) == [10, 12, 14, 900, 902])

        // Even heavily smoothed, the cursor is on the click point when the click happens.
        let reach = StudioEvents(region: .init(width: 1000, height: 600), duration: 3, events: [
            .init(t: 0, type: "move", x: 0, y: 0), .init(t: 0.9, type: "move", x: 800, y: 400),
            .init(t: 1, type: "down", x: 800, y: 400), .init(t: 1.05, type: "up", x: 800, y: 400),
        ])
        let p = CursorTrack(reach, smoothing: 1).position(at: 1)
        assert(hypot(p.x - 800, p.y - 400) < 3, "cursor reaches the click: \(p)")
    }
}

// MARK: - Cursor

/// Cursor path sampled at 120 Hz, optionally smoothed with a critically damped spring.
final class CursorTrack: @unchecked Sendable {
    static let rate = 120.0
    let smoothing: Double
    let removeJumps: Bool
    let jumpLimit: Double
    let steadyShapes: Bool
    private let samples: [CGPoint]         // points, top-left origin
    private let moves: [Double]            // times the pointer actually moved
    private let keys: [Double]
    private let presses: [(Double, Double)]
    let clicks: [(t: Double, p: CGPoint)]
    private let shapes: [(t: Double, id: String)]     // shape changes, in time order

    init(_ ev: StudioEvents, smoothing: Double, removeJumps: Bool = true, jumpLimit: Double = 500, steadyShapes: Bool = false) {
        self.smoothing = smoothing
        self.removeJumps = removeJumps
        self.jumpLimit = jumpLimit
        self.steadyShapes = steadyShapes
        var pts = ev.events.filter(\.hasPosition).sorted { $0.t < $1.t }
        if removeJumps { pts = Self.withoutJumps(pts, limit: jumpLimit) }
        let duration = max(ev.duration, pts.last?.t ?? 0) + 1
        let n = max(2, Int(duration * Self.rate) + 1)
        var raw = [CGPoint](repeating: .zero, count: n)
        var j = 0
        let first = pts.first.map { CGPoint(x: $0.x!, y: $0.y!) } ?? CGPoint(x: ev.region.width / 2, y: ev.region.height / 2)
        for i in 0..<n {
            let t = Double(i) / Self.rate
            while j + 1 < pts.count, pts[j + 1].t <= t { j += 1 }
            guard !pts.isEmpty, t >= pts[0].t else { raw[i] = first; continue }
            let a = pts[j]
            if j + 1 < pts.count {
                let b = pts[j + 1], u = (t - a.t) / max(1e-6, b.t - a.t)
                raw[i] = CGPoint(x: a.x! + (b.x! - a.x!) * u, y: a.y! + (b.y! - a.y!) * u)
            } else {
                raw[i] = CGPoint(x: a.x!, y: a.y!)
            }
        }
        var lastP: CGPoint?
        moves = pts.compactMap { e in
            let p = CGPoint(x: e.x!, y: e.y!)
            defer { lastP = p }
            return lastP.map { hypot($0.x - p.x, $0.y - p.y) > 0.5 } ?? true ? e.t : nil
        }
        keys = ev.events.filter { $0.type == "key" || $0.type == "typing" }.map(\.t).sorted()
        var downs: [(Double, Double)] = []
        var open: Double?
        for e in ev.events.sorted(by: { $0.t < $1.t }) {
            if e.type == "down" || e.type == "rightDown" { open = e.t }
            if (e.type == "up" || e.type == "rightUp"), let o = open { downs.append((o, e.t)); open = nil }
        }
        if let o = open { downs.append((o, o + 0.15)) }
        presses = downs
        clicks = pts.filter(\.isClick).map { ($0.t, CGPoint(x: $0.x!, y: $0.y!)) }
        let allShapes = ev.events.compactMap { e in e.type == "cursor" ? e.cursor.map { (t: e.t, id: $0) } : nil }.sorted { $0.t < $1.t }
        // Steady shapes: a shape that lasts under 0.2 s (passing over a button or an edge) is skipped.
        shapes = steadyShapes ? allShapes.indices.filter { i in i + 1 == allShapes.count || allShapes[i + 1].t - allShapes[i].t >= 0.2 }.map { allShapes[$0] } : allShapes
        if smoothing <= 0.001 {
            samples = raw
        } else {
            let (target, omega) = Self.clickAware(raw, clicks: clicks, presses: downs, omega: 40 * pow(0.12, smoothing))
            samples = Self.spring(target) { omega[$0] }
        }
    }

    /// Drops a move sample that is more than `limit` points (Manhattan) from both of the next two samples, shortly after:
    /// a jump that comes right back (accessibility tools, remote control), not a movement.
    static func withoutJumps(_ pts: [StudioEvents.Event], limit: Double = 500) -> [StudioEvents.Event] {
        guard pts.count > 2 else { return pts }
        func d(_ a: StudioEvents.Event, _ b: StudioEvents.Event) -> Double { abs(a.x! - b.x!) + abs(a.y! - b.y!) }
        return pts.indices.filter { i in
            let e = pts[i]
            guard e.type == "move", i + 2 < pts.count, pts[i + 2].t - e.t < 0.25 else { return true }
            return d(e, pts[i + 1]) <= limit || d(e, pts[i + 2]) <= limit
        }.map { pts[$0] }
    }

    /// Clicks pull the smoothed cursor: up to 0.5 s before a click it heads straight for the click point, and the spring
    /// stiffens around clicks and drags, so the cursor lands on target as the click happens instead of trailing in.
    private static func clickAware(_ raw: [CGPoint], clicks: [(t: Double, p: CGPoint)], presses: [(Double, Double)],
                                   omega w: Double) -> ([CGPoint], [Double]) {
        var target = raw, omega = [Double](repeating: w, count: raw.count)
        let tight = max(w, 18)
        func index(_ t: Double) -> Int { min(raw.count - 1, max(0, Int((t * rate).rounded()))) }
        var free = -Double.infinity    // the previous press must finish before heading for the next click
        for c in clicks {
            let a = index(max(c.t - 0.5, free)), b = index(c.t)
            if a <= b { for i in a...b { target[i] = c.p; omega[i] = tight } }
            free = presses.first { $0.0 == c.t }?.1 ?? c.t
        }
        for (a, b) in presses where index(a) <= index(b) { for i in index(a)...index(b) { omega[i] = tight } }
        return (target, omega)
    }

    private static func spring(_ raw: [CGPoint], omega: (Int) -> Double) -> [CGPoint] {
        var out = raw
        var p = raw[0], v = CGPoint.zero
        let dt = 1 / rate
        for i in 0..<raw.count {
            let w = omega(i)
            let ax = w * w * (raw[i].x - p.x) - 2 * w * v.x
            let ay = w * w * (raw[i].y - p.y) - 2 * w * v.y
            v.x += ax * dt; v.y += ay * dt
            p.x += v.x * dt; p.y += v.y * dt
            out[i] = p
        }
        return out
    }

    private static func sample(_ a: [CGPoint], _ t: Double) -> CGPoint {
        let f = min(max(t * rate, 0), Double(a.count - 1))
        let i = Int(f), u = f - Double(i)
        guard i + 1 < a.count else { return a[a.count - 1] }
        return CGPoint(x: a[i].x + (a[i + 1].x - a[i].x) * u, y: a[i].y + (a[i + 1].y - a[i].y) * u)
    }

    func position(at t: Double) -> CGPoint { Self.sample(samples, t) }

    func isPressed(at t: Double) -> Bool { presses.contains { t >= $0.0 && t <= $0.1 } }

    /// Recorded cursor shape id at `t` (nil for recordings without shapes).
    func shape(at t: Double) -> String? {
        var lo = 0, hi = shapes.count
        while lo < hi { let m = (lo + hi) / 2; if shapes[m].t <= t { lo = m + 1 } else { hi = m } }
        return lo > 0 ? shapes[lo - 1].id : shapes.first?.id
    }

    private static func last(_ a: [Double], before t: Double) -> Double? {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) / 2; if a[m] <= t { lo = m + 1 } else { hi = m } }
        return lo > 0 ? a[lo - 1] : nil
    }

    /// 0…1 visibility: fades out `idleDelay` seconds after the last movement, and while typing.
    func alpha(at t: Double, hideIdle: Bool, hideTyping: Bool, idleDelay: Double = 1.5) -> Double {
        var a = 1.0
        let lastMove = Self.last(moves, before: t) ?? -10
        if hideIdle { a = min(a, 1 - StudioTracks.smoothstep(idleDelay, idleDelay + 0.3, t - lastMove)) }
        if hideTyping, let k = Self.last(keys, before: t), k > lastMove {
            a = min(a, 1 - StudioTracks.smoothstep(0, 0.15, t - k))
        }
        return a
    }
}

// MARK: - Zoom

/// The camera. A zoom on point u (0…1 across the recording) at scale S shows the window whose
/// left edge is u·(1 − 1/S): the point sits as far across the view as it is across the screen, so the view never leaves
/// the recording and needs no clamping. Springs move the view transform v = x·s + t (scale s and translation t, every
/// channel with the same spring), and a transform interpolated that way keeps one point still — the zoomed point. The
/// picture grows out of the cursor instead of sliding while it scales. The path is simulated once (120 Hz), so preview,
/// scrubbing and export show the same frames.
/// Follow-cursor zooms aim at click groups: the camera holds still while the pointer works inside half the visible
/// width / 70 % of its height, and moves on when it leaves. Within a quarter view of an edge, the view pins to it.
struct ZoomTrack: Sendable {
    struct Segment: Sendable {
        var start: Double      // output seconds
        var end: Double
        var scale: Double
        var follow: Bool
        var focus: CGPoint     // manual zooms: centre of the view, normalized, top-left origin
        var glide = CGVector.zero   // manual zooms: how far the centre moves over the zoom (normalized)
    }

    /// The spring that moves the view: angular frequency and damping ratio.
    struct Spring {
        var omega: Double
        var zeta: Double
        /// From a settle time (0.8 s ≈ k 200, m 2.25) and a style.
        init(animation: Double, style: ZoomStyle) {
            omega = 7.54 / max(0.1, animation)
            zeta = style == .dynamic ? 0.62 : 0.94
        }
        /// From stiffness, damping and mass.
        init(stiffness k: Double, damping c: Double, mass m: Double) {
            let k = max(1, k), m = max(0.05, m)
            omega = (k / m).squareRoot()
            zeta = max(0.05, c) / (2 * (k * m).squareRoot())
        }
    }
    struct State {
        var scale = 1.0
        var focus = CGPoint(x: 0.5, y: 0.5)     // centre of the visible window, normalized, top-left origin
        var envelope = 0.0     // 0 = not zoomed, 1 = fully in
    }

    static let rate = 120.0
    private let path: [State]
    var isEmpty: Bool { path.isEmpty }

    /// `animation`: seconds for a zoom to settle (and the longest gap a pan bridges). `cursor`: output time → normalized
    /// cursor position.
    init(segments: [Segment], animation: Double, style: ZoomStyle, length: Double, cursor: (Double) -> CGPoint) {
        self.init(segments: segments, animation: animation, spring: Spring(animation: animation, style: style), length: length, cursor: cursor)
    }

    /// `edge`: snap-to-edges share (a pointer that close to an edge pins the view to it; 0 = off).
    init(segments: [Segment], animation: Double, spring: Spring, length: Double, edge: Double = 0.25, cursor: (Double) -> CGPoint) {
        let segs = segments.filter { $0.end - $0.start > 0.01 }.sorted { $0.start < $1.start }
        guard !segs.isEmpty, length > 0 else { path = []; return }
        // Each segment's view translations (t = −u·(S − 1) per axis), from when they apply. A gliding zoom's centre moves
        // steadily from half its travel before the focus to half after.
        let aims: [[(t: Double, shift: CGPoint)]] = segs.map { s in
            if s.follow { return Self.clickGroups(s, cursor: cursor).map { ($0.t, Self.shift(point: $0.p, scale: s.scale, edge: edge)) } }
            guard s.glide != .zero else { return [(s.start, Self.shift(center: s.focus, scale: s.scale))] }
            return stride(from: s.start, through: s.end, by: 1.0 / 30).map { t in
                let u = (t - s.start) / max(0.01, s.end - s.start) - 0.5
                return (t, Self.shift(center: CGPoint(x: s.focus.x + s.glide.dx * u, y: s.focus.y + s.glide.dy * u), scale: s.scale))
            }
        }
        // A zoom holds until the next one when the gap is shorter than an animation: the camera pans across instead of
        // zooming out and back in.
        let holds = segs.indices.map { k in k + 1 < segs.count && segs[k + 1].start - segs[k].end < animation ? segs[k + 1].start : segs[k].end }
        let w = spring.omega, zeta = spring.zeta
        let n = Int(length * Self.rate) + 2, dt = 1 / Self.rate
        var out = [State](repeating: State(), count: n)
        var x = [1.0, 0, 0, 0], v = [0.0, 0, 0, 0]            // scale, tx, ty, envelope
        var k = 0                                               // first segment not yet over
        for i in 0..<n {
            let t = Double(i) * dt
            while k < segs.count, t > holds[k] { k += 1 }
            var target = [1.0, 0, 0, 0]
            if k < segs.count, t >= segs[k].start {
                let shift = aims[k].last { $0.t <= t }?.shift ?? aims[k][0].shift
                target = [segs[k].scale, shift.x, shift.y, 1]
            }
            for c in 0..<4 {
                v[c] += (w * w * (target[c] - x[c]) - 2 * zeta * w * v[c]) * dt
                x[c] += v[c] * dt
            }
            let s = max(1, x[0])
            out[i] = State(scale: s, focus: CGPoint(x: (0.5 - x[1]) / s, y: (0.5 - x[2]) / s), envelope: min(1, max(0, x[3])))
        }
        path = out
    }

    func state(at t: Double) -> State {
        guard !path.isEmpty else { return State() }
        let f = min(max(t * Self.rate, 0), Double(path.count - 1))
        let i = Int(f), u = f - Double(i)
        guard i + 1 < path.count else { return path[i] }
        let a = path[i], b = path[i + 1]
        func mix(_ p: Double, _ q: Double) -> Double { p + (q - p) * u }
        return State(scale: mix(a.scale, b.scale), focus: CGPoint(x: mix(a.focus.x, b.focus.x), y: mix(a.focus.y, b.focus.y)),
                     envelope: mix(a.envelope, b.envelope))
    }

    /// "Always keep zoomed in": the gaps between `segs` (and before / after them) filled with cursor-following zooms at
    /// `scale`, so a cropped (vertical) frame keeps showing where the pointer is.
    static func filled(_ segs: [Segment], length: Double, scale: Double) -> [Segment] {
        var out: [Segment] = [], t = 0.0
        for s in segs.sorted(by: { $0.start < $1.start }) where s.end > s.start {
            if s.start - t > 0.05 { out.append(Segment(start: t, end: s.start, scale: scale, follow: true, focus: CGPoint(x: 0.5, y: 0.5))) }
            out.append(s)
            t = max(t, s.end)
        }
        if length - t > 0.05 { out.append(Segment(start: t, end: length, scale: scale, follow: true, focus: CGPoint(x: 0.5, y: 0.5))) }
        return out
    }

    /// Translation that zooms on `point`, after pinning: a point within a quarter view of an
    /// edge counts as on the edge.
    static func shift(point p: CGPoint, scale: Double, edge: Double = 0.25) -> CGPoint {
        let s = max(1, scale), r = min(max(0, edge), 1 / s, 0.49)
        func axis(_ v: Double) -> Double { -min(1, max(0, (v - r) / (1 - 2 * r))) * (s - 1) }
        return CGPoint(x: axis(p.x), y: axis(p.y))
    }

    /// Translation that puts the view's centre on `center` (manual zooms), kept inside the recording.
    static func shift(center c: CGPoint, scale: Double) -> CGPoint {
        let s = max(1, scale), h = 0.5 / s
        func axis(_ v: Double) -> Double { -(min(max(v, h), 1 - h) - h) * s }
        return CGPoint(x: axis(c.x), y: axis(c.y))
    }

    /// Cursor samples of a follow zoom split into groups that each fit in half the visible width and 70 % of its height;
    /// the camera aims at each group's center from the group's first sample on.
    static func clickGroups(_ s: Segment, cursor: (Double) -> CGPoint) -> [(t: Double, p: CGPoint)] {
        let maxW = 0.5 / s.scale, maxH = 0.7 / s.scale
        var groups: [(t: Double, box: CGRect)] = []
        var t = s.start
        while t <= s.end {
            let p = cursor(t)
            if let g = groups.last, g.box.union(CGRect(origin: p, size: .zero)).width <= maxW, g.box.union(CGRect(origin: p, size: .zero)).height <= maxH {
                groups[groups.count - 1].box = g.box.union(CGRect(origin: p, size: .zero))
            } else {
                groups.append((t, CGRect(origin: p, size: .zero)))
            }
            t += 1.0 / 30
        }
        return groups.map { ($0.t, CGPoint(x: $0.box.midX, y: $0.box.midY)) }
    }
}

// MARK: - Keystrokes

struct KeyBadge: Sendable {
    var start: Double
    var end: Double
    var text: String
    /// The shortcut without a repeat count ("⌘Z ×3" → "⌘Z"): what "hide every …" hides.
    var label: String { text.components(separatedBy: " ×").first ?? text }

    static let hold = 1.2
    static let repeatWindow = 2.0
    private static let modifiers: Set<Character> = ["⌘", "⌃", "⌥"]

    /// Display label of a logged key and whether it stands alone (shortcuts, plus arrows, ⌫, ⎋, F-keys…).
    static func classify(_ key: String) -> (label: String, standalone: Bool) {
        var k = key
        if k.hasPrefix("⇧"), k.count == 2 { k.removeFirst() }      // ⇧A → A
        return (k, k.contains { modifiers.contains($0) } || KeystrokeFormatter.standalone.contains(k))
    }

    /// Distinct standalone labels in order of first use (the "hide shortcut" list).
    static func shortcuts(_ ev: StudioEvents) -> [String] {
        var seen = Set<String>()
        return ev.events.compactMap { e in
            guard e.type == "key", let k = e.key, !k.isEmpty else { return nil }
            let c = classify(k)
            return c.standalone && seen.insert(c.label).inserted ? c.label : nil
        }
    }

    /// The same shortcut pressed again within `repeatWindow` updates one badge ("⌘Z ×3") instead of stacking new ones.
    /// Keys that only edit what's being typed: no badge of their own inside a typing stretch.
    static let editingKeys: Set<String> = ["⌫", "⌦", "←", "→", "↑", "↓", "⇧←", "⇧→", "⇧↑", "⇧↓", "⌥⌫", "⌥←", "⌥→"]

    static func build(_ ev: StudioEvents, allKeys: Bool, hidden: Set<String> = []) -> [KeyBadge] {
        var out: [KeyBadge] = []
        let typingStretches = allKeys ? [] : ev.typingBursts
        var typing = false
        var repeats = 1, lastShortcut: String?, lastPress = -Double.infinity
        for e in ev.events where e.type == "key" {
            guard let raw = e.key, !raw.isEmpty else { continue }
            let (k, isShortcut) = classify(raw)
            let isChar = !isShortcut && k.count == 1
            guard allKeys || isShortcut, !hidden.contains(k) else { continue }
            if editingKeys.contains(k), typingStretches.contains(where: { $0.contains(e.t) }) { continue }
            defer { lastShortcut = isShortcut ? k : nil; lastPress = e.t; typing = isChar }
            if isShortcut, k == lastShortcut, e.t - lastPress <= repeatWindow, var last = out.last {
                repeats += 1
                last.text = "\(k) ×\(repeats)"
                last.end = e.t + hold
                out[out.count - 1] = last
            } else if isChar, typing, var last = out.last, e.t <= last.end {
                last.text = String((last.text + (k == " " ? "␣" : k)).suffix(28))
                last.end = e.t + hold
                out[out.count - 1] = last
            } else {
                if var last = out.last, last.end > e.t { last.end = e.t; out[out.count - 1] = last }
                out.append(KeyBadge(start: e.t, end: e.t + hold, text: k == " " ? "␣" : k))
                repeats = 1
            }
        }
        return out
    }
}
