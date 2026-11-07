import AppKit
import ApplicationServices
import SwiftUI

extension Prefs.Key {
    /// Auto-scroll speed: 0 slow, 1 normal, 2 fast.
    static let scrollAutoSpeed = Prefs.Key("scrollAutoSpeed", 1)
}

/// Scrolling capture: outlines the selected region, grabs it ~8×/s while the user (or auto-scroll) scrolls,
/// and stitches the frames into one tall (or wide) image (see `Stitch`). The direction is detected from the first
/// movement and then locked. Done (↩) delivers it, Cancel (⎋) discards it.
@MainActor
enum ScrollCapture {
    private static var session: ScrollSession?

    static var isActive: Bool { session != nil }

    static func start(region: CaptureRegion) { start(region: region, begin: false, autoscroll: false) }

    /// URL API variant: `begin` starts capturing immediately, `autoscroll` also scrolls down automatically.
    /// `onEnd` runs once the session is over (Done or Cancel), or right away when another session is already running.
    static func start(region: CaptureRegion, begin: Bool, autoscroll: Bool, onEnd: (() -> Void)? = nil) {
        guard session == nil else { onEnd?(); return }
        let s = ScrollSession(region: region) { session = nil; onEnd?() }
        session = s
        if begin || autoscroll { s.begin(autoscroll: autoscroll) }
    }

    /// Options for the next scrolling capture command (URL API). Read and cleared by that command as soon as it's
    /// issued (`takePendingOptions`), so they never leak into a later capture when it's cancelled or ignored.
    static var pendingOptions: (begin: Bool, autoscroll: Bool)?

    static func takePendingOptions() -> (begin: Bool, autoscroll: Bool) {
        defer { pendingOptions = nil }
        return pendingOptions ?? (false, false)
    }

    /// "Start/Stop Capturing" shortcut: selects an area, then starts capturing, then finishes.
    static func toggle() {
        if let session { session.shortcutPressed() } else { CaptureController.shared.scrollingCapture() }
    }
}

enum ScrollAxis { case vertical, horizontal }

@MainActor
final class ScrollModel: ObservableObject {
    @Published var running = false
    @Published var auto: ScrollAxis?
    @Published var axis: ScrollAxis?
    @Published var size = CGSize.zero
    @Published var preview: CGImage?
    @Published var status = "Press Start, then scroll the content"
    @Published var warning = false
    @Published var speed = Prefs.int(.scrollAutoSpeed) { didSet { Prefs.set(speed, .scrollAutoSpeed) } }
}

@MainActor
private final class ScrollSession {
    private let region: CaptureRegion
    private let model = ScrollModel()
    private let vertical: Stitch
    private let horizontal: Stitch
    private let outline: FloatingPanel
    private var controls: FloatingPanel!
    private var monitors: [Any] = []
    private var loop: Task<Void, Never>?
    private var scale: CGFloat = 1
    private var idleFrames = 0
    private var ended = false
    private let onEnd: () -> Void

    init(region: CaptureRegion, onEnd: @escaping () -> Void) {
        self.region = region
        self.onEnd = onEnd
        let screen = NSScreen.withID(region.displayID) ?? .underMouse
        // Leave the overlay scrollbar (right edge, or bottom edge when horizontal) out of matching.
        let bar = Int(16 * screen.backingScaleFactor)
        vertical = Stitch(maxHeight: 30_000, ignoreRight: bar)
        horizontal = Stitch(maxHeight: 30_000, ignoreRight: bar)
        let frame = screen.fromDisplayRect(region.rect)

        outline = FloatingPanel(rect: frame.insetBy(dx: -3, dy: -3), level: .statusBar, interactive: false)
        outline.hasShadow = false
        let border = NSView()
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.controlAccentColor.cgColor
        border.layer?.borderWidth = 2
        border.layer?.cornerRadius = 3
        outline.contentView = border
        outline.orderFrontRegardless()

        let host = NSHostingView(rootView: ScrollControls(
            model: model,
            toggleRunning: { [weak self] in self?.setRunning(!(self?.model.running ?? true)) },
            toggleAuto: { [weak self] axis in self?.setAuto(self?.model.auto == axis ? nil : axis) },
            done: { [weak self] in self?.finish(deliver: true) },
            cancel: { [weak self] in self?.finish(deliver: false) }))
        let size = host.fittingSize
        controls = FloatingPanel(rect: Self.place(size, beside: frame, in: screen.visibleFrame), level: .statusBar)
        controls.contentView = host
        controls.alphaValue = 0
        controls.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; controls.animator().alphaValue = 1 }

