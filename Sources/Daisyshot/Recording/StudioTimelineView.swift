import AppKit
import SwiftUI

/// Ruler, typing stretches, clip track (thumbnails + waveform), zoom track and mask track. Selection tool: select, trim
/// edges, scrub. Cut tool: click to split. Zoom / mask tracks: click or drag to add, drag to move, drag edges to resize.
/// Typing stretches: click for the "Speed up typing" popover.
final class StudioTimelineView: NSView, NSPopoverDelegate {
    private unowned let editor: StudioEditor
    private let playhead = PlayheadView()

    private let inset: CGFloat = 18
    private let rulerH: CGFloat = 24
    // Tracks can be hidden (View menu); everything below a hidden track moves up.
    private var typingTop: CGFloat { rulerH + 4 }
    private var typingH: CGFloat { Prefs.bool(.studioShowTyping) ? 18 : 0 }
    /// Keystroke badges as the video shows them; click one to hide just that one.
    private var keysH: CGFloat { Prefs.bool(.studioShowKeys) && editor.hasKeys && editor.doc.keystrokes.show ? 18 : 0 }
    private var keysTop: CGFloat { typingTop + typingH + (typingH > 0 && keysH > 0 ? 4 : 0) }
    private var clipTop: CGFloat { keysTop + keysH + (typingH + keysH > 0 ? 6 : 4) }
    private let clipH: CGFloat = 62
    private var lanesTop: CGFloat { clipTop + clipH + 10 }

    /// The zoom, mask and camera-layout tracks: bars of non-overlapping output-time ranges.
    enum Lane { case zoom, mask, camera }
    /// Shown lanes, top to bottom (the camera lane only for recordings with a camera).
    private var lanes: [Lane] {
        var l: [Lane] = []
        if Prefs.bool(.studioShowZooms) { l.append(.zoom) }
        if Prefs.bool(.studioShowMasks) { l.append(.mask) }
        if editor.hasCamera, Prefs.bool(.studioShowLayouts) { l.append(.camera) }
        return l
    }

    /// Height that fits the ruler, the shown tracks and the scroll indicator.
    var preferredHeight: CGFloat {
        lanesTop + lanes.reduce(0) { $0 + laneH($1) + 6 } - (lanes.isEmpty ? 10 : 6) + 18
    }

    private(set) var pps: CGFloat = 50          // points per second
    private var offsetX: CGFloat = 0
    private var fitMode = true
    private var hover: CGPoint?

    private enum Drag {
        case scrub
        case trim(index: Int, leading: Bool, startX: CGFloat, origin: Double)
        case move(Lane, id: UUID, startX: CGFloat, range: ClosedRange<Double>, gap: ClosedRange<Double>)
        case resize(Lane, id: UUID, leading: Bool, startX: CGFloat, range: ClosedRange<Double>, gap: ClosedRange<Double>)
        case new(Lane, start: Double, current: Double, gap: ClosedRange<Double>)
    }
    private var drag: Drag?
    private var dragUndoPushed = false

