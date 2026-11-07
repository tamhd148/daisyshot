import AppKit
import QuartzCore

/// On-screen base of the canvas — background fill, shadow, rounded frame, inset colour and the screenshot — built from
/// Core Animation layers so the GPU composites it. Dragging padding / inset / corners / shadow only moves layers;
/// nothing is re-rendered on the CPU. Export still goes through `AnnotateRenderer` (Core Graphics), which draws the same thing.
final class BaseLayerView: NSView {
    private let root = CALayer()
    private let fill = CALayer()
    private let gradient = CAGradientLayer()
    private let frameHost = CALayer()   // carries the shadow
    private let frameClip = CALayer()   // rounded corners, inset colour
    private let content = CALayer()     // visible canvas (crop), checkerboard when there's no background
    private let image = CALayer()
    private var key: String?
    private var fillImage: CGImage?
    private var shownImage: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root                 // layer-hosting: we own the tree
        wantsLayer = true
        root.isGeometryFlipped = true
        root.masksToBounds = true
        fill.masksToBounds = true
        fill.contentsGravity = .resizeAspectFill
        gradient.startPoint = .zero
        gradient.endPoint = CGPoint(x: 1, y: 1)
        frameClip.masksToBounds = true
        frameClip.cornerCurve = .circular
        content.masksToBounds = true
        image.contentsGravity = .resize
        image.minificationFilter = .trilinear
        frameHost.shadowColor = NSColor.black.cgColor
        for l in [fill, gradient, frameHost] { root.addSublayer(l) }
        frameHost.addSublayer(frameClip)
        frameClip.addSublayer(content)
        content.addSublayer(image)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        for l in [root, fill, gradient, frameHost, frameClip, content, image] { l.contentsScale = s }
    }

    private static let checker: CGColor = {
        let img = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { r in
            NSColor(white: 0.97, alpha: 1).setFill(); r.fill()
            NSColor(white: 0.86, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: 8, height: 8).fill(); CGRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: img).cgColor
    }()

    /// Cheap when nothing changed (keyed); otherwise only layer geometry/properties are touched.
    @MainActor
    func update(_ s: DocState, _ L: CanvasLayout, zoom: CGFloat) {
        let bg = s.background
        let k = "\(ObjectIdentifier(s.image).hashValue)|\(L.size)|\(L.inner)|\(L.content)|\(L.imageOrigin)|\(String(describing: bg))|\(zoom >= 2)"
        guard k != key else { return }
        key = k
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let full = CGRect(origin: .zero, size: L.size)
        fill.frame = full
        gradient.frame = full
        fill.isHidden = true
        gradient.isHidden = true
        if bg.isActive {
            switch bg.fill {
            case .none: break
            case .solid(let hex):
                fill.contents = nil
                fill.backgroundColor = NSColor(hex: hex).cgColor
                fill.isHidden = false
            case .gradient(let i):
                let g = BackgroundSettings.gradients[i % BackgroundSettings.gradients.count]
                gradient.colors = g.map { NSColor(hex: $0).cgColor }
                gradient.isHidden = false
            default:
                if let img = Backgrounds.image(for: bg.fill, screenshot: s.image) {
                    if fillImage !== img { fillImage = img; fill.contents = img }
                    fill.backgroundColor = nil
                    fill.isHidden = false
                } else {
                    gradient.colors = BackgroundSettings.gradients[0].map { NSColor(hex: $0).cgColor }
                    gradient.isHidden = false
                }
            }
        }

        let r = bg.isActive ? min(bg.cornerRadius, L.inner.width / 2, L.inner.height / 2) : 0
        frameHost.frame = L.inner
        frameClip.frame = CGRect(origin: .zero, size: L.inner.size)
        frameClip.cornerRadius = r
        frameClip.backgroundColor = bg.isActive && L.inner != L.content ? AnnotateRenderer.edgeColor(s) : nil
        if bg.isActive, bg.shadow > 0 {
            // Same look as AnnotateRenderer.drawBase (CG blur ≈ 2 × CA radius). A path is much cheaper for the GPU, but only
            // matches when the framed area is opaque; transparent window corners get a shadow from the real alpha instead.
            frameHost.shadowOpacity = Float(0.5 + 0.2 * bg.shadow)
            frameHost.shadowRadius = 25 * bg.shadow
            frameHost.shadowOffset = CGSize(width: 0, height: 12 * bg.shadow)
            let opaque = L.inner != L.content || Self.isOpaque(s.image)
            frameHost.shadowPath = opaque ? CGPath(roundedRect: frameClip.frame, cornerWidth: r, cornerHeight: r, transform: nil) : nil
        } else {
            frameHost.shadowOpacity = 0
            frameHost.shadowPath = nil
        }

        content.frame = L.content.offsetBy(dx: -L.inner.minX, dy: -L.inner.minY)
        content.backgroundColor = bg.isActive ? nil : Self.checker
        if shownImage !== s.image { shownImage = s.image; image.contents = s.image }
        image.frame = CGRect(x: L.imageOrigin.x - L.content.minX, y: L.imageOrigin.y - L.content.minY,
                             width: s.imageSize.width, height: s.imageSize.height)
        image.magnificationFilter = zoom >= 2 ? .nearest : .linear
    }

    /// Screenshots usually carry an alpha channel even when fully opaque; window shots have transparent corners.
    private static var opaqueCache: (ObjectIdentifier, Bool)?

    @MainActor
    private static func isOpaque(_ img: CGImage) -> Bool {
        if let c = opaqueCache, c.0 == ObjectIdentifier(img) { return c.1 }
        var opaque = true
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: break
        default:
            let w = img.width, h = img.height
            for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w / 2, 0), (0, h / 2)] {
                var px: UInt8 = 0
                guard let one = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
                      let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { continue }
                ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                if px < 250 { opaque = false; break }
            }
        }
        opaqueCache = (ObjectIdentifier(img), opaque)
        return opaque
    }
}

/// Transparent view above the base that draws annotations and editing chrome (the canvas forwards its drawing here).
final class CanvasOverlayView: NSView {
    weak var canvas: AnnotateCanvas?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { canvas?.drawContent(dirtyRect) }
}
