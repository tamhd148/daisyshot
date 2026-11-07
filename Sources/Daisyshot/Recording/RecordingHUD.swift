import AppKit
import AVFoundation
import SwiftUI

/// Everything shown on screen while recording. All our windows are excluded from the capture except
/// `recordedWindowNumbers`: click highlights, keystrokes and the camera bubble (except in Studio Mode).
@MainActor
final class RecordingHUD {
    final class Model: ObservableObject {
        @Published var elapsed: Double = 0
        @Published var paused = false
        @Published var micMuted = false
        let hasMic: Bool
        init(hasMic: Bool) { self.hasMic = hasMic }
    }

    let model: Model
    private var border: FloatingPanel?
    private var bar: FloatingPanel?
    private var dims: [FloatingPanel] = []
    private(set) var webcam: WebcamBubble?
    private var keystrokes: KeystrokeOverlay?
    private var clicks: ClickHighlighter?
    private let studio: Bool

    /// Our windows that must appear in the video (everything else of ours is excluded).
    var recordedWindowNumbers: [Int] {
        var n = [keystrokes?.windowNumber, clicks?.windowNumber].compactMap { $0 }
        if !studio, let w = webcam { n.append(w.panel.windowNumber) }
        return n
    }

    /// `followsWindow`: the recording follows a window around, so there's no fixed area to frame or dim around.
    init(screen: NSScreen, rect: CGRect, mic: Bool, webcam: WebcamBubble?, keystrokes: Bool, clicks: Bool, studio: Bool, followsWindow: Bool = false) {
        model = Model(hasMic: mic)
        self.studio = studio
        let fullscreen = followsWindow || rect.insetBy(dx: 1, dy: 1).contains(screen.frame)
        if !fullscreen {
            let b = FloatingPanel(rect: rect.insetBy(dx: -3, dy: -3), level: .statusBar, interactive: false)
            b.hasShadow = false
            b.contentView = NSHostingView(rootView: RoundedRectangle(cornerRadius: 3).strokeBorder(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
            border = b
        }
        do {
            let host = NSHostingView(rootView: RecordingControls(model: model))
            let size = host.fittingSize
            let vf = screen.visibleFrame
            var y = rect.minY - size.height - 10
            if y < vf.minY + 4 { y = rect.maxY + 10 }
            if y + size.height > vf.maxY - 4 { y = rect.minY + 12 }   // no room outside: sit inside (still excluded from the video)
            let x = min(max(rect.midX - size.width / 2, vf.minX + 4), vf.maxX - size.width - 4)
            let p = FloatingPanel(rect: CGRect(x: x, y: y, width: size.width, height: size.height), level: .statusBar)
            p.isMovableByWindowBackground = true
            p.contentView = host
            bar = p
        }
        if Prefs.bool(.recDimScreen), !fullscreen {
            // "Dim screen while recording": darken everything outside the recorded area, on every display.
            for s in NSScreen.screens {
                let d = FloatingPanel(rect: s.frame, level: .floating, interactive: false)
                d.hasShadow = false
                let hole = s == screen ? CGRect(x: rect.minX - s.frame.minX, y: s.frame.maxY - rect.maxY, width: rect.width, height: rect.height) : .zero
                d.contentView = NSHostingView(rootView: DimView(hole: hole))
                dims.append(d)
            }
        }
        self.webcam = webcam
        if keystrokes { self.keystrokes = KeystrokeOverlay(in: rect) }
        if clicks { self.clicks = ClickHighlighter(screen: screen) }
    }

    func show() {
        dims.forEach { $0.orderFrontRegardless() }
        border?.orderFrontRegardless()
        if Prefs.bool(.recShowControls) { bar?.orderFrontRegardless() }
        // Studio records the camera to its own file: its bubble on screen can stay hidden.
        if !(studio && Prefs.bool(.recHideCameraPreview)) { webcam?.panel.orderFrontRegardless() }
    }

    /// Shows or hides the controls bar (built even when Settings hides it, so a shortcut can bring it back).
    func toggleControls() {
        guard let bar else { return }
        if bar.isVisible { bar.orderOut(nil) } else { bar.orderFrontRegardless() }
    }

    /// Hides everything. The camera session keeps running (for Studio Mode's camera file) until the caller stops it.
    func close() {
        dims.forEach { $0.orderOut(nil) }
        border?.orderOut(nil)
        bar?.orderOut(nil)
        webcam?.panel.orderOut(nil)
        keystrokes?.stop()
        clicks?.stop()
    }
}

private struct DimView: View {
    let hole: CGRect
    var body: some View {
        Canvas { ctx, size in
            var p = Path(CGRect(origin: .zero, size: size))
            p.addRect(hole)
            ctx.fill(p, with: .color(.black.opacity(0.45)), style: FillStyle(eoFill: true))
        }
    }
}

struct RecordingControls: View {
    @ObservedObject var model: RecordingHUD.Model

    var body: some View {
        HStack(spacing: 2) {
            Button { Recorder.shared.stop() } label: {
                RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 10, height: 10)
                    .frame(width: 26, height: 26).background(Color.red, in: Circle())
            }
            .buttonStyle(.plain).help("Stop recording")
            Text(Self.format(model.elapsed))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(model.paused ? .orange : .primary)
                .frame(minWidth: 50)
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(model.elapsed))
            Divider().frame(height: 16).padding(.horizontal, 2)
            if model.hasMic {
                button(model.micMuted ? "mic.slash.fill" : "mic.fill", model.micMuted ? "Unmute microphone" : "Mute microphone") { Recorder.shared.toggleMic() }
                    .foregroundStyle(model.micMuted ? .red : .primary)
            }
            button(model.paused ? "play.fill" : "pause.fill", model.paused ? "Resume" : "Pause") { Recorder.shared.togglePause() }
            button("flag", "Add marker") { Recorder.shared.addMarker() }
            button("arrow.counterclockwise", "Restart") { Recorder.shared.confirmRestart() }
            button("trash", "Delete recording") { Recorder.shared.confirmCancel() }
        }
        .padding(.leading, 5).padding(.trailing, 6).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .padding(4)
    }

