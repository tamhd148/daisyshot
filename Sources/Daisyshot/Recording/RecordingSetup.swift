import AppKit
import AVFoundation
import SwiftUI

/// Area size presets in the setup bar: free, aspect ratios (lock the selection) or fixed video sizes (pixels).
struct RecordingSizePreset: Identifiable {
    let id: String
    let title: String
    var ratio: CGFloat? = nil
    var pixels: CGSize? = nil

    static let all: [RecordingSizePreset] = [
        .init(id: "free", title: "Freeform"),
        .init(id: "16:9", title: "16:9", ratio: 16.0 / 9),
        .init(id: "4:3", title: "4:3", ratio: 4.0 / 3),
        .init(id: "3:2", title: "3:2", ratio: 3.0 / 2),
        .init(id: "1:1", title: "1:1", ratio: 1),
        .init(id: "9:16", title: "9:16", ratio: 9.0 / 16),
        .init(id: "3:4", title: "3:4", ratio: 3.0 / 4),
        .init(id: "2160p", title: "4K · 3840 × 2160", pixels: CGSize(width: 3840, height: 2160)),
        .init(id: "1440p", title: "1440p · 2560 × 1440", pixels: CGSize(width: 2560, height: 1440)),
        .init(id: "1080p", title: "1080p · 1920 × 1080", pixels: CGSize(width: 1920, height: 1080)),
        .init(id: "720p", title: "720p · 1280 × 720", pixels: CGSize(width: 1280, height: 720)),
        .init(id: "480p", title: "480p · 854 × 480", pixels: CGSize(width: 854, height: 480)),
        .init(id: "1080x1920", title: "Vertical · 1080 × 1920", pixels: CGSize(width: 1080, height: 1920)),
    ]
    static func find(_ id: String) -> RecordingSizePreset { all.first { $0.id == id } ?? all[0] }

    /// Rect of `size` centered on `center`, shrunk (keeping its ratio) and shifted to fit inside `bounds`.
    static func place(_ size: CGSize, center: CGPoint, in bounds: CGRect) -> CGRect {
        let f = min(1, bounds.width / max(1, size.width), bounds.height / max(1, size.height))
        let w = (size.width * f).rounded(), h = (size.height * f).rounded()
        let x = min(max(bounds.minX, center.x - w / 2), bounds.maxX - w)
        let y = min(max(bounds.minY, center.y - h / 2), bounds.maxY - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }

    /// Applies an aspect ratio to a rect being resized by handle `h` (0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L; top-left origin).
    static func constrain(_ r: CGRect, ratio: CGFloat, handle h: Int, in bounds: CGRect) -> CGRect {
        var r = r
        if h == 1 || h == 5 {
            let w = r.height * ratio
            r = CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height)
        } else {
            let hgt = r.width / ratio
            switch h {
            case 0, 2: r = CGRect(x: r.minX, y: r.maxY - hgt, width: r.width, height: hgt)
            case 3, 7: r = CGRect(x: r.minX, y: r.midY - hgt / 2, width: r.width, height: hgt)
            default: r.size.height = hgt
            }
        }
        if bounds.contains(r) { return r }
        return place(r.size, center: CGPoint(x: r.midX, y: r.midY), in: bounds)
    }

    static func selfTest() {
        let b = CGRect(x: 0, y: 0, width: 1000, height: 800)
        assert(place(CGSize(width: 200, height: 100), center: CGPoint(x: 500, y: 400), in: b) == CGRect(x: 400, y: 350, width: 200, height: 100))
        assert(place(CGSize(width: 200, height: 100), center: CGPoint(x: 990, y: 5), in: b) == CGRect(x: 800, y: 0, width: 200, height: 100), "shifted inside")
        assert(place(CGSize(width: 2000, height: 1000), center: .zero, in: b).size == CGSize(width: 1000, height: 500), "shrunk keeping ratio")
        let c = constrain(CGRect(x: 100, y: 100, width: 320, height: 50), ratio: 16.0 / 9, handle: 4, in: b)
        assert(c == CGRect(x: 100, y: 100, width: 320, height: 180))
        let t = constrain(CGRect(x: 100, y: 100, width: 320, height: 300), ratio: 16.0 / 9, handle: 0, in: b)
        assert(t.maxY == 400 && t.height == 180, "top handles keep the bottom edge")
        assert(VideoResolution.p1080.fit(points: CGSize(width: 1728, height: 1117), scale: 2) == (1670, 1080))
        assert(VideoResolution.original.fit(points: CGSize(width: 101, height: 51), scale: 2) == (202, 102))
        assert(VideoResolution.p720.fit(points: CGSize(width: 1080, height: 1920), scale: 1) == (720, 1280), "portrait uses the rotated box")
        assert(VideoResolution.p720.fit(points: CGSize(width: 640, height: 360), scale: 1) == (640, 360), "never upscales")
    }
}

/// Live input level for the setup bar's microphone meter.
final class MicLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let q = DispatchQueue(label: "daisyshot.micmeter")
    private var lastSent = 0.0
    var onLevel: (@Sendable (Float) -> Void)?

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    init?(deviceID: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let device = (deviceID.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceID)) ?? AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        super.init()
        session.addInput(input)
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: q)
        guard session.canAddOutput(out) else { return nil }
        session.addOutput(out)
        q.async { [session] in session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastSent > 1.0 / 20 else { return }
        lastSent = now
        let db = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
        onLevel?(max(0, min(1, (db + 55) / 50)))
    }

    func stop() { q.async { [session] in session.stopRunning() } }
}

/// Pre-recording step (Record Screen): a glass source bar at the top (Screen / Window / Area / Device, camera,
/// microphone, system audio), the target lit on a dimmed screen, and a Start card in the middle of the target
/// (design/record-setup). Always records Studio; GIF is chosen when exporting.
@MainActor
final class RecordingSetup {
    enum Source: String, CaseIterable { case display, window, area, device }

    struct Result {
        var region: CaptureRegion
        var mode: RecordingMode
        var webcam: WebcamBubble?
        var device: (id: String, name: String)? = nil
        /// What happens when it stops: editor | quickExport | saveFile | copyFile.
        var after = "editor"
    }

    final class Model: ObservableObject {
        @Published var source = Source.area
        @Published var preset: String = Prefs.string(.recLastRatio)
        /// What happens after recording (the Start card's menu; remembered).
        @Published var after = Prefs.string(.studioAfterRecording) {
            didSet { Prefs.set(after, .studioAfterRecording) }
        }
        /// Device source: the connected iPhone / iPad shown (nil = none connected).
        @Published var deviceName: String?
        @Published var deviceIsPad = false
        let micLevel = LiveValue<Float>(0)
        weak var owner: RecordingSetup?
    }

    /// What one Start card shows, and what its buttons do.
    final class Card: ObservableObject {
        @Published var kind = Source.area
        @Published var name = ""
        @Published var sub = ""
        @Published var chip: String?
        @Published var icon: NSImage?
        @Published var size = ""
        @Published var canStart = true
        @Published var after = ""
        var start: () -> Void = {}
        var sizeMenu: () -> Void = {}
        var afterMenu: () -> Void = {}
    }

    static let afterChoices = [("editor", "Open in Editor"), ("quickExport", "Show Quick Export"),
                               ("saveFile", "Export MP4 Automatically"), ("copyFile", "Export and Copy MP4 Automatically")]

