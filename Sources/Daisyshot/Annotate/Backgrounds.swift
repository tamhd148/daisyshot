import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Image sources for the Background tool: built-in procedural wallpapers, the desktop picture (plain/blurred),
/// the blurred screenshot and the user's own images. Everything is rendered lazily and cached in memory.
@MainActor
enum Backgrounds {
    // MARK: Built-in wallpapers (original, generated in code)

    struct Wallpaper {
        enum Style { case field, blobs, waves, dunes, aurora, conic, radial }
        let name: String
        let style: Style
        let colors: [String]
        let seed: UInt64
    }

    static let wallpapers: [Wallpaper] = [
        Wallpaper(name: "Sunset Haze", style: .field, colors: ["#FF7E5F", "#FEB47B", "#FF6F91", "#6A5ACD"], seed: 1),
        Wallpaper(name: "Lagoon", style: .field, colors: ["#00C9FF", "#92FE9D", "#0072FF", "#00F5A0"], seed: 2),
        Wallpaper(name: "Nebula", style: .blobs, colors: ["#0B0B2B", "#7F00FF", "#E100FF", "#00D4FF"], seed: 3),
        Wallpaper(name: "Peach", style: .field, colors: ["#FFDDE1", "#EE9CA7", "#FFC3A0", "#FFAFBD"], seed: 4),
        Wallpaper(name: "Ocean", style: .waves, colors: ["#0F4C81", "#1B6CA8", "#3FA7D6", "#8FD3FE", "#D6F0FF"], seed: 5),
        Wallpaper(name: "Mint", style: .waves, colors: ["#F1FFE0", "#D4FC79", "#96E6A1", "#3BB78F", "#0BAB64"], seed: 6),
        Wallpaper(name: "Dusk Dunes", style: .dunes, colors: ["#FFD6A5", "#F6A5C0", "#9A48D0", "#5B2A86", "#2E1A47"], seed: 7),
        Wallpaper(name: "Desert", style: .dunes, colors: ["#FFE8C2", "#F9D29D", "#F0A868", "#D9774B", "#A0522D"], seed: 8),
        Wallpaper(name: "Aurora", style: .aurora, colors: ["#011627", "#2EC4B6", "#7CFFCB", "#9B5DE5"], seed: 9),
        Wallpaper(name: "Candy", style: .blobs, colors: ["#FFF0F5", "#FF9AA2", "#B5EAD7", "#C7CEEA", "#FFDAC1"], seed: 10),
        Wallpaper(name: "Prism", style: .conic, colors: ["#FF0080", "#FF8C00", "#FFE53B", "#40E0D0", "#7B68EE", "#FF0080"], seed: 11),
        Wallpaper(name: "Ember", style: .field, colors: ["#200122", "#6F0000", "#FF512F", "#F09819"], seed: 12),
        Wallpaper(name: "Forest", style: .waves, colors: ["#0B3D2E", "#155E46", "#2E8B57", "#5FBF8F", "#A8E6CF"], seed: 13),
        Wallpaper(name: "Glacier", style: .field, colors: ["#E0EAFC", "#CFDEF3", "#A1C4FD", "#C2E9FB"], seed: 14),
        Wallpaper(name: "Midnight", style: .blobs, colors: ["#05050F", "#1E3C72", "#2A5298", "#6DD5FA"], seed: 15),
        Wallpaper(name: "Lavender", style: .dunes, colors: ["#FBF8FF", "#E6E6FA", "#C3B1E1", "#9F86C0", "#5E548E"], seed: 16),
        Wallpaper(name: "Citrus", style: .blobs, colors: ["#FFF8E1", "#FFD54F", "#FF8A65", "#AED581"], seed: 17),
        Wallpaper(name: "Rose Gold", style: .field, colors: ["#B76E79", "#EAC7C7", "#F7E1D7", "#DEB3AD"], seed: 18),
        Wallpaper(name: "Deep Space", style: .radial, colors: ["#4CA1AF", "#243B55", "#141E30"], seed: 19),
        Wallpaper(name: "Graphite", style: .waves, colors: ["#1C1C1E", "#2C2C2E", "#3A3A3C", "#48484A", "#636366"], seed: 20),
    ]

    private static var wallpaperCache: [Int: CGImage] = [:]

    /// Full-size (2000 px) wallpaper.
    static func wallpaper(_ i: Int) -> CGImage? {
        let i = ((i % wallpapers.count) + wallpapers.count) % wallpapers.count
        if let hit = wallpaperCache[i] { return hit }
        let img = render(wallpapers[i], size: CGSize(width: 2000, height: 1250))
        wallpaperCache[i] = img
        return img
    }

