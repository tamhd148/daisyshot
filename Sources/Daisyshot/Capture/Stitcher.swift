import CoreGraphics
import Foundation
import Vision

/// Tightly packed RGBA8 (premultiplied, sRGB) pixels, top row first.
struct PixelBuffer {
    var width: Int
    var height: Int
    var data: [UInt8]

    init(width: Int, height: Int, data: [UInt8]) {
        self.width = width; self.height = height; self.data = data
    }

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var d = [UInt8](repeating: 0, count: w * h * 4)
        let ok = d.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, data: d)
    }

    var cgImage: CGImage? { Self.cgImage(width: width, height: height, bytes: data[...]) }

    /// Rows become columns: horizontal scrolling is stitched as vertical scrolling of the transposed frames.
    func transposed() -> PixelBuffer {
        var out = [UInt32](repeating: 0, count: width * height)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt32.self)
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width { dst[x * height + y] = src[row + x] }
                }
            }
        }
        return PixelBuffer(width: height, height: width, data: out.withUnsafeBytes { Array($0) })
    }

    static func cgImage(width: Int, height: Int, bytes: ArraySlice<UInt8>) -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Per-row fingerprint of a frame: grayscale downsampled 4:1 horizontally, a hash of each row, and whether
/// the row carries enough detail to be worth matching (blank rows match everything and are skipped when voting).
struct RowSignature {
    static let block = 4
    let rows: Int
    let cols: Int
    var gray: [UInt8]
    var hash: [UInt64]
    var informative: [Bool]

    /// `ignoreRight` px on the right edge are left out (overlay scrollbars flash in and out while scrolling).
    init(_ b: PixelBuffer, ignoreRight: Int = 0) {
        let usable = b.width - ignoreRight >= b.width / 2 ? b.width - ignoreRight : b.width
        rows = b.height
        cols = max(1, usable / Self.block)
        var gray = [UInt8](repeating: 0, count: rows * cols)
        var hash = [UInt64](repeating: 0, count: rows)
        var informative = [Bool](repeating: false, count: rows)
        let rows = rows, cols = cols, rowBytes = b.width * 4
        // Raw pointers keep this usable in unoptimized (debug) builds; it runs on every captured frame.
        // ponytail: samples 2 of every 4 pixels per block; full averaging only if matching proves flaky.
        let step = b.width >= Self.block ? 8 : 0
        b.data.withUnsafeBufferPointer { px in
            gray.withUnsafeMutableBufferPointer { g in
                guard let px = px.baseAddress, let g = g.baseAddress else { return }
                for y in 0..<rows {
                    var h: UInt64 = 0xcbf2_9ce4_8422_2325
                    var lo = 255, hi = 0
                    var p = px + y * rowBytes
                    let out = g + y * cols
                    for c in 0..<cols {
                        let q = p + step
                        let v = (Int(p[0]) + 2 * Int(p[1]) + Int(p[2]) + Int(q[0]) + 2 * Int(q[1]) + Int(q[2])) >> 3
                        out[c] = UInt8(truncatingIfNeeded: v)
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                        h = (h ^ UInt64(v >> 2)) &* 0x100_0000_01b3
                        p += Self.block * 4
                    }
                    hash[y] = h
                    informative[y] = hi - lo > 8
                }
            }
        }
        self.gray = gray; self.hash = hash; self.informative = informative
    }
}

enum FrameMatch: Equatable {
    /// Content moved up by `offset` rows; the bottom `footer` rows are identical in both frames (fixed footer).
    case moved(offset: Int, footer: Int)
    case unchanged, scrolledUp, noMatch
}

enum Stitcher {
    /// Finds how far the content scrolled between two equally sized frames.
    /// Fixed header/footer bands (identical rows at the same position) are excluded, then each informative row of `cur`
    /// votes for offsets where `prev` has the same row hash; the top candidates are checked by mean abs gray difference.
    static func match(_ prev: RowSignature, _ cur: RowSignature) -> FrameMatch {
        let H = prev.rows
        guard cur.rows == H, cur.cols == prev.cols, H > 0 else { return .noMatch }
        let (top, footer) = bands(prev, cur)
        if top == H { return .unchanged }
        let lo = top, hi = H - footer

        var index: [UInt64: [Int]] = [:]
        for i in lo..<hi where prev.informative[i] { index[prev.hash[i], default: []].append(i) }
        var votes: [Int: Int] = [:]
        for j in lo..<hi where cur.informative[j] {
            // ponytail: rows repeated >4 times (table stripes) are too ambiguous to vote; fine for typical pages.
            guard let list = index[cur.hash[j]], list.count <= 4 else { continue }
            for i in list where i != j { votes[i - j, default: 0] += 1 }
        }
        let candidates = votes.sorted { $0.value != $1.value ? $0.value > $1.value : abs($0.key) < abs($1.key) }.prefix(3)

        let minOverlap = max(8, (hi - lo) / 8)
        var best: (d: Int, mad: Double)?
        for (d, _) in candidates {
            // cur row j shows what prev row j + d showed; both must lie in the moving band.
            let a = max(lo, lo - d), b = min(hi, hi - d)
            guard b - a >= minOverlap else { continue }
            let m = meanAbsDiff(prev, cur, rows: a..<b, offset: d)
            if m <= 3, m < (best?.mad ?? .infinity) { best = (d, m) }
        }
        guard let best else {
            // A small changing band (caret, spinner) in an otherwise still frame is not a scroll.
            return (hi - lo) * 4 < H ? .unchanged : .noMatch
        }
        return best.d > 0 ? .moved(offset: best.d, footer: footer) : .scrolledUp
    }

