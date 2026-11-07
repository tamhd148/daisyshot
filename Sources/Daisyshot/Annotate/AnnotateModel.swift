// `.daisyshot` document format (UTF-8 JSON, one flat file, keys sorted):
//
//   {
//     "version": 2,                       // 1 = original format (no previews/assets); readers accept <= 2
//     "image": "<base64 PNG>",            // the original screenshot, unflattened
//     "scale": 2,                         // pixels per point of `image`
//     "annotations": [Annotation],        // see `Annotation` (points are in image points, top-left origin)
//     "background": BackgroundSettings,   // Background tool state
//     "crop": [[x, y], [w, h]] | absent,  // canvas rect in image points (may extend past the image when images are combined)
//     "spotlightOpacity": 0.55,           // v2, optional
//     "assets": { "<uuid>": "<base64 PNG>" },  // v2, optional: images placed on the canvas (Annotation.assetID)
//     "previewPNG": "<base64 PNG>",       // v2: full-size flattened render (Quick Look preview)
//     "thumbnailPNG": "<base64 PNG>"      // v2: flattened render, longest side <= 512 px (Finder thumbnail)
//   }
//
// Quick Look only needs `previewPNG` / `thumbnailPNG`; everything else is for re-editing. New fields are always optional
// so older files keep opening.

import AppKit

// MARK: - Tools

enum AnnotateTool: String, CaseIterable, Identifiable {
    case move, rectangle, filledRectangle, ellipse, line, arrow, text, redact, spotlight, counter, pencil, highlighter, crop
    var id: String { rawValue }

    /// Drawing tools shown in the toolbar (Crop & Resize lives in the bottom bar).
    static let toolbar: [AnnotateTool] = allCases.filter { $0 != .crop }

    var symbol: String {
        switch self {
        case .move: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .filledRectangle: return "rectangle.fill"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .pencil: return "scribble.variable"
        case .redact: return "checkerboard.rectangle"
        case .spotlight: return "flashlight.on.fill"
        case .counter: return "1.circle"
        case .crop: return "crop"
        }
    }

    var title: String {
        switch self {
        case .move: return "Move"
        case .rectangle: return "Rectangle"
        case .filledRectangle: return "Filled Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .highlighter: return "Highlighter"
        case .pencil: return "Draw"
        case .redact: return "Redact"
        case .spotlight: return "Spotlight"
        case .counter: return "Counter"
        case .crop: return "Crop & Resize"
        }
    }

    /// The annotation kind this tool creates, if it draws.
    var kind: Annotation.Kind? {
        switch self {
        case .rectangle: return .rectangle
        case .filledRectangle: return .filledRectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .text: return .text
        case .highlighter: return .highlighter
        case .pencil: return .pencil
        case .redact: return .redact
        case .spotlight: return .spotlight
        case .counter: return .counter
        case .move, .crop: return nil
        }
    }

    static func forKind(_ k: Annotation.Kind) -> AnnotateTool? { allCases.first { $0.kind == k } }
}

enum ArrowStyle: String, Codable, CaseIterable { case standard, fancy, curved, double }
enum TextStyle: String, Codable, CaseIterable { case standard, rounded, monospaced, outline, boxed, monospacedBoxed, boxedRounded }
enum RedactStyle: String, Codable, CaseIterable { case pixelate, secureBlur, smoothBlur, blackout }
enum SpotShape: String, Codable, CaseIterable { case rectangle, roundedRectangle, ellipse }
enum CounterStyle: String, Codable, CaseIterable { case numeric, roman, alphaUpper, alphaLower }

/// Background canvas ratio (w/h).
enum AspectRatio: String, Codable, CaseIterable {
    case auto, square, threeFour, fourThree, threeTwo, sixteenNine, fourFive, nineSixteen, custom
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .square: return "1:1"
        case .threeFour: return "3:4"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .fourFive: return "4:5"
        case .nineSixteen: return "9:16"
        case .custom: return "Custom"
        }
    }
    /// nil = unconstrained.
    func value(custom: CGSize) -> CGFloat? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .threeFour: return 3.0 / 4
        case .fourThree: return 4.0 / 3
        case .threeTwo: return 3.0 / 2
        case .sixteenNine: return 16.0 / 9
        case .fourFive: return 4.0 / 5
        case .nineSixteen: return 9.0 / 16
        case .custom: return custom.width > 0 && custom.height > 0 ? custom.width / custom.height : nil
        }
    }
}