        let keys: (NSEvent) -> Bool = { [weak self] e in
            switch e.keyCode {
            case 36, 76: self?.finish(deliver: true); return true // Return, keypad Enter
            case 53: self?.finish(deliver: false); return true // Esc
            default: return false
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { e in MainActor.assumeIsolated { _ = keys(e) } }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in MainActor.assumeIsolated { keys(e) } ? nil : e }) { monitors.append(m) }
    }

    /// Just outside the region: right, else left, else inside its bottom-right corner.
    private static func place(_ size: CGSize, beside r: CGRect, in v: CGRect) -> CGRect {
        let y = min(max(r.maxY - size.height, v.minY), v.maxY - size.height)
        if r.maxX + 12 + size.width <= v.maxX { return CGRect(origin: CGPoint(x: r.maxX + 12, y: y), size: size) }
        if r.minX - 12 - size.width >= v.minX { return CGRect(origin: CGPoint(x: r.minX - 12 - size.width, y: y), size: size) }
        return CGRect(origin: CGPoint(x: r.maxX - size.width - 8, y: max(r.minY, v.minY) + 8), size: size)
    }

    private var ownWindows: [Int] { [outline.windowNumber, controls.windowNumber] }

    private var stitched: Stitch? {
        switch model.axis {
        case .vertical: return vertical
        case .horizontal: return horizontal
        case nil: return vertical.height > 0 ? vertical : nil
        }
    }

    func begin(autoscroll: Bool) {
        setRunning(true)
        if autoscroll { setAuto(.vertical) }
    }

    func shortcutPressed() {
        if !model.running, (stitched?.height ?? 0) == 0 { setRunning(true) } else { finish(deliver: true) }
    }

    private func setRunning(_ on: Bool) {
        model.running = on
        if !on { model.auto = nil }
        model.status = on ? "Scroll the content slowly" : "Paused"
        if on, loop == nil { loop = Task { await self.run() } }
    }

    private func setAuto(_ axis: ScrollAxis?) {
        if let axis {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            guard AXIsProcessTrustedWithOptions(opts) else {
                Toast.show("Auto-scroll needs Accessibility access. Enable Daisyshot in System Settings › Privacy & Security › Accessibility.", isError: true, seconds: 4)
                return
            }
            if let locked = model.axis, locked != axis {
                Toast.show("The direction can't change during a capture.", isError: true)
                return
            }
            idleFrames = 0
            CGWarpMouseCursorPosition(center) // scroll events go to the window under the pointer
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        model.auto = axis
        if axis != nil {
            setRunning(true)
            model.status = "Auto-scrolling…"
        }
    }

    /// Region center in global CG coordinates.
    private var center: CGPoint {
        let b = CGDisplayBounds(region.displayID)
        return CGPoint(x: b.minX + region.rect.midX, y: b.minY + region.rect.midY)
    }

    private func run() async {
        while !Task.isCancelled {
            let started = ContinuousClock.now
            if model.running {
                do { try await grabFrame() } catch {
                    Toast.show(error.localizedDescription, isError: true)
                    finish(deliver: false)
                    return
                }
                if let axis = model.auto { scroll(axis) }
            }
            let left = .milliseconds(120) - (ContinuousClock.now - started)
            try? await Task.sleep(for: max(left, .milliseconds(10)))
        }
    }

    private func grabFrame() async throws {
        let shot = try await CaptureService.shot(of: region, excludingWindowNumbers: ownWindows)
        guard !Task.isCancelled else { return }
        scale = shot.scale
        let (vertical, horizontal) = (vertical, horizontal)
        let locked = model.axis ?? model.auto
        let (step, axis, thumb) = await Task.detached(priority: .userInitiated) { () -> (Stitch.Step, ScrollAxis?, CGImage?) in
            guard let buf = PixelBuffer(shot.image) else { return (.noMatch, nil, nil) }
            var step: Stitch.Step
            var axis = locked
            switch locked {
            case .vertical: step = vertical.add(buf)
            case .horizontal: step = horizontal.add(buf.transposed())
            case nil:
                if vertical.height == 0 {
                    step = vertical.add(buf)
                    _ = horizontal.add(buf.transposed())
                } else {
                    step = vertical.add(buf)
                    if case .appended = step { axis = .vertical } else {
                        let h = horizontal.add(buf.transposed())
                        if case .appended = h { step = h; axis = .horizontal }
                    }
                }
            }
            guard case .appended = step else { return (step, axis, nil) }
            let thumb: CGImage?
            if axis == .horizontal {
                thumb = horizontal.thumbnail(maxW: 400, maxH: 240).flatMap { PixelBuffer($0) }?.transposed().cgImage
            } else {
                thumb = vertical.thumbnail(maxW: 240, maxH: 400)
            }
            return (step, axis, thumb)
        }.value
        guard !Task.isCancelled else { return }
        if model.axis == nil, let axis { model.axis = axis }
        if let thumb { model.preview = thumb }
        if let s = stitched {
            model.size = model.axis == .horizontal ? CGSize(width: s.height, height: s.width) : CGSize(width: s.width, height: s.height)
        }
        model.warning = false
        switch step {
        case .appended:
            idleFrames = 0
            let large = max(model.size.width, model.size.height) > 20_000
            model.warning = large
            model.status = large ? "⚠️ Screenshot is very large" : model.auto != nil ? "Auto-scrolling…" : "Capturing…"
        case .noMatch:
            model.status = "Please slow down…"
            model.warning = true
        case .scrolledUp:
            model.status = model.axis == .horizontal ? "Scroll right to continue" : "Scroll down to continue"
        case .full:
            setRunning(false)
            model.status = "Maximum size reached"
            model.warning = true
        case .unchanged:
            idleFrames += 1
            if model.auto != nil, idleFrames >= 8 { // ~1 s without movement: the end of the content
                model.auto = nil
                model.status = "Reached the end"
            }
        }
    }

    private func scroll(_ axis: ScrollAxis) {
        let speed = min(2, max(0, model.speed))
        let viewport = axis == .vertical ? region.rect.height : region.rect.width
        let step = Int32(min([60.0, 150.0, 300.0][speed], max(20, viewport * [0.15, 0.3, 0.5][speed])))
        let e = axis == .vertical
            ? CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0)
            : CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -step, wheel3: 0)
        guard let e else { return }
        e.location = center
        e.post(tap: .cghidEventTap)
    }

    private func finish(deliver: Bool) {
        guard !ended else { return }
        ended = true
        let loop = loop
        loop?.cancel()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        outline.orderOut(nil)
        controls.orderOut(nil)
        guard deliver else { onEnd(); return }
        Task { @MainActor in
            defer { onEnd() } // after the final grab, so temporarily hidden desktop icons stay hidden for it
            await loop?.value // the stitcher is not shared with an in-flight frame
            guard let s = stitched, s.height > 0 else { // Done before Start: a plain region screenshot
                do { CaptureController.shared.process(try await CaptureService.shot(of: region), action: .screenshot, shift: false) } catch {
                    Toast.show(error.localizedDescription, isError: true)
                }
                return
            }
            let horizontal = model.axis == .horizontal
            guard let image = await Task.detached(operation: { horizontal ? s.buffer().transposed().cgImage : s.image() }).value else { return }
            CaptureController.shared.process(Shot(image: image, scale: scale), action: .screenshot, shift: false)
        }
    }
}