    func afterMenu() {
        popUpMenu([disabledItem("After Recording")] + Self.afterChoices.map { id, title in
            checked(ClosureMenuItem(title: title, keyEquivalent: "") { [weak self] in
                self?.model.after = id
                self?.layoutCards()
            }, model.after == id)
        })
    }

    let model = Model()
    private var windows: [NSWindow] = []
    private var views: [SetupOverlayView] = []
    private var sourceBar: PaddedHostingView<SourceBar>!
    private var continuation: CheckedContinuation<Result?, Never>?
    private var meter: MicLevelMonitor?
    private var webcam: WebcamBubble?
    /// The window the target was picked from; it stays "the window" (recorded on its own) while the area still matches it.
    var picked: (id: CGWindowID, rect: CGRect)?

    /// `region` nil: nothing is chosen yet; `source` (else the last used one) says how the user picks.
    static func run(region: CaptureRegion?, source: Source? = nil) async -> Result? {
        let s = RecordingSetup()
        return await s.present(region, source: source)
    }

    private init() {
        model.owner = self
        sourceBar = PaddedHostingView(rootView: SourceBar(model: model))
    }

    private func present(_ region: CaptureRegion?, source: Source?) async -> Result? {
        let wins = CaptureService.visibleWindows()
        return await withCheckedContinuation { c in
            continuation = c
            for (n, screen) in NSScreen.screens.enumerated() {
                let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.level = .statusBar
                w.isOpaque = false
                w.backgroundColor = .clear
                w.hasShadow = false
                w.acceptsMouseMovedEvents = true
                w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                w.setFrame(screen.frame, display: false)
                let v = SetupOverlayView(frame: CGRect(origin: .zero, size: screen.frame.size), screen: screen, index: n, owner: self)
                let ignored = Self.ignoredWindows
                v.windowList = wins.compactMap { win in
                    guard !ignored.contains(Self.windowKey(win.owner, win.title)) else { return nil }
                    let r = screen.toDisplayRect(NSScreen.fromCGGlobal(win.frame)).intersection(v.bounds)
                    return r.isNull || r.isEmpty ? nil : .init(id: win.id, rect: r, app: win.owner, title: win.title, pid: win.pid)
                }
                w.contentView = v
                windows.append(w)
                views.append(v)
            }
            let mouseScreen = NSScreen.underMouse.displayID
            let start = views.first { $0.screen.displayID == (region?.displayID ?? mouseScreen) } ?? views[0]
            if let region {
                // A remembered area can lie off-screen after a display change: fall back to the whole display.
                let sel = region.rect.intersection(start.bounds)
                start.selection = sel.isNull || sel.width < 2 || sel.height < 2 ? start.bounds : sel
                if let id = region.windowID, let s = start.selection {
                    picked = (id, s)
                    start.chosenWindow = start.windowList.first { $0.id == id }
                }
                model.source = region.windowID != nil ? .window : start.selection == start.bounds ? .display : .area
            } else {
                model.source = source ?? Source(rawValue: Prefs.string(.recLastSource)) ?? .area
                if model.source == .display { start.selection = start.bounds }
                if model.source == .device { enterDevice(start) }
            }
            placeSourceBar(in: start)
            NSApp.activate(ignoringOtherApps: true)
            windows.forEach { $0.orderFrontRegardless() }
            if let i = views.firstIndex(where: { $0 === start }) {
                windows[i].makeKeyAndOrderFront(nil)
                windows[i].makeFirstResponder(start)
            }
            start.showHint()
            if start.selection != nil { activate(start) } else { layoutCards() }
            views.forEach { $0.pointerMoved() }
            devicesChanged()
        }
    }

    // MARK: State

    private var active: SetupOverlayView? { views.first { $0.selection != nil } }
    /// Nothing chosen yet: the overlay highlights windows under the pointer, or waits for a drag.
    var isPicking: Bool { active == nil }
    var screenCount: Int { views.count }

    /// `view` now holds the target; every other display drops its own.
    func activate(_ view: SetupOverlayView) {
        for v in views where v !== view {
            if v.selection != nil || v.chosenWindow != nil { v.selection = nil; v.chosenWindow = nil }
            v.needsDisplay = true
        }
        view.needsDisplay = true
        placeSourceBar(in: view)
        selectionChanged()
    }

    func selectionChanged() {
        layoutCards()
        guard let (v, r) = webcamTarget else { return }
        syncWebcam()
        webcam?.move(to: v.screen.fromDisplayRect(r))
        if webcam?.panel.isVisible == false { webcam?.panel.orderFrontRegardless() }
    }

    /// What the camera bubble sits on: the area / window / display, or the device preview.
    private var webcamTarget: (SetupOverlayView, CGRect)? {
        if let v = active, let sel = v.selection { return (v, sel) }
        if model.source == .device, let v = deviceView, let stage, stage.superview != nil { return (v, stage.frame) }
        return nil
    }

    /// The source bar sits at the top of the display being worked on, 12 pt under the menu bar.
    func placeSourceBar(in view: SetupOverlayView) {
        if sourceBar.superview !== view { view.addSubview(sourceBar) }
        let size = sourceBar.fittingSize
        let menuBar = view.screen.frame.maxY - view.screen.visibleFrame.maxY
        let pad = PaddedHostingView<SourceBar>.pad
        sourceBar.frame = CGRect(x: ((view.bounds.width - size.width) / 2).rounded(), y: menuBar + 12 - pad, width: size.width, height: size.height)
    }

    /// Bottom of the source bar's glass on `view` (cards and labels stay below it), 0 elsewhere.
    func sourceBarBottom(in view: SetupOverlayView) -> CGFloat {
        sourceBar.superview === view ? sourceBar.frame.maxY - PaddedHostingView<SourceBar>.pad : 0
    }

    /// Screen / Window / Area / Device in the source bar (or ⌘1–4, Space): start picking again.
    func pick(_ source: Source) {
        if model.source == .device, source != .device { leaveDevice() }
        model.source = source
        Prefs.set(source.rawValue, .recLastSource)
        picked = nil
        let here = views.first { $0.bounds.contains($0.mouse) } ?? (sourceBar.superview as? SetupOverlayView) ?? views[0]
        for v in views { v.selection = nil; v.chosenWindow = nil; v.needsDisplay = true }
        webcam?.panel.orderOut(nil)
        if source == .display { here.selection = here.bounds; activate(here) } else { layoutCards() }
        if source == .device { enterDevice(here) }
        if source == .area { here.showHint() }
        here.window?.makeKey()
        here.window?.makeFirstResponder(here)
        here.updateCursor()
    }

    /// Window source: `info` becomes the target (clicked, or its card's Start / size button used).
    func lock(_ info: SetupOverlayView.WindowInfo, in view: SetupOverlayView) {
        view.selection = info.rect
        view.chosenWindow = info
        picked = (info.id, info.rect)
        activate(view)
    }

    // MARK: Start cards

    private static let card = CGSize(width: 340, height: 176)

