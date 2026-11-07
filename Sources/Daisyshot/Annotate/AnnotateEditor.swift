import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One Annotate editor window: owns the document state, undo history, tool options and output actions.
@MainActor
final class AnnotateEditor: NSObject, ObservableObject, NSWindowDelegate {
    private(set) static var editors: [AnnotateEditor] = []
    private static var selfTested = false

    /// Not @Published: a document change (every slider tick / mouse drag) must not re-render every bar. Bars update through
    /// `backgroundState` (background sidebar) and `refreshUI()` (only when something they show changed).
    var doc: DocState { didSet { docChanged(old: oldValue) } }
    let backgroundState: BackgroundState
    private var uiSignature: UISignature?
    @Published var tool: AnnotateTool = AnnotateTool(rawValue: Prefs.string(.annotateLastTool)) ?? .arrow { didSet { toolChanged(from: oldValue) } }
    @Published var selection: UUID? { didSet { canvas?.needsDisplay = true } }
    @Published var pendingCrop: CGRect? { didSet { canvas?.needsDisplay = true } }
    @Published var cropChoice = CropChoice.freeform { didSet { fitPendingCropToRatio() } }
    @Published var customCropRatio = CGSize(width: 16, height: 9) { didSet { fitPendingCropToRatio() } }
    /// Not @Published (it changes on every auto-fit while the canvas grows); the zoom menu observes `zoomState`.
    var zoom: CGFloat = 1 { didSet { if zoomState.value != zoom { zoomState.value = zoom } } }
    let zoomState = ZoomState()
    @Published private(set) var dirty = false { didSet { window.isDocumentEdited = dirty } }
    @Published var showBackground = false { didSet { backgroundToggled() } }
    @Published var canvasLocked = Prefs.bool(.annotateLockCanvas) { didSet { Prefs.set(canvasLocked, .annotateLockCanvas); syncExpand() } }
    @Published private(set) var optionDown = false

    // Tool options (defaults for new annotations; also applied to the selection). Remembered across sessions.
    @Published var color = Prefs.string(.annotateColor) { didSet { Prefs.set(color, .annotateColor) } }
    @Published var lineWidth = CGFloat(Prefs.double(.annotateLineWidth)) { didSet { Prefs.set(Double(lineWidth), .annotateLineWidth) } }
    @Published var fontSize = CGFloat(Prefs.double(.annotateFontSize)) { didSet { Prefs.set(Double(fontSize), .annotateFontSize) } }
    @Published var shadow = Prefs.bool(.annotateShadow) { didSet { Prefs.set(shadow, .annotateShadow) } }
    @Published var arrowStyle = ArrowStyle(rawValue: Prefs.string(.annotateArrowStyle)) ?? .standard { didSet { Prefs.set(arrowStyle.rawValue, .annotateArrowStyle) } }
    @Published var textStyle = TextStyle(rawValue: Prefs.string(.annotateTextStyle)) ?? .standard { didSet { Prefs.set(textStyle.rawValue, .annotateTextStyle) } }
    @Published var redactStyle = RedactStyle(rawValue: Prefs.string(.annotateRedactStyle)) ?? .pixelate { didSet { Prefs.set(redactStyle.rawValue, .annotateRedactStyle) } }
    @Published var intensity = CGFloat(Prefs.double(.annotateRedactIntensity)) { didSet { Prefs.set(Double(intensity), .annotateRedactIntensity) } }
    @Published var spotShape = SpotShape(rawValue: Prefs.string(.annotateSpotShape)) ?? .rectangle { didSet { Prefs.set(spotShape.rawValue, .annotateSpotShape) } }
    @Published var counterStyle = CounterStyle(rawValue: Prefs.string(.annotateCounterStyle)) ?? .numeric { didSet { Prefs.set(counterStyle.rawValue, .annotateCounterStyle) } }
    @Published var counterStart = 1
    private(set) lazy var autoRedact = AutoRedactSession(editor: self)

    var fileURL: URL?
    var documentURL: URL?
    let window: AnnotateWindow
    private(set) var canvas: AnnotateCanvas!
    private let scrollView = AnnotateScrollView()
    let dropZones = DropZoneView()
    private var sidebarWidth: NSLayoutConstraint!
    private var previousTool = AnnotateTool.arrow
    private var userZoomed = false
    private var flagsMonitor: Any?
    private var saveLastBackground: DispatchWorkItem?

    private var undoStack: [DocState] = []
    private var redoStack: [DocState] = []
    private var pending: DocState?
    private var lastCoalesce: (key: String, time: Date)?

    // MARK: Lifecycle

    static func present(_ state: DocState, fileURL: URL?, documentURL: URL?) {
        #if DEBUG
        if !selfTested { selfTested = true; Geo.selfTest(); ImageAnalysis.selfTest(); selfTest() }
        #endif
        let e = AnnotateEditor(state: state, fileURL: fileURL, documentURL: documentURL)
        editors.append(e)
        applyWindowPrefs()
        NSApp.activate(ignoringOtherApps: true)
        e.window.makeKeyAndOrderFront(nil)
        e.window.makeFirstResponder(e.canvas)
        e.window.layoutIfNeeded()
        e.syncTitleBar()
        // Build the colour palette popover now, while idle, so its first opening is instant.
        DispatchQueue.main.async { PopoverCache.prewarm("color", AnyView(ColorPalettePanel(hex: .constant(e.color)))) }
        e.zoomToFit()
        e.userZoomed = false
    }