    private func button(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help.loc)
    }

    static func format(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: Camera

/// Draggable camera preview (shape/size/mirror from settings). Click toggles full screen over the recorded area.
/// In normal recordings it's part of the video; in Studio Mode the camera is also written to its own file.
@MainActor
final class WebcamBubble {
    let panel: FloatingPanel
    nonisolated(unsafe) let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer
    /// Clips the preview to the bubble's shape: the camera's video ignores corner radii and `masksToBounds` (its own and
    /// its ancestors'), only a mask layer cuts it.
    private let clip = CALayer()
    private let maskShape = CAShapeLayer()
    private var area: CGRect
    private var fullscreen = false
    /// One serial queue per bubble, so a stopRunning can never overtake its startRunning (camera left on).
    private let queue = DispatchQueue(label: "daisyshot.webcam")
    let deviceID: String

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static func device(_ id: String) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: id) ?? AVCaptureDevice.default(for: .video)
    }

    init?(deviceID: String, area: CGRect) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let device = Self.device(deviceID), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        self.deviceID = deviceID
        session.sessionPreset = .high
        session.addInput(input)
        self.area = area
        panel = FloatingPanel(rect: .zero, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        panel.hasShadow = true
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        clip.masksToBounds = true
        clip.borderWidth = 2
        clip.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        clip.addSublayer(preview)
        preview.mask = maskShape
        let view = BubbleView(frame: .zero)
        view.layer = clip
        view.wantsLayer = true
        view.onClick = { [weak self] in self?.toggleFullscreen() }
        view.onMoved = { [weak self] in self?.savePosition() }
        panel.contentView = view
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = Prefs.bool(.recCameraMirror)
        }
        layout(animated: false)
        nonisolated(unsafe) let s = session
        queue.async { s.startRunning() }
    }

    /// Follows the recording area (setup overlay adjustments).
    func move(to area: CGRect) {
        self.area = area
        layout(animated: false)
    }

    private var bubbleSize: CGSize {
        let shape = CameraShape(rawValue: Prefs.string(.recCameraShape)) ?? .circle
        var s = shape.size((CameraSize(rawValue: Prefs.string(.recCameraSize)) ?? .medium).side)
        let fit = min(1, area.width * 0.6 / s.width, area.height * 0.6 / s.height)
        s.width = max(60, s.width * fit)
        s.height = max(60, s.height * fit)
        return s
    }

    private func layout(animated: Bool) {
        let shape = CameraShape(rawValue: Prefs.string(.recCameraShape)) ?? .circle
        let frame: CGRect
        if fullscreen {
            frame = area
        } else {
            let s = bubbleSize, m: CGFloat = 20
            let fx = Prefs.double(.recCameraX), fy = Prefs.double(.recCameraY)
            let x = area.minX + m + CGFloat(fx) * max(0, area.width - s.width - 2 * m)
            let y = area.maxY - m - s.height - CGFloat(fy) * max(0, area.height - s.height - 2 * m)
            frame = CGRect(x: x, y: y, width: s.width, height: s.height)
        }
        clip.cornerRadius = fullscreen ? 0 : shape.cornerRadius(frame.size)
        clip.borderWidth = fullscreen ? 0 : 2
        panel.setFrame(frame, display: true, animate: animated)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        preview.frame = CGRect(origin: .zero, size: frame.size)
        let r = clip.cornerRadius
        maskShape.path = CGPath(roundedRect: preview.bounds, cornerWidth: min(r, frame.width / 2), cornerHeight: min(r, frame.height / 2), transform: nil)
        CATransaction.commit()
    }

    func toggleFullscreen() {
        fullscreen.toggle()
        layout(animated: true)
    }

    private func savePosition() {
        guard !fullscreen else { return }
        let s = panel.frame.size, m: CGFloat = 20
        let fx = (panel.frame.minX - area.minX - m) / max(1, area.width - s.width - 2 * m)
        let fy = (area.maxY - m - s.height - panel.frame.minY) / max(1, area.height - s.height - 2 * m)
        Prefs.set(Double(min(1, max(0, fx))), .recCameraX)
        Prefs.set(Double(min(1, max(0, fy))), .recCameraY)
    }

    func stop() {
        panel.orderOut(nil)
        nonisolated(unsafe) let s = session
        queue.async { s.stopRunning() }
    }

    /// Drag to move, click (no drag) to toggle full screen.
    private final class BubbleView: NSView {
        var onClick: (() -> Void)?
        var onMoved: (() -> Void)?
        private var start: CGPoint?
        private var origin: CGPoint = .zero
        private var dragged = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with e: NSEvent) {
            start = NSEvent.mouseLocation
            origin = window?.frame.origin ?? .zero
            dragged = false
        }
        override func mouseDragged(with e: NSEvent) {
            guard let start else { return }
            let p = NSEvent.mouseLocation
            if hypot(p.x - start.x, p.y - start.y) > 3 { dragged = true }
            window?.setFrameOrigin(CGPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
        }
        override func mouseUp(with e: NSEvent) {
            if dragged { onMoved?() } else { onClick?() }
            start = nil
        }
    }
}

