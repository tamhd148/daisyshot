import AppKit
import ScreenCaptureKit
import SwiftUI

enum OverlayMode { case area, window, allInOne }

enum OverlayAction: String, CaseIterable {
    case screenshot, video, gif, scroll, text, timer, pin, copy, annotate, save
}

enum OverlayResult {
    case region(CaptureRegion, OverlayAction)
    case window(CGWindowID, OverlayAction)
    case cancelled
}

enum CrosshairMode: Int, CaseIterable {
    case disabled, withCommand, always
    var title: String { ["Disabled", "When ⌘ Command is pressed", "Always enabled"][rawValue] }
}

extension Prefs.Key {
    /// `CrosshairMode` raw value. The magnifier is only shown while the crosshair is.
    static let crosshairStyle = Prefs.Key("crosshairStyle", 0)
}

/// A window under the pointer, in overlay (display-local, top-left) points.
struct OverlayWindowInfo {
    var id: CGWindowID
    var rect: CGRect
    var name: String
}

/// Full-screen selection UI on every display: area drag, window picking, crosshair + magnifier, and the
/// adjustable All-In-One frame with its HUD.
@MainActor
final class SelectionOverlay {
    private var windows: [NSWindow] = []
    private var views: [OverlayView] = []
    private var continuation: CheckedContinuation<OverlayResult, Never>?
    let mode: OverlayMode
    let hint: String?
    /// A click without dragging selects the whole display instead of the window under the pointer (timer, recording).
    var clickCapturesFullscreen = false
    /// All-In-One: start with this selection (adjusting) instead of the remembered one.
    var seed: CaptureRegion?
    /// ⇧ state at the moment the result was produced (inverts window background / skips the background preset).
    private(set) var shiftHeld = false
    let aio = AIOModel()

    init(mode: OverlayMode, hint: String? = nil) {
        self.mode = mode
        self.hint = hint
    }

    var windowNumbers: [Int] { windows.map(\.windowNumber) }

    /// Shows the overlay and waits for a result. Windows stay up until `close()` so the caller can capture
    /// the live screen while excluding them (no flicker, no stale frames).
    func run() async -> OverlayResult {
        // The overlay appears at once; the stills of every display (magnifier, edge snapping, "freeze screen") are
        // grabbed concurrently right after and filled in (`loadBackgrounds`).
        let wins = CaptureService.visibleWindows()
        let freeze = Prefs.bool(.freezeScreen)
        return await withCheckedContinuation { cont in
            continuation = cont
            for screen in NSScreen.screens {
                let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                // Just below pop-up menus so the HUD's menus and tooltips appear above the overlay.
                w.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
                w.isOpaque = false
                w.backgroundColor = .clear
                w.hasShadow = false
                w.isReleasedWhenClosed = false
                w.acceptsMouseMovedEvents = true
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                w.setFrame(screen.frame, display: false)
                let v = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
                v.owner = self
                v.screen_ = screen
                v.allInOne = mode == .allInOne
                v.windowMode = mode == .window
                v.clickCapturesFullscreen = clickCapturesFullscreen
                v.hint = hint
                v.windowRects = wins.compactMap { win in
                    let r = screen.toDisplayRect(NSScreen.fromCGGlobal(win.frame))
                    let vis = r.intersection(CGRect(origin: .zero, size: screen.frame.size))
                    return vis.isNull || vis.isEmpty ? nil : OverlayWindowInfo(id: win.id, rect: r, name: win.title.isEmpty ? win.owner : "\(win.owner) — \(win.title)")
                }
                v.configure(freeze: freeze)
                w.contentView = v
                windows.append(w)
                views.append(v)
            }
            setUpAIO()
            for w in windows { w.orderFrontRegardless() }
            let seed = mode == .allInOne ? self.seed : nil
            let target = seed.flatMap { s in NSScreen.screens.firstIndex { $0.displayID == s.displayID } }
                ?? NSScreen.screens.firstIndex(of: NSScreen.underMouse)
            if let i = target, i < windows.count {
                if let seed { views[i].restoreSelection(seed.rect) } else if mode == .allInOne { restoreAIOArea(on: views[i]) }
            }
            views.forEach { $0.refreshMouse() }
            // Taking focus greys out the user's active window, so "freeze screen" grabs its stills first.
            if !freeze { focus(target) }
            Task {
                await loadBackgrounds()
                if freeze { focus(target) }
            }
        }
    }

    private func focus(_ i: Int?) {
        guard continuation != nil else { return }
        NSApp.activate()
        guard let i, i < windows.count else { return }
        windows[i].makeKeyAndOrderFront(nil)
        windows[i].makeFirstResponder(views[i])
    }