    /// One card per display in Screen mode; otherwise one card on the target (hidden while dragging).
    func layoutCards() {
        let afterTitle = (Self.afterChoices.first { $0.0 == model.after } ?? Self.afterChoices[0]).1.loc
        for v in views {
            var target: CGRect?
            let c = v.cardModel
            c.after = afterTitle
            c.afterMenu = { [weak self] in self?.afterMenu() }
            switch model.source {
            case .display:
                c.kind = .display
                c.name = v.screen.localizedName
                c.sub = "\(Int(v.bounds.width)) × \(Int(v.bounds.height)) · \(v.screen.maximumFramesPerSecond) Hz"
                c.chip = views.count > 1 ? "Display %d of %d".loc(v.index + 1, views.count) : nil
                c.icon = nil
                c.size = sizeText(v.bounds.size)
                c.start = { [weak self, weak v] in
                    guard let self, let v else { return }
                    v.selection = v.bounds
                    self.activate(v)
                    self.finish(record: true)
                }
                c.sizeMenu = { [weak self, weak v] in
                    guard let self, let v else { return }
                    if v.selection == nil { v.selection = v.bounds; self.activate(v) }
                    self.sizeMenu()
                }
                target = v.bounds
            case .window:
                guard let w = v.chosenWindow ?? v.hovered else { break }
                c.kind = .window
                c.name = w.title.isEmpty ? w.app : w.title
                let size = "\(Int(w.rect.width)) × \(Int(w.rect.height))"
                c.sub = w.title.isEmpty ? size : "\(w.app) · \(size)"
                c.chip = nil
                c.icon = NSRunningApplication(processIdentifier: w.pid)?.icon
                c.size = sizeText(w.rect.size)
                c.start = { [weak self, weak v] in
                    guard let self, let v else { return }
                    if v.chosenWindow?.id != w.id { self.lock(w, in: v) }
                    self.finish(record: true)
                }
                c.sizeMenu = { [weak self, weak v] in
                    guard let self, let v else { return }
                    if v.chosenWindow?.id != w.id { self.lock(w, in: v) }
                    self.sizeMenu()
                }
                target = w.rect
            case .area:
                guard let sel = v.selection, !v.dragging else { break }
                c.kind = .area
                c.name = "Area".loc
                let preset = model.preset == "free" ? "" : " · " + RecordingSizePreset.find(model.preset).id
                c.sub = "\(Int(sel.width)) × \(Int(sel.height))" + preset
                c.chip = nil
                c.icon = nil
                c.size = sizeText(sel.size)
                c.start = { [weak self] in self?.finish(record: true) }
                c.sizeMenu = { [weak self] in self?.sizeMenu() }
                target = sel
            case .device:
                guard v === deviceView else { break }
                c.kind = .device
                c.chip = nil
                c.icon = nil
                if let d = device {
                    let px = deviceSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "…"
                    c.name = d.localizedName
                    c.sub = "\(px) · " + "Cable".loc
                    c.size = "\("Original".loc) · \(px)"
                    c.canStart = deviceSize != nil
                } else {
                    c.name = "No device connected".loc
                    c.sub = "Connect with a cable, unlock it and tap Trust".loc
                    c.size = "Original".loc
                    c.canStart = false
                }
                c.start = { [weak self] in self?.finish(record: true) }
                c.sizeMenu = { popUpMenu([checked(disabledItem("Original"), true), disabledItem("Device recordings keep the device's resolution")]) }
                v.cardBaseAlpha = 1
                v.setCard(deviceCardFrame, animated: false)
                continue
            }
            c.canStart = true
            guard let target else { v.setCard(nil, animated: false); continue }
            v.cardBaseAlpha = model.source == .display && v !== active ? 0.85 : 1
            v.setCard(cardFrame(for: target, kind: model.source, in: v), animated: model.source == .window)
        }
    }

    private func sizeText(_ s: CGSize) -> String {
        let label = model.preset == "free" ? "Original".loc : RecordingSizePreset.find(model.preset).id
        return "\(label) · \(Int(s.width)) × \(Int(s.height))"
    }

    /// Card centre: the middle of the target when it fits there (and clears the camera bubble), else below / above /
    /// beside it; always on screen and under the source bar.
    private func cardFrame(for t: CGRect, kind: Source, in v: SetupOverlayView) -> CGRect {
        let s = Self.card, gap: CGFloat = 14, margin: CGFloat = 12
        let top = max(margin, sourceBarBottom(in: v) + margin), bottom = v.bounds.maxY - margin
        let centred = CGRect(x: t.midX - s.width / 2, y: t.midY - s.height / 2, width: s.width, height: s.height)
        let camera = webcam.flatMap { $0.panel.isVisible ? v.screen.toDisplayRect($0.panel.frame) : nil }
        let fitsInside = (kind == .area ? t.width >= 380 && t.height >= 300 : t.width >= s.width + 32 && t.height >= s.height + 32)
            && !(camera?.intersects(centred) ?? false)
        var c = CGPoint(x: t.midX, y: t.midY)
        if !fitsInside {
            if t.maxY + gap + s.height <= bottom { c.y = t.maxY + gap + s.height / 2 }
            else if t.minY - gap - s.height >= top { c.y = t.minY - gap - s.height / 2 }
            else if kind == .area { c = CGPoint(x: t.maxX + gap + s.width / 2, y: t.midY) }
        }
        var r = CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
        r.origin.x = min(max(margin, r.minX), v.bounds.width - margin - s.width)
        r.origin.y = min(max(top, r.minY), bottom - s.height)
        return r.integral
    }

    // MARK: Device

    private weak var deviceView: SetupOverlayView?
    private var stage: DeviceStageView?
    private var device: AVCaptureDevice?
    private var deviceSize: CGSize?
    private var deviceCardFrame: CGRect?
    private var deviceObservers: [NSObjectProtocol] = []