    private init(state: DocState, fileURL: URL?, documentURL: URL?) {
        var state = state
        state.expandCanvas = Prefs.bool(.annotateExpandCanvas) && !Prefs.bool(.annotateLockCanvas)
        doc = state
        backgroundState = BackgroundState(state.background)
        self.fileURL = fileURL.flatMap { Self.isScratchLocation($0) ? nil : $0 }
        self.documentURL = documentURL.flatMap { Self.isScratchLocation($0) ? nil : $0 }
        let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let L = AnnotateRenderer.layout(state)
        let size = CGSize(width: min(max(L.size.width + 40, 1000), vis.width * 0.9), height: min(max(L.size.height + 180, 560), vis.height * 0.9))
        window = AnnotateWindow(contentRect: CGRect(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2, width: size.width, height: size.height),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        canvas = AnnotateCanvas(editor: self)
        counterStart = doc.annotations.filter { $0.kind == .counter }.map(\.number).min() ?? 1
        window.editor = self
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = self.documentURL?.lastPathComponent ?? self.fileURL?.lastPathComponent ?? "Annotate".loc
        window.tabbingMode = .disallowed
        window.minSize = CGSize(width: 980, height: 460)
        // An empty unified toolbar gives a tall title bar with vertically centred traffic lights; our SwiftUI bar fills it.
        window.toolbar = NSToolbar(identifier: "annotate")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior.insert(.fullScreenPrimary)

        scrollView.editor = self
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.image")])
        NotificationCenter.default.addObserver(self, selector: #selector(liveMagnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        dropZones.isHidden = true

        let top = NSHostingView(rootView: AnnotateToolbar(editor: self))
        let bottom = NSHostingView(rootView: AnnotateActionBar(editor: self))
        let sidebar = NSHostingView(rootView: BackgroundPanel(editor: self, state: backgroundState, fillState: backgroundState.fill))
        // The bars lay themselves out; the title-bar safe area (taller than the toolbar itself) would skew SwiftUI's centring.
        top.safeAreaRegions = []
        bottom.safeAreaRegions = []
        sidebar.safeAreaRegions = []
        let root = NSView()
        for v in [scrollView, dropZones, sidebar, top, bottom] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 0)
        sidebar.wantsLayer = true
        sidebar.layer?.masksToBounds = true
        sidebar.isHidden = true
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportResized), name: NSView.frameDidChangeNotification, object: scrollView)
        topHeight = top.heightAnchor.constraint(equalToConstant: 52)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topHeight,
            sidebar.topAnchor.constraint(equalTo: top.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            sidebarWidth,
            scrollView.topAnchor.constraint(equalTo: top.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            dropZones.topAnchor.constraint(equalTo: scrollView.topAnchor),
            dropZones.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            dropZones.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            dropZones.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 46),
        ])
        window.contentView = root
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            let down = e.modifierFlags.contains(.option)
            if self?.optionDown != down { self?.optionDown = down }
            return e
        }
        if Prefs.bool(.annotateRememberBackground), Prefs.bool(.annotateBackgroundLastOpened) { showBackground = true }
        if tool == .highlighter { _ = ImageAnalysis.textLines(doc.image, scale: doc.scale) }
        canvas.refresh()
    }

    /// Files in another app's sandbox container or a temp folder aren't a save target: the editor treats them as untitled.
    nonisolated static func isScratchLocation(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return path.contains("/Library/Containers/") || path.hasPrefix(tmp.hasSuffix("/") ? tmp : tmp + "/")
    }

    private var topHeight: NSLayoutConstraint!
    /// Leading space the toolbar leaves for the traffic lights.
    @Published private(set) var titleBarLeading: CGFloat = 84

    /// Our toolbar fills the title bar: its height puts the tools' centre line on the traffic lights' centre line, and the
    /// tools start after the zoom button. Measured once the window is laid out (the unified title bar isn't final before).
    func syncTitleBar() {
        guard let close = window.standardWindowButton(.closeButton), let zoomB = window.standardWindowButton(.zoomButton) else { return }
        let c = close.convert(close.bounds, to: nil), z = zoomB.convert(zoomB.bounds, to: nil)
        let y = window.frame.height - c.midY
        if y > 8, y < 60 { topHeight.constant = (2 * y).rounded() }
        let lead = (z.maxX + 16).rounded()
        if lead > 40, lead < 200, lead != titleBarLeading { titleBarLeading = lead }
    }

    func windowDidResize(_ notification: Notification) { syncTitleBar() }
    func windowDidExitFullScreen(_ notification: Notification) { syncTitleBar() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.endEditing()
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your edits to this screenshot?"
        alert.informativeText = "Unsaved edits will be discarded."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save As…")
        alert.localize()
        switch alert.runModal() {
        case .alertFirstButtonReturn: save(); return !dirty
        case .alertSecondButtonReturn: return true
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1): return saveAs()
        default: return false
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let m = Self.installedMenu, NSApp.mainMenu === m { Self.installedMenu = AnnotateMenu.make(); NSApp.mainMenu = Self.installedMenu }
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        Self.editors.removeAll { $0 === self }
        Self.applyWindowPrefs()
        DispatchQueue.main.async { self.window.contentView = nil } // break hosting view → editor cycle
    }

    /// Closes without the unsaved-changes prompt (after an output action that "exits").
    func closeNow() {
        dirty = false
        window.close()
    }

    // MARK: Window preferences (Always on top / Dock icon)

    private static var dockShown = false
    private static var installedMenu: NSMenu?

    static func applyWindowPrefs() {
        for e in editors { e.window.level = Prefs.bool(.annotateAlwaysOnTop) ? .floating : .normal }
        let want = Prefs.bool(.annotateShowDockIcon) && !editors.isEmpty
        if want, !dockShown, NSApp.activationPolicy() != .regular {
            dockShown = true
            if NSApp.mainMenu == nil { installedMenu = AnnotateMenu.make(); NSApp.mainMenu = installedMenu }
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        } else if !want, dockShown {
            dockShown = false
            NSApp.setActivationPolicy(.accessory)
            if let m = installedMenu, NSApp.mainMenu === m { NSApp.mainMenu = nil }
            installedMenu = nil
        }
    }

    // MARK: State & undo

    /// What the canvas shows: in crop mode the whole extent without background, so the crop can be adjusted.
    var displayState: DocState {
        guard tool == .crop else { return doc }
        var s = doc
        s.crop = doc.extent
        s.expandCanvas = false
        s.background.fill = .none
        return s
    }

    var selected: Annotation? { selection.flatMap(annotation) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func annotation(_ id: UUID) -> Annotation? { doc.annotations.first { $0.id == id } }

    /// Direct edit without an undo step (used inside a begin/endChange gesture).
    func update(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let i = doc.annotations.firstIndex(where: { $0.id == id }) else { return }
        body(&doc.annotations[i])
    }

    func beginChange() { if pending == nil { pending = doc } }

    func endChange() {
        guard let p = pending else { return }
        pending = nil
        if p != doc { pushUndo(p) }
    }

    /// One undoable edit. Edits with the same `coalesce` key in quick succession (slider drags, nudges) share a step.
    func mutate(coalesce key: String? = nil, _ body: (inout DocState) -> Void) {
        var s = doc
        body(&s)
        guard s != doc else { return }
        let merge = key != nil && lastCoalesce?.key == key && Date().timeIntervalSince(lastCoalesce!.time) < 1.5
        if pending == nil, !merge { pushUndo(doc) }
        doc = s
        if !dirty { dirty = true }
        if let key { lastCoalesce = (key, Date()) }
    }

    private func pushUndo(_ s: DocState) {
        undoStack.append(s)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastCoalesce = nil
        if !dirty { dirty = true }
        refreshUI()
    }

    /// What the bars show that depends on the document: re-render them only when this changes.
    private struct UISignature: Equatable {
        var canUndo = false, canRedo = false
        var selected: Annotation?      // options of the selection (geometry stripped)
        var spotlightOpacity: CGFloat = 0
    }

    private func refreshUI() {
        var sel = selected
        sel?.points = []
        let sig = UISignature(canUndo: canUndo, canRedo: canRedo, selected: sel, spotlightOpacity: doc.spotlightOpacity)
        if sig != uiSignature { uiSignature = sig; objectWillChange.send() }
        syncBackgroundState()
    }

    /// The sidebar only tracks the document while it's open (a hidden SwiftUI tree still pays for updates).
    private func syncBackgroundState() {
        guard showBackground else { return }
        if backgroundState.bg != doc.background { backgroundState.bg = doc.background }
        if backgroundState.fill.fill != doc.background.fill { backgroundState.fill.fill = doc.background.fill }
    }

    func undo() {
        canvas.endEditing()
        guard let s = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(doc)
        lastCoalesce = nil
        doc = s
        if !dirty { dirty = true }
        refreshUI()
    }

    func redo() {
        canvas.endEditing()
        guard let s = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(doc)
        lastCoalesce = nil
        doc = s
        if !dirty { dirty = true }
        refreshUI()
    }

    private func docChanged(old: DocState) {
        if let s = selection, annotation(s) == nil { selection = nil }
        refreshUI()
        if doc.background != old.background, doc.background.isActive {
            // "Apply Previous Settings" memory — written once a slider drag settles, not on every tick.
            saveLastBackground?.cancel()
            let bg = doc.background
            let w = DispatchWorkItem { Prefs.setCodable(bg, .annotateLastBackground) }
            saveLastBackground = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
        }
        let before = canvas?.frame.size
        canvas?.refresh()
        if !userZoomed, let before, before != canvas.frame.size, pending == nil { zoomToFit(); userZoomed = false }
    }

    /// "Automatically expand canvas" unless the canvas is locked (not an undo step).
    func syncExpand() {
        let want = Prefs.bool(.annotateExpandCanvas) && !canvasLocked
        if doc.expandCanvas != want { doc.expandCanvas = want }
    }

    private func toolChanged(from old: AnnotateTool) {
        guard old != tool else { return }
        canvas.endEditing()
        selection = nil
        if tool != .crop { Prefs.set(tool.rawValue, .annotateLastTool) }
        if old == .crop { pendingCrop = nil }
        if tool == .crop {
            previousTool = old
            pendingCrop = doc.contentRect
        }
        if tool == .highlighter { _ = ImageAnalysis.textLines(doc.image, scale: doc.scale) }
        canvas.refresh()
        window.invalidateCursorRects(for: canvas)
        window.makeFirstResponder(canvas)
        if old == .crop || tool == .crop { zoomToFit(); userZoomed = false }
    }

    private func backgroundToggled() {
        Prefs.set(showBackground, .annotateBackgroundLastOpened)
        syncBackgroundState()
        if showBackground, !doc.background.isActive {
            var last = Prefs.codable(.annotateLastBackground, BackgroundSettings.self) ?? BackgroundSettings()
            if !last.isActive { last.fill = .builtin(0) }
            mutate { $0.background = last }
        }
        guard let sidebarWidth, let sidebar = sidebarWidth.firstItem as? NSView else { return }
        let open = showBackground
        sidebar.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = window.isVisible ? 0.2 : 0
            ctx.allowsImplicitAnimation = true
            sidebarWidth.constant = open ? 286 : 0
            window.contentView?.layoutSubtreeIfNeeded()
        } completionHandler: {
            MainActor.assumeIsolated { if !self.showBackground { sidebar.isHidden = true } }
        }
    }

    func toggleBackground() { showBackground.toggle() }

    /// Keeps the canvas fitted while the viewport changes size (window resize, sidebar), unless the user zoomed.
    @objc private func viewportResized() {
        if !userZoomed { zoomToFit() }
    }

    // MARK: Annotation commands

    func newAnnotation(_ kind: Annotation.Kind, at p: CGPoint) -> Annotation {
        var a = Annotation(kind: kind, points: [p, p], color: color, lineWidth: lineWidth, shadow: shadow, fontSize: fontSize)
        a.arrowStyle = arrowStyle
        a.textStyle = textStyle
        a.redactStyle = redactStyle
        a.intensity = intensity
        a.spotShape = spotShape
        a.counterStyle = counterStyle
        if [.text, .counter, .pencil, .highlighter].contains(kind) { a.points = [p] }
        if kind == .redact || kind == .spotlight || kind == .highlighter { a.shadow = false }
        if kind == .counter { a.number = nextCounter() }
        return a
    }

    func nextCounter() -> Int {
        (doc.annotations.filter { $0.kind == .counter }.map(\.number).max()).map { $0 + 1 } ?? counterStart
    }

    /// Changing the starting number renumbers the existing counters in order.
    func setCounterStart(_ n: Int) {
        counterStart = max(0, n)
        mutate(coalesce: "counterStart") { s in
            let ids = s.annotations.filter { $0.kind == .counter }.sorted { $0.number < $1.number }.map(\.id)
            for (i, id) in ids.enumerated() { if let j = s.annotations.firstIndex(where: { $0.id == id }) { s.annotations[j].number = counterStart + i } }
        }
    }

    func deleteSelection() {
        guard let id = selection else { return }
        mutate { $0.annotations.removeAll { $0.id == id } }
        selection = nil
    }

    func duplicate() {
        guard var a = selected else { return }
        a.id = UUID()
        a.offset(by: CGVector(dx: 12, dy: 12))
        if a.kind == .counter { a.number = nextCounter() }
        mutate { $0.annotations.append(a) }
        selection = a.id
    }

    func nudge(_ d: CGVector) {
        guard let id = selection else { return }
        mutate(coalesce: "nudge") { s in
            if let i = s.annotations.firstIndex(where: { $0.id == id }) { s.annotations[i].offset(by: d) }
        }
    }

    func bringToFront() {
        guard let a = selected else { return }
        mutate { s in s.annotations.removeAll { $0.id == a.id }; s.annotations.append(a) }
    }

    func sendToBack() {
        guard let a = selected else { return }
        mutate { s in s.annotations.removeAll { $0.id == a.id }; s.annotations.insert(a, at: 0) }
    }

    /// +/- keys: font size for text/counter, stroke width otherwise.
    func bumpSize(_ dir: CGFloat) {
        let kind = selected?.kind ?? tool.kind
        if kind == .text || kind == .counter {
            setOption(\.fontSize, \.fontSize, max(8, min(200, (selected?.fontSize ?? fontSize) + dir * 2)))
        } else {
            setOption(\.lineWidth, \.lineWidth, max(1, min(40, (selected?.lineWidth ?? lineWidth) + dir)))
        }
    }

    /// Sets a tool option and applies it to the selected annotation (one coalesced undo step).
    func setOption<T: Equatable>(_ kp: ReferenceWritableKeyPath<AnnotateEditor, T>, _ akp: WritableKeyPath<Annotation, T>, _ v: T) {
        self[keyPath: kp] = v
        guard let id = selection else { return }
        mutate(coalesce: "opt\(akp.hashValue)") { s in
            if let i = s.annotations.firstIndex(where: { $0.id == id }) { s.annotations[i][keyPath: akp] = v }
        }
    }

    func option<T: Equatable>(_ kp: ReferenceWritableKeyPath<AnnotateEditor, T>, _ akp: WritableKeyPath<Annotation, T>) -> Binding<T> {
        Binding(get: { self.selected?[keyPath: akp] ?? self[keyPath: kp] }, set: { self.setOption(kp, akp, $0) })
    }

    func background<T: Equatable>(_ kp: WritableKeyPath<BackgroundSettings, T>) -> Binding<T> {
        Binding(get: { self.doc.background[keyPath: kp] }, set: { v in self.mutate(coalesce: "bg\(kp.hashValue)") { $0.background[keyPath: kp] = v } })
    }

    var spotlightOpacity: Binding<CGFloat> {
        Binding(get: { self.doc.spotlightOpacity }, set: { v in self.mutate(coalesce: "spotOpacity") { $0.spotlightOpacity = v } })
    }

    /// Emoji & Symbols palette for the text being edited (starts editing the selected text first).
    func showEmoji() {
        if canvas.textView == nil, let a = selected, a.kind == .text { canvas.beginEditing(a.id) }
        if canvas.textView == nil { tool = .text; Toast.show("Click on the image to place text, then pick an emoji"); return }
        NSApp.orderFrontCharacterPalette(nil)
    }

    // MARK: Combining images

    enum Edge { case top, bottom, left, right }

    /// Adds an image to the canvas. `edge` places it next to the canvas and grows the canvas; nil centres it when it fits.
    func place(_ img: CGImage, scale: CGFloat, edge: Edge?) {
        canvas.endEditing()
        if tool == .crop { cancelCrop() }
        let size = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
        let c = doc.contentRect
        let fits = size.width <= c.width && size.height <= c.height
        let edge = edge ?? (fits ? nil : .right)
        var r: CGRect
        switch edge {
        case .right: r = CGRect(x: c.maxX, y: c.midY - size.height / 2, width: size.width, height: size.height)
        case .left: r = CGRect(x: c.minX - size.width, y: c.midY - size.height / 2, width: size.width, height: size.height)
        case .top: r = CGRect(x: c.midX - size.width / 2, y: c.minY - size.height, width: size.width, height: size.height)
        case .bottom: r = CGRect(x: c.midX - size.width / 2, y: c.maxY, width: size.width, height: size.height)
        case nil: r = CGRect(x: c.midX - size.width / 2, y: c.midY - size.height / 2, width: size.width, height: size.height)
        }
        r.origin = CGPoint(x: (r.minX * doc.scale).rounded() / doc.scale, y: (r.minY * doc.scale).rounded() / doc.scale)
        let asset = UUID()
        var a = Annotation(kind: .image, points: [r.origin, CGPoint(x: r.maxX, y: r.maxY)], color: "#000000", lineWidth: 0, shadow: edge == nil, fontSize: 0)
        a.assetID = asset
        mutate { s in
            s.assets[asset] = img
            s.annotations.insert(a, at: s.annotations.lastIndex { $0.kind == .image }.map { $0 + 1 } ?? 0)
            if edge != nil { s.crop = c.union(r) }
        }
        tool = .move
        selection = a.id
        userZoomed = false
        zoomToFit()
    }

    func addFromClipboard() {
        guard let shot = Exporter.shotFromPasteboard() else { return Toast.show("No image on the clipboard", isError: true) }
        place(shot.image, scale: shot.scale, edge: nil)
    }

    func addFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(url, edge: panel.urls.count > 1 ? .right : nil) }
    }

    /// Places an image file (From File…, recent captures) on the canvas.
    func add(_ url: URL, edge: Edge? = nil) {
        guard let s = Exporter.loadShot(url) else { return Toast.show("Couldn't open %@".loc(url.lastPathComponent), isError: true) }
        place(s.image, scale: s.scale, edge: edge)
    }

    /// The most recent screenshots in History, for the "Add screenshot" menu.
    private static let recentFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func recentCaptures(_ n: Int = 6) -> [(title: String, url: URL)] {
        let f = recentFormatter
        return History.shared.entries.lazy.filter { $0.kind == MediaKind.image.rawValue }
            .map { (f.string(from: $0.date), History.shared.url($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.1.path) }
            .prefix(n).map { $0 }
    }

    func addNewScreenshot() {
        canvas.endEditing()
        window.orderOut(nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000) // let the window disappear before the overlay grabs the screen
            let shot = await CaptureController.shared.selectShot()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let shot { place(shot.image, scale: shot.scale, edge: nil) }
        }
    }

    // MARK: Object clipboard

    private static var objectClipboard: (change: Int, items: [Annotation], assets: [UUID: CGImage])?

    func paste() {
        if let c = Self.objectClipboard, c.change == NSPasteboard.general.changeCount, !c.items.isEmpty {
            let items = c.items.map { a -> Annotation in
                var a = a
                a.id = UUID()
                a.offset(by: CGVector(dx: 16, dy: 16))
                if a.kind == .counter { a.number = nextCounter() }
                return a
            }
            mutate { s in
                for (k, v) in c.assets { s.assets[k] = v }
                s.annotations += items
            }
            Self.objectClipboard?.items = items
            selection = items.last?.id
        } else if let shot = Exporter.shotFromPasteboard() {
            place(shot.image, scale: shot.scale, edge: nil)
        } else {
            NSSound.beep()
        }
    }

    // MARK: Crop & Resize

    var cropRatioValue: CGFloat? { cropChoice.value(original: doc.imageSize, custom: customCropRatio) }

    func applyCrop() {
        guard let c = pendingCrop else { return }
        let k = doc.scale
        let aligned = CGRect(x: (c.minX * k).rounded() / k, y: (c.minY * k).rounded() / k, width: (c.width * k).rounded() / k, height: (c.height * k).rounded() / k)
            .intersection(doc.extent)
        if aligned.width >= 1, aligned.height >= 1 {
            mutate { $0.crop = aligned == $0.imageRect ? nil : aligned }
        }
        tool = previousTool == .crop ? .move : previousTool
    }

    func cancelCrop() { tool = previousTool == .crop ? .move : previousTool }

    func resetCrop() { cropChoice = .freeform; pendingCrop = doc.extent }

    private func fitPendingCropToRatio() {
        guard let c = pendingCrop, let k = cropRatioValue else { return }
        pendingCrop = Geo.fit(c, ratio: k)
    }

    func swapCustomRatio() { customCropRatio = CGSize(width: customCropRatio.height, height: customCropRatio.width) }

    func orient(_ o: Geo.Orient) {
        canvas.endEditing()
        guard let s = Self.oriented(doc, o) else { return }
        mutate { $0 = s; $0.orientation.append(o) }
        if tool == .crop { pendingCrop = doc.extent }
        zoomToFit()
    }

    /// Undoes rotations/flips and the crop.
    func revertToOriginal() {
        var s = doc
        for o in doc.orientation.reversed() {
            let inv: Geo.Orient = o == .rotateRight ? .rotateLeft : o == .rotateLeft ? .rotateRight : o
            guard let r = Self.oriented(s, inv) else { return }
            s = r
        }
        s.orientation = []
        s.crop = nil
        mutate { $0 = s }
        pendingCrop = doc.extent
        cropChoice = .freeform
        zoomToFit()
    }

    /// Rotates/flips the image, placed images, annotations and crop together.
    static func oriented(_ s: DocState, _ o: Geo.Orient) -> DocState? {
        guard let img = orientedImage(s.image, o) else { return nil }
        let size = s.imageSize
        func p(_ q: CGPoint) -> CGPoint { Geo.orient(q, in: size, o) }
        func r(_ q: CGRect) -> CGRect { Geo.rect(p(q.origin), p(CGPoint(x: q.maxX, y: q.maxY))) }
        var out = s
        out.image = img
        out.assets = s.assets.compactMapValues { orientedImage($0, o) }
        out.crop = s.crop.map(r)
        out.annotations = s.annotations.map { a in
            var a = a
            switch a.kind {
            case .text:
                let b = AnnotateRenderer.textBox(a), c = p(CGPoint(x: b.midX, y: b.midY))
                a.points = [CGPoint(x: c.x - b.width / 2, y: c.y - b.height / 2)]
            default:
                a.points = a.points.map(p)
            }
            return a
        }
        return out
    }

    static func orientedImage(_ img: CGImage, _ o: Geo.Orient) -> CGImage? {
        let size = CGSize(width: img.width, height: img.height), out = Geo.orientedSize(size, o)
        guard let ctx = AnnotateRenderer.bitmapContext(Int(out.width), Int(out.height)) else { return nil }
        ctx.translateBy(x: 0, y: out.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(Geo.orientTransform(size, o))
        AnnotateRenderer.drawImage(img, in: CGRect(origin: .zero, size: size), ctx)
        return ctx.makeImage()
    }

    func resizeImage() {
        canvas.endEditing()
        let c = doc.contentRect
        let px = CGSize(width: (c.width * doc.scale).rounded(), height: (c.height * doc.scale).rounded())
        let model = ResizeModel(base: px)
        let alert = NSAlert()
        alert.messageText = "Resize Image"
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        alert.localize()
        alert.informativeText = "Current size: %d × %d px".loc(Int(px.width), Int(px.height))
        let host = NSHostingView(rootView: ResizeForm(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 140)
        alert.accessoryView = host
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let target = model.pixels
        let sx = target.width / px.width, sy = target.height / px.height
        guard sx > 0, sy > 0, sx.isFinite, sy.isFinite, sx != 1 || sy != 1 || model.flatten else { return }
        var base = doc
        if model.flatten {
            var content = doc
            content.background.fill = .none
            let flat = AnnotateRenderer.flatten(content)
            base = DocState(image: flat.image, scale: doc.scale, background: doc.background, spotlightOpacity: doc.spotlightOpacity, expandCanvas: doc.expandCanvas)
        }
        guard let s = Self.resized(base, sx: sx, sy: sy) else { return Toast.show("Couldn't resize the image", isError: true) }
        mutate { $0 = s }
        zoomToFit()
    }

    /// Resamples the original image and scales every annotation (and the crop) to match.
    static func resized(_ s: DocState, sx: CGFloat, sy: CGFloat) -> DocState? {
        func resample(_ img: CGImage) -> CGImage? {
            let w = max(1, Int((CGFloat(img.width) * sx).rounded())), h = max(1, Int((CGFloat(img.height) * sy).rounded()))
            guard let ctx = AnnotateRenderer.bitmapContext(w, h) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
        guard let img = resample(s.image) else { return nil }
        let k = sqrt(sx * sy)
        var out = s
        out.image = img
        out.orientation = []
        out.annotations = s.annotations.map { a in
            var a = a
            a.points = a.points.map { CGPoint(x: $0.x * sx, y: $0.y * sy) }
            if a.kind != .image { a.lineWidth *= k; a.fontSize *= k; a.textWidth = a.textWidth.map { $0 * sx } }
            return a
        }
        out.crop = s.crop.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
        return out
    }

    // MARK: Zoom

    private var visibleCenter: CGPoint {
        let r = scrollView.contentView.bounds
        return CGPoint(x: r.midX, y: r.midY)
    }

    func setZoom(_ m: CGFloat, at point: CGPoint? = nil, animated: Bool = true) {
        userZoomed = true
        let m = min(max(m, scrollView.minMagnification), scrollView.maxMagnification)
        guard animated, point == nil else {
            scrollView.setMagnification(m, centeredAt: point ?? visibleCenter)
            return zoomChanged()
        }
        zoom = m
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            scrollView.animator().setMagnification(m, centeredAt: visibleCenter)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.zoomChanged() }
        }
    }

    func zoomToFit(animated: Bool = false) {
        let avail = scrollView.contentView.frame.size, size = canvas.frame.size
        guard size.width > 0, size.height > 0, avail.width > 0 else { return }
        setZoom(min(1, (avail.width - 40) / size.width, (avail.height - 40) / size.height), animated: animated)
        userZoomed = false
    }

    func zoomChanged() {
        if zoom != scrollView.magnification { zoom = scrollView.magnification }
        canvas.zoomDidChange()
    }

    @objc private func liveMagnifyEnded() { userZoomed = true; zoomChanged() }

    // MARK: Output

    func flattened() -> Shot {
        canvas.endEditing()
        return AnnotateRenderer.flatten(doc)
    }

    /// True when ⌥ is held: output actions also close the editor.
    private var exitAfter: Bool { NSEvent.modifierFlags.contains(.option) }

    /// ⌘C: the selected object (rendered from the canvas) or the whole image.
    func copySelectionOrImage() {
        guard let a = selected else { return copyScreenshot() }
        let shot = flattened(), L = AnnotateRenderer.layout(doc)
        let b = AnnotateRenderer.bounds(a).insetBy(dx: -6, dy: -6).offsetBy(dx: L.imageOrigin.x, dy: L.imageOrigin.y)
            .intersection(CGRect(origin: .zero, size: L.size))
        Exporter.copy(CaptureService.crop(shot, to: b))
        Self.objectClipboard = (NSPasteboard.general.changeCount, [a], a.assetID.flatMap { id in doc.assets[id].map { [id: $0] } } ?? [:])
        Toast.show("Object copied to clipboard")
    }

    func copyScreenshot() {
        let close = exitAfter
        Exporter.copy(flattened())
        Toast.show("Copied to clipboard")
        AutoRedact.warnAfterCopy(self)
        if close { closeNow() }
    }

    /// The writable format matching `url`'s extension; nil for files we can't write back (GIF, BMP, PSD, WebP without cwebp…).
    static func format(for url: URL) -> ImageFormat? {
        let ext = url.pathExtension.lowercased()
        return ImageFormat.allCases.first { $0.rawValue == ext || $0.utType.preferredFilenameExtension == ext || $0.utType.tags[.filenameExtension]?.contains(ext) == true }
    }

    @discardableResult
    func save() -> Bool {
        // Never write PNG bytes under another format's extension (or flatten an animated GIF): go through Save As.
        if documentURL == nil, let f = fileURL, Self.format(for: f) == nil { return saveAs(forcePNG: true) }
        let shot = flattened()
        do {
            if let d = documentURL {
                guard let doc = AnnotateDocument(doc) else { throw CocoaError(.fileWriteUnknown) }
                try doc.write(to: d)
                AutoRedact.noteProjectSave(self.doc)
            } else if let f = fileURL, let fmt = Self.format(for: f) {
                guard let data = Exporter.encode(shot, format: fmt) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: f, options: .atomic)
            } else {
                fileURL = try Exporter.save(shot)
                window.title = fileURL!.lastPathComponent
            }
            dirty = false
            Toast.show("Saved %@".loc((documentURL ?? fileURL)?.lastPathComponent ?? ""))
            return true
        } catch {
            Toast.show("Couldn't save: %@".loc(error.localizedDescription), isError: true)
            return false
        }
    }

    /// Done: save and close. ⌥: choose the export location, then close.
    func done() {
        if exitAfter { if saveAs() { closeNow() }; return }
        if save() { closeNow() }
    }

    static let documentType = UTType(filenameExtension: "daisyshot", conformingTo: .json) ?? .json

    /// `forcePNG`: the original's format can't be written, so default to PNG.
    @discardableResult
    func saveAs(forcePNG: Bool = false) -> Bool {
        canvas.endEditing()
        let panel = NSSavePanel()
        let base = (documentURL ?? fileURL)?.deletingPathExtension().lastPathComponent ?? Exporter.fileName()
        let last = Prefs.string(.annotateLastSaveFolder)
        panel.directoryURL = (documentURL ?? fileURL)?.deletingLastPathComponent() ?? (last.isEmpty ? Prefs.exportFolder : URL(fileURLWithPath: last))
        let projectType = Self.documentType
        let options: [(String, UTType, String)] = [("PNG Image", .png, "png"), ("JPEG Image", .jpeg, "jpg"), ("HEIC Image", .heic, "heic"),
                                                   ("TIFF Image", .tiff, "tiff"), ("Daisyshot Project", projectType, "daisyshot")]
        let current = ImageFormat(rawValue: Prefs.string(.imageFormat)) ?? .png
        var chosen = documentURL != nil ? options.count - 1 : forcePNG ? 0 : options.firstIndex { $0.2 == current.rawValue } ?? 0
        func apply(_ i: Int) {
            chosen = i
            panel.allowedContentTypes = [options[i].1]
            panel.nameFieldStringValue = base + "." + options[i].2
        }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, o) in options.enumerated() {
            popup.menu?.addItem(ClosureMenuItem(title: o.0, keyEquivalent: "") { apply(i) })
        }
        popup.selectItem(at: chosen)
        let label = NSTextField(labelWithString: "Format:".loc)
        let hint = NSTextField(wrappingLabelWithString: "Select “Daisyshot Project” if you want to edit the screenshot later, otherwise select another format.".loc)
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 320
        let row = NSStackView(views: [label, popup])
        let stack = NSStackView(views: [row, hint])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        panel.accessoryView = stack
        apply(chosen)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        Prefs.set(url.deletingLastPathComponent().path, .annotateLastSaveFolder)
        if options[chosen].2 == "daisyshot" {
            documentURL = url
            fileURL = nil
        } else {
            documentURL = nil
            fileURL = url
        }
        window.title = url.lastPathComponent
        return save()
    }

    /// Flattened PNG in a temp folder, for share / drag-out.
    func writeTempFile() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? Exporter.fileName(bumpCounter: false)
        let url = dir.appendingPathComponent(name).appendingPathExtension("png")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              let data = Exporter.encode(flattened(), format: .png), (try? data.write(to: url)) != nil else { return nil }
        AutoRedact.warnAfterCopy(self)
        return url
    }

    func share(from view: NSView) {
        guard let url = writeTempFile() else { return }
        let level = window.level
        window.level = .normal // the share sheet must appear above the editor
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.window.level = level }
    }

    func pin() {
        let close = exitAfter
        PinWindow.pin(flattened())
        if close { closeNow() }
    }

    func recognizeText() {
        let img = flattened().image
        Task { @MainActor in
            let text = await TextRecognizer.recognize(img)
            guard !text.isEmpty else { return Toast.show("No text found", isError: true) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show("Text copied to clipboard")
        }
    }

    func printImage() {
        let shot = flattened()
        let size = CGSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        let view = NSImageView(frame: CGRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: shot.image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        NSPrintOperation(view: view, printInfo: info).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Keyboard

    /// ⌘-shortcuts (the app usually runs as an accessory without a main menu, so the window routes them here).
    func handleCommandKey(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection([.command, .shift, .option, .control])
        guard f.contains(.command) || f.contains(.control) else { return false }
        let k = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = f.contains(.shift)
        if let tv = canvas.textView, window.firstResponder === tv {
            guard f.contains(.command), !f.contains(.control) else { return false }
            switch k {
            case "c": tv.copy(nil)
            case "v": tv.pasteAsPlainText(nil)
            case "x": tv.cut(nil)
            case "a": tv.selectAll(nil)
            case "z": shift ? tv.undoManager?.redo() : tv.undoManager?.undo()
            default: canvas.endEditing(); return handleCommandKey(e)
            }
            return true
        }
        guard window.firstResponder === canvas || window.firstResponder === window else { return false }
        if performShortcut(e) { return true }
        // Fixed (not remappable) ⌘ keys.
        guard f.contains(.command), !f.contains(.control) else { return false }
        switch (k, shift) {
        case ("z", false): undo()
        case ("z", true): redo()
        case ("v", false): paste()
        case ("x", false): if selected != nil { copySelectionOrImage(); deleteSelection() } else { return false }
        case ("w", _): window.performClose(nil)
        case ("=", _), ("+", _): setZoom(zoom * 1.25)
        case ("-", _): setZoom(zoom / 1.25)
        case ("0", false): zoomToFit()
        case ("1", false): setZoom(1)
        case ("]", false): bringToFront()
        case ("[", false): sendToBack()
        default: return false
        }
        return true
    }

    /// The remappable editor shortcuts (EditorShortcuts.annotate). Returns false when `e` matches none of them.
    func performShortcut(_ e: NSEvent) -> Bool {
        let actions: [(String, () -> Void)] = [
            ("annotate.save", { self.save() }),
            ("annotate.saveAs", { self.saveAs() }),
            ("annotate.done", { self.done() }),
            ("annotate.copyScreenshot", { self.copyScreenshot() }),
            ("annotate.copyObject", { self.copySelectionOrImage() }),
            ("annotate.duplicate", { self.duplicate() }),
            ("annotate.print", { self.printImage() }),
            ("annotate.pin", { self.pin() }),
            ("annotate.addFromFile", { self.addFromFile() }),
            ("annotate.addNewScreenshot", { self.addNewScreenshot() }),
            ("annotate.increaseSize", { self.bumpSize(1) }),
            ("annotate.decreaseSize", { self.bumpSize(-1) }),
            ("annotate.background", { self.toggleBackground() }),
            ("annotate.autoRedact", { self.autoRedact.start() }),
        ] + AnnotateTool.allCases.map { t in (t.shortcutID, { self.tool = t }) }
        guard let hit = actions.first(where: { EditorShortcuts.annotateMatches(e, $0.0) }) else { return false }
        hit.1()
        return true
    }

    #if DEBUG
    /// Rotating four times (and flipping twice) is the identity for annotations, crop and image size.
    static func selfTest() {
        let ctx = AnnotateRenderer.bitmapContext(40, 20)!
        var s = DocState(image: ctx.makeImage()!, scale: 2)
        s.annotations = [Annotation(kind: .rectangle, points: [CGPoint(x: 1, y: 2), CGPoint(x: 5, y: 7)], color: "#000", lineWidth: 2, shadow: false, fontSize: 10)]
        s.crop = CGRect(x: 1, y: 1, width: 10, height: 5)
        var r = s
        for _ in 0 ..< 4 { r = oriented(r, .rotateRight)! }
        assert(r.annotations == s.annotations && r.crop == s.crop && r.image.width == 40)
        let once = oriented(s, .rotateRight)!
        assert(once.image.width == 20 && once.imageSize == CGSize(width: 10, height: 20))
        r = oriented(oriented(s, .flipV)!, .flipV)!
        assert(r.annotations == s.annotations)
        let half = resized(s, sx: 0.5, sy: 0.5)!
        assert(half.image.width == 20 && half.annotations[0].points[1] == CGPoint(x: 2.5, y: 3.5) && half.crop == CGRect(x: 0.5, y: 0.5, width: 5, height: 2.5))
    }
    #endif
}

/// Routes ⌘-shortcuts and stray key presses to the editor; also the target of the main-menu items.
final class AnnotateWindow: NSWindow {
    weak var editor: AnnotateEditor?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editor?.handleCommandKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if editor?.canvas.handleKey(event) != true { super.keyDown(with: event) }
    }

    @objc func annotateSave(_ sender: Any?) { editor?.save() }
    @objc func annotateSaveAs(_ sender: Any?) { editor?.saveAs() }
    @objc func annotatePrint(_ sender: Any?) { editor?.printImage() }
    @objc func annotateUndo(_ sender: Any?) { editor?.undo() }
    @objc func annotateRedo(_ sender: Any?) { editor?.redo() }
    @objc func annotateCopy(_ sender: Any?) { editor?.copySelectionOrImage() }
    @objc func annotateCopyAll(_ sender: Any?) { editor?.copyScreenshot() }
    @objc func annotatePaste(_ sender: Any?) { editor?.paste() }
    @objc func annotateDuplicate(_ sender: Any?) { editor?.duplicate() }
    @objc func annotateDelete(_ sender: Any?) { editor?.deleteSelection() }
    @objc func annotateZoomIn(_ sender: Any?) { editor.map { $0.setZoom($0.zoom * 1.25) } }
    @objc func annotateZoomOut(_ sender: Any?) { editor.map { $0.setZoom($0.zoom / 1.25) } }
    @objc func annotateZoomFit(_ sender: Any?) { editor?.zoomToFit() }
    @objc func annotateZoomActual(_ sender: Any?) { editor?.setZoom(1) }
    @objc func annotateAddFile(_ sender: Any?) { editor?.addFromFile() }
    @objc func annotateAddNew(_ sender: Any?) { editor?.addNewScreenshot() }
}

/// Minimal main menu shown while the Dock icon is visible (the app normally has none).
enum AnnotateMenu {
    @MainActor static func make() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title.loc)
            items.forEach(m.addItem)
            let it = NSMenuItem(title: title.loc, action: nil, keyEquivalent: "")
            it.submenu = m
            main.addItem(it)
        }
        func item(_ t: String, _ sel: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t.loc, action: Selector(sel), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        sub("Daisyshot", [item("Hide Daisyshot", "hide:", "h"), item("Hide Others", "hideOtherApplications:", "h", [.command, .option]), .separator(),
                         item("Quit Daisyshot", "terminate:", "q")])
        /// A menu item showing the current binding of a remappable editor shortcut.
        func bound(_ t: String, _ sel: String, _ id: String) -> NSMenuItem {
            let s = EditorShortcuts.shortcut(id)
            return item(t, sel, s?.menuKeyEquivalent ?? "", s?.flags ?? [])
        }
        sub("File", [bound("Save", "annotateSave:", "annotate.save"), bound("Save As…", "annotateSaveAs:", "annotate.saveAs"), .separator(),
                     bound("Add Screenshot From File…", "annotateAddFile:", "annotate.addFromFile"),
                     bound("Add New Screenshot", "annotateAddNew:", "annotate.addNewScreenshot"), .separator(),
                     bound("Print…", "annotatePrint:", "annotate.print"), item("Close", "performClose:", "w")])
        sub("Edit", [item("Undo", "annotateUndo:", "z"), item("Redo", "annotateRedo:", "Z"), .separator(),
                     bound("Copy", "annotateCopy:", "annotate.copyObject"), bound("Copy Screenshot", "annotateCopyAll:", "annotate.copyScreenshot"),
                     item("Paste", "annotatePaste:", "v"),
                     bound("Duplicate", "annotateDuplicate:", "annotate.duplicate"), item("Delete", "annotateDelete:", "\u{8}", [])])
        sub("View", [item("Zoom In", "annotateZoomIn:", "+"), item("Zoom Out", "annotateZoomOut:", "-"),
                     item("Zoom to Fit", "annotateZoomFit:", "0"), item("Actual Size", "annotateZoomActual:", "1"), .separator(),
                     item("Enter Full Screen", "toggleFullScreen:", "f", [.command, .control])])
        let windowMenu = NSMenu(title: "Window".loc)
        windowMenu.addItem(item("Minimize", "performMiniaturize:", "m"))
        windowMenu.addItem(item("Zoom", "performZoom:"))
        let w = NSMenuItem(title: "Window".loc, action: nil, keyEquivalent: "")
        w.submenu = windowMenu
        main.addItem(w)
        NSApp.windowsMenu = windowMenu
        return main
    }
}