    /// Stills of every display, captured concurrently. Our own windows (this overlay included) are left out of them.
    private func loadBackgrounds() async {
        let overlay = Set(windows.map { CGWindowID($0.windowNumber) })
        var content: SCShareableContent?
        for _ in 0..<5 {   // the overlay must be listed to be excluded; it normally is on the first query
            content = try? await CaptureService.content()
            guard let c = content, !overlay.isSubset(of: Set(c.windows.map(\.windowID))) else { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
        guard let content else {
            Toast.show(CaptureError.permission.localizedDescription, isError: true, seconds: 5)
            finish(.cancelled)
            return
        }
        let grabs = views.map { v in
            (v, Task { try? await CaptureService.displayShot(v.screen_?.displayID ?? 0, content: content) })
        }
        for (v, grab) in grabs {
            if let shot = await grab.value { v.setBackground(shot) }
        }
    }

    func finish(_ r: OverlayResult) {
        guard let c = continuation else { return }
        continuation = nil
        shiftHeld = NSEvent.modifierFlags.contains(.shift)
        if mode == .allInOne, case let .region(region, _) = r { rememberAIOArea(region) }
        views.forEach { $0.endInteraction() }
        NSCursor.arrow.set()
        if case .cancelled = r { close() }
        c.resume(returning: r)
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }

    /// When one display starts a selection the others go back to plain dimming; the HUD follows the selection.
    func didBeginSelection(on view: OverlayView) {
        for v in views where v !== view { v.resetSelection() }
        if mode == .allInOne { view.showToolbar() }
    }

    /// Key events go to the display holding the selection (or the one under the pointer), whichever window is key.
    func keyDown(_ e: NSEvent, from view: OverlayView) {
        let target = views.first { $0.hasSelection } ?? views.first { $0.mouseInside } ?? view
        target.handleKey(e)
    }

    func setWindowMode(_ on: Bool) {
        for v in views { v.setWindowMode(on) }
        aio.windowMode = on
    }

    /// Captured still of the selection, used when "freeze screen" is on.
    func frozenShot(for region: CaptureRegion) -> Shot? {
        guard let v = views.first(where: { $0.screen_?.displayID == region.displayID }), v.freeze, let bg = v.background else { return nil }
        return CaptureService.crop(bg, to: region.rect)
    }

    // MARK: All-In-One

    private func setUpAIO() {
        guard mode == .allInOne else { return }
        aio.perform = { [weak self] a in self?.activeView?.complete(a) }
        aio.setSize = { [weak self] w, h in self?.activeView?.setSelectionSize(CGSize(width: w, height: h)) }
        aio.fullscreen = { [weak self] in self?.activeView?.selectFullscreen() }
        aio.toggleWindowMode = { [weak self] in self.map { $0.setWindowMode(!$0.aio.windowMode) } }
        aio.cancel = { [weak self] in self?.finish(.cancelled) }
        aio.onRatioChange = { [weak self] in self?.activeView?.applyRatio() }
        aio.endEditing = { [weak self] in
            guard let v = self?.activeView else { return }
            v.window?.makeFirstResponder(v)
        }
    }

    private var activeView: OverlayView? { views.first { $0.hasToolbar } ?? views.first { $0.hasSelection } }

    private var savedAreas: [String: CGRect] {
        get { Prefs.codable(.allInOneAreas, [String: CGRect].self) ?? [:] }
        set { Prefs.setCodable(newValue, .allInOneAreas) }
    }

    private func restoreAIOArea(on view: OverlayView) {
        if Prefs.bool(.rememberAllInOneArea), let id = view.screen_?.displayID, let r = savedAreas[String(id)] {
            view.restoreSelection(r)
        } else {
            view.showToolbar()
        }
    }

    private func rememberAIOArea(_ region: CaptureRegion) {
        guard Prefs.bool(.rememberAllInOneArea) else { return }
        savedAreas[String(region.displayID)] = region.rect
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    weak var owner: SelectionOverlay?
    var screen_: NSScreen?
    private(set) var background: Shot?
    private(set) var freeze = false
    var allInOne = false
    var windowMode = false
    var clickCapturesFullscreen = false
    var hint: String?
    var windowRects: [OverlayWindowInfo] = []

    private enum Drag {
        case none
        case drawing(origin: CGPoint)
        case moving
        case resizing(handle: Int, start: CGRect, from: CGPoint)
    }

    private(set) var mouseInside = false
    private var mouse: CGPoint = .zero
    private var lastDrag: CGPoint = .zero
    private var selection: CGRect?
    private var drag: Drag = .none
    private var adjusting = false
    private var spaceHeld = false
    private var commandHeld = NSEvent.modifierFlags.contains(.command)
    private var shiftHeld = false
    private var toolbar: NSHostingView<AIOToolbar>?

    // Layers (all inside `canvas`, kept beneath subviews such as the HUD). Everything that moves with the pointer is a
    // plain colour/border layer (composited on the GPU) rather than a full-screen CAShapeLayer re-rasterized per event.
    private let canvas = CALayer()
    private let bgLayer = CALayer()
    private let dimLayer = DimLayer()
    private let hoverLayer = CALayer()
    private let borderDark = CALayer()
    private let borderLight = CALayer()
    private let handlesLayer = CAShapeLayer()
    private let crossDark = CrossLayer(thickness: 3)
    private let crossLight = CrossLayer(thickness: 1)
    private let sizePill = PillLayer()
    private let hintPill = PillLayer()
    private let windowPill = PillLayer()
    private let loupe = LoupeLayer()
    private let snapLayer = CAShapeLayer()
    private var crosshairMode = CrosshairMode.disabled
    private var showMagnifier = false

    /// Edge the dragged corner is snapped to (x and/or y), drawn as a guide.
    private var snapGuide: (x: CGFloat?, y: CGFloat?) = (nil, nil)
    private var drawnSnapGuide: (x: CGFloat?, y: CGFloat?) = (nil, nil)
    /// Snap targets: window frames, plus strong straight edges of the background still once it has been analysed (off-main).
    private var snapLines: (xs: [CGFloat], ys: [CGFloat]) = ([], [])

    var hasSelection: Bool { selection != nil }
    var hasToolbar: Bool { toolbar != nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(freeze: Bool) {
        self.freeze = freeze
        crosshairMode = CrosshairMode(rawValue: Prefs.int(.crosshairStyle)) ?? .disabled
        showMagnifier = Prefs.bool(.showMagnifier)
        for w in windowRects {
            snapLines.xs += [w.rect.minX, w.rect.maxX]
            snapLines.ys += [w.rect.minY, w.rect.maxY]
        }
        wantsLayer = true
        guard let root = layer else { return }
        let scale = screen_?.backingScaleFactor ?? 2
        canvas.frame = bounds
        root.insertSublayer(canvas, at: 0)
        bgLayer.frame = bounds
        bgLayer.contentsGravity = .resize
        dimLayer.frame = bounds
        dimLayer.color = NSColor.black.withAlphaComponent(0.3).cgColor
        hoverLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        hoverLayer.borderColor = NSColor.controlAccentColor.cgColor
        hoverLayer.borderWidth = 2
        borderDark.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        borderDark.borderWidth = 1
        borderLight.borderColor = NSColor.white.withAlphaComponent(0.95).cgColor
        borderLight.borderWidth = 1
        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
        handlesLayer.lineWidth = 1
        handlesLayer.shadowColor = NSColor.black.cgColor
        handlesLayer.shadowOpacity = 0.3
        handlesLayer.shadowRadius = 2
        handlesLayer.shadowOffset = .zero
        crossDark.frame = bounds
        crossDark.color = NSColor.black.withAlphaComponent(0.3).cgColor
        crossLight.frame = bounds
        crossLight.color = NSColor.white.withAlphaComponent(0.9).cgColor
        snapLayer.fillColor = nil
        snapLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        snapLayer.lineWidth = 1
        snapLayer.lineDashPattern = [4, 3]
        for l in [bgLayer, dimLayer, hoverLayer, snapLayer, borderDark, borderLight, handlesLayer, crossDark, crossLight, windowPill, sizePill, hintPill, loupe] as [CALayer] {
            l.contentsScale = scale
            l.isHidden = l !== bgLayer && l !== dimLayer
            canvas.addSublayer(l)
        }
        [sizePill, hintPill, windowPill].forEach { $0.setScale(scale) }
        loupe.setScale(scale)
        refresh()
    }

    /// The display still arrived: frozen backdrop, magnifier source, and (analysed off the main thread) edge snap targets.
    func setBackground(_ shot: Shot) {
        background = shot
        if freeze {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bgLayer.contents = shot.image
            CATransaction.commit()
        }
        refresh()
        Task {
            let e = await Task.detached(priority: .userInitiated) { Self.edges(of: shot) }.value
            snapLines.xs += e.xs
            snapLines.ys += e.ys
        }
    }

    /// Strong straight vertical (xs) and horizontal (ys) edges of a display still, in points: the detector Annotate uses
    /// for crop snapping (`ImageAnalysis.edgeLines` on a ≤1600 px luminance map). ~60 ms on a 5K display, so never on main.
    nonisolated static func edges(of shot: Shot) -> (xs: [CGFloat], ys: [CGFloat]) {
        let img = shot.image
        let k = min(1, 1600 / CGFloat(max(img.width, img.height, 1)))
        let w = max(1, Int(CGFloat(img.width) * k)), h = max(1, Int(CGFloat(img.height) * k))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return ([], []) }
        let lum: [Int] = stride(from: 0, to: px.count, by: 4).map { i in
            let r = Int(px[i]) * 3, g = Int(px[i + 1]) * 6
            return r + g + Int(px[i + 2])
        }
        let e = ImageAnalysis.edgeLines(lum, w: w, h: h)
        let f = CGFloat(img.width) / (CGFloat(w) * shot.scale)
        return (e.xs.map { CGFloat($0) * f }, e.ys.map { CGFloat($0) * f })
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    func refreshMouse() {
        guard let win = window else { return }
        mouse = convert(win.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        mouseInside = bounds.contains(mouse)
        refresh()
        if mouseInside { cursor.set() }
    }

    func resetSelection() {
        selection = nil
        drag = .none
        adjusting = false
        hideToolbar()
        refresh()
    }

    func endInteraction() {
        drag = .none
        mouseInside = false
        refresh()
    }

    private var hoveredWindow: OverlayWindowInfo? {
        windowRects.first { $0.rect.contains(mouse) }
    }

    private var ratio: CGFloat? { allInOne ? owner?.aio.ratio : nil }

    private var crosshairVisible: Bool {
        guard mouseInside, !windowMode, !adjusting || isDragging else { return false }
        switch crosshairMode {
        case .disabled: return false
        case .withCommand: return commandHeld
        case .always: return true
        }
    }

    private var isDragging: Bool { if case .none = drag { return false } else { return true } }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        mouseInside = true
        refresh()
        cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        refresh()
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        if window?.firstResponder is NSTextView { return } // keep focus in a HUD field being edited
        window?.makeKey()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        lastDrag = p
        window?.makeFirstResponder(self)
        if adjusting, let sel = selection {
            if let h = handle(at: p, in: sel) { drag = .resizing(handle: h, start: sel, from: p); refresh(); return }
            if sel.contains(p) { drag = .moving; cursor.set(); refresh(); return }
        }
        if windowMode { return } // the window is picked on mouse-up
        owner?.didBeginSelection(on: self)
        adjusting = false
        let o = snapped(p, event)
        drag = .drawing(origin: o)
        selection = CGRect(origin: o, size: .zero)
        refresh()
    }

    /// `p` pulled onto a window / UI edge within 6 pt (each axis on its own). ⌘ held disables snapping —
    /// ⌃ instead when ⌘ already shows the crosshair.
    private func snapped(_ p: CGPoint, _ event: NSEvent) -> CGPoint {
        let commandShowsCrosshair = crosshairMode == .withCommand
        let off = event.modifierFlags.contains(commandShowsCrosshair ? .control : .command)
        snapGuide = off ? (nil, nil) : (Self.snap(p.x, to: snapLines.xs), Self.snap(p.y, to: snapLines.ys))
        return CGPoint(x: snapGuide.x ?? p.x, y: snapGuide.y ?? p.y)
    }

    /// Nearest candidate within `distance`, else nil.
    static func snap(_ v: CGFloat, to candidates: [CGFloat], within distance: CGFloat = 6) -> CGFloat? {
        candidates.min { abs($0 - v) < abs($1 - v) }.flatMap { abs($0 - v) <= distance ? $0 : nil }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil).clamped(to: bounds)
        defer { mouse = p; lastDrag = p; refresh(); cursor.set() }
        switch drag {
        case .none:
            return
        case let .resizing(h, start, from):
            let r = resize(start, handle: h, dx: p.x - from.x, dy: p.y - from.y, ratio: ratio)
            if ratio != nil, !bounds.insetBy(dx: -0.5, dy: -0.5).contains(r) { return }
            selection = r.intersection(bounds)
        case .moving:
            guard let sel = selection else { return }
            selection = sel.offsetBy(dx: p.x - lastDrag.x, dy: p.y - lastDrag.y).keptInside(bounds)
        case let .drawing(origin):
            if spaceHeld, let sel = selection {
                // Space + drag moves the selection being drawn.
                let moved = sel.offsetBy(dx: p.x - lastDrag.x, dy: p.y - lastDrag.y).keptInside(bounds)
                drag = .drawing(origin: CGPoint(x: origin.x + moved.minX - sel.minX, y: origin.y + moved.minY - sel.minY))
                selection = moved
                snapGuide = (nil, nil)
                return
            }
            selection = Self.rect(from: origin, to: snapped(p, event), square: event.modifierFlags.contains(.shift),
                                  fromCenter: event.modifierFlags.contains(.option), ratio: ratio).intersection(bounds)
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .resizing, .moving:
            drag = .none
            refresh()
            cursor.set()
        case .none:
            if windowMode, let hw = hoveredWindow { owner?.finish(.window(hw.id, .screenshot)) }
        case .drawing:
            drag = .none
            spaceHeld = false
            guard let sel = selection else { return }
            if sel.width < 4 || sel.height < 4 {
                // A click without a drag grabs the window under the cursor (or the whole display).
                if allInOne {
                    selection = hoveredWindow?.rect.intersection(bounds) ?? bounds
                    enterAdjusting()
                } else if !clickCapturesFullscreen, let hw = hoveredWindow {
                    owner?.finish(.window(hw.id, .screenshot))
                } else {
                    selection = bounds
                    complete(.screenshot)
                }
                return
            }
            if allInOne { enterAdjusting() } else { complete(.screenshot) }
        }
    }

    override func rightMouseDown(with event: NSEvent) { owner?.finish(.cancelled) }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { owner?.keyDown(event, from: self) }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
    }

    override func flagsChanged(with event: NSEvent) {
        commandHeld = event.modifierFlags.contains(.command)
        shiftHeld = event.modifierFlags.contains(.shift)
        refresh()
        if mouseInside { cursor.set() }
    }

    func handleKey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: // esc
            owner?.finish(.cancelled)
            return
        case 36, 76: // return / enter
            if selection != nil, !isDragging { complete(.screenshot) }
            else if windowMode, let hw = hoveredWindow { owner?.finish(.window(hw.id, .screenshot)) }
            return
        case 49: // space: move while drawing, otherwise toggle window picking
            if case .drawing = drag { spaceHeld = true } else if !event.isARepeat { owner?.setWindowMode(!windowMode) }
            return
        case 123, 124, 125, 126: // arrows nudge (⌥ resizes, ⇧ ×10)
            guard adjusting, var sel = selection else { return }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let (dx, dy): (CGFloat, CGFloat) = [123: (-step, 0), 124: (step, 0), 125: (0, step), 126: (0, -step)][event.keyCode]!
            if flags.contains(.option) {
                sel.size.width = max(4, sel.width + dx)
                sel.size.height = max(4, sel.height + dy)
                selection = sel.intersection(bounds)
            } else {
                selection = sel.offsetBy(dx: dx, dy: dy).keptInside(bounds)
            }
            refresh()
            return
        default:
            break
        }
        guard let ch = event.charactersIgnoringModifiers?.lowercased() else { return }
        if flags.contains(.command) {
            if allInOne, selection != nil, ch == "c" { complete(.copy) }
            if allInOne, selection != nil, ch == "s" { complete(.save) }
            return
        }
        switch ch {
        case "w": owner?.setWindowMode(!windowMode)
        case "f": selectFullscreen()
        case "a" where allInOne:
            if windowMode { owner?.setWindowMode(false) } else if selection != nil { complete(.screenshot) }
        default:
            guard allInOne, selection != nil, !isDragging else { return }
            let map: [String: OverlayAction] = ["s": .scroll, "t": .timer, "o": .text, "r": .video, "g": .gif, "p": .pin, "e": .annotate]
            if let a = map[ch] { complete(a) }
        }
    }