    /// Device source on `view`: publish iOS screen devices, ask for camera access (needed to read them), show the first.
    private func enterDevice(_ view: SetupOverlayView) {
        deviceView = view
        IOSDevices.enable()
        if deviceObservers.isEmpty {
            for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
                deviceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshDevice() }
                })
            }
        }
        refreshDevice()
        Task { [weak self] in
            if await Recorder.access(.video, usage: "NSCameraUsageDescription", name: "Camera") { self?.refreshDevice(force: true) }
        }
        // Devices are published a moment after `enable()`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshDevice() }
    }

    private func leaveDevice() {
        stage?.stop()
        stage?.removeFromSuperview()
        stage = nil
        device = nil
        deviceSize = nil
        deviceCardFrame = nil
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        deviceObservers = []
        model.deviceName = nil
        deviceView?.deviceLabel = nil
        deviceView?.needsDisplay = true
        deviceView = nil
    }

    /// Shows the chosen (else first) connected device's live screen; `force` restarts the preview.
    func refreshDevice(force: Bool = false) {
        guard model.source == .device, let v = deviceView else { return }
        let d = IOSDevices.chosen()
        if force || d?.uniqueID != device?.uniqueID || (d != nil && stage == nil) {
            stage?.stop()
            stage?.removeFromSuperview()
            stage = nil
            device = d
            deviceSize = d.flatMap(IOSDevices.pixelSize)
            if let d, AVCaptureDevice.authorizationStatus(for: .video) == .authorized, let s = DeviceStageView(device: d) {
                s.onSize = { [weak self] size in self?.deviceSize = size; self?.layoutDevice() }
                v.addSubview(s, positioned: .below, relativeTo: nil)
                stage = s
            }
        }
        model.deviceName = d?.localizedName
        model.deviceIsPad = d.map(IOSDevices.isPad) ?? false
        layoutDevice()
    }

    /// Preview (≤ 620 pt tall, true aspect ratio) and its Start card side by side, centred under the source bar.
    private func layoutDevice() {
        guard model.source == .device, let v = deviceView else { return }
        let card = Self.card, gap: CGFloat = 40, margin: CGFloat = 24
        let top = sourceBarBottom(in: v) + 56, bottom = v.bounds.maxY - margin
        let size = deviceSize ?? CGSize(width: 1179, height: 2556)
        let aspect = size.width / max(1, size.height)
        var h = min(620, bottom - top)
        h = min(h, (v.bounds.width - card.width - gap - margin * 2) / aspect)
        let w = (h * aspect).rounded()
        let x0 = ((v.bounds.width - (stage == nil ? card.width : w + gap + card.width)) / 2).rounded()
        let y = (top + (bottom - top - h) / 2).rounded()
        if let stage {
            stage.frame = CGRect(x: x0, y: y, width: w, height: h.rounded())
            v.deviceLabel = (model.deviceName ?? "", deviceSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "", stage.frame)
            deviceCardFrame = CGRect(x: x0 + w + gap, y: y + h / 2 - card.height / 2, width: card.width, height: card.height).integral
        } else {
            v.deviceLabel = nil
            deviceCardFrame = CGRect(x: x0, y: (v.bounds.height - card.height) / 2, width: card.width, height: card.height).integral
        }
        v.needsDisplay = true
        layoutCards()
        selectionChanged()
    }

    /// The Device tile's menu: connected devices, the frame option, and help for devices that don't show up.
    func deviceMenu() {
        let devices = IOSDevices.list()
        var items: [NSMenuItem] = [disabledItem("Device")]
        for d in devices {
            let item = checked(ClosureMenuItem(title: d.localizedName, keyEquivalent: "") { [weak self] in
                Prefs.set(d.uniqueID, .recDeviceID)
                self?.refreshDevice()
            }, d.uniqueID == device?.uniqueID)
            item.toolTip = "Cable".loc
            items.append(item)
        }
        if devices.isEmpty { items.append(disabledItem("No device connected")) }
        items.append(.separator())
        items.append(checked(ClosureMenuItem(title: "Show Device Frame", keyEquivalent: "") {
            Prefs.set(!Prefs.bool(.recDeviceFrame), .recDeviceFrame)
        }, Prefs.bool(.recDeviceFrame)))
        items.append(.separator())
        items.append(disabledItem("Not listed? Connect the device with a cable, unlock it and tap “Trust”."))
        popUpMenu(items)
    }

    // MARK: Size presets

    func sizeMenu() {
        var items: [NSMenuItem] = []
        if model.source == .window, let v = active, v.chosenWindow != nil {
            items.append(ClosureMenuItem(title: "Adjust Area Instead of Following the Window", keyEquivalent: "") { [weak self] in
                guard let self, let v = self.active else { return }
                self.becomeArea(v)
                v.needsDisplay = true
                self.selectionChanged()
            })
            items.append(.separator())
        }
        for (i, p) in RecordingSizePreset.all.enumerated() {
            if i == 1 || i == 7 { items.append(.separator()) }
            items.append(checked(ClosureMenuItem(title: p.title, keyEquivalent: "") { [weak self] in self?.applyPreset(p.id) }, model.preset == p.id))
        }
        // Sizes you saved (points, like the area).
        let saved = Self.savedSizes
        if !saved.isEmpty {
            items.append(.separator())
            items.append(disabledItem("Saved Sizes"))
            for s in saved {
                items.append(ClosureMenuItem(title: "\(Int(s.width)) × \(Int(s.height))", keyEquivalent: "") { [weak self] in self?.applySize(s) })
            }
        }
        items.append(.separator())
        if let sel = active?.selection {
            items.append(ClosureMenuItem(title: "Save Current Size", keyEquivalent: "") {
                var list = Self.savedSizes.filter { $0 != sel.size.rounded }
                list.insert(sel.size.rounded, at: 0)
                Self.savedSizes = Array(list.prefix(12))
            })
        }
        if !saved.isEmpty {
            let del = NSMenuItem(title: "Delete Saved Size".loc, action: nil, keyEquivalent: "")
            del.submenu = NSMenu()
            for s in saved {
                del.submenu?.addItem(ClosureMenuItem(title: "\(Int(s.width)) × \(Int(s.height))", keyEquivalent: "") { Self.savedSizes.removeAll { $0 == s } })
            }
            items.append(del)
        }
        items.append(ClosureMenuItem(title: "Set Size and Position…", keyEquivalent: "") { [weak self] in self?.askSizeAndPosition() })
        popUpMenu(items)
    }

    // MARK: Saved sizes, exact size

    static var savedSizes: [CGSize] {
        get {
            Prefs.string(.recSavedSizes).split(separator: "\n").compactMap { line in
                let p = line.split(separator: "x").compactMap { Double($0) }
                return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
            }
        }
        set { Prefs.set(newValue.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: "\n"), .recSavedSizes) }
    }

    /// An area of `size` (points) centred on the current one.
    private func applySize(_ size: CGSize) {
        guard let v = active ?? sourceBar.superview as? SetupOverlayView else { return }
        let c = v.selection.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: v.bounds.midX, y: v.bounds.midY)
        v.selection = RecordingSizePreset.place(size, center: c, in: v.bounds)
        model.preset = "free"
        becomeArea(v)
        activate(v)
    }

    /// Width, height and top-left position typed in (points on this display).
    private func askSizeAndPosition() {
        guard let v = active ?? sourceBar.superview as? SetupOverlayView else { return }
        let r = v.selection ?? CGRect(x: v.bounds.midX - 400, y: v.bounds.midY - 225, width: 800, height: 450)
        let fields = [r.width, r.height, r.minX, r.minY].map { n -> NSTextField in
            let f = NSTextField(string: "\(Int(n))")
            f.frame.size = CGSize(width: 70, height: 24)
            return f
        }
        let labels = ["W", "H", "X", "Y"].map { NSTextField(labelWithString: $0) }
        let row = NSStackView(views: zip(labels, fields).flatMap { [$0.0 as NSView, $0.1] })
        row.spacing = 6
        row.frame.size = CGSize(width: 380, height: 24)
        let a = NSAlert()
        a.messageText = "Set Size and Position"
        a.informativeText = "Points on this display, from its top-left corner."
        a.accessoryView = row
        a.addButton(withTitle: "Set")
        a.addButton(withTitle: "Cancel")
        a.localize()
        a.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        a.window.initialFirstResponder = fields[0]
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let n = fields.map { CGFloat(Double($0.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0) }
        guard n[0] >= 8, n[1] >= 8 else { NSSound.beep(); return }
        v.selection = CGRect(x: n[2], y: n[3], width: n[0], height: n[1]).intersection(v.bounds)
        model.preset = "free"
        becomeArea(v)
        activate(v)
    }

    // MARK: Ignored windows

    static func windowKey(_ app: String, _ title: String) -> String { app + "\t" + title }
    static var ignoredWindows: Set<String> { Set(Prefs.string(.recIgnoredWindows).split(separator: "\n").map(String.init)) }

    /// Right-click a window while picking windows.
    func windowMenu(_ w: SetupOverlayView.WindowInfo, in v: SetupOverlayView) {
        var items: [NSMenuItem] = [
            ClosureMenuItem(title: "Record This Window", keyEquivalent: "") { [weak self] in self?.lock(w, in: v) },
            ClosureMenuItem(title: "Bring to Front", keyEquivalent: "") { [weak self] in self?.bringToFront(w, in: v) },
            ClosureMenuItem(title: "Ignore This Window", keyEquivalent: "") { [weak self] in
                var set = Self.ignoredWindows
                set.insert(Self.windowKey(w.app, w.title))
                Prefs.set(set.sorted().joined(separator: "\n"), .recIgnoredWindows)
                self?.views.forEach { $0.windowList.removeAll { $0.app == w.app && $0.title == w.title } }
                v.needsDisplay = true
            },
        ]
        if !Self.ignoredWindows.isEmpty {
            items.append(.separator())
            items.append(ClosureMenuItem(title: "Reset Ignored Windows", keyEquivalent: "") {
                Prefs.set("", .recIgnoredWindows)
                Toast.show("Ignored windows reset — they show the next time you record")
            })
        }
        popUpMenu(items)
    }

    /// Raises the window (its app comes forward, the window via Accessibility), then takes the keyboard back.
    private func bringToFront(_ w: SetupOverlayView.WindowInfo, in v: SetupOverlayView) {
        NSRunningApplication(processIdentifier: w.pid)?.activate()
        let app = AXUIElementCreateApplication(w.pid)
        var list: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &list) == .success, let wins = list as? [AXUIElement] {
            for win in wins {
                var t: CFTypeRef?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t)
                if (t as? String) == w.title { AXUIElementPerformAction(win, kAXRaiseAction as CFString); break }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.activate(ignoringOtherApps: true)
            v.window?.makeKeyAndOrderFront(nil)
            v.window?.makeFirstResponder(v)
        }
    }

    /// Fixed-size presets are pixel sizes, so they depend on the display's scale and "Scale Retina videos to 1x".
    func applyPreset(_ id: String) {
        model.preset = id
        Prefs.set(id, .recLastRatio)
        guard let v = active, let sel = v.selection else { return }
        let p = RecordingSizePreset.find(id)
        let center = CGPoint(x: sel.midX, y: sel.midY)
        if let px = p.pixels, let w = picked, w.rect == sel {
            // A picked window is resized itself (Accessibility), so the app lays out at exactly that size.
            if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
                let scale = Prefs.bool(.recDownscaleRetina) ? 1 : v.screen.backingScaleFactor
                Task { [weak self] in
                    guard let frame = await CaptureService.resizeWindow(w.id, to: CGSize(width: px.width / scale, height: px.height / scale)),
                          let self, let v = self.active else { return }
                    let r = v.screen.toDisplayRect(NSScreen.fromCGGlobal(frame)).intersection(v.bounds)
                    v.selection = r
                    v.chosenWindow?.rect = r
                    self.picked = (w.id, r)
                    v.needsDisplay = true
                    self.selectionChanged()
                }
                return
            }
            Toast.show("Allow Accessibility access to resize windows to a preset size", isError: true)
        }
        if let px = p.pixels {
            let scale = Prefs.bool(.recDownscaleRetina) ? 1 : v.screen.backingScaleFactor
            v.selection = RecordingSizePreset.place(CGSize(width: px.width / scale, height: px.height / scale), center: center, in: v.bounds)
        } else if let r = p.ratio {
            let area = sel.width * sel.height
            let w = (area * r).squareRoot()
            v.selection = RecordingSizePreset.place(CGSize(width: w, height: w / r), center: center, in: v.bounds)
        }
        // A display or window that no longer matches the target is now just an area.
        if v.selection != sel || model.source == .display { becomeArea(v) }
        v.needsDisplay = true
        selectionChanged()
    }

    /// The target was dragged / resized by hand into a plain area.
    func becomeArea(_ v: SetupOverlayView) {
        guard model.source != .area else { return }
        model.source = .area
        picked = nil
        v.chosenWindow = nil
    }

    /// Aspect ratio that drags must keep (fixed sizes turn into freeform once the user resizes by hand).
    var lockedRatio: CGFloat? { RecordingSizePreset.find(model.preset).ratio }
    func userResized() {
        if RecordingSizePreset.find(model.preset).pixels != nil { model.preset = "free"; Prefs.set("free", .recLastRatio) }
    }

    // MARK: Devices

    /// Mic / camera choice changed: restart the level meter and camera preview.
    func devicesChanged() {
        meter?.stop()
        meter = nil
        model.micLevel.value = 0
        if Prefs.bool(.recMicrophone) {
            meter = MicLevelMonitor(deviceID: Prefs.string(.recMicDeviceID))
            meter?.onLevel = { [weak model] l in DispatchQueue.main.async { model?.micLevel.value = l } }
        }
        syncWebcam()
    }

    /// The camera preview follows the target; it appears once there is one.
    private func syncWebcam() {
        let camID = Prefs.string(.recCameraDeviceID)
        if !Prefs.bool(.recWebcam) {
            webcam?.stop()
            webcam = nil
        } else if webcam == nil || webcam?.deviceID != camID, let (v, r) = webcamTarget {
            webcam?.stop()
            webcam = WebcamBubble(deviceID: camID, area: v.screen.fromDisplayRect(r))
            webcam?.panel.orderFrontRegardless()
        }
    }

    // MARK: Settings

    private var settingsObserver: NSObjectProtocol?

    /// Settings › Screen Recording, with the setup hidden meanwhile (it floats above every window); it comes back when
    /// the Settings window closes.
    func openSettings() {
        guard settingsObserver == nil, let settings = SettingsWindow.show(tab: "screenRecording") else { return }
        windows.forEach { $0.orderOut(nil) }
        webcam?.panel.orderOut(nil)
        settingsObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: settings, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsClosed() }
        }
    }

    private func settingsClosed() {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        guard continuation != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        if let v = (sourceBar.superview as? SetupOverlayView), let w = v.window {
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(v)
        }
        devicesChanged()          // camera / microphone may have changed in Settings
        selectionChanged()
    }

    // MARK: Finish

    /// Return: the target under the pointer — this display, the hovered (or chosen) window, or the area.
    func startDefault() {
        switch model.source {
        case .display:
            if let v = views.first(where: { $0.bounds.contains($0.mouse) }), v.selection == nil { v.selection = v.bounds; activate(v) }
        case .window:
            if active == nil, let v = views.first(where: { $0.hovered != nil }), let w = v.hovered { lock(w, in: v) }
        case .area, .device:
            break
        }
        finish(record: true)
    }

    /// Device source: a connected device that is streaming.
    private var deviceReady: Bool { model.source == .device && device != nil && deviceSize != nil && stage != nil }

    func finish(record: Bool) {
        guard let c = continuation, !record || active != nil || deviceReady else { return }   // Return with nothing chosen yet does nothing
        continuation = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        meter?.stop()
        var result: Result?
        if record, deviceReady, let d = device, let v = deviceView, let stage {
            result = Result(region: CaptureRegion(displayID: v.screen.displayID, rect: stage.frame), mode: .studio, webcam: webcam,
                            device: (d.uniqueID, d.localizedName), after: model.after)
            Prefs.set(d.uniqueID, .recDeviceID)
        } else if record, let v = active, let sel = v.selection?.integral, sel.width >= 2, sel.height >= 2 {
            let window = picked.flatMap { $0.rect.integral == sel ? $0.id : nil }
            result = Result(region: CaptureRegion(displayID: v.screen.displayID, rect: sel, windowID: window), mode: .studio, webcam: webcam,
                            after: model.after)
        } else {
            webcam?.stop()
        }
        sourceBar.removeFromSuperview()
        leaveDevice()
        views.forEach { $0.teardown() }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        c.resume(returning: result)
    }
}

