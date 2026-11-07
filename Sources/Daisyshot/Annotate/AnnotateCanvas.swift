import AppKit
import Carbon.HIToolbox

/// The document view inside the editor's scroll view. Its bounds are canvas points (flipped), so the scroll view's
/// magnification is the zoom. Drawing goes through AnnotateRenderer (base layer cached); this view adds chrome and input.
final class AnnotateCanvas: NSView, NSTextViewDelegate {
    unowned let editor: AnnotateEditor

    private enum Drag {
        case create(UUID, origin: CGPoint, snapText: Bool)
        case move(UUID, last: CGPoint)
        case handle(UUID, Int, original: Annotation)
        case cropNew(origin: CGPoint)
        case cropMove(last: CGPoint)
        case cropHandle(Int, original: CGRect)
        case pan(last: NSPoint)
    }

    private var drag: Drag?
    /// ⌥-drag duplicate in progress: dropped again if the mouse never moved.
    private var pendingDuplicate: (copy: UUID, original: UUID, start: CGPoint)?
    private(set) var textView: NSTextView?
    private(set) var editingID: UUID?
    private var spaceDown = false
    private var hover: UUID? { didSet { if hover != oldValue { needsDisplay = true } } }
    private var snapLines: (x: CGFloat?, y: CGFloat?) = (nil, nil)

    /// GPU-composited background/frame/screenshot, and the transparent view that draws annotations on top.
    private let base = BaseLayerView()
    private let overlay = CanvasOverlayView()

    init(editor: AnnotateEditor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        for v in [base, overlay] as [NSView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        overlay.canvas = self
    }

    /// All of the canvas's own drawing happens in the overlay view (above the layer-based base).
    override var needsDisplay: Bool {
        get { overlay.needsDisplay }
        set { overlay.needsDisplay = newValue }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) { overlay.setNeedsDisplay(invalidRect) }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// The in-place text view is a little wider than the text (room to type), so it would swallow clicks on the
    /// edited text's handles: those go to the canvas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let id = editingID, let a = editor.annotation(id) {
            let local = convert(point, from: superview), o = layout.imageOrigin
            if handleIndex(handles(a), CGPoint(x: local.x - o.x, y: local.y - o.y)) != nil { return self }
        }
        return super.hitTest(point)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var layout: CanvasLayout { AnnotateRenderer.layout(editor.displayState) }
    private var zoom: CGFloat { enclosingScrollView?.magnification ?? 1 }
    private var tol: CGFloat { 5 / zoom }

    private func imagePoint(_ e: NSEvent) -> CGPoint { imagePoint(window: e.locationInWindow) }

    private func imagePoint(window w: NSPoint) -> CGPoint {
        let v = convert(w, from: nil), o = layout.imageOrigin
        return CGPoint(x: v.x - o.x, y: v.y - o.y)
    }

    /// Called whenever the document, tool or selection changes.
    func refresh() {
        let s = editor.displayState, L = AnnotateRenderer.layout(s)
        if frame.size != L.size { setFrameSize(L.size) }
        base.update(s, L, zoom: zoom)
        syncTextView()
        needsDisplay = true
    }

