import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Where things go on the canvas, in canvas points (top-left origin).
struct CanvasLayout: Equatable {
    var size: CGSize
    var inner: CGRect      // rounded frame incl. inset
    var content: CGRect    // visible (cropped / extended) canvas
    var imageOrigin: CGPoint // canvas position of the original image's (0,0); annotations are offset by this
}

extension DocState {
    /// Visible canvas in image points: the crop (or the image), grown to fit every annotation when auto-expand is on.
    @MainActor var contentRect: CGRect {
        let base = crop ?? imageRect
        guard expandCanvas, !annotations.isEmpty else { return base }
        return annotations.reduce(base) { $0.union(AnnotateRenderer.bounds($1).insetBy(dx: -4, dy: -4)) }.integral
    }

    /// Everything that could be shown: image, canvas and placed images (the crop tool's full area).
    @MainActor var extent: CGRect {
        annotations.filter { $0.kind == .image }.reduce(imageRect.union(contentRect)) { $0.union($1.rect) }
    }
}

/// The one Core Graphics renderer used for the on-screen canvas and for export, so both are identical.
/// Every entry point expects a context whose user space is canvas points with a top-left origin.
@MainActor
enum AnnotateRenderer {
    // MARK: Layout

    static func layout(_ s: DocState) -> CanvasLayout {
        let c = s.contentRect, bg = s.background
        guard bg.isActive else {
            let r = CGRect(origin: .zero, size: c.size)
            return CanvasLayout(size: c.size, inner: r, content: r, imageOrigin: CGPoint(x: -c.minX, y: -c.minY))
        }
        let p = bg.padding
        var ins = NSEdgeInsets(top: bg.inset, left: bg.inset, bottom: bg.inset, right: bg.inset)
        if bg.autoBalance {
            let b = Geo.balance(ImageAnalysis.uniformMargins(s.image, scale: s.scale, rect: c.intersection(s.imageRect)))
            ins = NSEdgeInsets(top: ins.top + b.top, left: ins.left + b.left, bottom: ins.bottom + b.bottom, right: ins.right + b.right)
        }
        let inner = CGSize(width: c.width + ins.left + ins.right, height: c.height + ins.top + ins.bottom)
        var outer = CGSize(width: inner.width + 2 * p, height: inner.height + 2 * p)
        if let r = bg.ratio.value(custom: bg.customRatio) {
            if outer.width / outer.height < r { outer.width = outer.height * r } else { outer.height = outer.width / r }
        }
        // Keep the export pixel-exact.
        outer = CGSize(width: (outer.width * s.scale).rounded(.up) / s.scale, height: (outer.height * s.scale).rounded(.up) / s.scale)
        var o = Geo.align(inner, in: CGRect(x: p, y: p, width: outer.width - 2 * p, height: outer.height - 2 * p), bg.alignment)
        o = CGPoint(x: (o.x * s.scale).rounded() / s.scale, y: (o.y * s.scale).rounded() / s.scale)
        let innerRect = CGRect(origin: o, size: inner)
        let content = CGRect(x: innerRect.minX + ins.left, y: innerRect.minY + ins.top, width: c.width, height: c.height)
        return CanvasLayout(size: outer, inner: innerRect, content: content,
                            imageOrigin: CGPoint(x: content.minX - c.minX, y: content.minY - c.minY))
    }

    // MARK: Drawing

    /// Draws the whole canvas. `hidingTextOf`: a text annotation being edited in place (its box is drawn, glyphs are not).
    static func draw(_ s: DocState, in ctx: CGContext, hidingTextOf hidden: UUID? = nil) {
        let L = layout(s)
        drawBase(s, L, ctx)
        drawOverlay(s, L, ctx, hidingTextOf: hidden)
    }