    func setWindowMode(_ on: Bool) {
        windowMode = on
        if on { selection = nil; adjusting = false; drag = .none }
        refresh()
        if mouseInside { cursor.set() }
    }

    func complete(_ action: OverlayAction) {
        guard let sel = selection?.integral, sel.width >= 1, sel.height >= 1, let screen = screen_ else { return }
        owner?.finish(.region(CaptureRegion(displayID: screen.displayID, rect: sel), action))
    }

    /// F / the Fullscreen button: the whole display, captured straight away.
    func selectFullscreen() {
        owner?.didBeginSelection(on: self)
        selection = bounds
        complete(.screenshot)
    }

    // MARK: All-In-One

    func restoreSelection(_ r: CGRect) {
        let r = r.intersection(bounds)
        guard r.width >= 4, r.height >= 4 else { showToolbar(); return }
        selection = r
        enterAdjusting()
    }

    private func enterAdjusting() {
        adjusting = true
        showToolbar()
        handlesLayer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.15
        handlesLayer.add(fade, forKey: "fade")
        handlesLayer.opacity = 1
        refresh()
    }

    func showToolbar() {
        guard allInOne, toolbar == nil, let model = owner?.aio else { layoutToolbar(); return }
        let tb = NSHostingView(rootView: AIOToolbar(model: model))
        tb.setFrameSize(tb.fittingSize)
        tb.alphaValue = 0
        addSubview(tb)
        toolbar = tb
        syncModel()
        layoutToolbar()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            tb.animator().alphaValue = 1
        }
    }

    private func hideToolbar() {
        toolbar?.removeFromSuperview()
        toolbar = nil
    }

    func setSelectionSize(_ size: CGSize) {
        let w = min(size.width, bounds.width), h = min(size.height, bounds.height)
        let c = selection.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        owner?.didBeginSelection(on: self)
        selection = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h).keptInside(bounds)
        if !adjusting { enterAdjusting() } else { refresh() }
    }

    /// A new ratio was picked: reshape the current selection around its centre.
    func applyRatio() {
        guard let r = ratio, let sel = selection else { return }
        var w = sel.width, h = sel.width / r
        if h > bounds.height { h = bounds.height; w = h * r }
        if w > bounds.width { w = bounds.width; h = w / r }
        selection = CGRect(x: sel.midX - w / 2, y: sel.midY - h / 2, width: w, height: h).keptInside(bounds)
        refresh()
    }

    private func syncModel() {
        guard allInOne, toolbar != nil, let m = owner?.aio else { return }
        let w = Int(selection?.width.rounded() ?? 0), h = Int(selection?.height.rounded() ?? 0)
        if m.width != w { m.width = w }
        if m.height != h { m.height = h }
        let has = selection != nil && adjusting
        if m.hasSelection != has { m.hasSelection = has }
    }

    private func layoutToolbar() {
        guard let tb = toolbar, let screen = screen_ else { return }
        let size = tb.frame.size
        var origin: CGPoint
        if let sel = selection, adjusting {
            origin = CGPoint(x: sel.midX - size.width / 2, y: sel.maxY + 4)
            if origin.y + size.height > bounds.maxY - 4 { origin.y = sel.minY - size.height - 4 }
            if origin.y < 4 { origin.y = sel.maxY - size.height - 12 }
        } else {
            let dock = screen.visibleFrame.minY - screen.frame.minY
            origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - dock - size.height - 40)
        }
        origin.x = min(max(4, origin.x), bounds.width - size.width - 4)
        origin.y = min(max(4, origin.y), bounds.height - size.height - 4)
        tb.frame.origin = origin
    }

    // MARK: Geometry

    static func rect(from o: CGPoint, to p: CGPoint, square: Bool, fromCenter: Bool, ratio: CGFloat?) -> CGRect {
        var w = p.x - o.x, h = p.y - o.y
        if let r = ratio ?? (square ? 1 : nil) {
            if abs(w) / r > abs(h) { h = (h < 0 ? -1 : 1) * abs(w) / r } else { w = (w < 0 ? -1 : 1) * abs(h) * r }
        }
        if fromCenter { return CGRect(x: o.x - abs(w), y: o.y - abs(h), width: abs(w) * 2, height: abs(h) * 2) }
        return CGRect(x: o.x, y: o.y, width: w, height: h).standardized
    }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    /// 0…7 clockwise from the top-left corner; edges are grabbable along their whole length.
    private func handle(at p: CGPoint, in r: CGRect) -> Int? {
        if let i = handlePoints(r).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 10 }) { return i }
        let tol: CGFloat = 5
        let inX = p.x > r.minX && p.x < r.maxX, inY = p.y > r.minY && p.y < r.maxY
        if inX, abs(p.y - r.minY) < tol { return 1 }
        if inY, abs(p.x - r.maxX) < tol { return 3 }
        if inX, abs(p.y - r.maxY) < tol { return 5 }
        if inY, abs(p.x - r.minX) < tol { return 7 }
        return nil
    }

    static func resize(_ r: CGRect, handle h: Int, dx: CGFloat, dy: CGFloat, ratio: CGFloat?) -> CGRect {
        let left = [0, 6, 7].contains(h), right = [2, 3, 4].contains(h), top = [0, 1, 2].contains(h), bottom = [4, 5, 6].contains(h)
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        if left { minX += dx }
        if right { maxX += dx }
        if top { minY += dy }
        if bottom { maxY += dy }
        var out = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        guard let ratio, ratio > 0 else { return out }
        switch h {
        case 3, 7: // side edges drive the width
            let nh = out.width / ratio
            out = CGRect(x: out.minX, y: r.midY - nh / 2, width: out.width, height: nh)
        case 1, 5: // top/bottom edges drive the height
            let nw = out.height * ratio
            out = CGRect(x: r.midX - nw / 2, y: out.minY, width: nw, height: out.height)
        default: // corners: anchored at the opposite corner
            let ax = left ? r.maxX : r.minX, ay = top ? r.maxY : r.minY
            let mx = left ? minX : maxX, my = top ? minY : maxY
            let w = max(abs(mx - ax), abs(my - ay) * ratio), hh = w / ratio
            out = CGRect(x: mx >= ax ? ax : ax - w, y: my >= ay ? ay : ay - hh, width: w, height: hh)
        }
        return out
    }

    private func resize(_ r: CGRect, handle h: Int, dx: CGFloat, dy: CGFloat, ratio: CGFloat?) -> CGRect {
        Self.resize(r, handle: h, dx: dx, dy: dy, ratio: ratio)
    }

    // MARK: Cursor

    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }, hotSpot: .zero)

    private static func resizeCursor(_ h: Int) -> NSCursor {
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        return NSCursor.frameResize(position: positions[h], directions: .all)
    }

    private var cursor: NSCursor {
        if let tb = toolbar, tb.frame.contains(mouse) { return .arrow }
        switch drag {
        case .moving: return .closedHand
        case let .resizing(h, _, _): return Self.resizeCursor(h)
        default: break
        }
        if adjusting, !isDragging, let sel = selection {
            if let h = handle(at: mouse, in: sel) { return Self.resizeCursor(h) }
            if sel.contains(mouse) { return .openHand }
        }
        if windowMode { return .pointingHand }
        return crosshairVisible ? Self.blankCursor : .crosshair
    }

    // MARK: Rendering

    /// Pushes the current state into the layers (no implicit animations).
    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let hovered = windowMode && selection == nil ? hoveredWindow : nil
        let focus = selection ?? hovered?.rect
        dimLayer.hole = focus.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }

        hoverLayer.isHidden = hovered == nil
        windowPill.isHidden = hovered == nil || !mouseInside
        if let hw = hovered {
            hoverLayer.frame = hw.rect
            windowPill.text = "\(hw.name)  ·  \(Int(hw.rect.width)) × \(Int(hw.rect.height))"
            windowPill.position(centeredAt: CGPoint(x: hw.rect.midX, y: hw.rect.midY), in: bounds)
        }

        if let sel = selection, sel.width > 0, sel.height > 0 {
            // Same pixels as 1 pt strokes centred 0.5 / 1.5 pt outside the selection.
            borderLight.frame = sel.insetBy(dx: -1, dy: -1)
            borderDark.frame = sel.insetBy(dx: -2, dy: -2)
            borderLight.isHidden = false
            borderDark.isHidden = false
        } else {
            borderLight.isHidden = true
            borderDark.isHidden = true
        }

        if adjusting, let sel = selection {
            let p = CGMutablePath()
            for hp in handlePoints(sel) { p.addEllipse(in: CGRect(x: hp.x - 4.5, y: hp.y - 4.5, width: 9, height: 9)) }
            handlesLayer.path = p
            handlesLayer.shadowPath = p   // no offscreen pass to find the shadow's shape
            handlesLayer.isHidden = false
        } else {
            handlesLayer.isHidden = true
        }

        // Dimension label while drawing or resizing (the All-In-One HUD shows it otherwise).
        if let sel = selection, isDragging || (!allInOne && sel.width > 0) {
            sizePill.text = "\(Int(sel.width.rounded())) × \(Int(sel.height.rounded()))"
            let s = sizePill.bounds.size
            var y = sel.minY - s.height - 8
            if y < 4 { y = sel.minY + 8 }
            sizePill.frame.origin = CGPoint(x: min(max(4, sel.midX - s.width / 2), bounds.width - s.width - 4), y: y)
            sizePill.isHidden = false
        } else {
            sizePill.isHidden = true
        }

        if case .drawing = drag, snapGuide.x != nil || snapGuide.y != nil {
            if snapGuide != drawnSnapGuide {   // the guide usually stays put for many drag events
                drawnSnapGuide = snapGuide
                let p = CGMutablePath()
                if let x = snapGuide.x { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: bounds.height)) }
                if let y = snapGuide.y { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: bounds.width, y: y)) }
                snapLayer.path = p
            }
            snapLayer.isHidden = false
        } else {
            snapLayer.isHidden = true
        }

        let showCross = crosshairVisible
        crossDark.isHidden = !showCross
        crossLight.isHidden = !showCross
        if showCross {
            crossDark.at = CGPoint(x: floor(mouse.x), y: floor(mouse.y))
            crossLight.at = crossDark.at
        }
        if showCross, showMagnifier, let bg = background {
            loupe.isHidden = false
            loupe.update(source: bg, at: mouse, in: bounds)
        } else {
            loupe.isHidden = true
        }

        let hintText: String? = {
            guard mouseInside, selection == nil, !isDragging, hovered == nil else { return nil }
            if windowMode { return "Click a window to capture it · Space/W: select an area · Esc: cancel".loc }
            if let hint { return hint.loc }
            return (allInOne ? "Drag over the part of the screen you want." : "Drag to select capture area · Space/W: window · F: fullscreen · Esc: cancel").loc
        }()
        hintPill.isHidden = hintText == nil
        if let hintText {
            hintPill.text = hintText
            let menuBar = (screen_.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 24)
            hintPill.position(centeredAt: CGPoint(x: bounds.midX, y: menuBar + 36), in: bounds)
        }

        syncModel()
        layoutToolbar()
    }
}

