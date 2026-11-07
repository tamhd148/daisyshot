import AppKit
import SwiftUI

/// A screenshot floating above all windows. Drag to move, scroll/pinch to zoom (aspect kept), double-click to annotate,
/// arrow keys nudge (⇧ = 10 pt), ⌘0 actual size, ⌘+/⌘- zoom. Hover shows a toolbar: close, lock, opacity, zoom, copy, save, annotate, drag-out.
/// Locked pins are click-through and fade away while the cursor is over them; unlock them from the menu bar.
final class PinWindow: QuickLookPanel {
    private static var pins: [PinWindow] = []
    /// CONTRACT: pins stay visible in screenshots/recordings (everything else of ours is excluded).
    static var windowNumbers: [Int] { pins.map(\.windowNumber) }
    private static var hiddenAll = false
    private static var styleObserver: NSObjectProtocol?
    private static var lockTimer: Timer?

    let shot: Shot
    private let model = PinModel()
    private let content: PinContentView
    private let aspect: CGFloat
    private var naturalWidth: CGFloat { CGFloat(shot.image.width) / shot.scale }

    // MARK: Class API

    static func pin(_ shot: Shot) {
        let size = CGSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        let screen = NSScreen.underMouse.visibleFrame
        let fit = min(1, screen.width * 0.8 / size.width, screen.height * 0.8 / size.height)
        let s = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        // Cascade new pins a little so they don't stack exactly on top of each other.
        let offset = CGFloat(pins.count % 8) * 24
        let frame = CGRect(x: screen.midX - s.width / 2 + offset, y: screen.midY - s.height / 2 - offset, width: s.width, height: s.height)
        let p = PinWindow(shot: shot, frame: frame)
        pins.append(p)
        if hiddenAll { hiddenAll = false; pins.forEach { $0.orderFrontRegardless() } }
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        observeStyle()
    }

    static func unlockAll() { pins.forEach { $0.setLocked(false) } }

    static func closeAll() { pins.forEach { $0.close() } }

    static func toggleVisibility() {
        guard !pins.isEmpty else { Toast.show("No pinned screenshots", isError: true); return }
        hiddenAll.toggle()
        pins.forEach { hiddenAll ? $0.orderOut(nil) : $0.orderFrontRegardless() }
    }

