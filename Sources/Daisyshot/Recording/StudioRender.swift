import AppKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Sources

/// A recorded cursor shape: `size` and `hotspot` in points (top-left origin), `image` at a higher pixel density.
struct StudioCursorShape: @unchecked Sendable {
    let image: CGImage
    let size: CGSize
    let hotspot: CGPoint

    /// Shapes saved by the recorder in `<package>/cursors/`, by id.
    static func load(_ package: URL) -> [String: StudioCursorShape] {
        let folder = package.appendingPathComponent(StudioCaptureLayout.cursors, isDirectory: true)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("cursors.json")),
              let file = try? JSONDecoder().decode(CursorShapeFile.self, from: data) else { return [:] }
        var out: [String: StudioCursorShape] = [:]
        for s in file.shapes {
            guard let src = CGImageSourceCreateWithURL(folder.appendingPathComponent("\(s.id).png") as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            out[s.id] = StudioCursorShape(image: img, size: CGSize(width: s.width, height: s.height), hotspot: CGPoint(x: s.hotX, y: s.hotY))
        }
        return out
    }
}

/// The loaded media of a package (screen video, audio tracks, optional camera).
struct StudioSources: @unchecked Sendable {
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: [AVAssetTrack]
    let camera: AVAssetTrack?
    let cameraAsset: AVURLAsset?      // tracks don't retain their asset
    let videoRange: CMTimeRange
    let audioRanges: [CMTimeRange]
    let cameraRange: CMTimeRange
    let duration: Double
    let size: CGSize                  // oriented pixel size of the screen video
    let transform: CGAffineTransform  // CI-space orientation transform for screen frames
    let cameraSize: CGSize
    let cameraTransform: CGAffineTransform
    let cameraOffset: Double          // screen-video time at which the camera file starts
    let cursorShapes: [String: StudioCursorShape]
    let fps: Double
    /// Noise-reduced copies of audio tracks (by index); each starts where its original track starts.
    var cleanAudio: [Int: CleanAudio] = [:]
    /// Loudness-normalizing volume per track, measured on the original ("0") or the clean copy ("0c").
    var gains: [String: Float] = [:]

    /// Background music or the click sound, with the file they came from.
    struct ExtraAudio {
        let url: URL
        let asset: AVURLAsset
        let track: AVAssetTrack
        let range: CMTimeRange
    }
    var music: ExtraAudio?
    var click: ExtraAudio?
    /// Source times of the recording's clicks (for click sounds).
    var clickTimes: [Double] = []

    struct CleanAudio {
        let asset: AVURLAsset       // tracks don't retain their asset
        let track: AVAssetTrack
        let range: CMTimeRange
    }

    static func gainKey(_ i: Int, clean: Bool) -> String { clean ? "\(i)c" : "\(i)" }

    static func load(_ pkg: StudioPackage) async throws -> StudioSources {
        let asset = AVURLAsset(url: pkg.videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError("The file has no video track.") }
        let (natural, pref, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        // Every timeline/thumbnail/export calculation divides by the duration.
        guard duration.isFinite, duration > 0 else { throw StudioError("The video is empty or damaged.") }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var audioRanges: [CMTimeRange] = []
        for a in audio { audioRanges.append(try await a.load(.timeRange)) }
        var camera: AVAssetTrack?, camSize = CGSize.zero, camT = CGAffineTransform.identity, camRange = CMTimeRange.zero
        let cameraAsset = pkg.cameraURL.map { AVURLAsset(url: $0) }
        if let cameraAsset, let t = try? await cameraAsset.loadTracks(withMediaType: .video).first,
           case let (n, p, r)? = try? await t.load(.naturalSize, .preferredTransform, .timeRange) {
            camera = t
            camRange = r
            (camSize, camT) = orientation(n, p)
        }
        let (size, t) = orientation(natural, pref)
        return StudioSources(asset: asset, video: video, audio: audio, camera: camera, cameraAsset: cameraAsset, videoRange: try await video.load(.timeRange),
                             audioRanges: audioRanges, cameraRange: camRange, duration: duration, size: size, transform: t,
                             cameraSize: camSize, cameraTransform: camT, cameraOffset: pkg.events?.cameraOffset ?? 0,
                             cursorShapes: pkg.isStudio ? StudioCursorShape.load(pkg.url) : [:],
                             fps: rate > 1 ? Double(min(rate, 60).rounded()) : 30)
    }

    /// Converts an AV (top-left) preferred transform into a CI (bottom-left) transform that lands at the origin.
    static func orientation(_ natural: CGSize, _ t: CGAffineTransform) -> (CGSize, CGAffineTransform) {
        let r = CGRect(origin: .zero, size: natural).applying(t)
        let size = CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
        let flipSrc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
        let flipDst = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        let normalized = t.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
        return (size, flipSrc.concatenating(normalized).concatenating(flipDst))
    }
}

// MARK: - Render model

/// Immutable snapshot of everything needed to draw a frame. Shared by the preview, export and frame grabs.
final class StudioRenderModel: @unchecked Sendable {
    let doc: StudioDocument
    let events: StudioEvents?
    let cursor: CursorTrack?
    let rawCursor: CursorTrack?
    /// The picture the editor works with: the recording, cropped (`doc.crop`).
    let sourceSize: CGSize
    /// The whole recording (masks and the cursor are drawn on it before cropping).
    let fullSize: CGSize
    /// The crop in CI pixel coordinates of the whole recording.
    let cropRect: CGRect
    let sourceTransform: CGAffineTransform
    let cameraTransform: CGAffineTransform
    let canvasSize: CGSize
    let zooms: ZoomTrack
    /// "Fill the frame": the view's centre (normalized, top-left origin) over time, following the pointer; nil = off.
    private let reframe: [CGPoint]?
    static let reframeRate = 30.0
    let badges: [KeyBadge]
    let wallpaper: CGImage?
    let customImage: CGImage?
    let insetColor: CGColor
    let cursorShapes: [String: StudioCursorShape]
    private let lock = NSLock()
    private var staticCache: [String: CIImage] = [:]
    private var fillCache: [String: CIImage] = [:]     // just the fill (gradient, colour, picture), per size