private struct ScrollControls: View {
    @ObservedObject var model: ScrollModel
    let toggleRunning: () -> Void
    let toggleAuto: (ScrollAxis) -> Void
    let done: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: model.axis == .horizontal ? "arrow.left.and.right" : model.axis == .vertical ? "arrow.up.and.down" : "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                Text("Scrolling Capture").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    .help("Only scrollable content should be selected — leave out fixed headers and scroll bars. You can capture vertically or horizontally, but the direction can't change during a capture. Return: Done · Esc: Cancel")
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.3))
                if let img = model.preview {
                    Image(decorative: img, scale: 2).resizable().scaledToFit().padding(4)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "scroll").font(.system(size: 26))
                        Text("Preview").font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 148, height: 196)
            .animation(.easeOut(duration: 0.2), value: model.preview == nil)
            Text(model.size == .zero ? "—" : "\(Int(model.size.width)) × \(Int(model.size.height)) px")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text(model.status.loc)
                .font(.system(size: 11, weight: model.warning ? .semibold : .regular))
                .foregroundStyle(model.warning ? Color.orange : Color.secondary)
                .multilineTextAlignment(.center).frame(width: 148).fixedSize(horizontal: false, vertical: true)
                .animation(.easeOut(duration: 0.15), value: model.status)
            Button(action: toggleRunning) {
                Label(model.running ? "Pause".loc : "Start".loc, systemImage: model.running ? "pause.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.running ? .gray : .accentColor)
            HStack(spacing: 4) {
                autoButton(.vertical, symbol: "arrow.down.to.line", help: "Auto-scroll down")
                autoButton(.horizontal, symbol: "arrow.right.to.line", help: "Auto-scroll right")
                Menu {
                    Picker("Auto-scroll speed", selection: $model.speed) {
                        Text("Slow").tag(0); Text("Normal").tag(1); Text("Fast").tag(2)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "speedometer")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Auto-scroll speed")
            }
            Divider()
            HStack(spacing: 6) {
                Button(action: cancel) { Text("Cancel").frame(maxWidth: .infinity) }.help("Esc")
                Button(action: done) { Text("Done").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).help("Return")
            }
        }
        .controlSize(.regular)
        .padding(12)
        .frame(width: 172)
        .hudBox(radius: 14)
        .padding(10)
        .environment(\.colorScheme, .dark)
    }

    private func autoButton(_ axis: ScrollAxis, symbol: String, help: String) -> some View {
        Toggle(isOn: Binding(get: { model.auto == axis }, set: { _ in toggleAuto(axis) })) {
            Image(systemName: symbol).frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
        .disabled(model.axis != nil && model.axis != axis)
        .help(help.loc)
    }
}