    @MainActor
    static func chooseAndPin() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        p.message = "Choose images to pin to the screen".loc
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        p.urls.compactMap(Exporter.loadShot).forEach(pin)
    }

    static var hasLocked: Bool { pins.contains { $0.model.locked } }

    @discardableResult
    static func saveAs(_ shot: Shot) -> URL? { Exporter.saveAs(shot) }

    // MARK: Window

    init(shot: Shot, frame: CGRect) {
        self.shot = shot
        aspect = CGFloat(shot.image.width) / CGFloat(max(shot.image.height, 1))
        content = PinContentView(image: shot.image)
        super.init(rect: frame, level: .floating)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
        contentView = content
        content.window_ = self
        model.zoom = frame.width / naturalWidth
        model.actions = PinModel.Actions(
            close: { [unowned self] in close() },
            lock: { [unowned self] in setLocked(true) },
            copy: { [unowned self] in copyImage() },
            save: { [shot] in PinWindow.saveAs(shot) },
            annotate: { [unowned self] in annotate() },
            actualSize: { [unowned self] in resize(to: naturalWidth) },
            opacity: { [unowned self] v in alphaValue = v },
            dragURL: { [unowned self] in tempFile() })
        let bar = NSHostingView(rootView: PinToolbar(model: model))
        content.setToolbar(bar)
        applyStyle()
    }

    override func close() {
        PinWindow.pins.removeAll { $0 === self }
        if !PinWindow.hasLocked { PinWindow.lockTimer?.invalidate(); PinWindow.lockTimer = nil }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; animator().alphaValue = 0 }, completionHandler: { super.close() })
    }

    private var appliedStyle: [Bool]?

    /// Runs on every UserDefaults change (any pref anywhere), so it only touches the window when the pin style changed.
    fileprivate func applyStyle() {
        let style = [Prefs.bool(.pinShadow), Prefs.bool(.pinBorder), Prefs.bool(.pinRounded)]
        guard style != appliedStyle else { return }
        appliedStyle = style
        hasShadow = Prefs.bool(.pinShadow)
        content.applyStyle(border: Prefs.bool(.pinBorder), rounded: Prefs.bool(.pinRounded))
        invalidateShadow()
    }

    private static func observeStyle() {
        guard styleObserver == nil else { return }
        styleObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { pins.forEach { $0.applyStyle() } }
        }
    }

    fileprivate func setLocked(_ v: Bool) {
        model.locked = v
        ignoresMouseEvents = v
        model.hovered = false
        if v {
            Toast.show("Pin locked. Unlock it from the menu bar › Unlock Pins")
            PinWindow.startLockTimer()
        } else {
            alphaValue = model.opacity
        }
    }

    /// Locked pins fade out while the cursor is over them so what's underneath can be seen and clicked.
    private static func startLockTimer() {
        guard lockTimer == nil else { return }
        lockTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let p = NSEvent.mouseLocation
                for pin in pins where pin.model.locked {
                    let target = pin.frame.contains(p) ? 0.08 : pin.model.opacity
                    if abs(pin.alphaValue - target) > 0.01 {
                        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; pin.animator().alphaValue = target }
                    }
                }
            }
        }
    }

    private func copyImage() {
        Exporter.copy(shot)
        Toast.show("Copied to clipboard")
    }

    fileprivate func annotate() {
        AnnotateWindowController.open(shot: shot)
        close()
    }

    private var dragFile: URL?
    private func tempFile() -> URL? {
        if let dragFile { return dragFile }
        dragFile = try? Exporter.save(shot, to: FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot", isDirectory: true))
        return dragFile
    }

    // MARK: Zoom

    fileprivate func resize(to width: CGFloat, around anchor: CGPoint? = nil) {
        let w = min(max(48, width), naturalWidth * 8)
        let h = (w / aspect).rounded()
        let a = anchor ?? CGPoint(x: frame.midX, y: frame.midY)
        // Keep the anchor point fixed relative to the image.
        let fx = (a.x - frame.minX) / frame.width, fy = (a.y - frame.minY) / frame.height
        setFrame(CGRect(x: a.x - w * fx, y: a.y - h * fy, width: w, height: h), display: true)
        model.zoom = w / naturalWidth
        model.flashZoom()
        invalidateShadow()
    }

    override func scrollWheel(with e: NSEvent) {
        let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.005 : e.scrollingDeltaY * 0.05
        resize(to: frame.width * (1 + d), around: NSEvent.mouseLocation)
    }

    override func magnify(with e: NSEvent) {
        resize(to: frame.width * (1 + e.magnification), around: NSEvent.mouseLocation)
    }

    override func keyDown(with e: NSEvent) {
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 53: close()
        case 123: setFrameOrigin(CGPoint(x: frame.minX - step, y: frame.minY))
        case 124: setFrameOrigin(CGPoint(x: frame.minX + step, y: frame.minY))
        case 125: setFrameOrigin(CGPoint(x: frame.minX, y: frame.minY - step))
        case 126: setFrameOrigin(CGPoint(x: frame.minX, y: frame.minY + step))
        case 49 where !cmd: QuickLook.toggle([tempFile()].compactMap { $0 }, from: self)
        default:
            guard cmd, let k = e.charactersIgnoringModifiers else { super.keyDown(with: e); return }
            switch k {
            case "w": close()
            case "c": copyImage()
            case "s": PinWindow.saveAs(shot)
            case "e": annotate()
            case "0": resize(to: naturalWidth)
            case "=", "+": resize(to: frame.width * 1.1)
            case "-": resize(to: frame.width / 1.1)
            case "l": setLocked(true)
            default: super.keyDown(with: e)
            }
        }
    }

    fileprivate func makeMenu() -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ key: String = "", _ symbol: String? = nil, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            m.addItem(i)
        }
        add("Copy", "c", "doc.on.doc") { [unowned self] in copyImage() }
        add("Save As…", "s", "square.and.arrow.down") { [unowned self] in PinWindow.saveAs(shot) }
        add("Annotate", "e", "pencil.tip.crop.circle") { [unowned self] in annotate() }
        m.addItem(.separator())
        let opacity = NSMenuItem(title: "Opacity".loc, action: nil, keyEquivalent: "")
        opacity.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: nil)
        let sub = NSMenu()
        for v in [100, 90, 75, 50, 25] {
            let i = ClosureMenuItem(title: "\(v)%", keyEquivalent: "") { [unowned self] in model.opacity = CGFloat(v) / 100; alphaValue = model.opacity }
            i.state = Int((model.opacity * 100).rounded()) == v ? .on : .off
            sub.addItem(i)
        }
        opacity.submenu = sub
        m.addItem(opacity)
        add("Actual Size", "0", "1.magnifyingglass") { [unowned self] in resize(to: naturalWidth) }
        add("Zoom In", "+", "plus.magnifyingglass") { [unowned self] in resize(to: frame.width * 1.25) }
        add("Zoom Out", "-", "minus.magnifyingglass") { [unowned self] in resize(to: frame.width / 1.25) }
        add("Lock (click-through)", "l", "lock") { [unowned self] in setLocked(true) }
        m.addItem(.separator())
        add("Hide All Pins") { PinWindow.toggleVisibility() }
        add("Close", "w") { [unowned self] in close() }
        add("Close All Pins") { PinWindow.closeAll() }
        return m
    }

    fileprivate func hover(_ h: Bool) {
        guard !model.locked else { return }
        model.hovered = h
    }
}