/// Crop & Resize ratio popup.
enum CropChoice: Hashable {
    case freeform, original, custom, preset(Int)

    static let presets: [(title: String, w: CGFloat, h: CGFloat)] = [
        ("1 : 1 (Square)", 1, 1), ("16 : 9", 16, 9), ("16 : 10", 16, 10), ("4 : 3", 4, 3), ("3 : 2", 3, 2), ("5 : 4", 5, 4),
        ("7 : 5", 7, 5), ("3 : 4", 3, 4), ("2 : 3", 2, 3), ("4 : 5", 4, 5), ("9 : 16", 9, 16), ("1.85 : 1", 1.85, 1), ("2.35 : 1", 2.35, 1),
    ]

    var title: String {
        switch self {
        case .freeform: return "Freeform"
        case .original: return "Original Ratio"
        case .custom: return "Custom Ratio"
        case .preset(let i): return Self.presets[i].title
        }
    }

    func value(original: CGSize, custom: CGSize) -> CGFloat? {
        switch self {
        case .freeform: return nil
        case .original: return original.width / max(1, original.height)
        case .custom: return custom.width > 0 && custom.height > 0 ? custom.width / custom.height : nil
        case .preset(let i): return Self.presets[i].w / Self.presets[i].h
        }
    }
}

/// The 17 named default colours, in palette order.
enum Palette {
    static let named: [(name: String, hex: String)] = [
        ("Black", "#000000"), ("White", "#FFFFFF"), ("Red", "#E5484D"), ("Orange", "#FF9500"), ("Yellow", "#FFD60A"),
        ("Green", "#34C759"), ("Blue", "#0A84FF"), ("Violet", "#AF52DE"), ("Transparent", "#00000000"),
        ("Dark Gray", "#4A4A4F"), ("Light Gray", "#C7C7CC"), ("Light Red", "#FF8A84"), ("Light Orange", "#FFC27A"),
        ("Light Yellow", "#FFEB8A"), ("Light Green", "#8EE5A1"), ("Light Blue", "#7CC2FF"), ("Light Violet", "#D6A6F2"),
    ]
    static let maxCustom = 14

    static func name(_ hex: String) -> String? { named.first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.name }
}

// MARK: - Annotation

/// One annotation, in original-image point coordinates (top-left origin). Flat on purpose: every kind uses a subset of fields.
/// points: rect-like kinds [p0, p1]; line/arrow [start, end, (control for curved)]; pencil/highlighter n points; text/counter [origin/center].
struct Annotation: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case rectangle, filledRectangle, ellipse, line, arrow, text, highlighter, pencil, redact, spotlight, counter, image }
    var id = UUID()
    var kind: Kind
    var points: [CGPoint]
    var color: String
    var lineWidth: CGFloat
    var shadow: Bool
    var fontSize: CGFloat
    var text = ""
    var arrowStyle = ArrowStyle.standard
    var textStyle = TextStyle.standard
    var redactStyle = RedactStyle.pixelate
    var spotShape = SpotShape.rectangle
    var counterStyle = CounterStyle.numeric
    var number = 1
    var intensity: CGFloat = 0.5   // redact strength 0…1
    var assetID: UUID?             // .image: key into DocState.assets
    var textWidth: CGFloat?        // .text: wrapping width of the glyph area (nil = one line per paragraph, auto width)

    init(kind: Kind, points: [CGPoint], color: String, lineWidth: CGFloat, shadow: Bool, fontSize: CGFloat) {
        self.kind = kind
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.shadow = shadow
        self.fontSize = fontSize
    }

    /// Lenient: fields added after v1 fall back to their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        points = try c.decode([CGPoint].self, forKey: .points)
        color = try c.decode(String.self, forKey: .color)
        lineWidth = try c.decode(CGFloat.self, forKey: .lineWidth)
        shadow = c.value(.shadow, false)
        fontSize = c.value(.fontSize, 30)
        id = c.value(.id, UUID())
        text = c.value(.text, "")
        arrowStyle = c.value(.arrowStyle, .standard)
        textStyle = c.value(.textStyle, .standard)
        redactStyle = c.value(.redactStyle, .pixelate)
        spotShape = c.value(.spotShape, .rectangle)
        counterStyle = c.value(.counterStyle, .numeric)
        number = c.value(.number, 1)
        intensity = c.value(.intensity, 0.5)
        assetID = c.value(.assetID, nil)
        textWidth = c.value(.textWidth, nil)
    }

    var isRectLike: Bool { [.rectangle, .filledRectangle, .ellipse, .redact, .spotlight, .image].contains(kind) }
    var isLineLike: Bool { kind == .line || kind == .arrow }
    var rect: CGRect {
        guard let p0 = points.first else { return .zero }
        return Geo.rect(p0, points.count > 1 ? points[1] : p0)
    }

    /// Fewest points each kind needs to draw / hit-test without indexing past the end.
    var minPoints: Int { isRectLike || isLineLike ? 2 : 1 }

    /// Untrusted-input check for loaded documents: enough points, finite and sane geometry/sizes.
    var isWellFormed: Bool {
        let limit: CGFloat = 1_000_000
        func ok(_ v: CGFloat, _ range: ClosedRange<CGFloat> = -limit ... limit) -> Bool { v.isFinite && range.contains(v) }
        return points.count >= minPoints && points.count <= 200_000 && points.allSatisfy { ok($0.x) && ok($0.y) }
            && ok(lineWidth, 0 ... 10_000) && ok(fontSize, 0 ... 10_000) && ok(intensity, 0 ... 1)
            && (kind != .counter || (0 ... 100_000).contains(number)) && text.utf16.count <= 100_000
    }

    mutating func offset(by d: CGVector) {
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }
}

