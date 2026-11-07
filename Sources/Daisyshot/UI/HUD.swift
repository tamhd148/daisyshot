import AppKit
import SwiftUI

/// Borderless, non-activating floating panel used by toasts, HUDs, quick access and pins.
class FloatingPanel: NSPanel {
    init(rect: CGRect, level: NSWindow.Level = .floating, interactive: Bool = true) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = !interactive
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
    override var canBecomeKey: Bool { true }
}

@MainActor
enum Toast {
    private static var panel: FloatingPanel?
    private static var work: DispatchWorkItem?

    static func show(_ text: String, isError: Bool = false, seconds: Double = 2.2) {
        let text = text.loc
        panel?.orderOut(nil)
        let view = NSHostingView(rootView:
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .yellow : .green)
                Text(text).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: 420)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .environment(\.colorScheme, .dark)
        )
        let size = view.fittingSize
        let s = NSScreen.underMouse.visibleFrame
        let p = FloatingPanel(rect: CGRect(x: s.midX - size.width / 2, y: s.minY + 80, width: size.width, height: size.height), level: .statusBar, interactive: false)
        p.contentView = view
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p
        work?.cancel()
        let w = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}

/// Big centered 3-2-1 countdown (self-timer, recording start). Returns false if cancelled with Esc/click.
@MainActor
enum Countdown {
    static func run(seconds: Int, on screen: NSScreen = .underMouse, in rect: CGRect? = nil) async -> Bool {
        guard seconds > 0 else { return true }
        let model = CountdownModel(value: seconds)
        let host = NSHostingView(rootView: CountdownView(model: model))
        let size = CGSize(width: 160, height: 160)
        let center = rect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: screen.frame.midX, y: screen.frame.midY)
        let p = FloatingPanel(rect: CGRect(x: center.x - 80, y: center.y - 80, width: size.width, height: size.height), level: .screenSaver)
        p.contentView = host
        p.orderFrontRegardless()
        var cancelled = false
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in if e.keyCode == 53 { cancelled = true } }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { e in cancelled = true; return nil }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let local { NSEvent.removeMonitor(local) }
            p.orderOut(nil)
        }
        for v in stride(from: seconds, to: 0, by: -1) {
            model.value = v
            if Prefs.bool(.playSounds) { NSSound(named: "Tink")?.play() }
            try? await Task.sleep(for: .seconds(1))
            if cancelled { return false }
        }
        return true
    }
}

final class CountdownModel: ObservableObject {
    @Published var value: Int
    init(value: Int) { self.value = value }
}

struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    var body: some View {
        Text("\(model.value)")
            .font(.system(size: 80, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 140, height: 140)
            .background(.black.opacity(0.6), in: Circle())
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: model.value)
            .frame(width: 160, height: 160)
    }
}