// MARK: - Overlay view

/// One display: the dim layer, the lit target (area frame with petal handles, hovered / chosen window, whole display),
/// the size label, the drag hint and this display's Start card.
final class SetupOverlayView: NSView {
    struct WindowInfo {
        let id: CGWindowID
        var rect: CGRect
        let app: String
        let title: String
        let pid: pid_t
    }

    let screen: NSScreen
    let index: Int
    private weak var owner: RecordingSetup?
    var selection: CGRect?
    var windowList: [WindowInfo] = []
    /// Window source: the window under the pointer, and the one clicked (locked as the target).
    private(set) var hovered: WindowInfo?
    var chosenWindow: WindowInfo?
    private(set) var mouse = CGPoint(x: -1000, y: -1000)
    private(set) var dragging = false
    /// Device source: name, resolution and the preview's frame, for the label above it.
    var deviceLabel: (name: String, size: String, frame: CGRect)?
    private enum Drag { case create(CGPoint), move, handle(Int) }
    private var drag: Drag?
    private var last = CGPoint.zero
    private var moved = false
    private var hoverHandle: Int?
    private var hintUntil = Date.distantPast

    let cardModel = RecordingSetup.Card()
    private lazy var card = PaddedHostingView(rootView: StartCardView(card: cardModel))
    var cardBaseAlpha: CGFloat = 1