    /// Background, shadow and the framed screenshot: everything that doesn't change while annotating.
    static func drawBase(_ s: DocState, _ L: CanvasLayout, _ ctx: CGContext) {
        let bg = s.background
        ctx.interpolationQuality = .high
        if bg.isActive {
            ctx.saveGState()
            ctx.clip(to: CGRect(origin: .zero, size: L.size))
            drawFill(bg.fill, in: CGRect(origin: .zero, size: L.size), screenshot: s.image, ctx)
            ctx.restoreGState()
        }
        ctx.saveGState()
        if bg.isActive, bg.shadow > 0 { setShadow(ctx, blur: 50 * bg.shadow, offset: 12 * bg.shadow, alpha: 0.5 + 0.2 * bg.shadow) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        if bg.isActive {
            let r = min(bg.cornerRadius, L.inner.width / 2, L.inner.height / 2)
            ctx.addPath(CGPath(roundedRect: L.inner, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.clip()
            if L.inner != L.content {
                ctx.setFillColor(edgeColor(s))
                ctx.fill(L.inner)
            }
        }
        ctx.clip(to: L.content)
        drawImage(s.image, in: CGRect(origin: L.imageOrigin, size: s.imageSize), ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Annotations, in original-image coordinates, clipped to the visible canvas.
    static func drawOverlay(_ s: DocState, _ L: CanvasLayout, _ ctx: CGContext, hidingTextOf hidden: UUID? = nil) {
        ctx.saveGState()
        if s.background.isActive {
            let r = min(s.background.cornerRadius, L.inner.width / 2, L.inner.height / 2)
            ctx.addPath(CGPath(roundedRect: L.inner, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.clip()
        }
        ctx.clip(to: L.content)
        ctx.translateBy(x: L.imageOrigin.x, y: L.imageOrigin.y)
        // Placed images sit on the canvas like the screenshot: under everything else.
        for a in s.annotations where a.kind == .image { drawAnnotation(a, s, ctx) }
        for a in s.annotations where a.kind == .redact { drawRedaction(a, s, ctx) }
        let spots = s.annotations.filter { $0.kind == .spotlight }
        if !spots.isEmpty {
            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setFillColor(NSColor.black.withAlphaComponent(s.spotlightOpacity).cgColor)
            ctx.fill(L.content.offsetBy(dx: -L.imageOrigin.x, dy: -L.imageOrigin.y))
            ctx.setBlendMode(.clear)
            for a in spots where a.points.count >= a.minPoints { ctx.addPath(shapePath(a)) }
            ctx.fillPath()
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        for a in s.annotations where ![.redact, .spotlight, .image].contains(a.kind) {
            drawAnnotation(a, s, ctx, hideText: a.id == hidden)
        }
        ctx.restoreGState()
    }

    static func bitmapContext(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    /// Renders `body` into a pixel-exact bitmap of the canvas (canvas points × scale, top-left origin).
    static func render(_ s: DocState, _ L: CanvasLayout, _ body: (CGContext) -> Void) -> CGImage? {
        let w = Int((L.size.width * s.scale).rounded()), h = Int((L.size.height * s.scale).rounded())
        guard let ctx = bitmapContext(w, h) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(max(1, h)))
        ctx.scaleBy(x: s.scale, y: -s.scale)
        body(ctx)
        return ctx.makeImage()
    }

    /// Full-resolution flattened output.
    static func flatten(_ s: DocState) -> Shot {
        let L = layout(s)
        return Shot(image: render(s, L) { draw(s, in: $0) } ?? s.image, scale: s.scale)
    }

    /// CGContext.draw is y-up; this draws upright in our flipped space.
    static func drawImage(_ img: CGImage, in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    /// Shadow offsets/blur are in device space; scale them by the CTM so screen and export match.
    static func setShadow(_ ctx: CGContext, blur: CGFloat, offset: CGFloat, alpha: CGFloat) {
        let k = hypot(ctx.ctm.a, ctx.ctm.b)
        ctx.setShadow(offset: CGSize(width: 0, height: -offset * k), blur: blur * k, color: NSColor.black.withAlphaComponent(alpha).cgColor)
    }

    // MARK: Background fill

    static func drawFill(_ fill: BackgroundSettings.Fill, in r: CGRect, screenshot: CGImage?, _ ctx: CGContext) {
        switch fill {
        case .none: break
        case .solid(let hex):
            ctx.setFillColor(NSColor(hex: hex).cgColor)
            ctx.fill(r)
        case .gradient(let i):
            let g = BackgroundSettings.gradients[i % BackgroundSettings.gradients.count]
            let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: g.map { NSColor(hex: $0).cgColor } as CFArray, locations: nil)!
            // Corner to corner of the stretched unit square — the same geometry as the on-screen CAGradientLayer.
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: r.minY)
            ctx.scaleBy(x: r.width, y: r.height)
            ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 1, y: 1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        default:
            guard let img = Backgrounds.image(for: fill, screenshot: screenshot) else { return drawFill(.gradient(0), in: r, screenshot: nil, ctx) }
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let k = max(r.width / iw, r.height / ih)
            drawImage(img, in: CGRect(x: r.midX - iw * k / 2, y: r.midY - ih * k / 2, width: iw * k, height: ih * k), ctx)
        }
    }

    /// Inset colour = the screenshot's top-left pixel, so the inset blends with the window chrome.
    static func edgeColor(_ s: DocState) -> CGColor {
        let c = s.contentRect.intersection(s.imageRect)
        let px = CGRect(x: (c.minX * s.scale).rounded(), y: (c.minY * s.scale).rounded(), width: 1, height: 1)
        var bytes = [UInt8](repeating: 255, count: 4)
        if let one = s.image.cropping(to: px),
           let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return CGColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
    }

    // MARK: Redaction (Core Image, from what's underneath: the screenshot plus placed images)

    private static let ci = CIContext(options: [.cacheIntermediates: false])
    private static var redactCache: [(key: String, out: CGImage)] = []
    private static var sourceCache: (base: ObjectIdentifier, key: [Annotation], image: CGImage, origin: CGPoint)?

    /// The pixels redaction works on and their origin in image points.
    static func redactionSource(_ s: DocState) -> (CGImage, CGPoint) {
        let imgs = s.annotations.filter { $0.kind == .image }
        guard !imgs.isEmpty else { return (s.image, .zero) }
        if let c = sourceCache, c.base == ObjectIdentifier(s.image), c.key == imgs { return (c.image, c.origin) }
        let r = imgs.reduce(s.imageRect) { $0.union($1.rect) }.integral
        guard let ctx = bitmapContext(Int(r.width * s.scale), Int(r.height * s.scale)) else { return (s.image, .zero) }
        ctx.translateBy(x: 0, y: r.height * s.scale)
        ctx.scaleBy(x: s.scale, y: -s.scale)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        drawImage(s.image, in: s.imageRect, ctx)
        for a in imgs { drawAnnotation(a, s, ctx) }
        guard let img = ctx.makeImage() else { return (s.image, .zero) }
        sourceCache = (ObjectIdentifier(s.image), imgs, img, r.origin)
        return (img, r.origin)
    }

    static func redacted(_ img: CGImage, _ style: RedactStyle, intensity: CGFloat, scale: CGFloat) -> CGImage? {
        let q = (intensity * 20).rounded() / 20
        let key = "\(ObjectIdentifier(img).hashValue)|\(style)|\(q)"
        if let hit = redactCache.first(where: { $0.key == key }) { return hit.out }
        let input = CIImage(cgImage: img)
        func pixellate(_ i: CIImage, _ size: CGFloat) -> CIImage {
            let f = CIFilter.pixellate()
            f.inputImage = i.clampedToExtent()
            f.scale = Float(max(1, size * scale))
            f.center = .zero
            return f.outputImage ?? i
        }
        func blur(_ i: CIImage, _ r: CGFloat) -> CIImage {
            let f = CIFilter.gaussianBlur()
            f.inputImage = i.clampedToExtent()
            f.radius = Float(r * scale)
            return f.outputImage ?? i
        }
        let out: CIImage
        switch style {
        case .pixelate: out = pixellate(input, 5 + 25 * q)
        case .secureBlur: out = blur(pixellate(input, 4 + 12 * q), 4 + 12 * q) // pixelate first so the text can't be recovered
        case .smoothBlur: out = blur(input, 3 + 22 * q)
        case .blackout: return nil
        }
        guard let cg = ci.createCGImage(out.cropped(to: input.extent), from: input.extent) else { return nil }
        redactCache.append((key, cg))
        if redactCache.count > 6 { redactCache.removeFirst() } // ponytail: tiny FIFO; fine for a handful of open editors
        return cg
    }

    static func drawRedaction(_ a: Annotation, _ s: DocState, _ ctx: CGContext) {
        let r = a.rect
        ctx.saveGState()
        ctx.clip(to: r)
        if a.redactStyle == .blackout {
            ctx.setFillColor(.black)
            ctx.fill(r)
        } else {
            let (src, o) = redactionSource(s)
            if let img = redacted(src, a.redactStyle, intensity: a.intensity, scale: s.scale) {
                drawImage(img, in: CGRect(x: o.x, y: o.y, width: CGFloat(src.width) / s.scale, height: CGFloat(src.height) / s.scale), ctx)
            }
        }
        ctx.restoreGState()
    }

    // MARK: Annotations

    static func shapePath(_ a: Annotation) -> CGPath {
        let r = a.rect
        switch a.kind {
        case .ellipse: return CGPath(ellipseIn: r, transform: nil)
        case .spotlight:
            switch a.spotShape {
            case .rectangle: return CGPath(rect: r, transform: nil)
            case .ellipse: return CGPath(ellipseIn: r, transform: nil)
            case .roundedRectangle:
                let k = min(16, r.width / 2, r.height / 2)
                return CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil)
            }
        default:
            let k = min(a.lineWidth * 0.6, r.width / 2, r.height / 2)
            return CGPath(roundedRect: r, cornerWidth: k, cornerHeight: k, transform: nil)
        }
    }

    static func drawAnnotation(_ a: Annotation, _ s: DocState?, _ ctx: CGContext, hideText: Bool = false) {
        guard a.points.count >= a.minPoints else { return }
        let color = NSColor(hex: a.color).cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let shadow = a.shadow && a.kind != .highlighter
        if shadow {
            setShadow(ctx, blur: a.kind == .image ? 14 : 6, offset: a.kind == .image ? 4 : 2, alpha: a.kind == .image ? 0.35 : 0.45)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil) // one shadow for the whole composite (e.g. arrow shaft + head)
        }
        defer { if shadow { ctx.endTransparencyLayer() } }
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.kind {
        case .rectangle, .ellipse:
            ctx.addPath(shapePath(a))
            ctx.strokePath()
        case .filledRectangle:
            ctx.addPath(shapePath(a))
            ctx.fillPath()
        case .line:
            ctx.move(to: a.points[0])
            ctx.addLine(to: a.points[1])
            ctx.strokePath()
        case .arrow:
            drawArrow(a, ctx)
        case .pencil:
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(NSColor(hex: a.color).withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(highlighterWidth(a))
            ctx.setLineCap(.butt)
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()
        case .text:
            drawText(a, ctx, hideGlyphs: hideText)
        case .counter:
            drawCounter(a, ctx)
        case .image:
            if let id = a.assetID, let img = s?.assets[id] { drawImage(img, in: a.rect, ctx) }
        case .redact, .spotlight:
            break
        }
    }

    static func highlighterWidth(_ a: Annotation) -> CGFloat { max(8, a.lineWidth * 3) }

    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count < 3 {
            p.addLine(to: pts.last!)
            return p
        }
        for i in 1 ..< pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i])
        }
        p.addLine(to: pts.last!)
        return p
    }

    // MARK: Arrows

    static func headLength(_ a: Annotation) -> CGFloat { max(12, a.lineWidth * 3 + 8) }

    private static func unit(_ from: CGPoint, _ to: CGPoint) -> CGVector {
        let d = max(0.0001, Geo.dist(from, to))
        return CGVector(dx: (to.x - from.x) / d, dy: (to.y - from.y) / d)
    }

    private static func head(_ ctx: CGContext, tip: CGPoint, dir: CGVector, len: CGFloat) {
        let half = len * 0.5
        let base = CGPoint(x: tip.x - dir.dx * len, y: tip.y - dir.dy * len)
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: base.x - dir.dy * half, y: base.y + dir.dx * half))
        ctx.addLine(to: CGPoint(x: base.x + dir.dy * half, y: base.y - dir.dx * half))
        ctx.closePath()
        ctx.setLineWidth(max(1, len * 0.12))
        ctx.drawPath(using: .fillStroke) // stroke with round joins softens the tip
    }