    /// Magnification changed: pixel-exact sampling when zoomed in.
    func zoomDidChange() {
        base.update(editor.displayState, layout, zoom: zoom)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    // MARK: Drawing

    func drawContent(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = editor.displayState, L = AnnotateRenderer.layout(s)
        ctx.interpolationQuality = .high
        AnnotateRenderer.drawOverlay(s, L, ctx, hidingTextOf: editingID)
        ctx.saveGState()
        ctx.translateBy(x: L.imageOrigin.x, y: L.imageOrigin.y)
        if editor.tool == .crop, let c = editor.pendingCrop {
            drawCropChrome(c, area: s.contentRect, ctx)
        } else {
            if let h = hover, h != editor.selection, let a = editor.annotation(h) { drawHover(a, ctx) }
            if let a = editor.selected, editingID != a.id || a.kind == .text { drawSelection(a, ctx) }
            drawSnapGuides(L, ctx)
            editor.autoRedact.drawPreview(ctx, zoom: zoom)
        }
        ctx.restoreGState()
    }

    private func handles(_ a: Annotation) -> [CGPoint] {
        guard a.points.count >= a.minPoints else { return [] }
        if a.kind == .text {
            // Left / right edges set the wrapping width; the bottom-right corner scales the text.
            let b = AnnotateRenderer.textBox(a).insetBy(dx: -Self.textInset / zoom, dy: -Self.textInset / zoom)
            return [CGPoint(x: b.minX, y: b.midY), CGPoint(x: b.maxX, y: b.midY), CGPoint(x: b.maxX, y: b.maxY)]
        }
        if a.isRectLike { return Geo.handles(a.rect) }
        if a.isLineLike {
            var h = [a.points[0], a.points[1]]
            if a.kind == .arrow, a.arrowStyle == .curved { h.append(a.points.count > 2 ? a.points[2] : Geo.defaultControl(a.points[0], a.points[1])) }
            return h
        }
        return []
    }

    private func drawHandle(_ p: CGPoint, _ ctx: CGContext, square: Bool = false, accent: Bool = false) {
        let s = (square ? 10 : 9) / zoom
        let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(accent ? NSColor.controlAccentColor.cgColor : .white)
        ctx.setStrokeColor(accent ? CGColor.white : NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5 / zoom)
        ctx.addPath(square ? CGPath(roundedRect: r, cornerWidth: 2 / zoom, cornerHeight: 2 / zoom, transform: nil) : CGPath(ellipseIn: r, transform: nil))
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    private func outline(_ a: Annotation) -> CGRect {
        a.isRectLike ? a.rect : AnnotateRenderer.bounds(a).insetBy(dx: -3 / zoom, dy: -3 / zoom)
    }

    private func drawHover(_ a: Annotation, _ ctx: CGContext) {
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(1 / zoom)
        ctx.stroke(outline(a))
    }

    /// Gap between a text box and its selection frame (screen points).
    private static let textInset: CGFloat = 6

    private func drawSelection(_ a: Annotation, _ ctx: CGContext) {
        if a.kind == .text {
            let b = AnnotateRenderer.textBox(a).insetBy(dx: -Self.textInset / zoom, dy: -Self.textInset / zoom)
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(2 / zoom)
            ctx.addPath(CGPath(roundedRect: b, cornerWidth: 6 / zoom, cornerHeight: 6 / zoom, transform: nil))
            ctx.strokePath()
            let hs = handles(a)
            drawHandle(hs[0], ctx, accent: true)
            drawHandle(hs[1], ctx, accent: true)
            drawHandle(hs[2], ctx, square: true, accent: true)
            return
        }
        if !a.isLineLike {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1 / zoom)
            ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
            ctx.stroke(outline(a))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        for (i, p) in handles(a).enumerated() { drawHandle(p, ctx, accent: i == 2 && a.kind == .arrow) }
    }

    private func drawSnapGuides(_ L: CanvasLayout, _ ctx: CGContext) {
        guard snapLines.x != nil || snapLines.y != nil else { return }
        let area = L.content.offsetBy(dx: -L.imageOrigin.x, dy: -L.imageOrigin.y)
        ctx.setLineWidth(1 / zoom)
        if let x = snapLines.x {
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: area.minY), CGPoint(x: x, y: area.maxY)])
        }
        if let y = snapLines.y {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.strokeLineSegments(between: [CGPoint(x: area.minX, y: y), CGPoint(x: area.maxX, y: y)])
        }
    }

    private func drawCropChrome(_ c: CGRect, area: CGRect, _ ctx: CGContext) {
        let dim = CGMutablePath()
        dim.addRect(area)
        dim.addRect(c)
        ctx.addPath(dim)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(1 / zoom)
        for i in 1 ... 2 {
            let x = c.minX + c.width * CGFloat(i) / 3, y = c.minY + c.height * CGFloat(i) / 3
            ctx.strokeLineSegments(between: [CGPoint(x: x, y: c.minY), CGPoint(x: x, y: c.maxY), CGPoint(x: c.minX, y: y), CGPoint(x: c.maxX, y: y)])
        }
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(1.5 / zoom)
        ctx.stroke(c)
        Geo.handles(c).forEach { drawHandle($0, ctx, square: true) }
        drawSnapGuides(CanvasLayout(size: .zero, inner: .zero, content: area, imageOrigin: .zero), ctx)
        // Size badge.
        let k = editor.doc.scale
        let label = "\(Int((c.width * k).rounded())) × \(Int((c.height * k).rounded()))"
        let str = NSAttributedString(string: label, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11 / zoom, weight: .medium), .foregroundColor: NSColor.white])
        let sz = str.size(), pad = 5 / zoom
        var badge = CGRect(x: c.midX - sz.width / 2 - pad, y: c.maxY + 8 / zoom, width: sz.width + 2 * pad, height: sz.height + pad)
        if badge.maxY > area.maxY { badge.origin.y = c.maxY - badge.height - 8 / zoom }
        ctx.addPath(CGPath(roundedRect: badge, cornerWidth: badge.height / 2, cornerHeight: badge.height / 2, transform: nil))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        str.draw(at: CGPoint(x: badge.minX + pad, y: badge.minY + pad / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Hit-testing

    private func handleIndex(_ hs: [CGPoint], _ p: CGPoint) -> Int? {
        hs.indices.first { Geo.dist(hs[$0], p) <= 8 / zoom }
    }

    private func topmost(_ p: CGPoint) -> Annotation? {
        let all = editor.doc.annotations
        // Placed images are drawn below everything else, so they're hit last.
        return all.reversed().first { $0.kind != .image && AnnotateRenderer.hitTest($0, p, tol: tol) }
            ?? all.reversed().first { $0.kind == .image && AnnotateRenderer.hitTest($0, p, tol: tol) }
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        if let id = editingID {
            // The edited text's own handles still work (resize while typing); any other click commits the text.
            if let a = editor.annotation(id), let h = handleIndex(handles(a), imagePoint(e)) {
                drag = .handle(id, h, original: a)
                return
            }
            endEditing()
            return
        }
        window?.makeFirstResponder(self)
        if spaceDown { drag = .pan(last: e.locationInWindow); NSCursor.closedHand.set(); return }
        let p = imagePoint(e)

        if editor.tool == .crop {
            guard let c = editor.pendingCrop else { return }
            if let h = handleIndex(Geo.handles(c), p) { drag = .cropHandle(h, original: c) } else if c.contains(p) { drag = .cropMove(last: p) } else { drag = .cropNew(origin: p) }
            return
        }

        if editor.autoRedact.toggle(at: p) { return }
        let hit = topmost(p)
        if let hit, hit.kind == .text, e.clickCount == 2 {
            editor.selection = hit.id
            beginEditing(hit.id)
            return
        }
        if let sel = editor.selected, let h = handleIndex(handles(sel), p) {
            editor.beginChange()
            drag = .handle(sel.id, h, original: sel)
            return
        }
        // Any tool picks up an existing mark and moves it (double-click text to edit); ⌥-drag moves a copy instead.
        if let hit, grabbable(hit) {
            editor.beginChange()
            var target = hit
            if e.modifierFlags.contains(.option) {
                target.id = UUID()
                if target.kind == .counter { target.number = editor.nextCounter() }
                editor.doc.annotations.append(target)
                pendingDuplicate = (target.id, hit.id, p)
                NSCursor.dragCopy.set()
            } else {
                NSCursor.closedHand.set()
            }
            editor.selection = target.id
            drag = .move(target.id, last: p)
            return
        }
        if editor.tool == .move { editor.selection = nil; return }
        guard let kind = editor.tool.kind else { return }
        let a = editor.newAnnotation(kind, at: p)
        editor.beginChange()
        editor.doc.annotations.append(a)
        editor.selection = a.id
        switch kind {
        case .text: beginEditing(a.id)
        case .counter: drag = .move(a.id, last: p)
        default:
            let onText = kind == .highlighter && (ImageAnalysis.textLines(editor.doc.image, scale: editor.doc.scale)?.contains { $0.rect.insetBy(dx: -4, dy: -3).contains(p) } ?? false)
            drag = .create(a.id, origin: p, snapText: onText)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = imagePoint(e)
        let shift = e.modifierFlags.contains(.shift), option = e.modifierFlags.contains(.option), command = e.modifierFlags.contains(.command)
        switch drag {
        case let .create(id, origin, snapText):
            editor.update(id) { a in
                switch a.kind {
                case .line, .arrow:
                    let end = shift ? Geo.snap45(origin, p) : p
                    let flip = a.kind == .arrow && (Prefs.bool(.annotateInverseArrow) != option) // ⌥ flips arrow direction
                    a.points = flip ? [end, origin] : [origin, end]
                    if a.kind == .arrow, a.arrowStyle == .curved { a.points.append(Geo.defaultControl(a.points[0], a.points[1])) }
                case .highlighter where snapText:
                    if let lines = ImageAnalysis.textLines(editor.doc.image, scale: editor.doc.scale),
                       let s = ImageAnalysis.snapHighlight(lines, from: origin, to: p) {
                        a.points = [s.0, s.1]
                        a.lineWidth = s.height / 3
                    }
                case .pencil, .highlighter:
                    if shift { a.points = [origin, Geo.snap45(origin, p)] } else if Geo.dist(a.points.last!, p) > 1.5 / zoom { a.points.append(p) }
                default:
                    a.points = [origin, shift ? Geo.square(origin, p) : p]
                }
            }
        case let .move(id, last):
            var d = CGVector(dx: p.x - last.x, dy: p.y - last.y)
            if let a = editor.annotation(id) { d = snapMove(a, d, enabled: !command) }
            editor.update(id) { $0.offset(by: d) }
            drag = .move(id, last: CGPoint(x: last.x + d.dx, y: last.y + d.dy))
        case let .handle(id, h, original) where original.kind == .text:
            let box = AnnotateRenderer.textBox(original), pad = AnnotateRenderer.textPadding(original)
            let minWidth = max(original.fontSize, 12)
            editor.update(id) { a in
                switch h {
                case 0: // left edge: right edge stays put
                    let w = max(minWidth, box.maxX - p.x - 2 * pad.width)
                    a.textWidth = w
                    a.points[0].x = box.maxX - w - 2 * pad.width
                case 1: // right edge
                    a.textWidth = max(minWidth, p.x - box.minX - 2 * pad.width)
                default: // corner: scale the text from its top-left
                    let k = max((p.x - box.minX) / max(box.width, 1), (p.y - box.minY) / max(box.height, 1))
                    let size = min(max(original.fontSize * k, 6), 1000)
                    let f = size / original.fontSize
                    a.fontSize = size
                    a.textWidth = original.textWidth.map { $0 * f }
                }
            }
            syncTextView()
        case let .handle(id, h, original):
            editor.update(id) { a in
                if original.isRectLike {
                    let keep = (original.kind == .image) != shift
                    let r = keep ? Geo.resizeKeepingRatio(original.rect, handle: h, to: p) : Geo.resize(original.rect, handle: h, to: p)
                    a.points = [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
                } else {
                    if h == 2, a.points.count == 2 { a.points.append(p) }
                    let anchor = h < 2 ? a.points[1 - h] : nil
                    a.points[h] = shift && anchor != nil ? Geo.snap45(anchor!, p) : p
                }
            }
        case let .cropNew(origin):
            let q = snapCropPoint(p, command: command)
            editor.pendingCrop = constrainCrop(Geo.rect(origin, q), anchor: origin)
        case let .cropMove(last):
            guard var c = editor.pendingCrop else { return }
            let area = editor.doc.extent
            c.origin.x = min(max(area.minX, c.minX + p.x - last.x), area.maxX - c.width)
            c.origin.y = min(max(area.minY, c.minY + p.y - last.y), area.maxY - c.height)
            editor.pendingCrop = c
            drag = .cropMove(last: p)
        case let .cropHandle(h, o):
            let q = snapCropPoint(p, command: command, handle: h)
            editor.pendingCrop = constrainCrop(Geo.resize(o, handle: h, to: q), anchor: Geo.opposite(o, handle: h), vertical: h == 4 || h == 6)
        case let .pan(last):
            guard let clip = enclosingScrollView?.contentView else { return }
            var o = clip.bounds.origin
            o.x -= (e.locationInWindow.x - last.x) / zoom
            o.y += (e.locationInWindow.y - last.y) / zoom
            clip.scroll(to: o)
            enclosingScrollView?.reflectScrolledClipView(clip)
            drag = .pan(last: e.locationInWindow)
        case nil:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        switch drag {
        case let .create(id, _, _):
            if let a = editor.annotation(id), tooSmall(a) {
                editor.doc.annotations.removeAll { $0.id == id }
                editor.selection = nil
            } else if let a = editor.annotation(id), a.kind == .pencil || a.kind == .highlighter, a.points.count > 3, Prefs.bool(.annotateSmoothDrawing) {
                editor.update(id) { $0.points = Geo.smooth($0.points, radius: 3) }
            }
            editor.endChange()
        case .move, .handle:
            if let d = pendingDuplicate, Geo.dist(d.start, imagePoint(e)) < 2 / zoom {
                // ⌥-click without dragging: no copy.
                editor.doc.annotations.removeAll { $0.id == d.copy }
                editor.selection = d.original
            }
            pendingDuplicate = nil
            editor.endChange()
        case .pan:
            window?.invalidateCursorRects(for: self)
        default: break
        }
        if snapLines.x != nil || snapLines.y != nil { snapLines = (nil, nil); needsDisplay = true }
        drag = nil
        updateCursor(e)
    }

    private func tooSmall(_ a: Annotation) -> Bool {
        if a.isRectLike { return a.rect.width < 2 || a.rect.height < 2 }
        if a.points.count < a.minPoints { return true }
        if a.isLineLike { return Geo.dist(a.points[0], a.points[1]) < 3 }
        if a.kind == .pencil || a.kind == .highlighter { return a.points.count < 2 }
        return false
    }

    /// Snaps a moved object's edges/centre to the canvas edges/centre and other objects (⌘ disables). Shows guides.
    private func snapMove(_ a: Annotation, _ d: CGVector, enabled: Bool) -> CGVector {
        snapLines = (nil, nil)
        guard enabled else { return d }
        let b = AnnotateRenderer.bounds(a).offsetBy(dx: d.dx, dy: d.dy), area = editor.doc.contentRect
        var xs = [area.minX, area.midX, area.maxX], ys = [area.minY, area.midY, area.maxY]
        for o in editor.doc.annotations where o.id != a.id {
            let r = AnnotateRenderer.bounds(o)
            xs += [r.minX, r.midX, r.maxX]
            ys += [r.minY, r.midY, r.maxY]
        }
        let t = 5 / zoom
        var out = d
        let bx: [CGFloat] = [b.minX, b.midX, b.maxX], by: [CGFloat] = [b.minY, b.midY, b.maxY]
        if let (v, s) = bx.compactMap({ v in Geo.snap(v, to: xs, tol: t).map { (v, $0) } }).min(by: { abs($0.0 - $0.1) < abs($1.0 - $1.1) }) {
            out.dx += s - v
            snapLines.x = s
        }
        if let (v, s) = by.compactMap({ v in Geo.snap(v, to: ys, tol: t).map { (v, $0) } }).min(by: { abs($0.0 - $0.1) < abs($1.0 - $1.1) }) {
            out.dy += s - v
            snapLines.y = s
        }
        return out
    }

    /// Crop snapping to strong edges in the image (setting; ⌘ inverts).
    private func snapCropPoint(_ p: CGPoint, command: Bool, handle h: Int? = nil) -> CGPoint {
        snapLines = (nil, nil)
        guard Prefs.bool(.annotateSnapCrop) != command else { return p }
        let e = ImageAnalysis.edges(editor.doc.image, scale: editor.doc.scale), area = editor.doc.extent
        let t = 8 / zoom
        var q = p
        let movesX = h.map { ![4, 6].contains($0) } ?? true, movesY = h.map { ![5, 7].contains($0) } ?? true
        if movesX, let x = Geo.snap(p.x, to: e.xs + [area.minX, area.maxX, editor.doc.imageRect.maxX], tol: t) { q.x = x; snapLines.x = x }
        if movesY, let y = Geo.snap(p.y, to: e.ys + [area.minY, area.maxY, editor.doc.imageRect.maxY], tol: t) { q.y = y; snapLines.y = y }
        return q
    }

    /// Applies the crop ratio (growing to cover the drag from `anchor`) and clamps to the canvas extent.
    private func constrainCrop(_ r: CGRect, anchor: CGPoint, vertical: Bool = false) -> CGRect {
        let area = editor.doc.extent
        guard let k = editor.cropRatioValue else { return r.intersection(area) }
        var w = r.width, h = r.height
        if vertical { w = h * k } else if w / max(h, 0.001) > k { h = w / k } else { w = h * k }
        // Shrink to fit inside the area from the anchor so the ratio holds at the edges.
        let maxW = anchor.x - r.minX > r.maxX - anchor.x || abs(anchor.x - r.maxX) < 0.001 ? anchor.x - area.minX : area.maxX - anchor.x
        let maxH = anchor.y - r.minY > r.maxY - anchor.y || abs(anchor.y - r.maxY) < 0.001 ? anchor.y - area.minY : area.maxY - anchor.y
        let f = min(1, maxW / max(w, 0.001), maxH / max(h, 0.001))
        w *= f
        h *= f
        let x = abs(anchor.x - r.minX) <= abs(anchor.x - r.maxX) ? anchor.x : anchor.x - w
        let y = abs(anchor.y - r.minY) <= abs(anchor.y - r.maxY) ? anchor.y : anchor.y - h
        return CGRect(x: x, y: y, width: w, height: h).intersection(area)
    }

    // MARK: Cursors

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: baseCursor)
    }

    private var baseCursor: NSCursor {
        switch editor.tool {
        case .move: return .arrow
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }

    override func mouseMoved(with e: NSEvent) { updateCursor(e) }

    override func mouseExited(with event: NSEvent) { hover = nil }

    private func updateCursor(_ e: NSEvent) {
        guard drag == nil else { return }
        if spaceDown { return NSCursor.openHand.set() }
        // Key/flag events carry no mouse position.
        let p = e.type == .flagsChanged ? imagePoint(window: window?.mouseLocationOutsideOfEventStream ?? .zero) : imagePoint(e)
        if let id = editingID {
            // While typing only the text's own handles change the cursor (the text view shows the I-beam).
            if let a = editor.annotation(id), let h = handleIndex(handles(a), p) {
                (h < 2 ? NSCursor.resizeLeftRight : NSCursor.frameResize(position: .bottomRight, directions: .all)).set()
            }
            return
        }
        if editor.tool == .crop {
            guard let c = editor.pendingCrop else { return NSCursor.crosshair.set() }
            if let h = handleIndex(Geo.handles(c), p) { return (h == 4 || h == 6 ? NSCursor.resizeUpDown : h == 5 || h == 7 ? .resizeLeftRight : .crosshair).set() }
            return (c.contains(p) ? NSCursor.openHand : .crosshair).set()
        }
        if let sel = editor.selected, let h = handleIndex(handles(sel), p) {
            hover = nil
            if sel.kind == .text { return (h < 2 ? NSCursor.resizeLeftRight : NSCursor.frameResize(position: .bottomRight, directions: .all)).set() }
            return NSCursor.pointingHand.set()
        }
        let hit = topmost(p)
        let canGrab = hit.map(grabbable) ?? false
        hover = canGrab ? hit?.id : nil
        (canGrab ? (e.modifierFlags.contains(.option) ? NSCursor.dragCopy : NSCursor.openHand) : baseCursor).set()
    }

    override func flagsChanged(with e: NSEvent) {
        super.flagsChanged(with: e)
        updateCursor(e)
    }

    /// Drawing tools pick up existing marks directly. Placed images, redactions and spotlights
    /// act as part of the canvas (you draw over them), so only their own tool or the Move tool grabs those.
    private func grabbable(_ a: Annotation) -> Bool {
        if editor.tool == .move || a.id == editor.selection { return true }
        switch a.kind {
        case .image, .redact, .spotlight: return AnnotateTool.forKind(a.kind) == editor.tool
        default: return true
        }
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        editor.zoomChanged()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard editor.tool != .crop, let a = topmost(imagePoint(event)) else { return nil }
        editor.selection = a.id
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "Copy", keyEquivalent: "") { [weak self] in self?.editor.copySelectionOrImage() })
        m.addItem(ClosureMenuItem(title: "Duplicate", keyEquivalent: "") { [weak self] in self?.editor.duplicate() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Bring to Front", keyEquivalent: "") { [weak self] in self?.editor.bringToFront() })
        m.addItem(ClosureMenuItem(title: "Send to Back", keyEquivalent: "") { [weak self] in self?.editor.sendToBack() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Delete", keyEquivalent: "") { [weak self] in self?.editor.deleteSelection() })
        return m
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        if !handleKey(e) { super.keyDown(with: e) }
    }

    override func keyUp(with e: NSEvent) {
        if Int(e.keyCode) == kVK_Space { spaceDown = false; window?.invalidateCursorRects(for: self) } else { super.keyUp(with: e) }
    }

    /// Editor keys outside text editing: the remappable shortcuts (EditorShortcuts.annotate), then the fixed basics
    /// (space-pan, delete, esc, return, arrow nudges). Returns false if unhandled.
    func handleKey(_ e: NSEvent) -> Bool {
        guard editingID == nil else { return false }
        if editor.performShortcut(e) { return true }
        let flags = e.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty else { return false }
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(e.keyCode) {
        case kVK_Space:
            spaceDown = true
            NSCursor.openHand.set()
        case kVK_Delete, kVK_ForwardDelete:
            editor.deleteSelection()
        case kVK_Escape:
            if editor.tool == .crop { editor.cancelCrop() } else { editor.selection = nil }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if editor.tool == .crop { editor.applyCrop() } else if let a = editor.selected, a.kind == .text { beginEditing(a.id) }
        case kVK_LeftArrow: editor.nudge(CGVector(dx: -step, dy: 0))
        case kVK_RightArrow: editor.nudge(CGVector(dx: step, dy: 0))
        case kVK_DownArrow: editor.nudge(CGVector(dx: 0, dy: step))
        case kVK_UpArrow: editor.nudge(CGVector(dx: 0, dy: -step))
        default: return false
        }
        return true
    }

    // MARK: In-place text editing

    func beginEditing(_ id: UUID) {
        guard editingID == nil, let a = editor.annotation(id), a.kind == .text else { return }
        editor.beginChange()
        editingID = id
        let tv = NSTextView(frame: .zero)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = CGSize(width: 100_000, height: 100_000)
        tv.string = a.text
        tv.delegate = self
        textView = tv
        addSubview(tv)
        syncTextView()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (a.text as NSString).length, length: 0))
        needsDisplay = true
    }

    /// Keeps the editing text view on top of its annotation with matching font/colour.
    private func syncTextView() {
        guard let tv = textView, let id = editingID, let a = editor.annotation(id) else { return }
        let f = AnnotateRenderer.font(a), c = AnnotateRenderer.textColor(a)
        if tv.font != f { tv.font = f }
        if tv.textColor != c { tv.textColor = c; tv.insertionPointColor = c }
        let o = layout.imageOrigin, g = AnnotateRenderer.glyphRect(a)
        if let w = a.textWidth {
            // Fixed width: wrap exactly like the renderer.
            tv.isHorizontallyResizable = false
            tv.textContainer?.containerSize = CGSize(width: w, height: 100_000)
            tv.frame = CGRect(x: g.minX + o.x, y: g.minY + o.y, width: w, height: g.height)
        } else {
            tv.isHorizontallyResizable = true
            tv.textContainer?.containerSize = CGSize(width: 100_000, height: 100_000)
            tv.frame = CGRect(x: g.minX + o.x, y: g.minY + o.y, width: g.width + a.fontSize, height: g.height)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = editingID else { return }
        editor.update(id) { $0.text = tv.string }
    }

    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { endEditing(); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil) // ⇧↩ new line, ↩ commits
            } else { endEditing() }
            return true
        }
        return false
    }

    /// Commits the in-place text edit (empty text removes the annotation). Safe to call when not editing.
    func endEditing() {
        guard let id = editingID, let tv = textView else { return }
        editingID = nil
        textView = nil
        let text = tv.string
        tv.removeFromSuperview()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editor.doc.annotations.removeAll { $0.id == id }
            editor.selection = nil
        } else {
            editor.update(id) { $0.text = text }
        }
        editor.endChange()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

/// Centers the canvas when it's smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

/// The editor's scroll view: ⌘-scroll zooms around the cursor, and it accepts dropped images (edge drop zones).
final class AnnotateScrollView: NSScrollView {
    weak var editor: AnnotateEditor?

    override func scrollWheel(with e: NSEvent) {
        guard e.modifierFlags.contains(.command), let editor else { return super.scrollWheel(with: e) }
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
        let p = documentView.map { $0.convert(e.locationInWindow, from: nil) } ?? .zero
        editor.setZoom(magnification * exp(dy * 0.01), at: p)
    }

    private func images(_ info: NSDraggingInfo) -> [Shot] {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL], !urls.isEmpty {
            return urls.compactMap(Exporter.loadShot)
        }
        if let img = NSImage(pasteboard: pb), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return [Shot(image: cg, scale: max(1, (CGFloat(cg.width) / max(1, img.size.width)).rounded()))]
        }
        return []
    }

    private func canAccept(_ info: NSDraggingInfo) -> Bool {
        let pb = info.draggingPasteboard
        return pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) || NSImage.canInit(with: pb)
    }

    private func zone(_ info: NSDraggingInfo) -> AnnotateEditor.Edge? {
        let p = convert(info.draggingLocation, from: nil)
        return DropZoneView.edge(at: p, in: bounds)
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard canAccept(info), editor?.tool != .crop else { return [] }
        editor?.dropZones.isHidden = false
        return draggingUpdated(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let z = editor?.dropZones, !z.isHidden else { return [] }
        z.active = zone(info)
        return .copy
    }

    override func draggingExited(_ info: NSDraggingInfo?) { editor?.dropZones.isHidden = true }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let edge = zone(info)
        editor?.dropZones.isHidden = true
        let shots = images(info)
        guard let editor, !shots.isEmpty else { return false }
        for (i, s) in shots.enumerated() { editor.place(s.image, scale: s.scale, edge: edge ?? (i > 0 ? .right : nil)) }
        return true
    }
}

