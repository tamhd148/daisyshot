import AppKit
import Vision

/// Pixel analysis used by the editor: text lines (highlighter snapping), strong edges (crop snapping) and uniform margins
/// (background auto-balance). Results are cached per image (identity).
@MainActor
enum ImageAnalysis {
    struct TextLine {
        var rect: CGRect      // image points, top-left origin
        var chars: [CGRect]   // character boxes inside the line
    }

    // MARK: Text lines (Vision)

    private static var textCache: [ObjectIdentifier: [TextLine]] = [:]
    private static var textPending: Set<ObjectIdentifier> = []

    /// Cached text lines, or nil while detection is still running (it's started on first call).
    static func textLines(_ img: CGImage, scale: CGFloat) -> [TextLine]? {
        let key = ObjectIdentifier(img)
        if let hit = textCache[key] { return hit }
        guard !textPending.contains(key) else { return nil }
        textPending.insert(key)
        let size = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
        DispatchQueue.global(qos: .userInitiated).async {
            let req = VNDetectTextRectanglesRequest()
            req.reportCharacterBoxes = true
            try? VNImageRequestHandler(cgImage: img).perform([req])
            func convert(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
            }
            let lines = (req.results ?? []).map { o in
                TextLine(rect: convert(o.boundingBox), chars: (o.characterBoxes ?? []).map { convert($0.boundingBox) })
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    textPending.remove(key)
                    textCache[key] = lines
                    if textCache.count > 8 { textCache.removeValue(forKey: textCache.keys.first!) }
                }
            }
        }
        return nil
    }

    /// Highlighter snapping: if the drag starts on a detected text line, returns a horizontal stroke covering it from the
    /// character under `start` to the one under `end`, plus the band height.
    static func snapHighlight(_ lines: [TextLine], from start: CGPoint, to end: CGPoint) -> (CGPoint, CGPoint, height: CGFloat)? {
        guard let line = lines.first(where: { $0.rect.insetBy(dx: -4, dy: -3).contains(start) }) else { return nil }
        let r = line.rect
        let lo = min(start.x, end.x), hi = max(start.x, end.x)
        let edgesL = line.chars.map(\.minX), edgesR = line.chars.map(\.maxX)
        let x0 = edgesL.filter { $0 <= lo + 2 }.max() ?? max(r.minX, lo)
        let x1 = edgesR.filter { $0 >= hi - 2 }.min() ?? min(r.maxX, hi)
        let pad = r.height * 0.12
        return (CGPoint(x: x0 - pad, y: r.midY), CGPoint(x: max(x1, x0 + 1) + pad, y: r.midY), r.height + 2 * pad)
    }

    // MARK: Bitmap helpers

    /// Grey/RGBA bitmap of `rect` (pixels) downsampled so the long side is <= `maxSide`.
    private static func bitmap(_ img: CGImage, rect px: CGRect, maxSide: CGFloat) -> (bytes: [UInt8], w: Int, h: Int, k: CGFloat)? {
        guard let sub = img.cropping(to: px.integral) else { return nil }
        let k = min(1, maxSide / max(CGFloat(sub.width), CGFloat(sub.height)))
        let w = max(1, Int(CGFloat(sub.width) * k)), h = max(1, Int(CGFloat(sub.height) * k))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(sub, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (bytes, w, h, CGFloat(w) / CGFloat(sub.width)) : nil
    }

    // MARK: Uniform margins (auto-balance)

    private static var marginCache: [String: NSEdgeInsets] = [:]

    /// Width of the uniform border (same colour as the top-left pixel) on each side of `rect` (image points).
    static func uniformMargins(_ img: CGImage, scale: CGFloat, rect: CGRect) -> NSEdgeInsets {
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let key = "\(ObjectIdentifier(img).hashValue)|\(px)"
        if let hit = marginCache[key] { return hit }
        var out = NSEdgeInsets()
        if !px.isEmpty, let b = bitmap(img, rect: px, maxSide: 1000) {
            let m = margins(b.bytes, w: b.w, h: b.h)
            let f = 1 / (b.k * scale)
            out = NSEdgeInsets(top: CGFloat(m.top) * f, left: CGFloat(m.left) * f, bottom: CGFloat(m.bottom) * f, right: CGFloat(m.right) * f)
        }
        marginCache[key] = out
        if marginCache.count > 16 { marginCache.removeValue(forKey: marginCache.keys.first!) }
        return out
    }

    /// Pure: uniform border widths (in pixels) of an RGBA buffer, matching the top-left pixel.
    nonisolated static func margins(_ p: [UInt8], w: Int, h: Int) -> (top: Int, left: Int, bottom: Int, right: Int) {
        func same(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return abs(Int(p[i]) - Int(p[0])) <= 10 && abs(Int(p[i + 1]) - Int(p[1])) <= 10 && abs(Int(p[i + 2]) - Int(p[2])) <= 10
        }
        func col(_ x: Int) -> Bool { (0 ..< h).allSatisfy { same(x, $0) } }
        func row(_ y: Int) -> Bool { (0 ..< w).allSatisfy { same($0, y) } }
        var left = 0, right = 0, top = 0, bottom = 0
        while left < w * 2 / 5, col(left) { left += 1 }
        while right < w * 2 / 5, col(w - 1 - right) { right += 1 }
        while top < h * 2 / 5, row(top) { top += 1 }
        while bottom < h * 2 / 5, row(h - 1 - bottom) { bottom += 1 }
        return (top, left, bottom, right)
    }

    // MARK: Edges (crop snapping)

    private static var edgeCache: [ObjectIdentifier: (xs: [CGFloat], ys: [CGFloat])] = [:]

    /// Strong straight vertical (xs) and horizontal (ys) edges in image points, e.g. window and panel borders.
    static func edges(_ img: CGImage, scale: CGFloat) -> (xs: [CGFloat], ys: [CGFloat]) {
        let key = ObjectIdentifier(img)
        if let hit = edgeCache[key] { return hit }
        var out: (xs: [CGFloat], ys: [CGFloat]) = ([], [])
        if let b = bitmap(img, rect: CGRect(x: 0, y: 0, width: img.width, height: img.height), maxSide: 1600) {
            let px = b.bytes
            let lum: [Int] = stride(from: 0, to: px.count, by: 4).map { i in
                let r = Int(px[i]) * 3, g = Int(px[i + 1]) * 6
                return r + g + Int(px[i + 2])
            }
            let e = edgeLines(lum, w: b.w, h: b.h)
            let f = 1 / (b.k * scale)
            out = (e.xs.map { CGFloat($0) * f }, e.ys.map { CGFloat($0) * f })
        }
        edgeCache[key] = out
        if edgeCache.count > 8 { edgeCache.removeValue(forKey: edgeCache.keys.first!) }
        return out
    }

    /// Pure: indices (pixel boundaries) where at least 30% of a column/row has a strong luminance step, local maxima only.
    nonisolated static func edgeLines(_ lum: [Int], w: Int, h: Int) -> (xs: [Int], ys: [Int]) {
        guard w > 2, h > 2 else { return ([], []) }
        let t = 250 // ≈ 25 levels of 8-bit luminance (lum is ×10)
        var cx = [Int](repeating: 0, count: w + 1), cy = [Int](repeating: 0, count: h + 1)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let v = lum[y * w + x]
                if x > 0, abs(v - lum[y * w + x - 1]) > t { cx[x] += 1 }
                if y > 0, abs(v - lum[(y - 1) * w + x]) > t { cy[y] += 1 }
            }
        }
        func peaks(_ c: [Int], _ n: Int) -> [Int] {
            c.indices.filter { i in c[i] * 10 >= n * 3 && (i == 0 || c[i] >= c[i - 1]) && (i == c.count - 1 || c[i] > c[i + 1]) }
        }
        return (peaks(cx, h), peaks(cy, w))
    }

    nonisolated static func selfTest() {
        // 6×4 white image with a 1px black frame on the left and a black right half: margins and edges.
        let w = 6, h = 4
        var p = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0 ..< h { for x in 3 ..< w { let i = (y * w + x) * 4; p[i] = 0; p[i + 1] = 0; p[i + 2] = 0 } }
        let m = margins(p, w: w, h: h)
        assert(m.left == 2 && m.top == 0 && m.right == 0) // capped at 2/5 of 6 = 2
        let lum = stride(from: 0, to: p.count, by: 4).map { Int(p[$0]) * 10 }
        let e = edgeLines(lum, w: w, h: h)
        assert(e.xs == [3] && e.ys.isEmpty)
    }
}