    static func drawArrow(_ a: Annotation, _ ctx: CGContext) {
        let s = a.points[0], e = a.points[1], hl = headLength(a), w = a.lineWidth
        let d = unit(s, e)
        let back = { (p: CGPoint, v: CGVector, k: CGFloat) in CGPoint(x: p.x - v.dx * k, y: p.y - v.dy * k) }
        switch a.arrowStyle {
        case .standard, .double:
            let start = a.arrowStyle == .double ? back(s, CGVector(dx: -d.dx, dy: -d.dy), hl * 0.6) : s
            ctx.move(to: start)
            ctx.addLine(to: back(e, d, hl * 0.6))
            ctx.strokePath()
            head(ctx, tip: e, dir: d, len: hl)
            if a.arrowStyle == .double { head(ctx, tip: s, dir: CGVector(dx: -d.dx, dy: -d.dy), len: hl) }
        case .fancy:
            // Tapered body: a point at the tail widening into the head.
            let len = Geo.dist(s, e), hlen = min(hl * 1.2, len * 0.6), half = hlen * 0.55
            let base = back(e, d, hlen)
            let neck = back(e, d, hlen * 0.8)
            let n = CGVector(dx: -d.dy, dy: d.dx)
            let p = CGMutablePath()
            p.move(to: s)
            p.addLine(to: CGPoint(x: neck.x + n.dx * w * 0.7, y: neck.y + n.dy * w * 0.7))
            p.addLine(to: CGPoint(x: base.x + n.dx * half, y: base.y + n.dy * half))
            p.addLine(to: e)
            p.addLine(to: CGPoint(x: base.x - n.dx * half, y: base.y - n.dy * half))
            p.addLine(to: CGPoint(x: neck.x - n.dx * w * 0.7, y: neck.y - n.dy * w * 0.7))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setLineWidth(max(1, w * 0.3))
            ctx.drawPath(using: .fillStroke)
        case .curved:
            let c = a.points.count > 2 ? a.points[2] : Geo.defaultControl(s, e)
            let td = unit(c, e)
            ctx.move(to: s)
            ctx.addQuadCurve(to: back(e, td, hl * 0.6), control: c)
            ctx.strokePath()
            head(ctx, tip: e, dir: td, len: hl)
        }
    }

