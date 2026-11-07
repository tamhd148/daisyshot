import AppKit

/// A text style drawn by the real renderer (box, outline, font…), for the style menu and its dropdown label.
@MainActor
enum TextStylePreview {
    private static var cache: [String: NSImage] = [:]

    /// `backdrop`: a mid-grey chip behind the text (in menus), so light outlines and boxes read clearly.
    static func image(_ style: TextStyle, text: String, color: String, size: CGFloat, backdrop: Bool = false) -> NSImage {
        let key = "\(style.rawValue)|\(text)|\(color)|\(size)|\(backdrop)"
        if let hit = cache[key] { return hit }
        var a = Annotation(kind: .text, points: [.zero, .zero], color: color, lineWidth: 1, shadow: false, fontSize: size)
        a.text = text
        a.textStyle = style
        let box = AnnotateRenderer.textBox(a).integral, scale: CGFloat = 2, m: CGFloat = backdrop ? 5 : 2
        let w = Int((box.width + 2 * m) * scale), h = Int((box.height + 2 * m) * scale)
        guard let ctx = AnnotateRenderer.bitmapContext(w, h) else { return NSImage() }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        if backdrop {
            ctx.setFillColor(NSColor(white: 0.58, alpha: 1).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: box.width + 2 * m, height: box.height + 2 * m), cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }
        ctx.translateBy(x: m - box.minX, y: m - box.minY)
        AnnotateRenderer.drawAnnotation(a, nil, ctx)
        guard let cg = ctx.makeImage() else { return NSImage() }
        let img = NSImage(cgImage: cg, size: CGSize(width: box.width + 2 * m, height: box.height + 2 * m))
        cache[key] = img
        if cache.count > 64 { cache.removeAll() }
        return img
    }
}