/// Overlay shown while dragging an image over the editor: "Place on the top/bottom/left/right" zones, centre = on canvas.
final class DropZoneView: NSView {
    var active: AnnotateEditor.Edge? { didSet { if active != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    static func band(_ r: CGRect) -> CGFloat { min(120, min(r.width, r.height) * 0.22) }

    static func edge(at p: CGPoint, in r: CGRect) -> AnnotateEditor.Edge? {
        let b = band(r)
        let d: [(AnnotateEditor.Edge, CGFloat)] = [(.top, p.y - r.minY), (.bottom, r.maxY - p.y), (.left, p.x - r.minX), (.right, r.maxX - p.x)]
        let m = d.min { $0.1 < $1.1 }!
        return m.1 <= b ? m.0 : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds, b = Self.band(r)
        NSColor.black.withAlphaComponent(0.25).setFill()
        r.fill()
        let zones: [(AnnotateEditor.Edge?, CGRect, String, String)] = [
            (.top, CGRect(x: r.minX + b, y: r.minY, width: r.width - 2 * b, height: b), "Place on the top", "arrow.up"),
            (.bottom, CGRect(x: r.minX + b, y: r.maxY - b, width: r.width - 2 * b, height: b), "Place on the bottom", "arrow.down"),
            (.left, CGRect(x: r.minX, y: r.minY + b, width: b, height: r.height - 2 * b), "Place on the left", "arrow.left"),
            (.right, CGRect(x: r.maxX - b, y: r.minY + b, width: b, height: r.height - 2 * b), "Place on the right", "arrow.right"),
            (nil, r.insetBy(dx: b, dy: b), "Add to canvas", "plus"),
        ]
        for (edge, z, title, symbol) in zones {
            let on = edge == active
            let box = z.insetBy(dx: 8, dy: 8)
            let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
            (on ? NSColor.controlAccentColor.withAlphaComponent(0.85) : NSColor.windowBackgroundColor.withAlphaComponent(0.55)).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(on ? 0.9 : 0.4).setStroke()
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.lineWidth = 1.5
            path.stroke()
            let color: NSColor = on ? .white : .labelColor
            let str = NSAttributedString(string: title.loc, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: color])
            let sz = str.size()
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .semibold).applying(.init(paletteColors: [color]))) {
                img.draw(in: CGRect(x: box.midX - img.size.width / 2, y: box.midY - img.size.height - 4, width: img.size.width, height: img.size.height))
            }
            if sz.width < box.width - 8 { str.draw(at: CGPoint(x: box.midX - sz.width / 2, y: box.midY + 4)) }
        }
    }
}