    // MARK: Text

    static func font(_ a: Annotation) -> NSFont {
        let size = max(6, a.fontSize)
        switch a.textStyle {
        case .monospaced, .monospacedBoxed: return .monospacedSystemFont(ofSize: size, weight: .bold)
        case .rounded, .boxedRounded:
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        default: return .systemFont(ofSize: size, weight: .bold)
        }
    }

    static func contrast(_ hex: String) -> NSColor {
        let c = NSColor(hex: hex).usingColorSpace(.sRGB) ?? .black
        if c.alphaComponent < 0.3 { return .black }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.65 ? .black : .white
    }

    static func isBoxed(_ a: Annotation) -> Bool { [.boxed, .monospacedBoxed, .boxedRounded].contains(a.textStyle) }

    static func textColor(_ a: Annotation) -> NSColor { isBoxed(a) ? contrast(a.color) : NSColor(hex: a.color) }

    static func textPadding(_ a: Annotation) -> CGSize {
        switch a.textStyle {
        case .boxed, .monospacedBoxed: return CGSize(width: a.fontSize * 0.35, height: a.fontSize * 0.15)
        case .boxedRounded: return CGSize(width: a.fontSize * 0.55, height: a.fontSize * 0.2)
        default: return .zero
        }
    }

    static func attributed(_ a: Annotation, _ extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: font(a), .foregroundColor: textColor(a)]
        attrs.merge(extra) { $1 }
        return NSAttributedString(string: a.text.isEmpty ? " " : a.text, attributes: attrs)
    }

    static func glyphRect(_ a: Annotation) -> CGRect {
        var str = a.text.isEmpty ? " " : a.text
        if str.hasSuffix("\n") { str += " " } // boundingRect ignores a trailing empty line
        let wrap = a.textWidth.map { max($0, 4) }
        let r = NSAttributedString(string: str, attributes: [.font: font(a)])
            .boundingRect(with: CGSize(width: wrap ?? 100_000, height: 100_000), options: [.usesLineFragmentOrigin])
        let pad = textPadding(a)
        let o = a.points.first ?? .zero
        return CGRect(x: o.x + pad.width, y: o.y + pad.height, width: wrap ?? ceil(max(r.width, 4)), height: ceil(r.height))
    }

    static func textBox(_ a: Annotation) -> CGRect {
        let pad = textPadding(a)
        return glyphRect(a).insetBy(dx: -pad.width, dy: -pad.height)
    }

    static func drawText(_ a: Annotation, _ ctx: CGContext, hideGlyphs: Bool) {
        if isBoxed(a) {
            let box = textBox(a)
            let k = a.textStyle == .boxedRounded ? min(box.height / 2, a.fontSize) : a.fontSize * 0.15
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: k, cornerHeight: k, transform: nil))
            ctx.fillPath()
        }
        guard !hideGlyphs, !a.text.isEmpty else { return }
        let r = glyphRect(a)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        if a.textStyle == .outline {
            attributed(a, [.strokeColor: contrast(a.color), .strokeWidth: 22]).draw(with: r, options: [.usesLineFragmentOrigin])
        }
        attributed(a).draw(with: r, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Counter

    static func counterRadius(_ a: Annotation) -> CGFloat { max(10, a.fontSize * 0.6) }

    static func counterRect(_ a: Annotation) -> CGRect {
        let r = counterRadius(a), c = a.points.first ?? .zero
        return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }

    static func drawCounter(_ a: Annotation, _ ctx: CGContext) {
        let rect = counterRect(a), r = counterRadius(a)
        ctx.fillEllipse(in: rect)
        let label = Geo.counterLabel(a.number, a.counterStyle)
        let size = r * (label.count > 2 ? 0.7 : label.count == 2 ? 0.9 : 1.1)
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        let f = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let str = NSAttributedString(string: label, attributes: [.font: f, .foregroundColor: contrast(a.color)])
        let sz = str.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        str.draw(at: CGPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Bounds & hit-testing (image coordinates)

    static func bounds(_ a: Annotation) -> CGRect {
        guard a.points.count >= a.minPoints else { return .zero }
        switch a.kind {
        case .text: return textBox(a)
        case .counter: return counterRect(a)
        case .rectangle, .ellipse: return a.rect.insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2)
        case .filledRectangle, .redact, .spotlight, .image: return a.rect
        case .line, .arrow, .pencil, .highlighter:
            var pts = a.points
            if a.kind == .arrow, a.arrowStyle == .curved, pts.count == 2 { pts.append(Geo.defaultControl(pts[0], pts[1])) }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let w = a.kind == .highlighter ? highlighterWidth(a) : a.kind == .arrow ? max(a.lineWidth, headLength(a)) : a.lineWidth
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -w / 2, dy: -w / 2)
        }
    }

    /// Strict hit: outlines are hit on their stroke, filled things anywhere inside. `tol` in image points.
    static func hitTest(_ a: Annotation, _ p: CGPoint, tol: CGFloat) -> Bool {
        guard a.points.count >= a.minPoints else { return false }
        let band = a.lineWidth / 2 + tol
        switch a.kind {
        case .rectangle, .ellipse:
            let r = a.rect, outer = r.insetBy(dx: -band, dy: -band), inner = r.insetBy(dx: band, dy: band)
            if a.kind == .rectangle { return outer.contains(p) && (inner.isEmpty || !inner.contains(p)) }
            return CGPath(ellipseIn: outer, transform: nil).contains(p) && (inner.isEmpty || !CGPath(ellipseIn: inner, transform: nil).contains(p))
        case .filledRectangle, .redact, .spotlight, .image:
            return a.rect.insetBy(dx: -tol, dy: -tol).contains(p)
        case .line:
            return Geo.distToSegment(p, a.points[0], a.points[1]) <= band
        case .arrow:
            if a.arrowStyle == .curved {
                let c = a.points.count > 2 ? a.points[2] : Geo.defaultControl(a.points[0], a.points[1])
                let pts = (0 ... 24).map { Geo.quad(a.points[0], c, a.points[1], CGFloat($0) / 24) }
                return Geo.distToPolyline(p, pts) <= band + 2
            }
            return Geo.distToSegment(p, a.points[0], a.points[1]) <= max(band, headLength(a) / 2 + tol)
        case .pencil:
            return Geo.distToPolyline(p, a.points) <= band
        case .highlighter:
            return Geo.distToPolyline(p, a.points) <= highlighterWidth(a) / 2 + tol
        case .text, .counter:
            return bounds(a).insetBy(dx: -tol, dy: -tol).contains(p)
        }
    }
}