extension KeyedDecodingContainer {
    /// Decodes `key`, or returns `fallback` when it's missing or malformed.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
}

// MARK: - Background

struct BackgroundSettings: Codable, Equatable {
    enum Fill: Codable, Equatable, Hashable {
        case none
        case solid(String)
        case gradient(Int)          // BackgroundSettings.gradients
        case wallpaper              // current desktop picture
        case blurredWallpaper
        case blurredScreenshot
        case builtin(Int)           // Wallpapers.all (procedural)
        case custom(String)         // file name in Backgrounds.customFolder
    }
    var fill = Fill.none
    var padding: CGFloat = 64
    var cornerRadius: CGFloat = 10
    var shadow: CGFloat = 0.5
    var inset: CGFloat = 0
    var autoBalance = false
    var alignment = 4 // 3×3 grid, row-major, 4 = center
    var ratio = AspectRatio.auto
    var customRatio = CGSize(width: 16, height: 9)

    var isActive: Bool { fill != .none }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BackgroundSettings()
        fill = c.value(.fill, d.fill)
        padding = c.value(.padding, d.padding)
        cornerRadius = c.value(.cornerRadius, d.cornerRadius)
        shadow = c.value(.shadow, d.shadow)
        inset = c.value(.inset, d.inset)
        autoBalance = c.value(.autoBalance, d.autoBalance)
        alignment = c.value(.alignment, d.alignment)
        ratio = c.value(.ratio, d.ratio)
        customRatio = c.value(.customRatio, d.customRatio)
    }

    /// Two- or three-stop linear gradients (the first 8 keep their v1 indices).
    static let gradients: [[String]] = [
        ["#FF5F6D", "#FFC371"], ["#2193B0", "#6DD5ED"], ["#8E2DE2", "#4A00E0"], ["#11998E", "#38EF7D"],
        ["#FC466B", "#3F5EFB"], ["#F7971E", "#FFD200"], ["#0F2027", "#2C5364"], ["#EE9CA7", "#FFDDE1"],
        ["#C471F5", "#FA71CD"], ["#00C6FB", "#005BEA"], ["#F6D365", "#FDA085"], ["#84FAB0", "#8FD3F4"],
        ["#A18CD1", "#FBC2EB", "#FAD0C4"], ["#43E97B", "#38F9D7"], ["#30CFD0", "#330867"], ["#FF9A9E", "#FECFEF"],
        ["#232526", "#414345"], ["#FDFC47", "#24FE41"], ["#E0C3FC", "#8EC5FC"], ["#FF6E7F", "#BFE9FF"],
    ]
    static let solids = ["#FFFFFF", "#F2F2F7", "#D1D1D6", "#8E8E93", "#3A3A3C", "#1C1C1E", "#000000",
                         "#FF453A", "#FF9F0A", "#FFD60A", "#32D74B", "#64D2FF", "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F"]
}