// MARK: - Layers

/// Dimming with an optional clear hole: four solid rectangles around it (no path to rasterize when the hole moves).
final class DimLayer: CALayer {
    private let parts = (0..<4).map { _ in CALayer() }
    var color: CGColor? { didSet { parts.forEach { $0.backgroundColor = color } } }
    var hole: CGRect? { didSet { if hole != oldValue { layoutParts() } } }

    override init() {
        super.init()
        parts.forEach(addSublayer)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override var frame: CGRect { didSet { layoutParts() } }

    private func layoutParts() {
        let b = bounds
        guard let h = hole?.intersection(b), !h.isNull, !h.isEmpty else {
            parts[0].frame = b
            for p in parts.dropFirst() { p.frame = .zero }
            return
        }
        parts[0].frame = CGRect(x: b.minX, y: b.minY, width: b.width, height: h.minY - b.minY)        // above
        parts[1].frame = CGRect(x: b.minX, y: h.maxY, width: b.width, height: b.maxY - h.maxY)        // below
        parts[2].frame = CGRect(x: b.minX, y: h.minY, width: h.minX - b.minX, height: h.height)       // left
        parts[3].frame = CGRect(x: h.maxX, y: h.minY, width: b.maxX - h.maxX, height: h.height)       // right
    }
}

/// Full-length horizontal + vertical line through `at` (the pixel's top-left corner), `thickness` pt, centred on that pixel.
final class CrossLayer: CALayer {
    private let h = CALayer(), v = CALayer()
    private var thickness: CGFloat = 1
    var color: CGColor? { didSet { h.backgroundColor = color; v.backgroundColor = color } }
    var at = CGPoint.zero {
        didSet {
            let o = 0.5 - thickness / 2
            h.frame = CGRect(x: 0, y: at.y + o, width: bounds.width, height: thickness)
            v.frame = CGRect(x: at.x + o, y: 0, width: thickness, height: bounds.height)
        }
    }