// MARK: - Resize dialog model

final class ResizeModel: ObservableObject {
    let base: CGSize
    @Published var percent = false { didSet { if percent != oldValue { convertUnits() } } }
    @Published var lock = true
    @Published var flatten = false
    @Published var width: Int { didSet { if lock, !syncing { sync { height = Int((Double(width) * ratio).rounded()) } } } }
    @Published var height: Int { didSet { if lock, !syncing { sync { width = Int((Double(height) / ratio).rounded()) } } } }
    private var syncing = false

    init(base: CGSize) {
        self.base = base
        width = Int(base.width)
        height = Int(base.height)
    }

    private var ratio: Double { percent ? 1 : Double(base.height / max(1, base.width)) }

    private func sync(_ body: () -> Void) { syncing = true; body(); syncing = false }

    private func convertUnits() {
        sync {
            if percent {
                width = Int((Double(width) / Double(base.width) * 100).rounded())
                height = Int((Double(height) / Double(base.height) * 100).rounded())
            } else {
                width = Int((Double(width) * Double(base.width) / 100).rounded())
                height = Int((Double(height) * Double(base.height) / 100).rounded())
            }
        }
    }

    var pixels: CGSize {
        percent ? CGSize(width: (base.width * CGFloat(width) / 100).rounded(), height: (base.height * CGFloat(height) / 100).rounded())
            : CGSize(width: width, height: height)
    }
}

struct ResizeForm: View {
    @ObservedObject var model: ResizeModel

    private func field(_ v: Binding<Int>) -> some View {
        TextField("", text: Binding(get: { String(v.wrappedValue) }, set: { if let n = Int($0.filter(\.isNumber)), n > 0 { v.wrappedValue = min(n, 30000) } }))
            .frame(width: 90)
            .multilineTextAlignment(.trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack { Text("Width:"); field($model.width) }
                    HStack { Text("Height:"); field($model.height) }
                }
                Button { model.lock.toggle() } label: {
                    Image(systemName: model.lock ? "lock.fill" : "lock.open").frame(width: 18, height: 40)
                }
                .buttonStyle(.borderless)
                .help((model.lock ? "Proportions locked" : "Proportions unlocked").loc)
                Picker("", selection: $model.percent) {
                    Text("pixels").tag(false)
                    Text("percent").tag(true)
                }
                .labelsHidden()
                .frame(width: 96)
            }
            Toggle(isOn: $model.flatten) {
                Text("Flatten Annotations")
                Text("Merges annotations into the image (⌘Z still undoes it).")
            }
        }
        .padding(4)
    }
}