// MARK: - Document state

/// Everything undoable about an editor: the original image, its scale, annotations, background and canvas.
struct DocState: Equatable {
    var image: CGImage
    var scale: CGFloat
    var annotations: [Annotation] = []
    var background = BackgroundSettings()
    var crop: CGRect? // canvas rect in image points; nil = the image. May extend past the image (combined images).
    var spotlightOpacity: CGFloat = 0.55
    var assets: [UUID: CGImage] = [:]
    var expandCanvas = false // "Automatically expand canvas" (and canvas not locked); set by the editor, not saved
    var orientation: [Geo.Orient] = [] // rotations/flips since opening, for "Revert to Original"; not saved

    var imageSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    var imageRect: CGRect { CGRect(origin: .zero, size: imageSize) }

    static func == (a: DocState, b: DocState) -> Bool {
        a.image === b.image && a.scale == b.scale && a.annotations == b.annotations && a.background == b.background && a.crop == b.crop
            && a.spotlightOpacity == b.spotlightOpacity && a.expandCanvas == b.expandCanvas && a.orientation == b.orientation
            && a.assets.count == b.assets.count && a.assets.allSatisfy { b.assets[$0.key] === $0.value }
    }
}

/// `.daisyshot` document (format documented at the top of this file).
struct AnnotateDocument: Codable {
    static let currentVersion = 2
    var version = AnnotateDocument.currentVersion
    var image: Data
    var scale: CGFloat
    @Lossy var annotations: [Annotation]
    var background: BackgroundSettings
    var crop: CGRect?
    var spotlightOpacity: CGFloat?
    var assets: [String: Data]?
    var previewPNG: Data?
    var thumbnailPNG: Data?

    @MainActor
    init?(_ s: DocState) {
        guard let png = Self.png(s.image) else { return nil }
        image = png
        scale = s.scale
        annotations = s.annotations
        background = s.background
        crop = s.crop
        spotlightOpacity = s.spotlightOpacity
        let used = Set(s.annotations.compactMap(\.assetID))
        assets = Dictionary(uniqueKeysWithValues: s.assets.filter { used.contains($0.key) }.compactMap { k, v in Self.png(v).map { (k.uuidString, $0) } })
        let preview = AnnotateRenderer.flatten(s).image
        previewPNG = Self.png(preview)
        let k = min(1, 512 / CGFloat(max(preview.width, preview.height)))
        thumbnailPNG = Self.png(k < 1 ? preview.resized(by: k) ?? preview : preview)
    }

    /// The editable state. The file is untrusted: malformed annotations are dropped and bad numbers fall back to defaults.
    var state: DocState? {
        guard let img = Self.image(image), scale.isFinite, scale > 0, scale <= 16 else { return nil }
        var s = DocState(image: img, scale: scale, annotations: annotations.filter(\.isWellFormed), background: Self.sane(background))
        if let c = crop, [c.minX, c.minY, c.width, c.height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), c.width >= 1, c.height >= 1 { s.crop = c }
        if let o = spotlightOpacity, o.isFinite { s.spotlightOpacity = min(max(o, 0), 1) }
        for (k, v) in assets ?? [:] { if let id = UUID(uuidString: k), let i = Self.image(v) { s.assets[id] = i } }
        return s
    }

    static func sane(_ b: BackgroundSettings) -> BackgroundSettings {
        let d = BackgroundSettings()
        var b = b
        func fix(_ kp: WritableKeyPath<BackgroundSettings, CGFloat>, _ r: ClosedRange<CGFloat>) { if !b[keyPath: kp].isFinite || !r.contains(b[keyPath: kp]) { b[keyPath: kp] = d[keyPath: kp] } }
        fix(\.padding, 0 ... 2000); fix(\.cornerRadius, 0 ... 2000); fix(\.shadow, 0 ... 1); fix(\.inset, 0 ... 2000)
        fix(\.customRatio.width, 0.01 ... 1000); fix(\.customRatio.height, 0.01 ... 1000)
        if !(0 ... 8).contains(b.alignment) { b.alignment = d.alignment }
        switch b.fill {
        case .gradient(let i) where i < 0, .builtin(let i) where i < 0: b.fill = d.fill
        default: break
        }
        return b
    }

