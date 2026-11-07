import AppKit
import CoreGraphics
import CoreText

/// Cursor skins, click ripples and keystroke badges, drawn in code and cached as CGImages.
enum StudioSprites {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CGImage] = [:]

    private static func cached(_ key: String, _ make: () -> CGImage?) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        guard let img = make() else { return nil }
        if cache.count > 400 { cache.removeAll() }
        cache[key] = img
        return img
    }

    static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: Cursor

    /// Classic arrow outline in a 16×24 unit box, top-left origin, tip at (1,1).
    private static func arrowPath(rounded: Bool) -> CGPath {
        let p = CGMutablePath()
        let pts: [CGPoint] = [(1, 1), (1, 17.5), (5, 13.8), (7.6, 20), (10.4, 18.8), (7.9, 12.8), (13, 12.8)].map { CGPoint(x: $0.0, y: $0.1) }
        if rounded {
            let n = pts.count
            p.move(to: CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2))
            for i in 0..<n { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: i == 0 ? 0.6 : 1.1) }
            p.closeSubpath()
        } else {
            p.addLines(between: pts)
            p.closeSubpath()
        }
        return p
    }

    /// Unit box size and hotspot (in units, top-left origin) for each style.
    static func metrics(_ s: CursorStyle) -> (size: CGSize, hotspot: CGPoint) {
        switch s {
        case .macOS, .modern, .inverted, .bold, .color: return (CGSize(width: 16, height: 24), CGPoint(x: 1, y: 1))
        case .touch, .ring: return (CGSize(width: 24, height: 24), CGPoint(x: 12, y: 12))
        case .dot: return (CGSize(width: 14, height: 14), CGPoint(x: 7, y: 7))
        }
    }

    /// Cursor image whose unit box is `unit` pixels per cursor point. Hotspot in pixels, top-left origin.
    static func cursor(_ style: CursorStyle, unit: CGFloat) -> (image: CGImage, hotspot: CGPoint)? {
        let u = max(0.25, (unit * 4).rounded() / 4)
        let m = metrics(style)
        let pad: CGFloat = 4   // room for the shadow, in units
        let w = Int(ceil((m.size.width + pad * 2) * u)), h = Int(ceil((m.size.height + pad * 2) * u))
        guard let img = cached("cur-\(style.rawValue)-\(u)", {
            guard let ctx = context(w, h) else { return nil }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: u, y: -u)              // unit space, top-left origin
            ctx.translateBy(x: pad, y: pad)
            draw(style, ctx)
            return ctx.makeImage()
        }) else { return nil }
        return (img, CGPoint(x: (m.hotspot.x + pad) * u, y: (m.hotspot.y + pad) * u))
    }

    private static func draw(_ style: CursorStyle, _ ctx: CGContext) {
        let shadow = CGColor(gray: 0, alpha: 0.35)
        switch style {
        case .macOS, .inverted, .modern, .bold, .color:
            let path = arrowPath(rounded: style == .modern || style == .color)
            let fill = style == .inverted ? CGColor(gray: 1, alpha: 1)
                : style == .color ? NSColor(hex: "#3E7BFA").cgColor
                : CGColor(gray: style == .modern ? 0.1 : 0, alpha: 1)
            let stroke = style == .inverted ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.8), blur: 2.2, color: shadow)
            ctx.addPath(path)
            ctx.setLineWidth(style == .bold ? 3.2 : style == .modern || style == .color ? 2.2 : 1.6)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(stroke)
            ctx.strokePath()
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
        case .touch:
            let r = CGRect(x: 2, y: 2, width: 20, height: 20)
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: shadow)
            ctx.setFillColor(CGColor(gray: 0.55, alpha: 0.55))
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: r.insetBy(dx: 0.75, dy: 0.75))
        case .ring:
            // A hollow ring: a dark outer edge under a white band.
            let r = CGRect(x: 3, y: 3, width: 18, height: 18)
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: shadow)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.55))
            ctx.setLineWidth(4)
            ctx.strokeEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(2.2)
            ctx.strokeEllipse(in: r)
        case .dot:
            let r = CGRect(x: 1.5, y: 1.5, width: 11, height: 11)
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: shadow)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
            ctx.fillEllipse(in: r.insetBy(dx: 2, dy: 2))
        }
    }

    /// Preview image for the sidebar's style buttons.
    static func cursorPreview(_ style: CursorStyle) -> NSImage {
        guard let c = cursor(style, unit: 4) else { return NSImage() }
        return NSImage(cgImage: c.image, size: CGSize(width: c.image.width / 2, height: c.image.height / 2))
    }

    // MARK: Click ripple

    static let rippleSize = 160

    static func ripple(_ color: ClickColor, filled: Bool) -> CGImage? {
        cached("ripple-\(color.rawValue)-\(filled)") {
            let s = CGFloat(rippleSize)
            guard let ctx = context(rippleSize, rippleSize) else { return nil }
            let c = NSColor(hex: color.hex).cgColor
            let r = CGRect(x: 0, y: 0, width: s, height: s)
            if filled {
                ctx.setFillColor(c.copy(alpha: 0.45)!)
                ctx.fillEllipse(in: r.insetBy(dx: 2, dy: 2))
            } else {
                ctx.setStrokeColor(c)
                ctx.setLineWidth(s * 0.07)
                ctx.strokeEllipse(in: r.insetBy(dx: s * 0.05, dy: s * 0.05))
                ctx.setFillColor(c.copy(alpha: 0.18)!)
                ctx.fillEllipse(in: r.insetBy(dx: s * 0.05, dy: s * 0.05))
            }
            return ctx.makeImage()
        }
    }

    // MARK: Keystroke badge

    static func badge(_ text: String, light: Bool, fontSize: CGFloat) -> CGImage? {
        let fs = max(6, fontSize.rounded())
        return cached("key-\(text)-\(light)-\(fs)") {
            let font = CTFontCreateUIFontForLanguage(.system, fs, nil) ?? CTFontCreateWithName("Helvetica" as CFString, fs, nil)
            let bold = CTFontCreateCopyWithSymbolicTraits(font, fs, nil, .traitBold, .traitBold) ?? font
            let fg = light ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1)
            let attr = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): bold,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): fg,
                NSAttributedString.Key(kCTKernAttributeName as String): fs * 0.04,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let tw = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let padX = fs * 0.75, padY = fs * 0.5, shadow = fs * 0.4
            let w = tw + padX * 2, h = ascent + descent + padY * 2
            guard let ctx = context(Int(ceil(w + shadow * 2)), Int(ceil(h + shadow * 2))) else { return nil }
            let r = CGRect(x: shadow, y: shadow, width: w, height: h)
            let path = CGPath(roundedRect: r, cornerWidth: h * 0.28, cornerHeight: h * 0.28, transform: nil)
            ctx.setShadow(offset: CGSize(width: 0, height: -fs * 0.08), blur: shadow * 0.8, color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(path)
            ctx.setFillColor(light ? CGColor(gray: 1, alpha: 0.94) : CGColor(gray: 0.08, alpha: 0.82))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(path)
            ctx.setStrokeColor(light ? CGColor(gray: 0, alpha: 0.12) : CGColor(gray: 1, alpha: 0.14))
            ctx.setLineWidth(1)
            ctx.strokePath()
            ctx.textPosition = CGPoint(x: r.minX + padX, y: r.minY + padY + descent)
            CTLineDraw(line, ctx)
            return ctx.makeImage()
        }
    }
}