    init(thickness: CGFloat) {
        super.init()
        self.thickness = thickness
        addSublayer(h)
        addSublayer(v)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }
}

/// Rounded dark label used for dimensions, hints and window names.
final class PillLayer: CALayer {
    private let textLayer = CATextLayer()
    private let swatch = CALayer()

    var text = "" {
        didSet { if text != oldValue { relayout() } }
    }
    /// Optional colour chip shown before the text (magnifier).
    var swatchColor: CGColor? {
        didSet { swatch.backgroundColor = swatchColor; swatch.isHidden = swatchColor == nil; relayout() }
    }

    override init() {
        super.init()
        backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        borderWidth = 1
        textLayer.alignmentMode = .left
        swatch.cornerRadius = 3
        swatch.borderWidth = 1
        swatch.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        swatch.isHidden = true
        addSublayer(textLayer)
        addSublayer(swatch)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setScale(_ s: CGFloat) {
        contentsScale = s
        textLayer.contentsScale = s
        swatch.contentsScale = s
    }

    private func relayout() {
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ])
        textLayer.string = str
        let size = str.size()
        let lead: CGFloat = swatch.isHidden ? 10 : 30
        bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + lead + 10, height: ceil(size.height) + 8)
        cornerRadius = bounds.height / 2
        textLayer.frame = CGRect(x: lead, y: 4, width: ceil(size.width) + 1, height: ceil(size.height))
        swatch.frame = CGRect(x: 9, y: (bounds.height - 14) / 2, width: 14, height: 14)
    }

    func position(centeredAt c: CGPoint, in area: CGRect) {
        let s = bounds.size
        frame.origin = CGPoint(x: min(max(area.minX + 4, c.x - s.width / 2), area.maxX - s.width - 4),
                               y: min(max(area.minY + 4, c.y - s.height / 2), area.maxY - s.height - 4))
    }
}