    static func png(_ img: CGImage) -> Data? { NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) }

    static func image(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    static func load(_ url: URL) throws -> AnnotateDocument {
        try JSONDecoder().decode(AnnotateDocument.self, from: Data(contentsOf: url))
    }
}

/// Decodes an array, dropping elements that fail (e.g. annotation kinds added by a newer Daisyshot). Same wire format.
@propertyWrapper
struct Lossy<T: Codable>: Codable {
    var wrappedValue: [T]
    init(wrappedValue: [T]) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else { _ = try c.decode(Skip.self) }
        }
        wrappedValue = out
    }

    func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }
}

private struct Skip: Decodable {}

// MARK: - Pure geometry / labels

enum Geo {
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return dist(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    static func distToPolyline(_ p: CGPoint, _ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return pts.first.map { dist(p, $0) } ?? .infinity }
        return zip(pts, pts.dropFirst()).map { distToSegment(p, $0, $1) }.min()!
    }

    static func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    /// Default control point for a curved arrow: bowed to one side of the midpoint.
    static func defaultControl(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2 - (b.y - a.y) * 0.25, y: (a.y + b.y) / 2 + (b.x - a.x) * 0.25)
    }

    /// Snaps `p` relative to `origin` to 45° increments (shift-drag for lines/arrows).
    static func snap45(_ origin: CGPoint, _ p: CGPoint) -> CGPoint {
        let d = dist(origin, p)
        let a = (atan2(p.y - origin.y, p.x - origin.x) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: origin.x + cos(a) * d, y: origin.y + sin(a) * d)
    }

    /// Shift-drag for rect-like shapes: square.
    static func square(_ origin: CGPoint, _ p: CGPoint) -> CGPoint {
        let s = max(abs(p.x - origin.x), abs(p.y - origin.y))
        return CGPoint(x: origin.x + (p.x < origin.x ? -s : s), y: origin.y + (p.y < origin.y ? -s : s))
    }

    /// 8 resize handles: 0 tl, 1 tr, 2 br, 3 bl, 4 top, 5 right, 6 bottom, 7 left.
    static func handles(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
         CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    /// The point that stays fixed while dragging handle `h` of `r`.
    static func opposite(_ r: CGRect, handle h: Int) -> CGPoint {
        [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)][h]
    }

    /// Moves the edges controlled by handle `h` to `p`; the result is standardized (dragging past an edge flips).
    static func resize(_ r: CGRect, handle h: Int, to p: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if [0, 3, 7].contains(h) { minX = p.x }
        if [1, 2, 5].contains(h) { maxX = p.x }
        if [0, 1, 4].contains(h) { minY = p.y }
        if [2, 3, 6].contains(h) { maxY = p.y }
        return rect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
    }

    /// Corner-handle resize that keeps `r`'s aspect ratio (images, ⇧-resize).
    static func resizeKeepingRatio(_ r: CGRect, handle h: Int, to p: CGPoint) -> CGRect {
        guard h < 4, r.width > 0, r.height > 0 else { return resize(r, handle: h, to: p) }
        let o = opposite(r, handle: h), k = r.width / r.height
        var w = abs(p.x - o.x), hh = abs(p.y - o.y)
        if w / max(hh, 0.001) > k { hh = w / k } else { w = hh * k }
        return rect(o, CGPoint(x: o.x + (p.x < o.x ? -w : w), y: o.y + (p.y < o.y ? -hh : hh)))
    }

    /// Largest rect of ratio `k` (w/h) centred in `r`.
    static func fit(_ r: CGRect, ratio k: CGFloat) -> CGRect {
        let w = min(r.width, r.height * k), h = w / k
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    /// Moving-average smoothing for freehand strokes; endpoints are kept.
    static func smooth(_ pts: [CGPoint], radius: Int = 3) -> [CGPoint] {
        guard pts.count > 2, radius > 0 else { return pts }
        return pts.indices.map { i in
            if i == 0 || i == pts.count - 1 { return pts[i] }
            let r = min(radius, i, pts.count - 1 - i)
            let s = pts[(i - r) ... (i + r)]
            return CGPoint(x: s.map(\.x).reduce(0, +) / CGFloat(s.count), y: s.map(\.y).reduce(0, +) / CGFloat(s.count))
        }
    }

    /// Nearest candidate within `tol` of `v`, else nil.
    static func snap(_ v: CGFloat, to candidates: [CGFloat], tol: CGFloat) -> CGFloat? {
        candidates.min { abs($0 - v) < abs($1 - v) }.flatMap { abs($0 - v) <= tol ? $0 : nil }
    }

    enum Orient { case rotateRight, rotateLeft, flipH, flipV }

    /// Maps a point of a `size` image through a rotation/flip (top-left origin).
    static func orient(_ p: CGPoint, in size: CGSize, _ o: Orient) -> CGPoint {
        switch o {
        case .rotateRight: return CGPoint(x: size.height - p.y, y: p.x)
        case .rotateLeft: return CGPoint(x: p.y, y: size.width - p.x)
        case .flipH: return CGPoint(x: size.width - p.x, y: p.y)
        case .flipV: return CGPoint(x: p.x, y: size.height - p.y)
        }
    }

    /// The same mapping as `orient` as an affine transform (for drawing the image).
    static func orientTransform(_ s: CGSize, _ o: Orient) -> CGAffineTransform {
        switch o {
        case .rotateRight: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: s.height, ty: 0)
        case .rotateLeft: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: s.width)
        case .flipH: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: s.width, ty: 0)
        case .flipV: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: s.height)
        }
    }

    static func orientedSize(_ s: CGSize, _ o: Orient) -> CGSize {
        o == .rotateLeft || o == .rotateRight ? CGSize(width: s.height, height: s.width) : s
    }

    static func roman(_ n: Int) -> String {
        guard n > 0 else { return String(n) }
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, s = ""
        for (v, r) in table { while n >= v { s += r; n -= v } }
        return s
    }

    /// 1 → A, 26 → Z, 27 → AA (spreadsheet style).
    static func alpha(_ n: Int) -> String {
        guard n > 0 else { return String(n) }
        var n = n, s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }

    static func counterLabel(_ n: Int, _ style: CounterStyle) -> String {
        switch style {
        case .numeric: return String(n)
        case .roman: return roman(n)
        case .alphaUpper: return alpha(n)
        case .alphaLower: return alpha(n).lowercased()
        }
    }

    /// Places a box of `inner` size inside `outer` by a 3×3 alignment index.
    static func align(_ inner: CGSize, in outer: CGRect, _ alignment: Int) -> CGPoint {
        let ax = CGFloat(alignment % 3) / 2, ay = CGFloat(alignment / 3) / 2
        return CGPoint(x: outer.minX + (outer.width - inner.width) * ax, y: outer.minY + (outer.height - inner.height) * ay)
    }

    /// Auto-balance: extra inset per edge (left, top, right, bottom) so the screenshot's own uniform margins look equal.
    static func balance(_ margins: NSEdgeInsets) -> NSEdgeInsets {
        let m = max(margins.left, margins.top, margins.right, margins.bottom)
        return NSEdgeInsets(top: m - margins.top, left: m - margins.left, bottom: m - margins.bottom, right: m - margins.right)
    }

    /// Runnable self-check for the pure logic above (called once in debug builds when the first editor opens).
    static func selfTest() {
        assert(roman(1994) == "MCMXCIV" && roman(4) == "IV" && roman(3999) == "MMMCMXCIX")
        assert(alpha(1) == "A" && alpha(26) == "Z" && alpha(27) == "AA" && alpha(52) == "AZ")
        assert(counterLabel(3, .roman) == "III" && counterLabel(28, .alphaLower) == "ab")
        assert(distToSegment(CGPoint(x: 5, y: 3), .zero, CGPoint(x: 10, y: 0)) == 3)
        assert(distToSegment(CGPoint(x: -4, y: 3), .zero, CGPoint(x: 10, y: 0)) == 5)
        let r = CGRect(x: 0, y: 0, width: 10, height: 10)
        assert(resize(r, handle: 2, to: CGPoint(x: 20, y: 30)) == CGRect(x: 0, y: 0, width: 20, height: 30))
        assert(resize(r, handle: 5, to: CGPoint(x: -5, y: 99)) == CGRect(x: -5, y: 0, width: 5, height: 10)) // flips past left edge
        assert(resize(r, handle: 4, to: CGPoint(x: 99, y: 4)) == CGRect(x: 0, y: 4, width: 10, height: 6))
        assert(resizeKeepingRatio(CGRect(x: 0, y: 0, width: 20, height: 10), handle: 2, to: CGPoint(x: 40, y: 12)) == CGRect(x: 0, y: 0, width: 40, height: 20))
        let s = snap45(.zero, CGPoint(x: 10, y: 1))
        assert(abs(s.y) < 0.001 && abs(s.x - hypot(10, 1)) < 0.001)
        assert(align(CGSize(width: 10, height: 10), in: CGRect(x: 0, y: 0, width: 30, height: 30), 8) == CGPoint(x: 20, y: 20))
        assert(quad(.zero, CGPoint(x: 5, y: 10), CGPoint(x: 10, y: 0), 0.5) == CGPoint(x: 5, y: 5))
        assert(fit(CGRect(x: 0, y: 0, width: 100, height: 50), ratio: 1) == CGRect(x: 25, y: 0, width: 50, height: 50))
        let sm = smooth([.zero, CGPoint(x: 1, y: 10), CGPoint(x: 2, y: 0)], radius: 1)
        assert(sm[0] == .zero && sm[2] == CGPoint(x: 2, y: 0) && abs(sm[1].y - 10.0 / 3) < 0.001)
        assert(snap(9, to: [0, 10, 20], tol: 2) == 10 && snap(5, to: [0, 10], tol: 2) == nil)
        let sz = CGSize(width: 100, height: 50), p = CGPoint(x: 10, y: 5)
        assert(orient(orient(p, in: sz, .rotateRight), in: orientedSize(sz, .rotateRight), .rotateLeft) == p)
        assert(orient(p, in: sz, .rotateRight) == CGPoint(x: 45, y: 10))
        assert(orient(orient(p, in: sz, .flipH), in: sz, .flipH) == p)
        for o in [Orient.rotateRight, .rotateLeft, .flipH, .flipV] { assert(p.applying(orientTransform(sz, o)) == orient(p, in: sz, o)) }
        let b = balance(NSEdgeInsets(top: 4, left: 10, bottom: 0, right: 2))
        assert(b.left == 0 && b.top == 6 && b.bottom == 10 && b.right == 8)
        assert(CropChoice.preset(1).value(original: .zero, custom: .zero) == 16.0 / 9 && CropChoice.presets.count == 13)
        assert(Palette.named.count == 17 && Palette.name("#ffffff") == "White")
        // v1 documents (no new fields) still decode.
        let v1 = ##"{"kind":"arrow","points":[[0,0],[5,5]],"color":"#FF0000","lineWidth":4,"shadow":true,"fontSize":20}"##
        let a = try? JSONDecoder().decode(Annotation.self, from: Data(v1.utf8))
        assert(a?.intensity == 0.5 && a?.assetID == nil && a?.kind == .arrow)
        let bg = try? JSONDecoder().decode(BackgroundSettings.self, from: Data(#"{"fill":{"gradient":{"_0":2}},"padding":10}"#.utf8))
        assert(bg?.fill == .gradient(2) && bg?.padding == 10 && bg?.autoBalance == false)
        // Malformed documents: short point lists / NaN / absurd sizes are rejected.
        let bad = Annotation(kind: .arrow, points: [.zero], color: "#000", lineWidth: 2, shadow: false, fontSize: 10)
        assert(!bad.isWellFormed && bad.rect == .zero)
        var nan = bad; nan.points = [.zero, CGPoint(x: CGFloat.nan, y: 0)]
        assert(!nan.isWellFormed)
        var big = bad; big.points = [.zero, CGPoint(x: 5, y: 5)]; assert(big.isWellFormed)
        big.lineWidth = 1e9; assert(!big.isWellFormed)
        var wild = BackgroundSettings(); wild.fill = .gradient(-3); wild.padding = .infinity
        assert(AnnotateDocument.sane(wild).fill == .none && AnnotateDocument.sane(wild).padding == 64)
    }
}