    init(doc: StudioDocument, sources: StudioSources, events: StudioEvents?, cursor: CursorTrack?, wallpaper: CGImage?,
         customImage: CGImage?, insetColor: CGColor = CGColor(gray: 1, alpha: 1), rawCursor: CursorTrack? = nil) {
        self.doc = doc
        self.rawCursor = events?.cursorVisibleInVideo == false ? rawCursor : nil
        self.events = events
        self.cursor = events?.cursorVisibleInVideo == false ? cursor : nil
        fullSize = sources.size
        let c = doc.crop.isFull ? StudioDocument.Crop() : doc.crop
        cropRect = CGRect(x: c.x * sources.size.width, y: (1 - c.y - c.height) * sources.size.height,
                          width: c.width * sources.size.width, height: c.height * sources.size.height).integral
            .intersection(CGRect(origin: .zero, size: sources.size))
        sourceSize = cropRect.size
        sourceTransform = sources.transform
        cameraTransform = sources.cameraTransform
        canvasSize = Self.canvasSize(source: cropRect.size, aspect: doc.background.aspect)
        let pointer = events?.cursorVisibleInVideo == false ? cursor : nil
        let anim = doc.animation
        var segments: [ZoomTrack.Segment] = doc.zooms.filter { !$0.disabled }.map { z in
            let r = doc.outputRange(z)
            let follow = z.followCursor && pointer != nil
            let d = follow ? 0 : z.glideAmount / z.scale
            let glide: CGVector = switch z.glide {
            case .none: .zero
            case .left: CGVector(dx: -d, dy: 0)
            case .right: CGVector(dx: d, dy: 0)
            case .up: CGVector(dx: 0, dy: -d)
            case .down: CGVector(dx: 0, dy: d)
            }
            return .init(start: r.lowerBound, end: r.upperBound, scale: z.scale, follow: follow, focus: CGPoint(x: z.focusX, y: z.focusY), glide: glide)
        }
        if anim.keepZoomedIn, pointer != nil { segments = ZoomTrack.filled(segments, length: doc.duration, scale: anim.keepZoomScale) }
        let spring = anim.zoomStyle == .custom
            ? ZoomTrack.Spring(stiffness: anim.rigidity, damping: anim.smoothness, mass: anim.momentum)
            : ZoomTrack.Spring(animation: anim.zoomDuration, style: anim.zoomStyle)
        zooms = ZoomTrack(segments: segments, animation: anim.zoomDuration, spring: spring, length: doc.duration, edge: anim.snapToEdges) { t in
            guard let pointer, let ev = events, ev.region.width > 0, ev.region.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
            let p = Self.cursorPoint(pointer, doc: doc, at: t)
            return doc.crop.map(CGPoint(x: p.x / ev.region.width, y: p.y / ev.region.height))
        }
        if doc.background.fillFrame, doc.background.aspect != .auto {
            reframe = Self.reframePath(doc: doc, source: cropRect.size, canvas: canvasSize) { t in
                guard let pointer, let ev = events, ev.region.width > 0, ev.region.height > 0 else { return nil }
                let p = Self.cursorPoint(pointer, doc: doc, at: t)
                return doc.crop.map(CGPoint(x: p.x / ev.region.width, y: p.y / ev.region.height))
            }
        } else {
            reframe = nil
        }
        badges = (events.map { KeyBadge.build($0, allKeys: doc.keystrokes.allKeys, hidden: Set(doc.keystrokes.hidden)) } ?? [])
            .filter { !doc.keystrokes.isHidden($0) }
        self.wallpaper = wallpaper
        self.customImage = customImage
        self.insetColor = insetColor
        cursorShapes = sources.cursorShapes
    }

    /// Takes over `old`'s rendered backgrounds when nothing they depend on changed, so editing zooms, cursor, camera…
    /// (a new model per slider tick) doesn't re-render a blurred wallpaper for every preview frame request.
    /// Dragging padding / corners / shadow / inset keeps the fill (a blurred wallpaper is the expensive part).
    func reuseBackgrounds(from old: StudioRenderModel?) {
        guard let old, old !== self, old.wallpaper === wallpaper, old.customImage === customImage else { return }
        let a = old.doc.background, b = doc.background
        guard a.kind == b.kind, a.gradient == b.gradient, a.color == b.color, a.imagePath == b.imagePath, a.blur == b.blur else { return }
        let same = a == b && old.sourceSize == sourceSize && old.insetColor == insetColor
        old.lock.lock()
        let (statics, fills) = (old.staticCache, old.fillCache)
        old.lock.unlock()
        lock.lock()
        fillCache = fills
        if same { staticCache = statics }
        lock.unlock()
    }

    static func canvasSize(source: CGSize, aspect: StudioAspect) -> CGSize {
        guard let r = aspect.ratio else { return source }
        let long = max(source.width, source.height)
        let s = r >= 1 ? CGSize(width: long, height: long / r) : CGSize(width: long * r, height: long)
        return CGSize(width: (s.width / 2).rounded() * 2, height: (s.height / 2).rounded() * 2)
    }

    /// Canvas scaled to fit `maxSide`, even dimensions.
    func renderSize(maxSide: CGFloat) -> CGSize {
        let k = min(1, maxSide / max(canvasSize.width, canvasSize.height))
        return CGSize(width: max(2, (canvasSize.width * k / 2).rounded() * 2), height: max(2, (canvasSize.height * k / 2).rounded() * 2))
    }

    // MARK: Geometry

    struct Layout {
        var frame: CGRect        // outer rounded frame (video + inset), CI coordinates
        var video: CGRect        // where the full source frame lands
        var radius: CGFloat
        var innerRadius: CGFloat
        var unit: CGFloat        // pixels per 1080p reference point
        var bezel: CGFloat = 0   // device frame thickness around `frame` (iPhone / iPad recordings)
    }

    /// iPhone / iPad recording with "Device frame" on.
    var deviceFramed: Bool { events?.device != nil && doc.background.deviceFrame }

    func layout(_ size: CGSize) -> Layout {
        let bg = doc.background
        let minSide = min(size.width, size.height)
        let unit = minSide / 1080
        let pad = bg.isVisible ? bg.padding * minSide : 0
        let side = bg.isVisible ? bg.sides.map { CGFloat($0) * unit } : [0, 0, 0, 0]     // top, right, bottom, left
        let inset = side.min() ?? 0
        var avail = CGRect(origin: .zero, size: size).insetBy(dx: pad, dy: pad)
        // Room for the device frame, which sits outside the screen.
        if deviceFramed { avail = avail.insetBy(dx: min(avail.width, avail.height) * 0.025, dy: min(avail.width, avail.height) * 0.025) }
        let aw = sourceSize.width, ah = sourceSize.height
        let k = min(avail.width / aw, avail.height / ah)
        let frame = CGRect(x: avail.midX - aw * k / 2, y: avail.midY - ah * k / 2, width: aw * k, height: ah * k).integral
        let inner = CGRect(x: frame.minX + side[3], y: frame.minY + side[2], width: max(1, frame.width - side[1] - side[3]),
                           height: max(1, frame.height - side[0] - side[2]))
        let kv = min(inner.width / sourceSize.width, inner.height / sourceSize.height)
        let video = CGRect(x: inner.midX - sourceSize.width * kv / 2, y: inner.midY - sourceSize.height * kv / 2,
                           width: sourceSize.width * kv, height: sourceSize.height * kv)
        if deviceFramed {
            // Screen corners as rounded as the device's (≈ 12% of the short side), a bezel ≈ 4.5% thick around them.
            let short = min(frame.width, frame.height)
            let radius = short * 0.12
            return Layout(frame: frame, video: video, radius: radius, innerRadius: max(0, radius - inset), unit: unit, bezel: (short * 0.045).rounded())
        }
        let radius = bg.isVisible ? min(bg.cornerRadius * unit, frame.height / 2) : 0
        return Layout(frame: frame, video: video, radius: radius, innerRadius: max(0, radius - inset), unit: unit)
    }