    /// Rows identical at the same position at the top (fixed header) and bottom (fixed footer) of both frames.
    static func bands(_ prev: RowSignature, _ cur: RowSignature) -> (top: Int, footer: Int) {
        let H = prev.rows
        var top = 0
        while top < H, prev.hash[top] == cur.hash[top] { top += 1 }
        var footer = 0
        while footer < H - top, prev.hash[H - 1 - footer] == cur.hash[H - 1 - footer] { footer += 1 }
        return (top, footer)
    }

    /// Fallback when row hashes don't line up (anti-aliasing / subpixel noise): Vision's translational registration.
    /// Returns how many rows the content moved up between the frames (the caller verifies the overlap).
    static func visionOffset(_ prev: PixelBuffer, _ cur: PixelBuffer) -> Int? {
        guard let a = prev.cgImage, let b = cur.cgImage else { return nil }
        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: b)
        try? VNImageRequestHandler(cgImage: a).perform([req])
        guard let t = (req.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform else { return nil }
        return Int((-t.ty).rounded())
    }

    static func meanAbsDiff(_ prev: RowSignature, _ cur: RowSignature, rows: Range<Int>, offset d: Int) -> Double {
        let cols = cur.cols
        var total = 0
        cur.gray.withUnsafeBufferPointer { c in
            prev.gray.withUnsafeBufferPointer { p in
                guard let c = c.baseAddress, let p = p.baseAddress else { return }
                for j in rows {
                    let a = c + j * cols, b = p + (j + d) * cols
                    for i in 0..<cols {
                        let x = Int(a[i]) - Int(b[i])
                        total += x < 0 ? -x : x
                    }
                }
            }
        }
        return Double(total) / Double(max(1, rows.count * cols))
    }
}

/// Accumulates frames into one tall image. Invariant: the canvas always ends with the last accepted frame's bottom rows,
/// so each step drops the old footer, then appends the newly revealed rows plus the current footer.
/// Not thread-safe: the scroll session feeds it from one task at a time.
final class Stitch: @unchecked Sendable {
    enum Step: Equatable { case appended(Int), unchanged, scrolledUp, noMatch, full }

    let maxHeight: Int
    let ignoreRight: Int
    private(set) var width = 0
    private(set) var height = 0
    private var pixels: [UInt8] = []
    private var last: RowSignature?
    private var lastFrame: PixelBuffer?
    /// Use Vision registration when row matching finds nothing.
    var useVisionFallback = true

    init(maxHeight: Int = 30_000, ignoreRight: Int = 0) {
        self.maxHeight = maxHeight
        self.ignoreRight = ignoreRight
    }

    func add(_ frame: PixelBuffer) -> Step {
        guard let last else {
            width = frame.width
            height = min(frame.height, maxHeight)
            pixels = Array(frame.data.prefix(height * width * 4))
            self.last = RowSignature(frame, ignoreRight: ignoreRight)
            lastFrame = frame
            return .appended(height)
        }
        guard frame.width == width, frame.height == last.rows else { return .noMatch }
        guard height < maxHeight else { return .full }
        let sig = RowSignature(frame, ignoreRight: ignoreRight)
        var result = Stitcher.match(last, sig)
        if result == .noMatch, useVisionFallback, let prev = lastFrame, let d = Stitcher.visionOffset(prev, frame) {
            // Accept Vision's estimate only if the overlapping band really agrees.
            let (top, footer) = Stitcher.bands(last, sig)
            let lo = top, hi = frame.height - footer
            let a = max(lo, lo - d), b = min(hi, hi - d)
            if d > 0, b - a >= max(8, (hi - lo) / 8), Stitcher.meanAbsDiff(last, sig, rows: a..<b, offset: d) <= 8 {
                result = .moved(offset: d, footer: footer)
            }
        }
        switch result {
        case let .moved(d, footer):
            let rowBytes = width * 4, H = frame.height
            let take = min(d, maxHeight - height)
            pixels.removeLast(footer * rowBytes)
            let start = H - footer - d
            pixels += frame.data[(start * rowBytes)..<((start + take) * rowBytes)]
            pixels += frame.data[((H - footer) * rowBytes)..<(H * rowBytes)]
            height += take
            self.last = sig
            lastFrame = frame
            return take < d ? .full : .appended(d)
        case .unchanged: return .unchanged
        case .scrolledUp: return .scrolledUp
        case .noMatch: return .noMatch
        }
    }