// MARK: - Content

/// Image (rounded / bordered per settings) with the toolbar on top. Click-drag moves the window, double-click annotates.
private final class PinContentView: NSView {
    weak var window_: PinWindow?
    private let imageLayer = CALayer()
    private var toolbar: NSView?

    init(image: CGImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    func setToolbar(_ v: NSView) {
        toolbar = v
        addSubview(v)
        needsLayout = true
    }

    func applyStyle(border: Bool, rounded: Bool) {
        layer?.cornerRadius = rounded ? 8 : 0
        layer?.cornerCurve = .continuous
        layer?.borderWidth = border ? 1 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor   // keep transparent images grabbable
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        toolbar?.frame = CGRect(x: 0, y: bounds.height - 40, width: bounds.width, height: 40)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { window_?.annotate(); return }
        window?.performDrag(with: e)
    }

    override func menu(for event: NSEvent) -> NSMenu? { window_?.makeMenu() }
    override func mouseEntered(with event: NSEvent) { window_?.hover(true) }
    override func mouseExited(with event: NSEvent) { window_?.hover(false) }
}

// MARK: - Toolbar

final class PinModel: ObservableObject {
    struct Actions {
        var close, lock, copy, save, annotate, actualSize: () -> Void
        var opacity: (CGFloat) -> Void
        var dragURL: () -> URL?
    }
    var actions: Actions?
    @Published var hovered = false
    @Published var locked = false
    @Published var zoom: CGFloat = 1
    @Published var showZoom = false
    @Published var opacity: CGFloat = 1 { didSet { actions?.opacity(opacity) } }
    private var zoomWork: DispatchWorkItem?

    /// Shows the zoom percentage briefly while resizing.
    func flashZoom() {
        showZoom = true
        zoomWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.showZoom = false }
        zoomWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }
}

private struct PinToolbar: View {
    @ObservedObject var model: PinModel

    var body: some View {
        ZStack {
            if model.hovered {
                ViewThatFits(in: .horizontal) {
                    full
                    compact
                }
                .padding(6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if model.showZoom {
                zoomLabel.transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.15), value: model.hovered)
        .animation(.easeOut(duration: 0.15), value: model.showZoom)
        .environment(\.colorScheme, .dark)
    }

    private var full: some View {
        HStack(spacing: 4) {
            button("xmark", "Close (Esc)") { model.actions?.close() }
            button("lock.open", "Lock, and fade out under the pointer (⌘L)") { model.actions?.lock() }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 10))
                Slider(value: $model.opacity, in: 0.2...1).controlSize(.mini).frame(width: 64)
            }
            .help("Opacity")
            Button { model.actions?.actualSize() } label: { zoomText }.buttonStyle(.plain).help("Actual size (⌘0)")
            Spacer(minLength: 6)
            button("doc.on.doc", "Copy (⌘C)") { model.actions?.copy() }
            button("square.and.arrow.down", "Save As… (⌘S)") { model.actions?.save() }
            button("pencil", "Annotate (⌘E)") { model.actions?.annotate() }
            dragHandle
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compact: some View {
        HStack(spacing: 4) {
            button("xmark", "Close (Esc)") { model.actions?.close() }
            Spacer(minLength: 0)
            button("lock.open", "Lock") { model.actions?.lock() }
        }
    }

    private var zoomText: some View {
        Text("\(Int((model.zoom * 100).rounded()))%").font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white).frame(minWidth: 38)
    }

    private var zoomLabel: some View {
        zoomText.padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.6), in: Capsule()).padding(8)
    }

    private var dragHandle: some View {
        Image(systemName: "hand.draw").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 24, height: 24).background(.white.opacity(0.12), in: Circle())
            .help("Drag to another app")
            .onDrag { model.actions?.dragURL().flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(QAPressStyle())
        .help(help.loc)
    }
}

/// NSMenuItem that runs a closure. `title` is an English UI string; it's shown translated.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title.loc, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