    /// Camera bubble rect (CI coordinates) for a render size, used by the renderer and the preview's drag handling.
    /// `t`: output time, for camera layouts with their own size and position.
    func cameraRect(_ size: CGSize, envelope: Double, at t: Double? = nil) -> CGRect {
        let c = t.map { doc.camera(at: $0) } ?? doc.camera
        let minSide = min(size.width, size.height)
        let base = c.size * minSide * (c.shrinkOnZoom ? 1 - (1 - c.zoomSize) * envelope : 1)
        let a = c.shape.aspect
        let w = base * sqrt(a), h = base / sqrt(a)
        let m = minSide * 0.03
        let cx = min(max(c.x * size.width, m + w / 2), size.width - m - w / 2)
        let cy = min(max((1 - c.y) * size.height, m + h / 2), size.height - m - h / 2)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func cameraRadius(_ r: CGRect) -> CGFloat {
        min(r.width, r.height) / 2 * CGFloat(min(1, max(0, doc.camera.effectiveRoundness)))
    }

    // MARK: Time

    func sourceTime(_ t: Double) -> Double { doc.sourceTime(t) }

    /// Source time of the cursor shown at output time `t`: held still for the last `freezeAtEnd` seconds.
    private static func cursorSource(_ doc: StudioDocument, _ t: Double) -> Double {
        doc.sourceTime(min(t, max(0, doc.duration - doc.cursor.freezeAtEnd)))
    }
    private func cursorSource(_ t: Double) -> Double { Self.cursorSource(doc, t) }

    /// Drawn cursor position (points, top-left) at output time `t`. With "loop" it glides back to where it started
    /// during the last second, so a looping GIF has no jump.
    private static func cursorPoint(_ cursor: CursorTrack, doc: StudioDocument, at t: Double) -> CGPoint {
        let p = cursor.position(at: cursorSource(doc, t))
        guard doc.cursor.loopToStart else { return p }
        let loop = max(0.3, doc.cursor.loopDuration)
        let u = StudioTracks.easeInOut((t - (doc.duration - loop)) / (loop * 0.8))
        guard u > 0 else { return p }
        let start = cursor.position(at: doc.sourceTime(0))
        return CGPoint(x: p.x + (start.x - p.x) * u, y: p.y + (start.y - p.y) * u)
    }
    private func cursorPoint(_ cursor: CursorTrack, at t: Double) -> CGPoint { Self.cursorPoint(cursor, doc: doc, at: t) }

    func zoomState(at t: Double) -> ZoomTrack.State { zooms.state(at: t) }

    // MARK: Frame

    func render(outputTime t: Double, screen: CIImage?, camera: CIImage?, size: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let src = CGRect(origin: .zero, size: fullSize)
        let s = sourceTime(t)
        var frame = screen.map { $0.transformed(by: sourceTransform).cropped(to: src) } ?? CIImage(color: .black).cropped(to: src)
        frame = applyMasks(frame, at: s)
        frame = drawCursor(on: frame, at: t)
        if cropRect.size != fullSize {
            frame = frame.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        }
        let W = sourceSize.width

        let z = zoomState(at: t)
        let L: Layout
        var placed: CIImage
        if let reframe {
            // Fill the frame: a window of the canvas' shape (smaller while zoomed) moves over the recording.
            L = Layout(frame: canvas, video: canvas, radius: 0, innerRadius: 0, unit: min(size.width, size.height) / 1080)
            placed = frame.clampedToExtent().transformed(by: reframeTransform(reframe, z, at: t, size: size)).cropped(to: canvas)
        } else {
            L = layout(size)
            placed = frame.clampedToExtent().transformed(by: zoomTransform(z, k: L.video.width / W, dest: L.video)).cropped(to: L.video)
        }
        let k = L.video.width / W

        let blur = doc.animation.motionBlur.amount, panBlur = (doc.animation.panBlur ?? doc.animation.motionBlur).amount
        if blur > 0 || panBlur > 0, !zooms.isEmpty, reframe == nil {
            // A frame is either zooming (radial blur around the point that stays still — the zoomed
            // point) or moving (directional blur), never both.
            let prev = zoomState(at: t - 1.0 / 60)
            let dz = abs(z.scale - prev.scale) / z.scale
            let c0 = windowCenter(prev), c1 = windowCenter(z)
            let pan = hypot(c1.x - c0.x, c1.y - c0.y) * z.scale * k
            if dz > 0.002 {
                if blur > 0 {
                // View v = x·s + t per axis (t = 0.5 − focus·s); the fixed point satisfies x·s0 + t0 = x·s1 + t1.
                func still(_ f0: CGFloat, _ f1: CGFloat) -> CGFloat {
                    let t0 = 0.5 - f0 * prev.scale, t1 = 0.5 - f1 * z.scale
                    return min(1, max(0, (t0 - t1) / (z.scale - prev.scale) * z.scale + t1))
                }
                let center = CIVector(x: L.video.minX + still(prev.focus.x, z.focus.x) * L.video.width,
                                      y: L.video.maxY - still(prev.focus.y, z.focus.y) * L.video.height)
                placed = placed.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                    kCIInputCenterKey: center, kCIInputAmountKey: min(30, dz * 500 * blur),
                ]).cropped(to: L.video)
                }
            } else if pan > 1, panBlur > 0 {
                placed = placed.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                    kCIInputRadiusKey: min(40, pan * 0.6 * panBlur), kCIInputAngleKey: atan2(c1.y - c0.y, c1.x - c0.x),
                ]).cropped(to: L.video)
            }
        }

        let base = staticLayer(size, L)
        var out: CIImage
        if L.innerRadius > 0.5 {
            let mask = roundedRect(L.video, radius: L.innerRadius, color: .white)
            out = placed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask])
        } else {
            out = placed.composited(over: base)
        }

        if doc.keystrokes.show, let badge = badges.first(where: { s >= $0.start && s < $0.end }) {
            out = drawBadge(badge, at: s, over: out, size: size)
        }
        if let camera {
            // Camera layouts: "camera only" fills the frame over the blurred, slightly enlarged screen; "screen only"
            // hides the bubble. Both fade over 0.4 s.
            let full = doc.layoutAmount(.cameraOnly, at: t), hidden = doc.layoutAmount(.screenOnly, at: t)
            let bubble = doc.camera.show ? 1 - max(full, hidden) : 0
            if bubble > 0.001 {
                let with = drawCamera(camera, over: out, size: size, envelope: z.envelope, at: t)
                out = bubble > 0.999 ? with : withAlpha(with, bubble).composited(over: out)
            }
            if full > 0.001 { out = drawFullCamera(camera, over: out, size: size, amount: full) }
        }
        return out.cropped(to: canvas)
    }

    private func windowCenter(_ z: ZoomTrack.State) -> CGPoint {
        let W = sourceSize.width, H = sourceSize.height
        let vw = W / z.scale, vh = H / z.scale
        return CGPoint(x: min(max(z.focus.x * W, vw / 2), W - vw / 2), y: min(max((1 - z.focus.y) * H, vh / 2), H - vh / 2))
    }

    /// Maps the zoom window of the source onto `dest`.
    private func zoomTransform(_ z: ZoomTrack.State, k: CGFloat, dest: CGRect) -> CGAffineTransform {
        let c = windowCenter(z)
        let vw = sourceSize.width / z.scale, vh = sourceSize.height / z.scale
        return CGAffineTransform(translationX: -(c.x - vw / 2), y: -(c.y - vh / 2))
            .concatenating(CGAffineTransform(scaleX: z.scale * k, y: z.scale * k))
            .concatenating(CGAffineTransform(translationX: dest.minX, y: dest.minY))
    }

    /// The view's centre for "fill the frame", sampled at `reframeRate`: it moves only when the pointer leaves the middle
    /// 60 % of the view, on a critically damped spring, and stays inside the recording.
    static func reframePath(doc: StudioDocument, source: CGSize, canvas: CGSize, pointer: (Double) -> CGPoint?) -> [CGPoint] {
        let (vw, vh) = reframeWindow(source: source, canvas: canvas)        // normalized view size at zoom 1
        let n = max(1, Int(doc.duration * reframeRate) + 1)
        var c = pointer(0) ?? CGPoint(x: 0.5, y: 0.5), v = CGVector.zero
        let omega = 5.0, dt = 1 / reframeRate
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, vw / 2), 1 - vw / 2), y: min(max(p.y, vh / 2), 1 - vh / 2))
        }
        c = clamp(c)
        var out: [CGPoint] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            if let p = pointer(Double(i) * dt) {
                var target = c
                let hx = vw * 0.3, hy = vh * 0.3
                if p.x > c.x + hx { target.x = p.x - hx } else if p.x < c.x - hx { target.x = p.x + hx }
                if p.y > c.y + hy { target.y = p.y - hy } else if p.y < c.y - hy { target.y = p.y + hy }
                target = clamp(target)
                // Critically damped spring toward the target.
                let ax = omega * omega * (target.x - c.x) - 2 * omega * v.dx, ay = omega * omega * (target.y - c.y) - 2 * omega * v.dy
                v.dx += ax * dt; v.dy += ay * dt
                c = clamp(CGPoint(x: c.x + v.dx * dt, y: c.y + v.dy * dt))
            }
            out.append(c)
        }
        return out
    }

    /// Normalized size of the largest window with the canvas' shape inside the recording.
    static func reframeWindow(source: CGSize, canvas: CGSize) -> (Double, Double) {
        let a = canvas.width / max(1, canvas.height), sa = source.width / max(1, source.height)
        return a < sa ? (a / sa, 1) : (1, sa / a)
    }

    private func reframeTransform(_ path: [CGPoint], _ z: ZoomTrack.State, at t: Double, size: CGSize) -> CGAffineTransform {
        let W = sourceSize.width, H = sourceSize.height
        let (bw, bh) = Self.reframeWindow(source: sourceSize, canvas: size)
        let s = max(1, z.scale)
        let vw = bw / s, vh = bh / s
        let i = min(max(0, Int((t * Self.reframeRate).rounded())), path.count - 1)
        var c = path.isEmpty ? CGPoint(x: 0.5, y: 0.5) : path[i]
        // While a zoom is on, its own aim takes over.
        let a = StudioTracks.smoothstep(1, 1.25, s)
        c = CGPoint(x: c.x + (z.focus.x - c.x) * a, y: c.y + (z.focus.y - c.y) * a)
        c = CGPoint(x: min(max(c.x, vw / 2), 1 - vw / 2), y: min(max(c.y, vh / 2), 1 - vh / 2))
        let k = size.width / (vw * W)
        return CGAffineTransform(translationX: -(c.x - vw / 2) * W, y: -((1 - c.y) - vh / 2) * H)
            .concatenating(CGAffineTransform(scaleX: k, y: k))
    }

    private func roundedRect(_ r: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = r
        f.radius = Float(radius)
        f.color = color
        return f.outputImage ?? CIImage(color: color).cropped(to: r)
    }

    private func withAlpha(_ img: CIImage, _ a: Double) -> CIImage {
        guard a < 0.999 else { return img }
        return img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, a)))])
    }

    // MARK: Masks

    /// Blur masks soften their regions; highlight masks dim everything else. Applied to the recording before the cursor
    /// and the zoom, so they stay on the content.
    private func applyMasks(_ frame: CIImage, at s: Double) -> CIImage {
        let W = fullSize.width, H = fullSize.height, unit = min(W, H) / 1080
        var out = frame
        for m in doc.masks where !m.regions.isEmpty && !m.disabled {
            let a = StudioDocument.maskAlpha(m, at: s)
            guard a > 0.001 else { continue }
            let rects = m.regions.map { CGRect(x: $0.x * W, y: H - ($0.y + $0.height) * H, width: $0.width * W, height: $0.height * H) }
            func shapes(_ alpha: Double) -> CIImage {
                rects.map { roundedRect($0, radius: min($0.width * 0.15, $0.height * 0.15, 10 * unit), color: CIColor(red: 1, green: 1, blue: 1, alpha: alpha)) }
                    .reduce(CIImage.empty()) { $1.composited(over: $0) }
            }
            switch m.kind {
            case .blur:
                let sigma = (6 + 30 * m.strength) * unit
                let area = rects.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -sigma * 3, dy: -sigma * 3).intersection(frame.extent)
                guard !area.isNull else { continue }
                let blurred = out.cropped(to: area).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: area)
                out = blurred.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: shapes(a)])
            case .highlight:
                let k = CGFloat(pow(1 - 0.8 * m.strength * a, 2.2))     // Core Image works in linear light; dim perceptually
                let dimmed = out.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                ])
                out = out.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: dimmed, kCIInputMaskImageKey: shapes(1)])
            }
        }
        return out.cropped(to: frame.extent)
    }

    // MARK: Cursor

    private func drawCursor(on frame: CIImage, at t: Double) -> CIImage {
        let clip = doc.clipIndex(at: t).map { doc.clips[$0] }
        guard let smooth = cursor, let ev = events, doc.cursor.show, ev.region.width > 0, clip?.hideCursor != true else { return frame }
        // A clip with smoothing off follows the raw pointer path (precise menus).
        let cursor = clip?.smoothCursor == false ? rawCursor ?? smooth : smooth
        let c = doc.cursor
        let psx = fullSize.width / ev.region.width, psy = fullSize.height / max(1, ev.region.height)
        let H = fullSize.height
        let s = cursorSource(t), now = sourceTime(t)
        var out = frame
        if c.ripple, let ripple = StudioSprites.ripple(c.rippleColor, filled: c.rippleFilled) {
            for click in cursor.clicks where click.t <= s && now >= click.t && now - click.t < 0.5 {
                let u = (now - click.t) / 0.5
                let r = (5 + 22 * (1 - pow(1 - u, 3))) * psx * c.size / 1.5
                let k = 2 * r / CGFloat(StudioSprites.rippleSize)
                let p = CGPoint(x: click.p.x * psx, y: H - click.p.y * psy)
                let img = CIImage(cgImage: ripple).transformed(by: CGAffineTransform(scaleX: k, y: k))
                    .transformed(by: CGAffineTransform(translationX: p.x - r, y: p.y - r))
                out = withAlpha(img, 1 - u).composited(over: out)
            }
        }
        let alpha = cursor.alpha(at: s, hideIdle: c.hideWhenIdle, hideTyping: c.hideWhenTyping, idleDelay: c.idleDelay)
        guard alpha > 0.01 else { return out }
        let pressed = c.pressEffect && cursor.isPressed(at: s)
        let unit = psx * c.size * (pressed ? 0.8 : 1)
        let pos = cursorPoint(cursor, at: t)
        let p = CGPoint(x: pos.x * psx, y: H - pos.y * psy)
        var img: CIImage
        if c.realShapes, c.style.showsShapes, let id = cursor.shape(at: s), id != "arrow", let shape = cursorShapes[id] {
            // The recorded shape (I-beam, hand…), at the same points-to-pixels scale as the drawn arrow.
            let k = unit * shape.size.width / CGFloat(shape.image.width)
            img = CIImage(cgImage: shape.image).transformed(by: CGAffineTransform(scaleX: k, y: k))
                .transformed(by: CGAffineTransform(translationX: p.x - shape.hotspot.x * unit, y: p.y - (shape.size.height - shape.hotspot.y) * unit))
        } else {
            guard let sprite = StudioSprites.cursor(c.style, unit: unit) else { return out }
            img = CIImage(cgImage: sprite.image)
                .transformed(by: CGAffineTransform(translationX: p.x - sprite.hotspot.x, y: p.y - (CGFloat(sprite.image.height) - sprite.hotspot.y)))
        }
        if c.motionBlur != .off {
            // Streaks along the pointer's path when it moves fast (source pixels per 1/60 s).
            let prev = cursorPoint(cursor, at: t - 1.0 / 60)
            let dx = (pos.x - prev.x) * psx, dy = (pos.y - prev.y) * psy
            let speed = hypot(dx, dy)
            if speed > 3 {
                let r = min(28, speed * 0.35 * c.motionBlur.amount)
                let e = img.extent
                img = img.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: r, kCIInputAngleKey: atan2(-dy, dx)])
                    .cropped(to: e.insetBy(dx: -r * 1.5, dy: -r * 1.5))
            }
        }
        if c.tilt > 0.001 {
            // Leans into horizontal movement (clockwise when moving right), pivoting on the hotspot; at most 20°.
            let dx = pos.x - cursorPoint(cursor, at: t - 0.4).x
            let degrees = min(20, max(-20, dx * 0.12 * c.tilt))
            img = img.transformed(by: CGAffineTransform(translationX: -p.x, y: -p.y)
                .concatenating(CGAffineTransform(rotationAngle: -degrees * .pi / 180))
                .concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
        }
        return withAlpha(img, alpha).composited(over: out)
    }

    // MARK: Keystrokes

    private func drawBadge(_ b: KeyBadge, at s: Double, over img: CIImage, size: CGSize) -> CIImage {
        let k = doc.keystrokes
        let minSide = min(size.width, size.height)
        guard let cg = StudioSprites.badge(b.text, light: k.light, fontSize: minSide * 0.036 * k.size) else { return img }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let m = minSide * 0.04
        let col = k.position % 3, row = k.position / 3
        let x = col == 0 ? m : col == 1 ? (size.width - w) / 2 : size.width - m - w
        let y = row == 0 ? size.height - m - h : row == 1 ? (size.height - h) / 2 : m
        let a = min(1, (s - b.start) / 0.08) * min(1, (b.end - s) / 0.25)
        return withAlpha(CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded())), a).composited(over: img)
    }

    // MARK: Camera

    /// The camera filling the canvas (aspect fill, mirrored like the bubble), sharpening in as it fades over the screen,
    /// which blurs and grows by up to 10%.
    private func drawFullCamera(_ cam: CIImage, over img: CIImage, size: CGSize, amount a: Double) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let frame = cam.transformed(by: cameraTransform)
        let e = frame.extent
        guard e.width > 1, e.height > 1 else { return img }
        let unit = min(size.width, size.height) / 1080
        let grow = 1 + 0.1 * a
        let behind = img.clampedToExtent().applyingGaussianBlur(sigma: 30 * unit * a)
            .transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                .concatenating(CGAffineTransform(scaleX: grow, y: grow))
                .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2)))
            .cropped(to: canvas)
        let k = max(size.width / e.width, size.height / e.height)
        var t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
        if doc.camera.mirror { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: e.width, ty: 0)) }
        t = t.concatenating(CGAffineTransform(scaleX: k, y: k))
            .concatenating(CGAffineTransform(translationX: (size.width - e.width * k) / 2, y: (size.height - e.height * k) / 2))
        var fill = frame.transformed(by: t).cropped(to: canvas)
        if a < 0.999 { fill = fill.clampedToExtent().applyingGaussianBlur(sigma: 20 * unit * (1 - a)).cropped(to: canvas) }
        return withAlpha(fill, a).composited(over: behind)
    }

    private func drawCamera(_ cam: CIImage, over img: CIImage, size: CGSize, envelope: Double, at t: Double) -> CIImage {
        let frame = cam.transformed(by: cameraTransform)
        let e = frame.extent
        guard e.width > 1, e.height > 1 else { return img }
        let dest = cameraRect(size, envelope: envelope, at: t)
        let a = dest.width / dest.height
        let crop = e.width / e.height > a
            ? CGRect(x: e.midX - e.height * a / 2, y: e.minY, width: e.height * a, height: e.height)
            : CGRect(x: e.minX, y: e.midY - e.width / a / 2, width: e.width, height: e.width / a)
        let k = dest.width / crop.width
        var t = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        if doc.camera.mirror { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: crop.width, ty: 0)) }
        t = t.concatenating(CGAffineTransform(scaleX: k, y: k)).concatenating(CGAffineTransform(translationX: dest.minX, y: dest.minY))
        let placed = frame.cropped(to: crop).clampedToExtent().transformed(by: t).cropped(to: dest)
        let radius = cameraRadius(dest)
        let blurR = min(dest.width, dest.height) * 0.05
        let shadow = roundedRect(dest.offsetBy(dx: 0, dy: -blurR * 0.4), radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.4))
            .applyingGaussianBlur(sigma: blurR).cropped(to: dest.insetBy(dx: -blurR * 3, dy: -blurR * 3))
        let under = shadow.composited(over: img)
        return placed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: under, kCIInputMaskImageKey: roundedRect(dest, radius: radius, color: .white),
        ])
    }

    // MARK: Background (rendered once per size)

    private func staticLayer(_ size: CGSize, _ L: Layout) -> CIImage {
        let key = "\(size.width)x\(size.height)"
        lock.lock()
        if let c = staticCache[key] { lock.unlock(); return c }
        lock.unlock()
        let rect = CGRect(origin: .zero, size: size)
        var img = fill(size)
        let bg = doc.background
        let outer = L.frame.insetBy(dx: -L.bezel, dy: -L.bezel), outerRadius = L.radius + L.bezel
        if bg.isVisible {
            if bg.shadow > 0.01 {
                // A blurred rounded rectangle is smooth, so it's blurred at a quarter of the size and scaled up.
                let blur = min(size.width, size.height) * 0.025 * (0.4 + bg.shadow) * CGFloat(max(0.2, bg.shadowSoftness)), q: CGFloat = 0.25
                let a = bg.shadowAngle * .pi / 180, d = blur * CGFloat(bg.shadowDistance)
                let r = outer.offsetBy(dx: d * CGFloat(cos(a)), dy: d * CGFloat(sin(a)))
                let sh = roundedRect(CGRect(x: r.minX * q, y: r.minY * q, width: r.width * q, height: r.height * q), radius: outerRadius * q,
                                     color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.75 * bg.shadow))
                    .applyingGaussianBlur(sigma: blur * q)
                    .transformed(by: CGAffineTransform(scaleX: 1 / q, y: 1 / q))
                img = sh.composited(over: img)
            }
            if bg.sides.contains(where: { $0 > 0 }) {
                let c = bg.insetColor.isEmpty ? insetColor : NSColor(hex: bg.insetColor).cgColor
                img = roundedRect(L.frame, radius: L.radius, color: CIColor(cgColor: c.copy(alpha: CGFloat(bg.insetOpacity)) ?? c)).composited(over: img)
            }
        }
        if L.bezel > 0 {
            // A generic device: near-black body with a thin lighter edge (no product artwork).
            let edge = max(1, L.unit * 1.5)
            img = roundedRect(outer.insetBy(dx: -edge, dy: -edge), radius: outerRadius + edge, color: CIColor(red: 0.33, green: 0.35, blue: 0.41))
                .composited(over: img)
            img = roundedRect(outer, radius: outerRadius, color: CIColor(red: 0.055, green: 0.063, blue: 0.094)).composited(over: img)
        }
        img = img.cropped(to: rect)
        lock.lock()
        if staticCache.count > 6 { staticCache.removeAll() }
        staticCache[key] = img
        lock.unlock()
        return img
    }

    /// The background fill at `size`, rendered once (kept across padding / corner / shadow / inset changes).
    private func fill(_ size: CGSize) -> CIImage {
        let key = "\(size.width)x\(size.height)"
        lock.lock()
        if let c = fillCache[key] { lock.unlock(); return c }
        lock.unlock()
        let rect = CGRect(origin: .zero, size: size)
        let img = backgroundFill(size)
        let ready = StudioCompositor.context.createCGImage(img, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            .map { CIImage(cgImage: $0) } ?? img
        lock.lock()
        if fillCache.count > 4 { fillCache.removeAll() }
        fillCache[key] = ready
        lock.unlock()
        return ready
    }

    private func backgroundFill(_ size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let bg = doc.background
        func fill(_ cg: CGImage, blur: Bool) -> CIImage {
            let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
            let k = max(size.width / iw, size.height / ih)
            var i = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: k, y: k))
            i = i.transformed(by: CGAffineTransform(translationX: (size.width - iw * k) / 2, y: (size.height - ih * k) / 2))
            let amount = blur ? max(0.5, bg.blur) : bg.blur
            if amount > 0.001 { i = i.clampedToExtent().applyingGaussianBlur(sigma: min(size.width, size.height) * 0.08 * amount) }
            return i.cropped(to: rect)
        }
        func gradient(_ i: Int) -> CIImage {
            let g = StudioDocument.gradients[(i % StudioDocument.gradients.count + StudioDocument.gradients.count) % StudioDocument.gradients.count]
            let f = CIFilter.linearGradient()
            f.point0 = CGPoint(x: 0, y: size.height)
            f.point1 = CGPoint(x: size.width, y: 0)
            f.color0 = CIColor(cgColor: NSColor(hex: g.0).cgColor)
            f.color1 = CIColor(cgColor: NSColor(hex: g.1).cgColor)
            return (f.outputImage ?? CIImage(color: .black)).cropped(to: rect)
        }
        switch bg.kind {
        case .none: return CIImage(color: .black).cropped(to: rect)
        case .color: return CIImage(color: CIColor(cgColor: NSColor(hex: bg.color).cgColor)).cropped(to: rect)
        case .gradient: return gradient(bg.gradient)
        case .wallpaper: return wallpaper.map { fill($0, blur: false) } ?? gradient(0)
        case .blurredWallpaper: return wallpaper.map { fill($0, blur: true) } ?? gradient(0)
        case .image: return customImage.map { fill($0, blur: false) } ?? gradient(0)
        }
    }
}