    func image() -> CGImage? { PixelBuffer.cgImage(width: width, height: height, bytes: pixels[...]) }

    /// The canvas as pixels (horizontal sessions transpose it back).
    func buffer() -> PixelBuffer { PixelBuffer(width: width, height: height, data: pixels) }

    /// Nearest-neighbour downscale of the whole canvas, fitting `maxW`×`maxH`.
    func thumbnail(maxW: Int, maxH: Int) -> CGImage? {
        guard height > 0 else { return nil }
        let s = min(1, Double(maxW) / Double(width), Double(maxH) / Double(height))
        let tw = max(1, Int(Double(width) * s)), th = max(1, Int(Double(height) * s))
        var out = [UInt8](repeating: 0, count: tw * th * 4)
        for y in 0..<th {
            let sy = min(height - 1, Int(Double(y) / s))
            for x in 0..<tw {
                let sx = min(width - 1, Int(Double(x) / s))
                let si = (sy * width + sx) * 4, di = (y * tw + x) * 4
                out[di] = pixels[si]; out[di + 1] = pixels[si + 1]; out[di + 2] = pixels[si + 2]; out[di + 3] = pixels[si + 3]
            }
        }
        return PixelBuffer.cgImage(width: tw, height: th, bytes: out[...])
    }

    /// Runnable check: a synthetic page with a fixed header/footer, scrolled by known amounts (incl. a pause, a scroll-up
    /// and a near-full-viewport jump), must stitch back to exactly header + page + footer. Returns a failure description.
    static func selfTest() -> String? {
        let W = 64, header = 20, footer = 15, H = 200, band = H - header - footer, pageH = 600
        func row(_ seed: Int, blank: Bool) -> [UInt8] {
            (0..<W).flatMap { c -> [UInt8] in
                if blank { return [250, 250, 250, 255] }
                let v = UInt8(truncatingIfNeeded: (((seed &* 73_856_093) ^ ((c / 8) &* 19_349_663)) &* 2_654_435_761) >> 24)
                return [v, v &+ 40, v &+ 90, 255]
            }
        }
        let head = (0..<header).map { row(10_000 + $0, blank: false) }
        let foot = (0..<footer).map { row(20_000 + $0, blank: $0 == 0) }
        let page = (0..<pageH).map { row($0, blank: $0 % 7 == 0) }
        func frame(_ s: Int) -> PixelBuffer {
            PixelBuffer(width: W, height: H, data: (head + page[s..<(s + band)] + foot).flatMap { $0 })
        }
        let st = Stitch(maxHeight: 30_000, ignoreRight: 0)
        let script: [(Int, Step)] = [(0, .appended(H)), (30, .appended(30)), (30, .unchanged), (75, .appended(45)),
                                     (60, .scrolledUp), (140, .appended(65)), (200, .appended(60)),
                                     (300, .appended(100)), (435, .appended(135)), (435, .unchanged)]
        for (s, want) in script {
            let got = st.add(frame(s))
            if got != want { return "scroll \(s): expected \(want), got \(got)" }
        }
        let expected = (head + page + foot).flatMap { $0 }
        if st.height != header + pageH + footer { return "height \(st.height) != \(header + pageH + footer)" }
        if st.pixels != expected { return "stitched pixels differ from the source page" }

        let capped = Stitch(maxHeight: 300)
        _ = capped.add(frame(0)) // 200 rows, then +120 crosses the 300-row cap
        if capped.add(frame(120)) != .full || capped.height != 300 { return "cap: height \(capped.height)" }

        // Horizontal scrolling is stitched on transposed frames.
        let tiny = PixelBuffer(width: 2, height: 3, data: (0..<24).map { UInt8($0) })
        let t = tiny.transposed()
        if t.width != 3 || t.height != 2 || Array(t.data[4..<8]) != Array(tiny.data[8..<12]) || t.transposed().data != tiny.data {
            return "transpose"
        }

        // Vision fallback: a uniformly brightened frame defeats exact row hashes but still registers.
        func plain(_ s: Int, brighten: UInt8 = 0) -> PixelBuffer {
            PixelBuffer(width: W, height: H, data: page[s..<(s + H)].flatMap { $0 }.map { $0 > 250 ? $0 : $0 &+ min(brighten, 255 - $0) })
        }
        let v = Stitch(maxHeight: 30_000)
        _ = v.add(plain(0))
        v.useVisionFallback = false
        if v.add(plain(40, brighten: 6)) != .noMatch { return "brightened frame should defeat row matching" }
        v.useVisionFallback = true
        let got = v.add(plain(40, brighten: 6))
        if got != .appended(40) { return "vision fallback: expected appended(40), got \(got)" }
        return nil
    }
}