/// Pixel magnifier: a zoomed grid around the pointer plus coordinates and the hex colour of the centre pixel.
final class LoupeLayer: CALayer {
    static let pixels = 15
    static let zoom: CGFloat = 8
    private let box = CALayer()
    private let image = CALayer()
    private let grid = CAShapeLayer()
    private let center = CAShapeLayer()
    private let info = PillLayer()

    override init() {
        super.init()
        let side = CGFloat(Self.pixels) * Self.zoom
        bounds = CGRect(x: 0, y: 0, width: side, height: side + 32)
        box.frame = CGRect(x: 0, y: 0, width: side, height: side)
        box.cornerRadius = 12
        box.masksToBounds = true
        box.backgroundColor = NSColor.black.cgColor
        box.borderWidth = 2
        box.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        shadowColor = NSColor.black.cgColor
        shadowOpacity = 0.4
        shadowRadius = 6
        shadowOffset = CGSize(width: 0, height: -2)
        shadowPath = CGPath(roundedRect: box.frame, cornerWidth: 12, cornerHeight: 12, transform: nil)
        image.magnificationFilter = .nearest
        image.contentsGravity = .resize
        let p = CGMutablePath()
        for i in 1..<Self.pixels {
            let v = CGFloat(i) * Self.zoom
            p.move(to: CGPoint(x: v, y: 0)); p.addLine(to: CGPoint(x: v, y: side))
            p.move(to: CGPoint(x: 0, y: v)); p.addLine(to: CGPoint(x: side, y: v))
        }
        grid.path = p
        grid.strokeColor = NSColor.black.withAlphaComponent(0.12).cgColor
        grid.lineWidth = 0.5
        let c = CGFloat(Self.pixels / 2) * Self.zoom
        center.path = CGPath(rect: CGRect(x: c, y: c, width: Self.zoom, height: Self.zoom), transform: nil)
        center.fillColor = nil
        center.strokeColor = NSColor.white.cgColor
        center.lineWidth = 1.5
        center.shadowColor = NSColor.black.cgColor
        center.shadowOpacity = 0.8
        center.shadowRadius = 1
        center.shadowOffset = .zero
        box.addSublayer(image)
        box.addSublayer(grid)
        box.addSublayer(center)
        addSublayer(box)
        addSublayer(info)
        info.swatchColor = NSColor.black.cgColor
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    func setScale(_ s: CGFloat) {
        [self, box, image, grid, center].forEach { $0.contentsScale = s }
        info.setScale(s)
    }

    func update(source: Shot, at p: CGPoint, in area: CGRect) {
        let n = Self.pixels, half = n / 2
        let px = Int(p.x * source.scale), py = Int(p.y * source.scale)
        let src = CGRect(x: px - half, y: py - half, width: n, height: n)
        let clipped = src.intersection(CGRect(x: 0, y: 0, width: source.image.width, height: source.image.height))
        if clipped.isEmpty {
            image.contents = nil
        } else {
            image.contents = source.image.cropping(to: clipped)
            image.frame = CGRect(x: (clipped.minX - src.minX) * Self.zoom, y: (clipped.minY - src.minY) * Self.zoom,
                                 width: clipped.width * Self.zoom, height: clipped.height * Self.zoom)
        }
        let rgb = Self.pixel(source.image, px, py)
        info.swatchColor = rgb.map { CGColor(srgbRed: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255, blue: CGFloat($0.2) / 255, alpha: 1) }
        let hex = rgb.map { String(format: "#%02X%02X%02X", $0.0, $0.1, $0.2) } ?? ""
        info.text = "\(Int(p.x)), \(Int(p.y))   \(hex)"
        let side = box.bounds.width
        info.frame.origin = CGPoint(x: (side - info.bounds.width) / 2, y: side + 6)
        if info.bounds.width > bounds.width { info.frame.origin.x = 0 }

        var o = CGPoint(x: p.x + 22, y: p.y + 22)
        if o.x + bounds.width > area.maxX - 4 { o.x = p.x - bounds.width - 22 }
        if o.y + bounds.height > area.maxY - 4 { o.y = p.y - bounds.height - 22 }
        frame.origin = o
    }

    /// sRGB components of one pixel.
    static func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8)? {
        guard let px = img.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return ok ? (data[0], data[1], data[2]) : nil
    }
}

