import AppKit
import SwiftUI

/// Self-timer countdown: outlines the area (if any) and shows a ring countdown with a Cancel button.
/// Returns false when cancelled (Esc or the button). Its windows are gone by the time it returns.
@MainActor
enum SelfTimerOverlay {
    static func run(seconds: Int, on screen: NSScreen, highlight rect: CGRect?) async -> Bool {
        guard seconds > 0 else { return true }
        let model = TimerModel(total: seconds)
        var panels: [NSPanel] = []

        if let rect {
            let outline = FloatingPanel(rect: rect.insetBy(dx: -2, dy: -2), level: .screenSaver, interactive: false)
            outline.hasShadow = false
            let border = NSView()
            border.wantsLayer = true
            border.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
            border.layer?.borderWidth = 2
            border.layer?.cornerRadius = 2
            outline.contentView = border
            outline.orderFrontRegardless()
            panels.append(outline)
        }

        let host = NSHostingView(rootView: TimerView(model: model))
        let size = host.fittingSize
        let area = rect ?? screen.frame
        let p = FloatingPanel(rect: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height),
                              level: .screenSaver)
        p.hasShadow = false
        p.contentView = host
        p.orderFrontRegardless()
        panels.append(p)

        let monitors: [Any?] = [
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in if e.keyCode == 53 { MainActor.assumeIsolated { model.cancelled = true } } },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                guard e.keyCode == 53 else { return e }
                MainActor.assumeIsolated { model.cancelled = true }
                return nil
            },
        ]
        defer {
            monitors.compactMap { $0 }.forEach(NSEvent.removeMonitor)
            panels.forEach { $0.orderOut(nil) }
        }

        model.start()
        for v in stride(from: seconds, to: 0, by: -1) {
            model.remaining = v
            Sounds.countdown()
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if model.cancelled { return false }
            }
        }
        panels.forEach { $0.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(80)) // let the window server drop the panels before capturing
        return true
    }
}

@MainActor
private final class TimerModel: ObservableObject {
    let total: Int
    @Published var remaining: Int
    @Published var progress: CGFloat = 0
    var cancelled = false

    init(total: Int) {
        self.total = total
        remaining = total
    }

    func start() {
        withAnimation(.linear(duration: Double(total))) { progress = 1 }
    }
}

private struct TimerView: View {
    @ObservedObject var model: TimerModel

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 6)
                Circle().trim(from: model.progress, to: 1)
                    .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(model.remaining)")
                    .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: model.remaining)
            }
            .frame(width: 112, height: 112)
            Button("Cancel") { model.cancelled = true }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.15)))
                .help("Esc")
        }
        .foregroundStyle(.white)
        .padding(20)
        .hudBox(radius: 24)
        .padding(12)
        .environment(\.colorScheme, .dark)
    }
}