// MARK: - Compositor

final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let model: StudioRenderModel
    let hasCamera: Bool

    init(timeRange: CMTimeRange, model: StudioRenderModel, hasCamera: Bool) {
        self.timeRange = timeRange
        self.model = model
        self.hasCamera = hasCamera
        requiredSourceTrackIDs = ([StudioComposer.screenTrackID] + (hasCamera ? [StudioComposer.cameraTrackID] : [])).map { NSNumber(value: $0) }
    }
}

final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    static let context = CIContext(options: [.cacheIntermediates: false, .name: "Daisyshot Studio"])

    /// Source frames of the last rendered request, so a paused editor can redraw a look change without decoding again.
    struct LastFrame: @unchecked Sendable {
        let time: Double
        let size: CGSize
        let screen: CVPixelBuffer?
        let camera: CVPixelBuffer?
    }
    private static let lastLock = NSLock()
    nonisolated(unsafe) private static var _last: LastFrame?
    static var lastFrame: LastFrame? { lastLock.withLock { _last } }
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private let queue = DispatchQueue(label: "app.daisyshot.studio.render", qos: .userInteractive)
    private let lock = NSLock()
    private var generation = 0

    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock(); let gen = generation; lock.unlock()
        queue.async { [self] in
            lock.lock(); let cancelled = gen != generation; lock.unlock()
            if cancelled { request.finishCancelledRequest(); return }
            autoreleasepool {
                guard let ins = request.videoCompositionInstruction as? StudioInstruction, let out = request.renderContext.newPixelBuffer() else {
                    request.finish(with: StudioError("Couldn't render the frame."))
                    return
                }
                let screenBuffer = request.sourceFrame(byTrackID: StudioComposer.screenTrackID)
                let cameraBuffer = ins.hasCamera ? request.sourceFrame(byTrackID: StudioComposer.cameraTrackID) : nil
                let screen = screenBuffer.map { CIImage(cvPixelBuffer: $0) }
                let cam = cameraBuffer.map { CIImage(cvPixelBuffer: $0) }
                let size = request.renderContext.size
                let last = LastFrame(time: request.compositionTime.seconds, size: size, screen: screenBuffer, camera: cameraBuffer)
                Self.lastLock.withLock { Self._last = last }
                let img = ins.model.render(outputTime: request.compositionTime.seconds, screen: screen, camera: cam, size: size)
                Self.context.render(img, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: Self.sRGB)
                request.finish(withComposedVideoFrame: out)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock(); generation += 1; lock.unlock()
    }
}