extension CGPoint {
    func clamped(to r: CGRect) -> CGPoint { CGPoint(x: min(max(x, r.minX), r.maxX), y: min(max(y, r.minY), r.maxY)) }
}

extension CGRect {
    /// Shifted (not resized) so it lies inside `r` when it fits.
    func keptInside(_ r: CGRect) -> CGRect {
        var o = self
        o.origin.x = min(max(r.minX, o.minX), r.maxX - o.width)
        o.origin.y = min(max(r.minY, o.minY), r.maxY - o.height)
        return o.intersection(r)
    }
}

enum SelectionGeometry {
    /// Runnable check for the selection maths (ratio-constrained drawing and handle resizing).
    @MainActor
    static func selfTest() {
        let r = OverlayView.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 260, y: 120), square: false, fromCenter: false, ratio: 16.0 / 9)
        assert(r.width == 160 && abs(r.height - 90) < 0.001)
        let sq = OverlayView.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 40, y: 130), square: true, fromCenter: false, ratio: nil)
        assert(sq == CGRect(x: 40, y: 100, width: 60, height: 60))
        let c = OverlayView.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 110, y: 120), square: false, fromCenter: true, ratio: nil)
        assert(c == CGRect(x: 90, y: 80, width: 20, height: 40))
        let base = CGRect(x: 100, y: 100, width: 200, height: 100)
        assert(OverlayView.resize(base, handle: 4, dx: 20, dy: 10, ratio: nil) == CGRect(x: 100, y: 100, width: 220, height: 110))
        assert(OverlayView.resize(base, handle: 0, dx: 300, dy: 0, ratio: nil) == CGRect(x: 300, y: 100, width: 100, height: 100)) // flips past the edge
        let corner = OverlayView.resize(base, handle: 4, dx: 100, dy: 0, ratio: 2)
        assert(corner == CGRect(x: 100, y: 100, width: 300, height: 150))
        let topLeft = OverlayView.resize(base, handle: 0, dx: -100, dy: 0, ratio: 2)
        assert(topLeft == CGRect(x: 0, y: 50, width: 300, height: 150))
        let side = OverlayView.resize(base, handle: 3, dx: 100, dy: 0, ratio: 2)
        assert(side == CGRect(x: 100, y: 75, width: 300, height: 150))
        assert(OverlayView.snap(103, to: [50, 100, 110]) == 100)
        assert(OverlayView.snap(107, to: [100, 110]) == 110)
        assert(OverlayView.snap(120, to: [100, 113.9]) == nil)
        assert(CGRect(x: -10, y: 5, width: 20, height: 20).keptInside(CGRect(x: 0, y: 0, width: 100, height: 100)) == CGRect(x: 0, y: 5, width: 20, height: 20))
    }
}