    init(editor: StudioEditor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(playhead)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Geometry

    private var duration: Double { max(0.001, editor.duration) }
    private var fitPPS: CGFloat { max(1, (bounds.width - inset * 2) / CGFloat(duration)) }
    private func x(_ t: Double) -> CGFloat { inset + CGFloat(t) * pps - offsetX }
    private func time(_ x: CGFloat) -> Double { min(max(0, Double((x - inset + offsetX) / pps)), duration) }
    private var maxOffset: CGFloat { max(0, CGFloat(duration) * pps + inset * 2 - bounds.width) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitMode { pps = fitPPS }
        offsetX = min(max(0, offsetX), maxOffset)
        updatePlayhead(follow: false)
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        if fitMode { pps = fitPPS }
        offsetX = min(max(0, offsetX), maxOffset)
        updatePlayhead(follow: false)
    }

    func zoom(by f: CGFloat, anchorX: CGFloat? = nil) {
        let ax = anchorX ?? x(editor.clock.time)
        let t = time(ax)
        pps = min(max(fitPPS, pps * f), 1200)
        fitMode = abs(pps - fitPPS) < 0.5
        offsetX = min(max(0, inset + CGFloat(t) * pps - ax), maxOffset)
        needsDisplay = true
        updatePlayhead(follow: false)
    }

    func zoomToFit() {
        fitMode = true
        pps = fitPPS
        offsetX = 0
        needsDisplay = true
        updatePlayhead(follow: false)
    }

    func updatePlayhead(follow: Bool) {
        var px = x(editor.clock.time)
        if follow, maxOffset > 0, px < inset || px > bounds.width - inset {
            offsetX = min(max(0, offsetX + px - (px > bounds.width - inset ? inset * 2 : bounds.width * 0.5)), maxOffset)
            px = x(editor.clock.time)
            needsDisplay = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playhead.frame = CGRect(x: px - PlayheadView.width / 2, y: 0, width: PlayheadView.width, height: bounds.height)
        playhead.isHidden = editor.sources == nil
        CATransaction.commit()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        StudioTheme.timelineNS.setFill()
        bounds.fill()
        guard editor.sources != nil else { return }
        if dirtyRect.contains(bounds) { drawnLook = hoverLook(hover) }   // what this full redraw shows for the pointer
        // Partial redraws (hover, cut line) only touch one band.
        if dirtyRect.minY < rulerH { drawRuler(ctx); drawMarkers(ctx) }
        if typingH > 0, dirtyRect.intersects(CGRect(x: 0, y: typingTop, width: bounds.width, height: typingH)) { drawTyping(ctx) }
        if keysH > 0, dirtyRect.intersects(CGRect(x: 0, y: keysTop, width: bounds.width, height: keysH)) { drawKeys(ctx) }
        if dirtyRect.intersects(CGRect(x: 0, y: clipTop, width: bounds.width, height: clipH)) { drawClips(ctx) }
        for lane in lanes where dirtyRect.intersects(laneRect(lane)) { drawLane(ctx, lane) }
        if case let .new(lane, a, b, _)? = drag, abs(b - a) > 0 {
            drawBar(ctx, lane, CGRect(x: x(min(a, b)), y: laneTop(lane), width: CGFloat(abs(b - a)) * pps, height: laneH(lane)), label: "", selected: true, ghost: true)
        }
        if let h = hover, editor.tool == .cut, h.y >= clipTop, h.y <= clipTop + clipH {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: h.x.rounded() + 0.5, y: clipTop - 4))
            ctx.addLine(to: CGPoint(x: h.x.rounded() + 0.5, y: clipTop + clipH + 4))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        if maxOffset > 0 {   // scroll indicator
            let w = bounds.width - inset * 2
            let k = w / (CGFloat(duration) * pps + inset * 2)
            let r = CGRect(x: inset + offsetX * k, y: bounds.height - 6, width: max(24, bounds.width * k), height: 3)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
            ctx.fillPath()
        }
    }

    private static func timeString(_ t: Double, fine: Bool) -> String {
        let m = Int(t) / 60, s = t - Double(m * 60)
        return fine ? String(format: "%d:%04.1f", m, s) : String(format: "%d:%02d", m, Int(s.rounded(.down)))
    }

    private static func rulerString(_ t: Double, step: Double) -> String {
        let m = Int((t + 1e-6) / 60), s = t - Double(m * 60)
        if step >= 1 { return String(format: "%d:%02d", m, Int((s + 1e-6).rounded(.down))) }
        return step >= 0.5 ? String(format: "%d:%04.1f", m, s) : String(format: "%d:%05.2f", m, s)
    }

    private func drawRuler(_ ctx: CGContext) {
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first { CGFloat($0) * pps >= 64 } ?? 600
        let minor = step / 5
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.45)]
        var t = (Double(time(0)) / minor).rounded(.down) * minor
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        while t <= duration + 1e-6 {
            let px = x(t).rounded() + 0.5
            if px > bounds.width { break }
            let major = abs((t / step).rounded() * step - t) < 1e-6
            ctx.fill(CGRect(x: px - 0.5, y: rulerH - (major ? 8 : 4), width: 1, height: major ? 8 : 4))
            if major {
                NSAttributedString(string: Self.rulerString(t, step: step), attributes: attrs).draw(at: CGPoint(x: px + 3, y: 3))
            }
            t += minor
        }
    }

    /// Recording markers: a yellow flag on the ruler with a faint line down through the tracks' top.
    private func drawMarkers(_ ctx: CGContext) {
        for t in editor.markers {
            let px = x(t).rounded() + 0.5
            guard px > -10, px < bounds.width + 10 else { continue }
            ctx.setFillColor(Self.markerColor.withAlphaComponent(0.55).cgColor)
            ctx.fill(CGRect(x: px - 0.5, y: 2, width: 1, height: rulerH + 4))
            let flag = CGMutablePath()
            flag.move(to: CGPoint(x: px, y: 2))
            flag.addLine(to: CGPoint(x: px + 9, y: 5.5))
            flag.addLine(to: CGPoint(x: px, y: 9))
            flag.closeSubpath()
            ctx.addPath(flag)
            ctx.setFillColor(Self.markerColor.cgColor)
            ctx.fillPath()
        }
    }

    private static let markerColor = NSColor(hex: "#FFC633")

    private func marker(at p: CGPoint) -> Double? {
        guard p.y < rulerH + 4 else { return nil }
        return editor.markers.min { abs(x($0) - p.x) < abs(x($1) - p.x) }.flatMap { abs(x($0) + 4 - p.x) <= 8 ? $0 : nil }
    }

    private func drawImage(_ ctx: CGContext, _ img: CGImage, in r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: r.minY * 2 + r.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: r)
        ctx.restoreGState()
    }

    private func clipRects() -> [CGRect] {
        zip(editor.doc.clips, editor.doc.clipStarts).map { c, start in
            CGRect(x: x(start), y: clipTop, width: CGFloat(c.length) * pps, height: clipH)
        }
    }

    private func drawClips(_ ctx: CGContext) {
        let clips = editor.doc.clips
        let waves = editor.waveforms, music = editor.musicWaveform, m = editor.doc.music
        let starts = editor.doc.clipStarts
        // One colour per source (system audio, microphone, more), the music in pink from the top.
        let colors = [NSColor.white.withAlphaComponent(0.55), NSColor.systemTeal.withAlphaComponent(0.75), NSColor.systemYellow.withAlphaComponent(0.7)]
        let tileW = max(28, clipH * editor.sourceAspect)
        for (i, full) in clipRects().enumerated() where full.maxX > 0 && full.minX < bounds.width {
            let c = clips[i]
            let r = full.insetBy(dx: 1.5, dy: 0)
            let selected = editor.selection == .clip(c.id)
            let path = CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
            ctx.fill(r)
            var tx = r.minX - (r.minX - full.minX).truncatingRemainder(dividingBy: tileW)
            while tx < min(r.maxX, bounds.width) {
                if tx + tileW > 0, let img = editor.thumbnail(atSource: c.start + Double((tx + tileW / 2 - full.minX) / pps) * c.speed) {
                    let iw = CGFloat(img.width), ih = CGFloat(img.height)
                    let k = max(tileW / iw, clipH / ih)
                    drawImage(ctx, img, in: CGRect(x: tx + (tileW - iw * k) / 2, y: clipTop + (clipH - ih * k) / 2, width: iw * k, height: ih * k))
                }
                tx += tileW
            }
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
            ctx.fill(r)
            if Prefs.bool(.studioShowWaveform) {
                let base = r.maxY - 3, maxH = clipH * 0.42
                for (ti, wave) in waves.enumerated() where !wave.isEmpty {
                    let gain = CGFloat(min(1.5, c.volume * c.trackVolume(ti)))
                    ctx.setFillColor(colors[ti % colors.count].cgColor)
                    var px = max(r.minX, 0)
                    while px < min(r.maxX, bounds.width) {
                        let s = c.start + Double((px - full.minX) / pps) * c.speed
                        let bi = Int(s * StudioWaveform.binsPerSecond)
                        if bi >= 0, bi < wave.count {
                            let h = max(1, CGFloat(wave[bi]) * maxH * gain)
                            ctx.fill(CGRect(x: px, y: base - h, width: 1.5, height: h))
                        }
                        px += 2.5
                    }
                }
                // Music loops along the output from the start.
                if !music.isEmpty, !m.path.isEmpty {
                    let loop = Double(music.count) / StudioWaveform.binsPerSecond
                    let gain = m.muted ? 0 : CGFloat(min(1, m.volume * 2))
                    ctx.setFillColor(NSColor.systemPink.withAlphaComponent(0.7).cgColor)
                    var px = max(r.minX, 0)
                    while px < min(r.maxX, bounds.width) {
                        let out = starts[i] + Double((px - full.minX) / pps)
                        let bi = Int(out.truncatingRemainder(dividingBy: loop) * StudioWaveform.binsPerSecond)
                        if bi >= 0, bi < music.count {
                            ctx.fill(CGRect(x: px, y: r.minY + 2, width: 1.5, height: max(1, CGFloat(music[bi]) * clipH * 0.22 * gain)))
                        }
                        px += 2.5
                    }
                }
            }
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setLineWidth(selected ? 2 : 1)
            ctx.setStrokeColor(selected ? StudioTheme.accentNS.cgColor : NSColor.white.withAlphaComponent(0.14).cgColor)
            ctx.strokePath()
            if selected || (hover.map { r.insetBy(dx: -6, dy: 0).contains($0) } ?? false) && editor.tool == .select {
                ctx.setFillColor((selected ? StudioTheme.accentNS : NSColor.white.withAlphaComponent(0.7)).cgColor)
                for hx in [r.minX + 4, r.maxX - 7] {
                    ctx.addPath(CGPath(roundedRect: CGRect(x: hx, y: r.midY - 11, width: 3, height: 22), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                    ctx.fillPath()
                }
            }
            if r.width > 64 {
                let text = Self.timeString(c.length, fine: true) + (c.speed == 1 ? "" : "  ·  " + StudioDocument.Clip.speedTitle(c.speed))
                let label = NSAttributedString(string: text,
                                               attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white])
                let lr = CGRect(x: r.minX + 8, y: r.minY + 6, width: label.size().width + 10, height: 16)
                ctx.addPath(CGPath(roundedRect: lr, cornerWidth: 5, cornerHeight: 5, transform: nil))
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
                ctx.fillPath()
                label.draw(at: CGPoint(x: lr.minX + 5, y: lr.minY + 1.5))
            }
        }
    }

    // MARK: Keystrokes

    private func keyRects() -> [(badge: KeyBadge, rect: CGRect)] {
        guard keysH > 0 else { return [] }
        let doc = editor.doc
        return editor.keyBadges.compactMap { b in
            guard doc.clips.contains(where: { $0.start <= b.start && b.start < $0.end }) else { return nil }   // cut away
            let a = doc.outputTime(source: b.start), e = doc.outputTime(source: min(b.end, b.start + 4))
            let w = max(CGFloat(e - a) * pps, Self.keyFont.pointSize * CGFloat(b.text.count) * 0.62 + 12)
            return (b, CGRect(x: x(a), y: keysTop, width: w, height: keysH))
        }
    }

    private static let keyFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    /// Shown badges in the keystroke colour; hidden ones faint and struck through.
    private func drawKeys(_ ctx: CGContext) {
        let k = editor.doc.keystrokes
        for (b, full) in keyRects() where full.maxX > 0 && full.minX < bounds.width {
            let r = full.insetBy(dx: 1, dy: 0)
            let off = k.isHidden(b)
            let hot = hover.map { r.contains($0) } ?? false
            let path = CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.systemPurple.withAlphaComponent(off ? 0.12 : (hot ? 0.75 : 0.5)).cgColor)
            ctx.fillPath()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).addClip()
            var attrs: [NSAttributedString.Key: Any] = [.font: Self.keyFont, .foregroundColor: NSColor.white.withAlphaComponent(off ? 0.4 : 1)]
            if off { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let text = NSAttributedString(string: b.text, attributes: attrs)
            text.draw(at: CGPoint(x: r.minX + 5, y: r.midY - text.size().height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Typing

    /// Detected typing stretches (output rects in the typing lane), with the speed each plays at.
    private func typingRects() -> [(range: ClosedRange<Double>, speed: Double, rect: CGRect)] {
        guard typingH > 0 else { return [] }
        return editor.typingStretches.compactMap { s in
            let a = editor.doc.outputTime(source: s.range.lowerBound), b = editor.doc.outputTime(source: s.range.upperBound)
            guard b - a > 0.05 else { return nil }    // cut away
            return (s.range, s.speed, CGRect(x: x(a), y: typingTop, width: max(26, CGFloat(b - a) * pps), height: typingH))
        }
    }

    /// A suggestion is a tinted outline; an applied one is filled and shows its speed.
    private func drawTyping(_ ctx: CGContext) {
        for (range, speed, full) in typingRects() where full.maxX > 0 && full.minX < bounds.width {
            let r = full.insetBy(dx: 1, dy: 0)
            let applied = speed != 1
            let hot = (hover.map { r.contains($0) } ?? false) || popoverRange == range
            let path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(StudioTheme.typingNS.withAlphaComponent(applied ? (hot ? 1 : 0.85) : (hot ? 0.38 : 0.22)).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setLineWidth(1)
            ctx.setStrokeColor((hot ? NSColor.white.withAlphaComponent(0.85) : StudioTheme.typingNS.withAlphaComponent(0.75)).cgColor)
            ctx.strokePath()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).addClip()
            let icon = applied ? Self.keyboardIconWhite : Self.keyboardIcon
            let text = applied && r.width > 54 ? NSAttributedString(string: StudioDocument.Clip.speedTitle(speed), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.white]) : nil
            let w = (icon?.size.width ?? 0) + (text.map { $0.size().width + 5 } ?? 0)
            var cx = max(r.minX + 6, min(r.midX, bounds.width / 2) - w / 2)   // keep the label in view on long bars
            cx = min(cx, r.maxX - 6 - w)
            if let icon {
                icon.draw(in: CGRect(x: cx, y: r.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
                cx += icon.size.width + 5
            }
            text?.draw(at: CGPoint(x: cx, y: r.midY - (text?.size().height ?? 0) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func keyboard(_ color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [color])))
    }
    private static let keyboardIcon = keyboard(NSColor(hex: "#A9C7FF"))
    private static let keyboardIconWhite = keyboard(.white)

    private var typingPopover: NSPopover?
    /// The stretch whose popover is open (drawn highlighted).
    private var popoverRange: ClosedRange<Double>?

    private func showTypingPopover(_ range: ClosedRange<Double>, at rect: CGRect) {
        typingPopover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.delegate = self
        let host = NSHostingController(rootView: TypingPopover(editor: editor, range: range) { [weak pop] in pop?.performClose(nil) })
        host.sizingOptions = .preferredContentSize
        pop.contentViewController = host
        typingPopover = pop
        popoverRange = range
        needsDisplay = true
        pop.show(relativeTo: rect.intersection(visibleRect), of: self, preferredEdge: .minY)
    }

    #if DEBUG
    /// Opens the first typing stretch's popover; returns its content view (for snapshots).
    func debugTypingPopover() -> NSView? {
        guard let mark = typingRects().first else { return nil }
        showTypingPopover(mark.range, at: mark.rect)
        return typingPopover?.contentViewController?.view
    }
    #endif

    func popoverDidClose(_ notification: Notification) {
        typingPopover = nil
        popoverRange = nil
        needsDisplay = true
    }

    private func laneTop(_ l: Lane) -> CGFloat {
        var y = lanesTop
        for x in lanes { if x == l { return y }; y += laneH(x) + 6 }
        return -1000      // hidden
    }
    private func laneH(_ l: Lane) -> CGFloat { l == .zoom ? 30 : 26 }
    private func laneRect(_ l: Lane) -> CGRect { CGRect(x: 0, y: laneTop(l), width: bounds.width, height: laneH(l)) }
    private func lane(at y: CGFloat, slack: CGFloat = 0) -> Lane? {
        lanes.first { y >= laneTop($0) - slack && y <= laneTop($0) + laneH($0) + slack }
    }

    /// Output ranges of a lane's items (ignoring ones whose content was cut away).
    private func ranges(_ l: Lane) -> [(id: UUID, range: ClosedRange<Double>)] {
        let d = editor.doc
        let all = switch l {
        case .zoom: d.zooms.map { ($0.id, d.outputRange($0)) }
        case .mask: d.masks.map { ($0.id, d.outputRange($0)) }
        case .camera: d.layouts.map { ($0.id, d.outputRange($0)) }
        }
        return all.filter { $0.1.upperBound - $0.1.lowerBound > 0.001 }
    }

    private func barRects(_ l: Lane) -> [(id: UUID, rect: CGRect)] {
        ranges(l).map { ($0.id, CGRect(x: x($0.range.lowerBound), y: laneTop(l), width: CGFloat($0.range.upperBound - $0.range.lowerBound) * pps, height: laneH(l))) }
    }

    private func isOff(_ l: Lane, _ id: UUID) -> Bool {
        let d = editor.doc
        switch l {
        case .zoom: return d.zooms.first { $0.id == id }?.disabled ?? false
        case .mask: return d.masks.first { $0.id == id }?.disabled ?? false
        case .camera: return d.layouts.first { $0.id == id }?.disabled ?? false
        }
    }

    private func selection(_ l: Lane, _ id: UUID) -> StudioEditor.Selection {
        switch l {
        case .zoom: .zoom(id)
        case .mask: .mask(id)
        case .camera: .layout(id)
        }
    }

    private func label(_ l: Lane, _ id: UUID) -> String {
        if l == .zoom, let z = editor.doc.zooms.first(where: { $0.id == id }) {
            return String(format: "%.1f×  %@", z.scale, z.followCursor && editor.hasPointer ? Self.followLabel : Self.manualLabel)
        }
        if l == .camera, let c = editor.doc.layouts.first(where: { $0.id == id }) {
            return c.kind == .cameraOnly ? Self.cameraOnlyLabel : c.kind == .custom ? Self.customCameraLabel : Self.screenOnlyLabel
        }
        guard let m = editor.doc.masks.first(where: { $0.id == id }) else { return "" }
        return m.kind == .blur ? Self.blurLabel : Self.highlightLabel
    }

    private func drawBar(_ ctx: CGContext, _ lane: Lane, _ rect: CGRect, label: String, selected: Bool, ghost: Bool = false, warned: Bool = false,
                         off: Bool = false) {
        let r = rect.insetBy(dx: 1, dy: 0)
        let color = lane == .zoom ? StudioTheme.zoomNS : lane == .mask ? StudioTheme.maskNS : StudioTheme.cameraNS
        let path = CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(color.withAlphaComponent(ghost ? 0.35 : off ? (selected ? 0.4 : 0.22) : selected ? 1 : 0.78).cgColor)
        ctx.fillPath()
        if off {
            // Turned off: hatched, so it reads as "still here, not applied".
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.5)
            var hx = r.minX - r.height
            while hx < r.maxX { ctx.move(to: CGPoint(x: hx, y: r.maxY)); ctx.addLine(to: CGPoint(x: hx + r.height, y: r.minY)); hx += 8 }
            ctx.strokePath()
            ctx.restoreGState()
        }
        if selected || ghost {
            ctx.addPath(path)
            ctx.setLineWidth(ghost ? 1 : 2)
            if ghost { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(ghost ? 0.6 : 0.95).cgColor)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        guard r.width > 30 else { return }
        let symbol = switch lane {
        case .mask: ghost ? "plus.rectangle.on.rectangle" : warned ? "exclamationmark.triangle.fill" : "eye.slash"
        case .zoom: ghost ? "plus.magnifyingglass" : "magnifyingglass"
        case .camera: ghost ? "plus.square.on.square" : label == Self.screenOnlyLabel ? "display" : label == Self.customCameraLabel ? "rectangle.inset.bottomright.filled" : "person.crop.rectangle"
        }
        let text = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).addClip()
        let lx = min(max(r.minX, 0), max(r.minX, r.maxX - 90))
        if let icon = Self.whiteIcon(symbol) {
            icon.draw(in: CGRect(x: lx + 8, y: r.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
        }
        if r.width > 60 { text.draw(at: CGPoint(x: lx + 26, y: r.midY - text.size().height / 2)) }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLane(_ ctx: CGContext, _ l: Lane) {
        let lane = CGRect(x: x(0), y: laneTop(l), width: CGFloat(duration) * pps, height: laneH(l))
        ctx.addPath(CGPath(roundedRect: lane, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.045).cgColor)
        ctx.fillPath()
        let rects = barRects(l)
        let laneHover = hover.map { self.lane(at: $0.y) == l } ?? false
        if rects.isEmpty, drag == nil {
            let hint = NSAttributedString(string: l == .zoom ? Self.zoomHint : l == .mask ? Self.maskHint : Self.cameraHint,
                                          attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                       .foregroundColor: NSColor.white.withAlphaComponent(laneHover ? 0.6 : 0.35)])
            let s = hint.size()
            let vis = lane.intersection(bounds)
            hint.draw(at: CGPoint(x: vis.midX - s.width / 2, y: laneTop(l) + (laneH(l) - s.height) / 2))
        }
        for (id, r) in rects {
            drawBar(ctx, l, r, label: label(l, id), selected: editor.selection == selection(l, id), warned: l == .mask && editor.maskWarnings.contains(id),
                    off: isOff(l, id))
        }
        if laneHover, drag == nil, let h = hover, !rects.contains(where: { $0.rect.insetBy(dx: -4, dy: 0).contains(h) }),
           let gap = freeGap(l, around: time(h.x)) {
            let a = time(h.x), b = min(gap.upperBound, a + Self.defaultLength)
            if b - a >= StudioDocument.minZoom {
                drawBar(ctx, l, CGRect(x: x(a), y: laneTop(l), width: CGFloat(b - a) * pps, height: laneH(l)), label: "", selected: false, ghost: true)
            }
        }
    }

    private func freeGap(_ l: Lane, around t: Double) -> ClosedRange<Double>? {
        switch l {
        case .zoom: editor.doc.zoomGap(around: t)
        case .mask: editor.doc.maskGap(around: t)
        case .camera: editor.doc.layoutGap(around: t)
        }
    }

    static let defaultLength = 2.0

    /// Translated once, not on every redraw.
    private static let zoomHint = "Add a zoom: click, or drag across the timeline".loc
    private static let maskHint = "Add a blur or highlight: click, or drag across the timeline".loc
    private static let followLabel = "Follow".loc, manualLabel = "Manual".loc
    private static let blurLabel = "Blur".loc, highlightLabel = "Highlight".loc
    private static let cameraHint = "Show only the camera or only the screen: click, or drag across the timeline".loc
    private static let cameraOnlyLabel = "Camera only".loc, screenOnlyLabel = "Screen only".loc, customCameraLabel = "Custom camera".loc

    private static var whiteIcons: [String: NSImage] = [:]

    /// A bar symbol tinted white, made once (not per bar per redraw).
    private static func whiteIcon(_ symbol: String) -> NSImage? {
        if let hit = whiteIcons[symbol] { return hit }
        guard let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        else { return nil }
        let tinted = NSImage(size: icon.size, flipped: false) { b in
            icon.draw(in: b)
            NSColor.white.set()
            b.fill(using: .sourceAtop)
            return true
        }
        whiteIcons[symbol] = tinted
        return tinted
    }

    /// Everything `draw` shows that depends on the pointer, so moves that change none of it don't redraw.
    private struct HoverLook: Equatable {
        var cutX: CGFloat?      // cut tool line in the clip lane
        var clips: [Int] = []   // clips showing their trim handles
        var ghost: CGPoint?     // "add" ghost bar in the zoom or mask lane (x, lane top)
    }

    private func hoverLook(_ h: CGPoint?) -> HoverLook {
        guard let h else { return HoverLook() }
        var look = HoverLook()
        if editor.tool == .cut, h.y >= clipTop, h.y <= clipTop + clipH { look.cutX = h.x.rounded() }
        if editor.tool == .select {
            let rects = clipRects()
            look.clips = rects.indices.filter { rects[$0].insetBy(dx: -4.5, dy: 0).contains(h) }
        }
        if let l = lane(at: h.y) { look.ghost = CGPoint(x: h.x, y: laneTop(l)) }
        return look
    }

    private var drawnLook = HoverLook()

    private func setHover(_ p: CGPoint?) {
        let old = drawnLook, new = hoverLook(p)
        hover = p
        drawnLook = new
        guard old != new else { return }
        if old.clips == new.clips, old.ghost == new.ghost, let a = old.cutX, let b = new.cutX {
            for x in [a, b] { setNeedsDisplay(CGRect(x: x - 2, y: clipTop - 5, width: 4, height: clipH + 10)) }
        } else if old.clips == new.clips, old.cutX == new.cutX, let a = old.ghost, let b = new.ghost, a.y == b.y {
            setNeedsDisplay(CGRect(x: 0, y: a.y - 2, width: bounds.width, height: 26 + 30))
        } else {
            needsDisplay = true
        }
    }

    // MARK: Hit testing

    private func clipEdge(at px: CGFloat) -> (index: Int, leading: Bool)? {
        var best: (Int, Bool, CGFloat)?
        for (i, r) in clipRects().enumerated() {
            for (leading, ex) in [(true, r.minX), (false, r.maxX)] {
                let d = abs(px - ex)
                guard d < 7 else { continue }
                // At a cut both neighbours match; the side the pointer is on wins.
                let side = leading ? px >= ex : px <= ex
                let score = d - (side ? 3 : 0)
                if best == nil || score < best!.2 { best = (i, leading, score) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func barHit(_ p: CGPoint) -> (lane: Lane, id: UUID, edge: Bool?)? {
        guard let l = lane(at: p.y) else { return nil }
        for (id, r) in barRects(l) where r.insetBy(dx: -5, dy: 0).contains(CGPoint(x: p.x, y: r.midY)) {
            if abs(p.x - r.minX) < 7 { return (l, id, true) }
            if abs(p.x - r.maxX) < 7 { return (l, id, false) }
            return (l, id, nil)
        }
        return nil
    }

    private func gap(_ l: Lane, excluding id: UUID, range: ClosedRange<Double>) -> ClosedRange<Double> {
        var lo = 0.0, hi = duration
        for (other, r) in ranges(l) where other != id {
            if r.upperBound <= range.lowerBound + 1e-6 { lo = max(lo, r.upperBound) }
            if r.lowerBound >= range.upperBound - 1e-6 { hi = min(hi, r.lowerBound) }
        }
        return lo...hi
    }

    /// Snaps to the playhead and clip edges within 8 pt.
    private func snap(_ t: Double) -> Double {
        guard Prefs.bool(.studioSnap) else { return t }
        let candidates = [editor.clock.time] + editor.clipEdges
        guard let c = candidates.min(by: { abs($0 - t) < abs($1 - t) }), abs(CGFloat(c - t)) * pps < 8 else { return t }
        return c
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setHover(p)
        if typingRects().contains(where: { $0.rect.contains(p) }) {
            NSCursor.pointingHand.set()
            setNeedsDisplay(CGRect(x: 0, y: typingTop, width: bounds.width, height: typingH))
        } else if p.y >= clipTop, p.y <= clipTop + clipH {
            if editor.tool == .cut { StudioTheme.scissorsCursor.set() } else if clipEdge(at: p.x) != nil { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        } else if let hit = barHit(p) {
            (hit.edge != nil ? NSCursor.resizeLeftRight : NSCursor.openHand).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        setHover(nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard editor.sources != nil else { return }
        window?.makeFirstResponder(nil)
        let p = convert(event.locationInWindow, from: nil)
        let t = time(p.x)
        dragUndoPushed = false
        if let mark = typingRects().first(where: { $0.rect.contains(p) }) {
            drag = nil
            showTypingPopover(mark.range, at: mark.rect)
        } else if let key = keyRects().last(where: { $0.rect.contains(p) }) {
            drag = nil
            editor.toggleBadgeHidden(key.badge)
            needsDisplay = true
        } else if let m = marker(at: p) {
            editor.pause()
            editor.seek(to: m)
            drag = nil
        } else if p.y < clipTop - 2 {
            editor.pause()
            editor.seek(to: t)
            drag = .scrub
        } else if p.y <= clipTop + clipH + 4 {
            if editor.tool == .cut {
                editor.edit { if !$0.split(at: t) { NSSound.beep() } }
                drag = nil
            } else if let (i, leading) = clipEdge(at: p.x) {
                let c = editor.doc.clips[i]
                editor.selection = .clip(c.id)
                editor.pause()
                drag = .trim(index: i, leading: leading, startX: p.x, origin: leading ? c.start : c.end)
            } else if let i = editor.doc.clipIndex(at: t), x(Double(duration)) >= p.x {
                editor.selection = .clip(editor.doc.clips[i].id)
                editor.pause()
                editor.seek(to: t)
                drag = .scrub
            } else {
                editor.selection = nil
            }
        } else if let l = lane(at: p.y, slack: 3) {
            if let (l, id, edge) = barHit(p), let r = ranges(l).first(where: { $0.id == id })?.range {
                editor.selection = selection(l, id)
                let g = gap(l, excluding: id, range: r)
                if event.clickCount == 2 { editor.pause(); editor.seek(to: r.lowerBound) }
                drag = edge.map { .resize(l, id: id, leading: $0, startX: p.x, range: r, gap: g) } ?? .move(l, id: id, startX: p.x, range: r, gap: g)
            } else if let g = freeGap(l, around: t) {
                drag = .new(l, start: t, current: t, gap: g)
            }
        } else {
            editor.selection = nil
        }
        needsDisplay = true
    }

    private func pushUndoOnce() {
        if !dragUndoPushed { editor.pushUndo(); dragUndoPushed = true }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        setHover(p)
        let offset = offsetX
        autoscroll(p)
        switch drag {
        case .scrub?:
            editor.scrub(to: time(p.x))
            if offsetX == offset { return }   // only the playhead (its own view) moved
        case let .trim(i, leading, startX, origin)?:
            pushUndoOnce()
            guard let src = editor.sources, editor.doc.clips.indices.contains(i) else { return }
            let c = editor.doc.clips[i]
            var target = origin + Double((p.x - startX) / pps) * c.speed      // pointer moves in output time
            if !leading {   // snap the outgoing edge to the playhead / other edges
                let start = editor.doc.clipStarts[i]
                target = c.start + (snap(start + (target - c.start) / c.speed) - start) * c.speed
            }
            editor.apply { $0.trim(i, leading: leading, to: target, sourceDuration: src.duration) }
            let start = editor.doc.clipStarts[i]
            editor.seek(to: leading ? start : start + editor.doc.clips[i].length - 1 / editor.fps)
        case let .move(l, id, startX, r, g)?:
            pushUndoOnce()
            let len = r.upperBound - r.lowerBound
            var a = r.lowerBound + Double((p.x - startX) / pps)
            let snappedA = snap(a), snappedB = snap(a + len)
            a = snappedA != a ? snappedA : snappedB != a + len ? snappedB - len : a
            a = min(max(a, g.lowerBound), max(g.lowerBound, g.upperBound - len))
            setRange(l, id, a...(a + len))
            NSCursor.closedHand.set()
        case let .resize(l, id, leading, startX, r, g)?:
            pushUndoOnce()
            let dt = Double((p.x - startX) / pps)
            let range = leading
                ? min(max(snap(r.lowerBound + dt), g.lowerBound), r.upperBound - StudioDocument.minZoom)...r.upperBound
                : r.lowerBound...max(min(snap(r.upperBound + dt), g.upperBound), r.lowerBound + StudioDocument.minZoom)
            setRange(l, id, range)
        case let .new(l, start, _, g)?:
            drag = .new(l, start: start, current: min(max(time(p.x), g.lowerBound), g.upperBound), gap: g)
        case nil:
            break
        }
        needsDisplay = true
    }

    private func setRange(_ l: Lane, _ id: UUID, _ range: ClosedRange<Double>) {
        editor.apply { d in
            switch l {
            case .zoom: d.setZoom(id, output: range)
            case .mask: d.setMask(id, output: range)
            case .camera: d.setLayout(id, output: range)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case let .new(l, a, b, g)? = drag {
            var range = min(a, b)...max(a, b)
            if abs(b - a) * Double(pps) < 4 {
                let end = min(g.upperBound, a + Self.defaultLength)
                range = max(g.lowerBound, min(a, end - Self.defaultLength))...end
            }
            switch l {
            case .zoom: editor.addZoom(range)
            case .mask: editor.addMask(range)
            case .camera: editor.addLayout(range)
            }
        }
        if case .move? = drag { NSCursor.openHand.set() }
        drag = nil
        needsDisplay = true
    }

    // MARK: Context menu

    /// Right-click: selects what's under the pointer and offers its commands (or adding one on an empty track).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard editor.sources != nil else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let t = time(p.x)
        let ed = editor
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ key: String = "", on: Bool? = nil, enabled: Bool = true, _ run: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, keyEquivalent: key, action: run)
            if let on { i.state = on ? .on : .off }
            i.isEnabled = enabled
            menu.addItem(i)
        }
        func edits() {
            menu.addItem(.separator())
            item("Copy", "c") { ed.copy() }
            item("Paste", "v", enabled: ed.copied != nil) { ed.paste() }
        }
        if let key = keyRects().last(where: { $0.rect.contains(p) }) {
            let off = ed.doc.keystrokes.isHidden(key.badge)
            item(off ? "Show This Time" : "Hide This Time") { ed.toggleBadgeHidden(key.badge); self.needsDisplay = true }
            if KeyBadge.classify(key.badge.label).standalone {   // a shortcut, not typed text
                item("Hide Every “%@”".loc(key.badge.label)) { ed.hideEveryBadge(key.badge.label); self.needsDisplay = true }
            }
            return menu
        }
        if let (l, id, _) = barHit(p) {
            ed.selection = selection(l, id)
            needsDisplay = true
            switch l {
            case .zoom:
                guard let z = ed.doc.zooms.first(where: { $0.id == id }) else { return nil }
                item("Follow Cursor", on: z.followCursor && ed.hasPointer, enabled: ed.hasPointer) { ed.setSelectedZoomFollows(true) }
                item("Manual", on: !(z.followCursor && ed.hasPointer)) { ed.setSelectedZoomFollows(false) }
                menu.addItem(.separator())
                item("Zoom On", on: !z.disabled) { ed.toggleSelectionDisabled() }
                item("Split at Playhead") { ed.splitZoomAtPlayhead() }
                item("Duplicate", "d") { ed.duplicateSelection() }
            case .mask:
                guard let m = ed.doc.masks.first(where: { $0.id == id }) else { return nil }
                item("Blur", on: m.kind == .blur) { ed.editMask(id, coalesce: "kind") { $0.kind = .blur } }
                item("Highlight", on: m.kind == .highlight) { ed.editMask(id, coalesce: "kind") { $0.kind = .highlight } }
                menu.addItem(.separator())
                item("Mask On", on: !m.disabled) { ed.toggleSelectionDisabled() }
                item(m.kind == .blur ? "Apply Blur Amount to All Blur Masks" : "Apply Dimming to All Highlight Masks",
                     enabled: ed.doc.masks.filter { $0.kind == m.kind }.count > 1) { ed.applyMaskStrengthToAll(m) }
                item("Duplicate", "d") { ed.duplicateSelection() }
            case .camera:
                guard let c = ed.doc.layouts.first(where: { $0.id == id }) else { return nil }
                item("Camera only", on: c.kind == .cameraOnly) { ed.setLayoutKind(id, .cameraOnly) }
                item("Custom camera", on: c.kind == .custom) { ed.setLayoutKind(id, .custom) }
                item("Screen only", on: c.kind == .screenOnly) { ed.setLayoutKind(id, .screenOnly) }
                menu.addItem(.separator())
                if c.kind == .custom {
                    let move = NSMenuItem(title: "Move Camera".loc, action: nil, keyEquivalent: "")
                    move.submenu = NSMenu()
                    for (title, dx, dy) in [("Left", -1, 0), ("Right", 1, 0), ("Up", 0, -1), ("Down", 0, 1)] {
                        move.submenu?.addItem(ClosureMenuItem(title: title, keyEquivalent: "") { ed.stepLayoutCamera(id, dx: dx, dy: dy) })
                    }
                    menu.addItem(move)
                }
                menu.addItem(.separator())
                item("Layout On", on: !c.disabled) { ed.toggleSelectionDisabled() }
                item("Split at Playhead") { ed.splitLayoutAtPlayhead() }
                item("Duplicate", "d") { ed.duplicateSelection() }
            }
            edits()
            menu.addItem(.separator())
            item("Delete") { ed.deleteSelection() }
        } else if p.y >= clipTop, p.y <= clipTop + clipH, let i = ed.doc.clipIndex(at: t), x(Double(duration)) >= p.x {
            let c = ed.doc.clips[i]
            ed.selection = .clip(c.id)
            needsDisplay = true
            let speed = NSMenuItem(title: "Speed".loc, action: nil, keyEquivalent: "")
            speed.submenu = NSMenu()
            for s in StudioDocument.Clip.speeds {
                let si = ClosureMenuItem(title: StudioDocument.Clip.speedTitle(s), keyEquivalent: "") { ed.setClipSpeed(c.id, s) }
                si.state = c.speed == s ? .on : .off
                speed.submenu?.addItem(si)
            }
            menu.addItem(speed)
            item("Hide Cursor", on: c.hideCursor, enabled: ed.hasPointer) { ed.editClip(c.id) { $0.hideCursor.toggle() } }
            item("Smooth Cursor Movement", on: c.smoothCursor, enabled: ed.hasPointer) { ed.editClip(c.id) { $0.smoothCursor.toggle() } }
            menu.addItem(.separator())
            item("Split at Playhead") { ed.splitAtPlayhead() }
            item("Merge with Previous", enabled: i > 0) { ed.mergeClipWithPrevious(c.id) }
            item("Merge with Next", enabled: i + 1 < ed.doc.clips.count) { ed.mergeClipWithNext(c.id) }
            item("Reset Trim") { ed.resetTrim(c.id) }
            item("Remove All Cuts", enabled: ed.doc.clips.count > 1 || c.start > 0) { ed.removeAllCuts() }
            edits()
            menu.addItem(.separator())
            item("Delete", enabled: ed.doc.clips.count > 1) { ed.deleteSelection() }
        } else if let l = lane(at: p.y), let g = freeGap(l, around: t) {
            let range = t...min(g.upperBound, t + Self.defaultLength)
            switch l {
            case .zoom: item("Add Zoom Here") { _ = ed.addZoom(range) }
            case .mask:
                item("Add Blur Here") { _ = ed.addMask(range) }
                item("Add Highlight Here") { _ = ed.addMask(range, kind: .highlight) }
            case .camera: item("Add Camera Layout Here") { ed.addLayout(range) }
            }
            item("Paste", "v", enabled: ed.copied != nil) { ed.selection = nil; ed.seek(to: t); ed.paste() }
        } else {
            return nil
        }
        return menu
    }

    private func autoscroll(_ p: CGPoint) {
        guard maxOffset > 0 else { return }
        let edge: CGFloat = 24
        if p.x < edge { offsetX = max(0, offsetX - (edge - p.x)) } else if p.x > bounds.width - edge { offsetX = min(maxOffset, offsetX + (p.x - bounds.width + edge)) }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            zoom(by: exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)), anchorX: convert(event.locationInWindow, from: nil).x)
            return
        }
        let d = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        offsetX = min(max(0, offsetX - d * (event.hasPreciseScrollingDeltas ? 1 : 8)), maxOffset)
        needsDisplay = true
        updatePlayhead(follow: false)
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, anchorX: convert(event.locationInWindow, from: nil).x)
    }
}

/// The playhead: a knob in the ruler and a line through the tracks. Never intercepts the mouse.
private final class PlayheadView: NSView {
    static let width: CGFloat = 13
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let mid = bounds.midX
        ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: mid - 1, y: 10, width: 2, height: bounds.height - 18))
        let knob = CGMutablePath()
        knob.addRoundedRect(in: CGRect(x: mid - 6, y: 2, width: 12, height: 10), cornerWidth: 3, cornerHeight: 3)
        knob.move(to: CGPoint(x: mid - 6, y: 9))
        knob.addLine(to: CGPoint(x: mid, y: 17))
        knob.addLine(to: CGPoint(x: mid + 6, y: 9))
        knob.closeSubpath()
        ctx.addPath(knob)
        ctx.fillPath()
    }
}