// MARK: - Composition

enum StudioComposer {
    static let screenTrackID: CMPersistentTrackID = 1
    static let cameraTrackID: CMPersistentTrackID = 2
    static func audioTrackID(_ i: Int) -> CMPersistentTrackID { CMPersistentTrackID(10 + i) }
    static let musicTrackID: CMPersistentTrackID = 8
    static let clickTrackID: CMPersistentTrackID = 9

    private static func time(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 60_000) }

    /// Concatenates the document's clips (cuts removed). Screen = track 1, camera = track 2, audio = 10 + index.
    static func composition(_ src: StudioSources, doc: StudioDocument, audio: Bool = true, camera: Bool = true) throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: screenTrackID) else { throw StudioError("Couldn't build the composition.") }
        let cam = camera && src.camera != nil ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: cameraTrackID) : nil
        let auds = audio ? src.audio.indices.map { comp.addMutableTrack(withMediaType: .audio, preferredTrackID: audioTrackID($0)) } : []
        var at = CMTime.zero
        for clip in doc.clips {
            let range = CMTimeRange(start: time(clip.start), duration: time(clip.duration)).intersection(src.videoRange)
            guard range.duration > .zero else { continue }
            try v.insertTimeRange(range, of: src.video, at: at)
            if let cam, let ct = src.camera {
                // camera.mov starts `cameraOffset` into the screen video: screen time s shows camera time s − offset.
                let off = time(src.cameraOffset)
                let r = CMTimeRange(start: range.start - off, duration: range.duration).intersection(src.cameraRange)
                if r.duration > .zero { try? cam.insertTimeRange(r, of: ct, at: at + (r.start + off - range.start)) }
            }
            for (i, track) in auds.enumerated() {
                guard let track else { continue }
                let r = range.intersection(src.audioRanges[i])
                guard r.duration > .zero else { continue }
                if doc.audio.denoises(i), let c = src.cleanAudio[i] {
                    // The clean copy's time 0 is the original track's start.
                    let shift = src.audioRanges[i].start
                    let cr = CMTimeRange(start: r.start - shift, duration: r.duration).intersection(c.range)
                    if cr.duration > .zero { try? track.insertTimeRange(cr, of: c.track, at: at + (cr.start + shift - range.start)) }
                } else {
                    try? track.insertTimeRange(r, of: src.audio[i], at: at + (r.start - range.start))
                }
            }
            var length = range.duration
            if clip.speed != 1 {
                length = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / clip.speed)
                for track in [v, cam] + auds { track?.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: length) }
            }
            at = at + length
        }
        if audio { addExtras(comp, src, doc: doc, length: at) }
        return comp
    }

    /// Background music looped over `length`, and the click sound at every click that wasn't cut out.
    private static func addExtras(_ comp: AVMutableComposition, _ src: StudioSources, doc: StudioDocument, length: CMTime) {
        if !doc.music.path.isEmpty, let m = src.music, m.range.duration.seconds > 0.01,
           let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: musicTrackID) {
            var t = CMTime.zero
            while t < length {
                let piece = CMTimeRange(start: m.range.start, duration: min(m.range.duration, length - t))
                try? track.insertTimeRange(piece, of: m.track, at: t)
                t = t + piece.duration
            }
        }
        if doc.cursor.clickSound, let c = src.click, !src.clickTimes.isEmpty,
           let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: clickTrackID) {
            var free = CMTime.zero
            // Not in parts sped up past 2×: clicks there would rattle.
            for s in src.clickTimes.sorted() where doc.clips.contains(where: { $0.start <= s && s < $0.end && $0.speed <= 2 }) {
                let at = time(doc.outputTime(source: s))
                guard at >= free, at + c.range.duration <= length else { continue }   // clicks closer than the sound overlap: one sound
                try? track.insertTimeRange(c.range, of: c.track, at: at)
                free = at + c.range.duration
            }
        }
    }

    static func videoComposition(_ comp: AVComposition, model: StudioRenderModel, renderSize: CGSize, fps: Double) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = StudioCompositor.self
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, min(fps, 60))))
        let hasCamera = !comp.tracks(withMediaType: .video).filter { $0.trackID == cameraTrackID && !$0.segments.isEmpty }.isEmpty
        vc.instructions = [StudioInstruction(timeRange: CMTimeRange(start: .zero, duration: comp.duration), model: model, hasCamera: hasCamera)]
        return vc
    }

    #if DEBUG
    /// A camera file starting 0.5 s into the screen video lands 0.5 s into the composition, and stays in sync after a cut;
    /// a 2× clip takes half the time on every track.
    static func compositionSelfTest() async -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-offset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            print("  · writing the sample recording")
            let pkg = try await StudioSample.make(in: dir, seconds: 3)
            print("  · loading it")
            let events = pkg.appendingPathComponent(StudioCaptureLayout.events)
            var ev = try JSONDecoder().decode(StudioEvents.self, from: Data(contentsOf: events))
            ev.cameraOffset = 0.5
            try StudioJSON.encode(ev)?.write(to: events)
            let src = try await StudioSources.load(try StudioPackage.open(pkg))
            print("  · rendering frames")
            let doc = StudioDocument(clips: [.init(start: 0, duration: 1), .init(start: 2, duration: 1)])
            let segs = (try composition(src, doc: doc).track(withTrackID: cameraTrackID)?.segments ?? []).filter { !$0.isEmpty }
                .map { ($0.timeMapping.source.start.seconds, $0.timeMapping.target.start.seconds) }
            // Clip 1 (screen 0…1) shows camera 0…0.5 from 0.5 on; clip 2 (screen 2…3) shows camera 1.5…2.5 from 1 on.
            let want = [(0.0, 0.5), (1.5, 1.0)]
            guard segs.count == 2, zip(segs, want).allSatisfy({ abs($0.0 - $1.0) < 0.01 && abs($0.1 - $1.1) < 0.01 }) else { return "segments \(segs)" }
            let fast = try composition(src, doc: StudioDocument(clips: [.init(start: 0, duration: 2, speed: 2)]))
            let ends = fast.tracks.map { $0.timeRange.end.seconds }
            guard abs(fast.duration.seconds - 1) < 0.01, ends.allSatisfy({ $0 < 1.01 }) else { return "2× clip lasts \(fast.duration.seconds), tracks end \(ends)" }

            // A highlight over the left half of the recording dims only the right half of the frame.
            var plain = StudioDocument(clips: [.init(start: 0, duration: 3)])
            plain.background.kind = .none
            var lit = plain
            lit.masks = [.init(start: 0, end: 3, kind: .highlight, strength: 1, regions: [.init(x: 0, y: 0, width: 0.5, height: 1)])]
            func halves(_ d: StudioDocument) async throws -> (Double, Double) {
                let comp = try composition(src, doc: d, audio: false, camera: false)
                let model = StudioRenderModel(doc: d, sources: src, events: nil, cursor: nil, wallpaper: nil, customImage: nil)
                let img = try await StudioExportJob.frame(comp, video: videoComposition(comp, model: model, renderSize: model.canvasSize, fps: 30), at: 1)
                guard let ctx = StudioSprites.context(64, 40) else { return (0, 0) }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: 64, height: 40))
                let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
                var sums = (0.0, 0.0)
                for y in 0..<40 { for x in 0..<64 { for c in 0..<3 {
                    let v = Double(p[y * ctx.bytesPerRow + x * 4 + c])
                    if x < 32 { sums.0 += v } else { sums.1 += v }
                } } }
                return sums
            }
            let (l0, r0) = try await halves(plain), (l1, r1) = try await halves(lit)
            guard abs(l1 - l0) < l0 * 0.02, r1 < r0 * 0.3 else { return "highlight halves \((l0, r0)) → \((l1, r1))" }

            // A device recording with "Device frame" gets a near-black bezel right outside the screen.
            var deviceEvents = try JSONDecoder().decode(StudioEvents.self, from: Data(contentsOf: events))
            deviceEvents.device = "iPhone"
            var framed = StudioDocument(clips: [.init(start: 0, duration: 3)])
            framed.background.kind = .color
            framed.background.color = "#FFFFFF"
            let model = StudioRenderModel(doc: framed, sources: src, events: deviceEvents, cursor: nil, wallpaper: nil, customImage: nil)
            let comp = try composition(src, doc: framed, audio: false, camera: false)
            let img = try await StudioExportJob.frame(comp, video: videoComposition(comp, model: model, renderSize: model.canvasSize, fps: 30), at: 1)
            let L = model.layout(model.canvasSize)
            guard L.bezel > 0, let ctx = StudioSprites.context(img.width, img.height) else { return "no device bezel" }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            // Sample the middle of the left bezel (context rows are top-down, the middle row is the same either way).
            let x = Int(L.frame.minX - L.bezel / 2), y = img.height / 2
            let p = ctx.data!.assumingMemoryBound(to: UInt8.self) + y * ctx.bytesPerRow + x * 4
            let lum = (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
            guard lum < 40 else { return "bezel pixel \(lum) at \(x)" }
            // Cropping to the left half: the canvas (Auto aspect) is the left half, and the picture is that half.
            var cropped = plain
            cropped.crop = .init(x: 0, y: 0, width: 0.5, height: 1)
            let cm = StudioRenderModel(doc: cropped, sources: src, events: nil, cursor: nil, wallpaper: nil, customImage: nil)
            guard abs(cm.canvasSize.width - src.size.width / 2) <= 1, cm.canvasSize.height == src.size.height else { return "crop canvas \(cm.canvasSize)" }
            let fullL = try await halves(plain).0
            let cc = try composition(src, doc: cropped, audio: false, camera: false)
            let cimg = try await StudioExportJob.frame(cc, video: videoComposition(cc, model: cm, renderSize: cm.canvasSize, fps: 30), at: 1)
            guard cimg.width == Int(cm.canvasSize.width), fullL > 0 else { return "cropped frame \(cimg.width)" }

            // Music loops over the whole video; a click sound plays at each kept click (not in a cut, not past the end).
            let clickAsset = AVURLAsset(url: StudioClickSound.url)
            guard let ct = try await clickAsset.loadTracks(withMediaType: .audio).first else { return "no click sound" }
            let extra = StudioSources.ExtraAudio(url: StudioClickSound.url, asset: clickAsset, track: ct, range: try await ct.load(.timeRange))
            var withExtras = src
            withExtras.music = extra
            withExtras.click = extra
            withExtras.clickTimes = [0.5, 1.5, 2.2, 2.98]
            var sounds = StudioDocument(clips: [.init(start: 0, duration: 1), .init(start: 2, duration: 1)])   // 1…2 cut
            sounds.music.path = "music.caf"
            sounds.cursor.clickSound = true
            let sc = try composition(withExtras, doc: sounds)
            let musicEnd = sc.track(withTrackID: musicTrackID)?.timeRange.end.seconds ?? 0
            let clicks = (sc.track(withTrackID: clickTrackID)?.segments ?? []).filter { !$0.isEmpty }.map { $0.timeMapping.target.start.seconds }
            guard abs(musicEnd - 2) < 0.01 else { return "music ends at \(musicEnd)" }
            guard clicks.count == 2, abs(clicks[0] - 0.5) < 0.01, abs(clicks[1] - 1.2) < 0.01 else { return "click sounds at \(clicks)" }
            sounds.clips[1].speed = 3
            let fastClicks = (try composition(withExtras, doc: sounds).track(withTrackID: clickTrackID)?.segments ?? []).filter { !$0.isEmpty }.count
            guard fastClicks == 1 else { return "\(fastClicks) click sounds with the second clip at 3×" }

            // "Camera only" fills the frame with the camera: the middle of the frame changes from the screen's colour.
            func centre(_ d: StudioDocument) async throws -> [UInt8] {
                let comp = try composition(src, doc: d, audio: false, camera: true)
                let m = StudioRenderModel(doc: d, sources: src, events: nil, cursor: nil, wallpaper: nil, customImage: nil)
                let img = try await StudioExportJob.frame(comp, video: videoComposition(comp, model: m, renderSize: m.canvasSize, fps: 30), at: 1.5)
                guard let ctx = StudioSprites.context(1, 1) else { return [] }
                ctx.draw(img, in: CGRect(x: -CGFloat(img.width) / 2 + 0.5, y: -CGFloat(img.height) / 2 + 0.5, width: CGFloat(img.width), height: CGFloat(img.height)))
                let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
                return [px[0], px[1], px[2]]
            }
            var camOnly = plain
            camOnly.layouts = [.init(start: 0, end: 3, kind: .cameraOnly)]
            let a = try await centre(plain), b = try await centre(camOnly)
            guard a.count == 3, b.count == 3, zip(a, b).map({ abs(Int($0) - Int($1)) }).max()! > 20 else { return "camera only centre \(a) → \(b)" }
            // "Fill the frame" at 9:16: the top of the frame shows the recording, not the background around it.
            func top(_ d: StudioDocument) async throws -> (CGSize, [UInt8]) {
                let comp = try composition(src, doc: d, audio: false)
                let m = StudioRenderModel(doc: d, sources: src, events: nil, cursor: nil, wallpaper: nil, customImage: nil)
                let img = try await StudioExportJob.frame(comp, video: videoComposition(comp, model: m, renderSize: m.canvasSize, fps: 30), at: 1.5)
                if d.background.fillFrame, let out = ProcessInfo.processInfo.environment["DAISYSHOT_FILL_PNG"],
                   let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dst, img, nil)
                    CGImageDestinationFinalize(dst)
                }
                guard let ctx = StudioSprites.context(1, 1) else { return (.zero, []) }
                ctx.draw(img, in: CGRect(x: -CGFloat(img.width) / 2 + 0.5, y: -CGFloat(img.height) * 0.97 + 0.5, width: CGFloat(img.width), height: CGFloat(img.height)))
                let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
                return (CGSize(width: img.width, height: img.height), [px[0], px[1], px[2]])
            }
            var tall = plain
            tall.background.aspect = .vertical
            let (fitSize, fitTop) = try await top(tall)
            tall.background.fillFrame = true
            let (fillSize, fillTop) = try await top(tall)
            guard fillSize == fitSize, fillSize.height > fillSize.width else { return "fill frame size \(fillSize)" }
            guard zip(fitTop, fillTop).map({ abs(Int($0) - Int($1)) }).max()! > 20 else { return "fill frame top \(fitTop) → \(fillTop)" }
            let path = StudioRenderModel.reframePath(doc: tall, source: CGSize(width: 1600, height: 900), canvas: CGSize(width: 900, height: 1600)) { t in
                CGPoint(x: t < 1 ? 0.5 : 0.98, y: 0.5)
            }
            let (vw, _) = StudioRenderModel.reframeWindow(source: CGSize(width: 1600, height: 900), canvas: CGSize(width: 900, height: 1600))
            guard let last = path.last, abs(path[10].x - 0.5) < 0.01, abs(last.x - (1 - vw / 2)) < 0.01 else { return "reframe path \(path.last ?? .zero)" }
            if let out = ProcessInfo.processInfo.environment["DAISYSHOT_BEZEL_PNG"],
               let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dst, img, nil)
                CGImageDestinationFinalize(dst)
            }
            return nil
        } catch { return error.localizedDescription }
    }
    #endif

    static func audioMix(_ comp: AVComposition, doc: StudioDocument, sources: StudioSources) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = comp.tracks(withMediaType: .audio).map { t in
            let p = AVMutableAudioMixInputParameters(track: t)
            if t.trackID == musicTrackID {
                let v = doc.music.muted ? 0 : Float(doc.music.volume)
                p.setVolume(v, at: .zero)
                let end = comp.duration
                if doc.music.fadeOut, end.seconds > 3 {
                    let fade = CMTime(seconds: 2, preferredTimescale: 600)
                    p.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: end - fade, duration: fade))
                }
                return p
            }
            if t.trackID == clickTrackID {
                p.setVolume(Float(doc.cursor.clickVolume), at: .zero)
                return p
            }
            let i = Int(t.trackID) - 10
            let a = doc.audio
            let gain = a.normalizes(i) ? sources.gains[StudioSources.gainKey(i, clean: a.denoises(i) && sources.cleanAudio[i] != nil)] ?? 1 : 1
            // Each clip's own volume applies from where it starts on the output timeline.
            for (c, start) in zip(doc.clips, doc.clipStarts) {
                p.setVolume(a.effectiveVolume(i) * gain * Float(c.volume * c.trackVolume(i)), at: CMTime(seconds: start, preferredTimescale: 60_000))
            }
            return p
        }
        return mix
    }
}