// MARK: Keystrokes

/// What to show for a key press. Plain typing is only shown with "Show all keys", so passwords don't end up in videos.
enum KeystrokeFormatter {
    static let special: [UInt16: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "␣", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    /// Single keys shown even without "all keys": they say what happened (navigate, delete, cancel) but reveal no text.
    static let standalone: Set<String> = ["⌫", "⌦", "⎋", "←", "→", "↓", "↑", "↖", "↘", "⇞", "⇟",
                                          "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"]

    /// Label for one key press, or nil if it must not be shown. `characters` is the typed text (layout-aware).
    static func label(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags, all: Bool) -> String? {
        let mods = flags.intersection([.command, .control, .option, .shift])
        let command = !mods.isDisjoint(with: [.command, .control])
            || (mods.contains(.option) && special[keyCode] != nil)   // ⌥+letter types a character
        if command {
            return Shortcut(keyCode: UInt32(keyCode), modifiers: mods.rawValue).display
        }
        if let s = special[keyCode], all || standalone.contains(s) { return (mods.contains(.shift) && keyCode != 49 ? "⇧" : "") + s }
        guard all else { return nil }
        guard let c = characters, !c.isEmpty, c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return c
    }

    /// Consecutive plain characters are joined ("Hello"); shortcuts and special keys start a new label.
    static func append(_ new: String, to current: String?, isText: Bool, currentIsText: Bool) -> String {
        guard isText, currentIsText, let current else { return new }
        return String((current + new).suffix(24))
    }

    static func selfTest() {
        assert(label(keyCode: 0, characters: "a", flags: [], all: false) == nil, "plain typing hidden by default")
        assert(label(keyCode: 0, characters: "A", flags: .shift, all: false) == nil)
        assert(label(keyCode: 0, characters: "å", flags: .option, all: false) == nil, "⌥-typed characters are text")
        assert(label(keyCode: 0, characters: "a", flags: [], all: true) == "a")
        assert(label(keyCode: 36, characters: "\r", flags: [], all: true) == "↩")
        assert(label(keyCode: 36, characters: "\r", flags: [], all: false) == nil)
        assert(label(keyCode: 123, characters: nil, flags: [], all: false) == "←", "navigation keys show without “all keys”")
        assert(label(keyCode: 48, characters: "\t", flags: .shift, all: true) == "⇧⇥")
        assert(label(keyCode: 0, characters: "a", flags: .command, all: false)?.hasPrefix("⌘") == true)
        assert(append("b", to: "a", isText: true, currentIsText: true) == "ab")
        assert(append("⌘S", to: "a", isText: false, currentIsText: true) == "⌘S")
        assert(append("c", to: "⌘S", isText: true, currentIsText: false) == "c")
    }
}

struct KeystrokeBadge: View {
    let text: String
    let size: CGFloat
    let light: Bool
    let blur: Bool

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
            .foregroundStyle(light ? Color.black : Color.white)
            .lineLimit(1)
            .padding(.horizontal, size * 0.4)
            .frame(height: size)
            .background {
                let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                if blur {
                    shape.fill(.regularMaterial).environment(\.colorScheme, light ? .light : .dark)
                } else {
                    shape.fill(light ? Color.white.opacity(0.92) : Color.black.opacity(0.78))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder((light ? Color.black : .white).opacity(0.1)))
            .fixedSize()
    }
}

/// Shows pressed keys inside the recorded area. Part of the recording.
@MainActor
final class KeystrokeOverlay {
    private let panel = FloatingPanel(rect: .zero, level: .screenSaver, interactive: false)
    private let rect: CGRect
    private var monitor: Any?
    private var hide: DispatchWorkItem?
    private var current: String?
    private var currentIsText = false
    private var lastKey = Date.distantPast
    private var lastLabel: String?
    private var repeats = 1
    private var generation = 0