    /// Deterministic PRNG so every wallpaper renders identically each time.
    struct Rand {
        var s: UInt64
        mutating func next() -> CGFloat {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((s >> 33) % 1_000_000) / 1_000_000
        }
    }

    static func render(_ w: Wallpaper, size: CGSize) -> CGImage? {
        let W = Int(size.width), H = Int(size.height)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let cols = w.colors.map { NSColor(hex: $0).cgColor }
        let r = CGRect(origin: .zero, size: size), m = max(size.width, size.height)
        var rnd = Rand(s: w.seed &* 0x9E3779B97F4A7C15)
        var blur: CGFloat = 0
        ctx.interpolationQuality = .high
        switch w.style {
        case .field:
            // Smooth "mesh" gradient: a tiny field of colour weights, upscaled with bilinear filtering, then softened.
            if let f = field(cols, &rnd) { ctx.draw(f, in: r.insetBy(dx: -m * 0.05, dy: -m * 0.05)) }
            blur = m * 0.02
        case .blobs:
            ctx.setFillColor(cols[0])
            ctx.fill(r)
            for i in 0 ..< 7 {
                let c = cols[1 + i % (cols.count - 1)]
                let p = CGPoint(x: rnd.next() * size.width, y: rnd.next() * size.height), rad = m * (0.18 + rnd.next() * 0.28)
                let g = CGGradient(colorsSpace: nil, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
                ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: rad, options: [])
            }
            blur = m * 0.035
        case .waves:
            linear(ctx, [cols[0], cols[1]], from: CGPoint(x: 0, y: size.height), to: .zero)
            for i in 1 ..< cols.count {
                let base = size.height * (0.75 - CGFloat(i) * 0.15), amp = size.height * (0.05 + rnd.next() * 0.06)
                let freq = (1.2 + rnd.next() * 1.5) * .pi * 2 / size.width, phase = rnd.next() * .pi * 2
                let p = CGMutablePath()
                p.move(to: CGPoint(x: 0, y: 0))
                for x in stride(from: CGFloat(0), through: size.width, by: 8) { p.addLine(to: CGPoint(x: x, y: base + amp * sin(x * freq + phase))) }
                p.addLine(to: CGPoint(x: size.width, y: 0))
                p.closeSubpath()
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: m * 0.02, color: CGColor(gray: 0, alpha: 0.25))
                ctx.addPath(p)
                ctx.setFillColor(cols[i].copy(alpha: 0.85)!)
                ctx.fillPath()
                ctx.restoreGState()
            }
            blur = m * 0.002
        case .dunes:
            linear(ctx, [cols[0], cols[1]], from: CGPoint(x: 0, y: size.height), to: CGPoint(x: 0, y: size.height * 0.4))
            for i in 1 ..< cols.count {
                let top = size.height * (0.72 - CGFloat(i - 1) * 0.17)
                let p = CGMutablePath()
                p.move(to: .zero)
                p.addLine(to: CGPoint(x: 0, y: top + (rnd.next() - 0.5) * size.height * 0.1))
                let c1 = CGPoint(x: size.width * (0.2 + rnd.next() * 0.3), y: top + size.height * (0.08 + rnd.next() * 0.12))
                let c2 = CGPoint(x: size.width * (0.5 + rnd.next() * 0.3), y: top - size.height * (0.05 + rnd.next() * 0.1))
                p.addCurve(to: CGPoint(x: size.width, y: top + (rnd.next() - 0.5) * size.height * 0.1), control1: c1, control2: c2)
                p.addLine(to: CGPoint(x: size.width, y: 0))
                p.closeSubpath()
                ctx.saveGState()
                ctx.addPath(p)
                ctx.clip()
                let lighter = NSColor(cgColor: cols[i])!.blended(withFraction: 0.18, of: .white)!.cgColor
                linear(ctx, [lighter, cols[i]], from: CGPoint(x: 0, y: top + size.height * 0.1), to: CGPoint(x: size.width * 0.3, y: 0))
                ctx.restoreGState()
            }
            blur = m * 0.0015
        case .aurora:
            linear(ctx, [cols[0], NSColor(cgColor: cols[0])!.blended(withFraction: 0.25, of: NSColor(cgColor: cols[1])!)!.cgColor],
                   from: CGPoint(x: 0, y: size.height), to: .zero)
            ctx.setLineCap(.round)
            for i in 0 ..< 5 {
                let c = cols[1 + i % (cols.count - 1)]
                let y0 = size.height * (0.35 + rnd.next() * 0.4)
                let p = CGMutablePath()
                p.move(to: CGPoint(x: -size.width * 0.1, y: y0))
                p.addCurve(to: CGPoint(x: size.width * 1.1, y: size.height * (0.3 + rnd.next() * 0.5)),
                           control1: CGPoint(x: size.width * 0.35, y: y0 + size.height * (rnd.next() - 0.5) * 0.8),
                           control2: CGPoint(x: size.width * 0.7, y: y0 + size.height * (rnd.next() - 0.5) * 0.8))
                ctx.addPath(p)
                ctx.setStrokeColor(c.copy(alpha: 0.55)!)
                ctx.setLineWidth(m * (0.04 + rnd.next() * 0.06))
                ctx.strokePath()
            }
            blur = m * 0.04
        case .conic:
            // Angular gradient as thin wedges; the final blur hides the seams.
            let c = CGPoint(x: size.width * (0.3 + rnd.next() * 0.4), y: size.height * (0.3 + rnd.next() * 0.4)), a0 = rnd.next() * .pi
            let ns = cols.map { NSColor(cgColor: $0)! }, n = 360
            for i in 0 ..< n {
                let t = CGFloat(i) / CGFloat(n) * CGFloat(ns.count - 1), k = min(Int(t), ns.count - 2)
                ctx.setFillColor(ns[k].blended(withFraction: t - CGFloat(k), of: ns[k + 1])!.cgColor)
                let a = a0 + CGFloat(i) / CGFloat(n) * 2 * .pi, b = a + 2 * .pi / CGFloat(n) + 0.004
                ctx.move(to: c)
                ctx.addArc(center: c, radius: m * 1.5, startAngle: a, endAngle: b, clockwise: false)
                ctx.closePath()
                ctx.fillPath()
            }
            let glow = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size.width / 2, y: size.height / 2), startRadius: 0,
                                   endCenter: CGPoint(x: size.width / 2, y: size.height / 2), endRadius: m * 0.6, options: [])
            blur = m * 0.03
        case .radial:
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: cols as CFArray, locations: nil)!
            let c = CGPoint(x: size.width * 0.3, y: size.height * 0.75)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: m * 0.95, options: [.drawsAfterEndLocation])
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.8))
            for _ in 0 ..< 160 { // stars
                let s = 0.5 + rnd.next() * m * 0.0012
                ctx.fillEllipse(in: CGRect(x: rnd.next() * size.width, y: rnd.next() * size.height, width: s, height: s))
            }
        }
        guard let img = ctx.makeImage() else { return nil }
        return blur > 0.5 ? blurred(img, radius: blur) : img
    }

    private static func linear(_ ctx: CGContext, _ c: [CGColor], from a: CGPoint, to b: CGPoint) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: c as CFArray, locations: nil)!
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// 48×30 bitmap where each pixel blends the colours by Gaussian distance to randomly placed control points.
    private static func field(_ cols: [CGColor], _ rnd: inout Rand) -> CGImage? {
        let w = 48, h = 30
        let comps = cols.map { c -> [CGFloat] in
            let n = NSColor(cgColor: c)!.usingColorSpace(.sRGB)!
            return [n.redComponent, n.greenComponent, n.blueComponent]
        }
        var pts: [(CGFloat, CGFloat, Int)] = []
        for i in 0 ..< max(6, cols.count * 2) { pts.append((rnd.next(), rnd.next(), i % cols.count)) }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let u = CGFloat(x) / CGFloat(w - 1), v = CGFloat(y) / CGFloat(h - 1)
                var acc: [CGFloat] = [0, 0, 0], sum: CGFloat = 0
                for (px, py, ci) in pts {
                    let d2 = (u - px) * (u - px) + (v - py) * (v - py)
                    let wt = exp(-d2 / 0.06)
                    for k in 0 ..< 3 { acc[k] += comps[ci][k] * wt }
                    sum += wt
                }
                let i = (y * w + x) * 4
                for k in 0 ..< 3 { bytes[i + k] = UInt8(max(0, min(255, acc[k] / max(sum, 1e-6) * 255))) }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Blur

    private static let ci = CIContext(options: [.cacheIntermediates: false])

    static func blurred(_ img: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: img)
        let f = CIFilter.gaussianBlur()
        f.inputImage = input.clampedToExtent()
        f.radius = Float(radius)
        guard let out = f.outputImage else { return img }
        return ci.createCGImage(out.cropped(to: input.extent), from: input.extent)
    }

    // MARK: Desktop picture

    private static var desktopCache: (URL, CGImage)?
    private static var blurredDesktopCache: (URL, CGImage)?

    static var desktop: CGImage? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        if let c = desktopCache, c.0 == url { return c.1 }
        guard let img = load(url, maxPixels: 3000) else { return nil }
        desktopCache = (url, img)
        return img
    }

    static var blurredDesktop: CGImage? {
        guard let d = desktop, let url = desktopCache?.0 else { return nil }
        if let c = blurredDesktopCache, c.0 == url { return c.1 }
        guard let b = blurred(d, radius: CGFloat(max(d.width, d.height)) * 0.025) else { return nil }
        blurredDesktopCache = (url, b)
        return b
    }

    private static var blurredShotCache: (ObjectIdentifier, CGImage)?

    static func blurredScreenshot(_ img: CGImage) -> CGImage? {
        if let c = blurredShotCache, c.0 == ObjectIdentifier(img) { return c.1 }
        let k = min(1, 1200 / CGFloat(max(img.width, img.height)))
        let small = k < 1 ? img.resized(by: k) ?? img : img
        guard let b = blurred(small, radius: CGFloat(max(small.width, small.height)) * 0.04) else { return nil }
        blurredShotCache = (ObjectIdentifier(img), b)
        return b
    }

    static func load(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
    }

    // MARK: Custom images

    static var customFolder: URL {
        let u = Prefs.supportFolder.appendingPathComponent("Backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// File names of the user's backgrounds, oldest first.
    static func customNames() -> [String] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: customFolder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return urls.sorted { date($0) < date($1) }.map(\.lastPathComponent)
    }

    /// Copies image files into the backgrounds folder; returns the new names.
    @discardableResult
    static func addCustom(_ urls: [URL]) -> [String] {
        urls.compactMap { url in
            guard load(url, maxPixels: 64) != nil else { return nil }
            let name = UUID().uuidString.prefix(8) + "." + (url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased())
            return (try? FileManager.default.copyItem(at: url, to: customFolder.appendingPathComponent(String(name)))) != nil ? String(name) : nil
        }
    }

    static func addCustom(_ img: CGImage) -> String? {
        let name = UUID().uuidString.prefix(8) + ".png"
        guard let data = AnnotateDocument.png(img), (try? data.write(to: customFolder.appendingPathComponent(String(name)))) != nil else { return nil }
        return String(name)
    }

    static func removeCustom(_ name: String) {
        try? FileManager.default.trashItem(at: customFolder.appendingPathComponent(name), resultingItemURL: nil)
        customCache[name] = nil
        thumbCache = thumbCache.filter { $0.key != .custom(name) }
    }

    private static var customCache: [String: CGImage] = [:]

    static func custom(_ name: String) -> CGImage? {
        if let hit = customCache[name] { return hit }
        guard let img = load(customFolder.appendingPathComponent(name), maxPixels: 3000) else { return nil }
        customCache[name] = img
        return img
    }

    // MARK: Lookup

    /// The image behind an image-type fill (nil for none/solid/gradient, or when unavailable).
    static func image(for fill: BackgroundSettings.Fill, screenshot: CGImage?) -> CGImage? {
        switch fill {
        case .builtin(let i): return wallpaper(i)
        case .wallpaper: return desktop
        case .blurredWallpaper: return blurredDesktop
        case .blurredScreenshot: return screenshot.flatMap(blurredScreenshot)
        case .custom(let n): return custom(n)
        case .none, .solid, .gradient: return nil
        }
    }

    private static var thumbCache: [BackgroundSettings.Fill: NSImage] = [:]

    /// Small preview for the background grid.
    static func thumbnail(_ fill: BackgroundSettings.Fill, screenshot: CGImage?) -> NSImage? {
        if fill != .blurredScreenshot, let hit = thumbCache[fill] { return hit }
        let size = CGSize(width: 96, height: 64)
        var cg: CGImage?
        if case .builtin(let i) = fill { cg = wallpaperCache[i] ?? render(wallpapers[i % wallpapers.count], size: CGSize(width: 192, height: 128)) }
        if cg == nil { cg = image(for: fill, screenshot: screenshot) }
        guard let cg else { return nil }
        let img = NSImage(size: size, flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let iw = CGFloat(cg.width), ih = CGFloat(cg.height), k = max(r.width / iw, r.height / ih)
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: r.midX - iw * k / 2, y: r.midY - ih * k / 2, width: iw * k, height: ih * k))
            return true
        }
        if fill != .blurredScreenshot { thumbCache[fill] = img }
        return img
    }
}