    init(frame: CGRect, screen: NSScreen, index: Int, owner: RecordingSetup) {
        self.screen = screen
        self.index = index
        self.owner = owner
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    func teardown() {
        card.removeFromSuperview()
    }

    private var source: RecordingSetup.Source { owner?.model.source ?? .area }
    /// The lit rect drawn as a window (accent outline), not as an area frame.
    private var litWindow: WindowInfo? { source == .window ? chosenWindow ?? (owner?.isPicking == true ? hovered : nil) : nil }

    // MARK: Card

    /// Shows the card at `frame` (glass size, without the shadow padding), or hides it.
    func setCard(_ frame: CGRect?, animated: Bool) {
        guard let frame else {
            if card.superview != nil { card.removeFromSuperview() }
            return
        }
        let pad = PaddedHostingView<StartCardView>.pad
        let size = card.fittingSize
        let f = CGRect(x: frame.minX - pad, y: frame.midY - size.height / 2, width: size.width, height: size.height)
        let appearing = card.superview == nil
        if appearing {
            addSubview(card)
            card.frame = f
            card.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.animator().alphaValue = cardBaseAlpha
            }
        } else if animated, card.frame != f, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)   // spring-like settle
                card.animator().frame = f
            }
        } else {
            card.frame = f
        }
        if !appearing { card.alphaValue = cardBaseAlpha }
    }

    private var pointerOnCard: Bool { card.superview != nil && card.frame.insetBy(dx: PaddedHostingView<StartCardView>.pad, dy: PaddedHostingView<StartCardView>.pad).contains(mouse) }

    // MARK: Hint

    /// "Drag to select an area · Space Window · Esc Cancel" beside the pointer for 4 s, until a drag starts.
    func showHint() {
        hintUntil = Date().addingTimeInterval(4)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.05) { [weak self] in self?.needsDisplay = true }
    }

    private var hintVisible: Bool { source == .area && selection == nil && !dragging && Date() < hintUntil && bounds.contains(mouse) }

    // MARK: Geometry

    /// Petal handles: centre, angle (degrees; 0 = horizontal capsule). Order 0 TL, 1 T, 2 TR, 3 R, 4 BR, 5 B, 6 BL, 7 L.
    private static func petals(_ r: CGRect) -> [(CGPoint, CGFloat)] {
        let d: CGFloat = 4
        return [(CGPoint(x: r.minX - d, y: r.minY - d), 45), (CGPoint(x: r.midX, y: r.minY - d), 90),
                (CGPoint(x: r.maxX + d, y: r.minY - d), -45), (CGPoint(x: r.maxX + d, y: r.midY), 0),
                (CGPoint(x: r.maxX + d, y: r.maxY + d), 45), (CGPoint(x: r.midX, y: r.maxY + d), 90),
                (CGPoint(x: r.minX - d, y: r.maxY + d), -45), (CGPoint(x: r.minX - d, y: r.midY), 0)]
    }

    private var showsHandles: Bool { source == .area && selection != nil && !dragging }

    private func handle(at p: CGPoint) -> Int? {
        guard showsHandles, let sel = selection else { return nil }
        return Self.petals(sel).firstIndex { hypot($0.0.x - p.x, $0.0.y - p.y) <= 12 }   // 24 pt hit area
    }

    private func window(at p: CGPoint) -> WindowInfo? { windowList.first { $0.rect.contains(p) } }

    // MARK: Mouse

    override func mouseMoved(with e: NSEvent) {
        pointerMoved(to: convert(e.locationInWindow, from: nil))
    }

    /// Also called when the overlay opens, so the hovered window / display and the hint show before the first move.
    func pointerMoved(to p: CGPoint? = nil) {
        let old = mouse
        mouse = p ?? screen.toDisplayRect(CGRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        guard let owner else { return }
        switch source {
        case .display:
            if selection == nil, bounds.contains(mouse) { selection = bounds; owner.activate(self) }
        case .window where owner.isPicking:
            // Keep the window while the pointer crosses over to its card.
            if !pointerOnCard {
                let w = window(at: mouse)
                if w?.id != hovered?.id { hovered = w; needsDisplay = true; owner.layoutCards() }
            }
        default:
            break
        }
        let h = handle(at: mouse)
        if h != hoverHandle { hoverHandle = h; invalidateFrame() }
        if Date() < hintUntil { setNeedsDisplay(hintRect(at: old)); setNeedsDisplay(hintRect(at: mouse)) }
        updateCursor()
    }

    override func mouseEntered(with e: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if owner?.isPicking == true { owner?.placeSourceBar(in: self) }
    }

    override func mouseExited(with e: NSEvent) {
        mouse = CGPoint(x: -1000, y: -1000)
        if hovered != nil, owner?.isPicking == true { hovered = nil; owner?.layoutCards() }
        needsDisplay = true
    }

    private static let crosshair: NSCursor = {
        let img = NSImage(size: CGSize(width: 34, height: 34), flipped: true) { _ in
            let p = NSBezierPath()
            for (a, b) in [((17, 2), (17, 14)), ((17, 20), (17, 32)), ((2, 17), (14, 17)), ((20, 17), (32, 17))] {
                p.move(to: CGPoint(x: a.0, y: a.1)); p.line(to: CGPoint(x: b.0, y: b.1))
            }
            p.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.55).setStroke(); p.lineWidth = 3.5; p.stroke()
            NSColor.white.setStroke(); p.lineWidth = 1.5; p.stroke()
            let dot = NSBezierPath(ovalIn: CGRect(x: 14.8, y: 14.8, width: 4.4, height: 4.4))
            NSColor(hex: "#FFC633").setFill(); dot.fill()
            NSColor.white.setStroke(); dot.lineWidth = 1; dot.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: CGPoint(x: 17, y: 17))
    }()

    func updateCursor() {
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        if source != .area || pointerOnCard { NSCursor.arrow.set() }
        else if let h = handle(at: mouse) { NSCursor.frameResize(position: positions[h], directions: .all).set() }
        else if selection?.contains(mouse) == true { NSCursor.openHand.set() }
        else { Self.crosshair.set() }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        last = p
        moved = false
        switch source {
        case .window, .device: drag = nil
        case .display: drag = .create(p)
        case .area:
            if let h = handle(at: p) { drag = .handle(h) }
            else if selection?.contains(p) == true { drag = .move; NSCursor.closedHand.set() }
            else { drag = .create(p) }
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let owner, let drag else { return }
        let p = convert(e.locationInWindow, from: nil).clamped(to: bounds)
        defer { last = p; mouse = p; needsDisplay = true; owner.selectionChanged() }
        if !moved, hypot(p.x - last.x, p.y - last.y) < 2, case .create = drag { return }
        if !moved { hintUntil = .distantPast }
        moved = true
        dragging = true
        let ratio = owner.lockedRatio
        switch drag {
        case let .create(o):
            var w = p.x - o.x, h = p.y - o.y
            if let ratio { h = (abs(w) / ratio) * (h < 0 ? -1 : 1) }
            else if e.modifierFlags.contains(.shift) { let m = max(abs(w), abs(h)); w = w < 0 ? -m : m; h = h < 0 ? -m : m }
            selection = CGRect(x: o.x, y: o.y, width: w, height: h).standardized.intersection(bounds)
            owner.userResized()
            owner.becomeArea(self)
            if selection != nil { owner.activate(self) }
        case .move:
            guard var sel = selection else { return }
            sel = sel.offsetBy(dx: p.x - last.x, dy: p.y - last.y)
            sel.origin.x = min(max(0, sel.minX), bounds.width - sel.width)
            sel.origin.y = min(max(0, sel.minY), bounds.height - sel.height)
            selection = sel
        case let .handle(h):
            guard let sel = selection else { return }
            let dx = p.x - last.x, dy = p.y - last.y
            var minX = sel.minX, minY = sel.minY, maxX = sel.maxX, maxY = sel.maxY
            if [0, 6, 7].contains(h) { minX += dx }
            if [2, 3, 4].contains(h) { maxX += dx }
            if [0, 1, 2].contains(h) { minY += dy }
            if [4, 5, 6].contains(h) { maxY += dy }
            var r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(8, abs(maxX - minX)), height: max(8, abs(maxY - minY)))
            if let ratio { r = RecordingSizePreset.constrain(r, ratio: ratio, handle: h, in: bounds) }
            selection = r.intersection(bounds)
            owner.userResized()
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = nil; updateCursor() }
        guard let owner else { return }
        let wasDragging = dragging
        dragging = false
        switch source {
        case .window:
            if let w = window(at: mouse) { owner.lock(w, in: self) }
        case .display:
            if !moved { selection = bounds; owner.activate(self) }
        default:
            break
        }
        if wasDragging { owner.selectionChanged() }
        needsDisplay = true
    }

    /// Right-click: a window's menu while picking windows; elsewhere it cancels.
    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if source == .window, let w = window(at: p) { owner?.windowMenu(w, in: self); return }
        owner?.finish(record: false)
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        guard let owner else { return }
        if e.modifierFlags.contains(.command), let i = [18: 0, 19: 1, 20: 2, 21: 3][Int(e.keyCode)] {
            owner.pick(RecordingSetup.Source.allCases[i])     // ⌘1–4: Screen / Window / Area / Device
            return
        }
        switch e.keyCode {
        case 53: owner.finish(record: false)
        case 36, 76: owner.startDefault()
        case 49: owner.pick(source == .window ? .area : .window)
        case 123, 124, 125, 126:
            guard source == .area, var sel = selection else { return }
            let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            let (dx, dy): (CGFloat, CGFloat) = [123: (-step, 0), 124: (step, 0), 125: (0, step), 126: (0, -step)][e.keyCode]!
            if e.modifierFlags.contains(.option) {
                sel.size.width = max(8, sel.width + dx)
                sel.size.height = max(8, sel.height + dy)
                owner.userResized()
            } else {
                sel = sel.offsetBy(dx: dx, dy: dy)
            }
            selection = sel.intersection(bounds)
            owner.selectionChanged()
            needsDisplay = true
        default:
            super.keyDown(with: e)
        }
    }

    // MARK: Drawing

    private func invalidateFrame() {
        guard let sel = selection else { return }
        setNeedsDisplay(sel.insetBy(dx: -30, dy: -30))
    }

    private static let accent = NSColor(hex: "#3E7BFA")
    private static let yellow = NSColor(hex: "#FFC633")
    private static let pillBg = NSColor(hex: "#101A33").withAlphaComponent(0.88)

    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        let dim = NSColor.black.withAlphaComponent(source == .device ? 0.55 : 0.4)
        switch source {
        case .display:
            if selection != nil {
                // The display being recorded: clear, with an accent outline drawn inside its edge.
                Self.accent.withAlphaComponent(0.08).setFill()
                bounds.fill()
                Self.accent.setStroke()
                let p = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2)); p.lineWidth = 4; p.stroke()
            } else {
                dim.setFill(); bounds.fill()
            }
        case .window:
            if let w = litWindow {
                let shape = NSBezierPath(roundedRect: w.rect, xRadius: 10, yRadius: 10)
                let d = NSBezierPath(rect: bounds); d.append(shape); d.windingRule = .evenOdd
                dim.setFill(); d.fill()
                Self.accent.withAlphaComponent(0.12).setFill(); shape.fill()
                Self.accent.setStroke()
                let o = NSBezierPath(roundedRect: w.rect.insetBy(dx: 1.5, dy: 1.5), xRadius: 9, yRadius: 9); o.lineWidth = 3; o.stroke()
                let name = w.title.isEmpty ? w.app : w.title
                label([(name, .white), ("\(Int(w.rect.width)) × \(Int(w.rect.height))", NSColor.white.withAlphaComponent(0.75))],
                      above: w.rect, background: NSColor(hex: "#2B5FE0"))
            } else {
                dim.setFill(); bounds.fill()
            }
        case .area:
            let d = NSBezierPath(rect: bounds)
            if let sel = selection, sel.width > 0, sel.height > 0 { d.append(NSBezierPath(rect: sel)); d.windingRule = .evenOdd }
            dim.setFill(); d.fill()
            if let sel = selection { drawArea(sel, owner: owner) }
            if hintVisible { drawHint(at: mouse) }
        case .device:
            dim.setFill(); bounds.fill()
            if let d = deviceLabel {
                label([("●", NSColor(hex: "#2FA57A")), (d.name, .white), (d.size, NSColor.white.withAlphaComponent(0.7))],
                      at: CGPoint(x: d.frame.minX, y: d.frame.minY - 30), background: Self.pillBg)
            }
        }
    }

    private func drawArea(_ sel: CGRect, owner: RecordingSetup) {
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let outer = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5)); outer.lineWidth = 1; outer.stroke()
        let line = NSBezierPath(rect: sel.insetBy(dx: 0.75, dy: 0.75))
        line.lineWidth = 1.5
        if !dragging { line.setLineDash([6, 4], count: 2, phase: 0) }
        NSColor.white.setStroke(); line.stroke()
        if dragging {
            // Rule of thirds while drawing / resizing.
            let g = NSBezierPath()
            for i in 1...2 {
                let x = sel.minX + sel.width * CGFloat(i) / 3, y = sel.minY + sel.height * CGFloat(i) / 3
                g.move(to: CGPoint(x: x, y: sel.minY)); g.line(to: CGPoint(x: x, y: sel.maxY))
                g.move(to: CGPoint(x: sel.minX, y: y)); g.line(to: CGPoint(x: sel.maxX, y: y))
            }
            NSColor.white.withAlphaComponent(0.3).setStroke(); g.lineWidth = 1; g.stroke()
        } else {
            for (i, (c, angle)) in Self.petals(sel).enumerated() { drawPetal(at: c, angle: angle, hover: i == hoverHandle) }
            // The daisy's centre: a yellow dot in the middle of the area.
            let dot = NSBezierPath(ovalIn: CGRect(x: sel.midX - 4.5, y: sel.midY - 4.5, width: 9, height: 9))
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.4); sh.shadowBlurRadius = 3; sh.shadowOffset = CGSize(width: 0, height: -1); sh.set()
            Self.yellow.setFill(); dot.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke(); dot.lineWidth = 1.5; dot.stroke()
        }
        let size = "\(Int(sel.width)) × \(Int(sel.height))"
        let preset = owner.model.preset == "free" ? nil : RecordingSizePreset.find(owner.model.preset).id
        var parts: [(String, NSColor)] = [(size, .white)]
        if let preset { parts.append((preset, Self.yellow)) }
        if dragging { label(parts, at: CGPoint(x: mouse.x + 16, y: mouse.y + 16), background: Self.pillBg) }
        else { label(parts, above: sel, background: Self.pillBg) }
    }

    private func drawPetal(at c: CGPoint, angle: CGFloat, hover: Bool) {
        let (l, w): (CGFloat, CGFloat) = hover ? (20, 8) : (16, 6)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: angle * .pi / 180)
        let r = CGRect(x: -l / 2, y: -w / 2, width: l, height: w)
        let p = NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2)
        if hover {
            Self.accent.withAlphaComponent(0.25).setStroke()
            let halo = NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: w / 2 + 2, yRadius: w / 2 + 2); halo.lineWidth = 3; halo.stroke()
            Self.accent.setFill(); p.fill()
            NSColor.white.setStroke(); p.lineWidth = 1.5; p.stroke()
        } else {
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 3; sh.shadowOffset = CGSize(width: 0, height: -1); sh.set()
            NSColor.white.setFill(); p.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor(hex: "#101A33").withAlphaComponent(0.45).setStroke(); p.lineWidth = 1; p.stroke()
        }
        ctx.restoreGState()
    }

    /// A size / name pill: above the top-left corner of `r` (8 pt gap), inside it when there's no room.
    private func label(_ parts: [(String, NSColor)], above r: CGRect, background: NSColor) {
        let top = (owner?.sourceBarBottom(in: self) ?? 0) + 4
        var p = CGPoint(x: r.minX, y: r.minY - 8 - 22)
        if p.y < top { p = CGPoint(x: r.minX + 8, y: r.minY + 8) }
        label(parts, at: p, background: background)
    }

    private func label(_ parts: [(String, NSColor)], at p: CGPoint, background: NSColor) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let s = NSMutableAttributedString()
        for (i, (text, color)) in parts.enumerated() {
            s.append(NSAttributedString(string: (i > 0 ? "  " : "") + text, attributes: [.font: font, .foregroundColor: color]))
        }
        let size = s.size()
        var r = CGRect(x: p.x, y: p.y, width: (size.width + 18).rounded(.up), height: 22)
        r.origin.x = min(max(4, r.minX), bounds.width - r.width - 4)
        r.origin.y = min(max(4, r.minY), bounds.height - r.height - 4)
        background.setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        s.draw(at: CGPoint(x: r.minX + 9, y: r.minY + (22 - size.height) / 2))
    }

    private static let hintText: NSAttributedString = {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium), key = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let s = NSMutableAttributedString()
        func add(_ t: String, _ f: NSFont, _ a: CGFloat = 1) {
            s.append(NSAttributedString(string: t, attributes: [.font: f, .foregroundColor: NSColor.white.withAlphaComponent(a)]))
        }
        add("Drag to select an area".loc, font); add("  ·  ", font, 0.6)
        add("Space", key); add("  " + "Window".loc, font); add("  ·  ", font, 0.6)
        add("Esc", key); add("  " + "Cancel".loc, font)
        return s
    }()

    private func hintRect(at p: CGPoint) -> CGRect {
        CGRect(x: p.x + 22, y: p.y + 20, width: Self.hintText.size().width + 40, height: 28).insetBy(dx: -4, dy: -4)
    }

    private func drawHint(at p: CGPoint) {
        let text = Self.hintText
        let size = text.size()
        let r = CGRect(x: p.x + 22, y: p.y + 20, width: (size.width + 20).rounded(.up), height: 28)
        Self.pillBg.setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        // Keycaps behind "Space" and "Esc".
        let ns = text.string as NSString
        for key in ["Space", "Esc"] {
            let range = ns.range(of: key)
            guard range.location != NSNotFound else { continue }
            let x0 = text.attributedSubstring(from: NSRange(location: 0, length: range.location)).size().width
            let w = text.attributedSubstring(from: range).size().width
            NSColor.white.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: CGRect(x: r.minX + 10 + x0 - 5, y: r.minY + 6, width: w + 10, height: 16), xRadius: 4, yRadius: 4).fill()
        }
        text.draw(at: CGPoint(x: r.minX + 10, y: r.minY + (28 - size.height) / 2))
    }
}

/// A hosting view whose SwiftUI content has `pad` of transparent room for its shadow; clicks there fall through.
final class PaddedHostingView<Content: View>: NSHostingView<Content> {
    static var pad: CGFloat { 24 }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.insetBy(dx: Self.pad, dy: Self.pad).contains(p) else { return nil }
        return super.hitTest(point)
    }
}

/// A single fast-changing value, observed only by the small view that shows it (the bar doesn't re-render).
final class LiveValue<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

func checked(_ item: NSMenuItem, _ on: Bool) -> NSMenuItem {
    item.state = on ? .on : .off
    return item
}

func disabledItem(_ title: String) -> NSMenuItem {
    let i = NSMenuItem(title: title.loc, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

func popUpMenu(_ items: [NSMenuItem]) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    items.forEach(menu.addItem)
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}

private extension CGSize {
    var rounded: CGSize { CGSize(width: width.rounded(), height: height.rounded()) }
}