    var windowNumber: Int { panel.windowNumber }

    init(in rect: CGRect) {
        self.rect = rect
        panel.hasShadow = false
        // Kept on screen (transparent) for the whole recording so the capture filter can include it by window ID.
        panel.alphaValue = 0
        panel.setFrame(CGRect(x: rect.midX, y: rect.midY, width: 1, height: 1), display: false)
        panel.orderFrontRegardless()
        let all = Prefs.bool(.recKeysAll)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let code = e.keyCode, chars = e.characters, flags = e.modifierFlags
            MainActor.assumeIsolated {
                guard let label = KeystrokeFormatter.label(keyCode: code, characters: chars, flags: flags, all: all) else { return }
                let isText = chars == label && KeystrokeFormatter.special[code] == nil
                self?.show(label, isText: isText)
            }
        }
    }

    private func show(_ label: String, isText: Bool) {
        let since = Date().timeIntervalSince(lastKey)
        if !isText, label == lastLabel, since < KeyBadge.repeatWindow {
            repeats += 1                                         // same shortcut again: "⌘Z ×3"
            current = "\(label) ×\(repeats)"
        } else {
            repeats = 1
            current = KeystrokeFormatter.append(label, to: since < 1.5 ? current : nil, isText: isText, currentIsText: currentIsText)
        }
        lastLabel = isText ? nil : label
        currentIsText = isText
        lastKey = Date()
        let size = CGFloat(Prefs.int(.recKeysSize))
        let host = NSHostingView(rootView: KeystrokeBadge(text: current ?? label, size: size, light: Prefs.string(.recKeysStyle) == "light", blur: Prefs.bool(.recKeysBlur)))
        let s = host.fittingSize
        panel.contentView = host
        let pos = KeystrokePosition(rawValue: Prefs.int(.recKeysPosition)) ?? .bottom
        let m: CGFloat = 24
        let x = rect.minX + m + pos.horizontal * (rect.width - s.width - 2 * m)
        let y = pos.isTop ? rect.maxY - m - s.height : rect.minY + m
        panel.setFrame(CGRect(x: x, y: y, width: s.width, height: s.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hide?.cancel()
        generation += 1
        let gen = generation
        let w = DispatchWorkItem { [weak self, panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { if self?.generation == gen { panel.alphaValue = 0 } }
            }
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hide?.cancel()
        panel.orderOut(nil)
    }
}
