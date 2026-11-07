import AppKit
import QuartzCore

/// Draws click highlights as layers. Used full-screen while recording (click-through, captured into the video)
/// and by the settings preview, so both always look the same.
final class ClickRippleView: NSView {
    struct Style {
        var diameter: CGFloat
        var color: NSColor
        var filled: Bool
        var animate: Bool

        static var current: Style {
            Style(diameter: CGFloat(max(10, Prefs.int(.recClickSize))),
                  color: (HighlightColor(rawValue: Prefs.string(.recClickColor)) ?? .accent).nsColor,
                  filled: Prefs.string(.recClickStyle) != "outline",
                  animate: Prefs.bool(.recClickAnimate))
        }
    }

    var style = Style.current
    private var held: CAShapeLayer?
    private var pressedAt = Date()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func press(at p: CGPoint, secondary: Bool = false) {
        release()
        let d = style.diameter
        let l = CAShapeLayer()
        l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        l.position = p
        l.path = CGPath(ellipseIn: l.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        let c = style.color.usingColorSpace(.sRGB) ?? style.color
        if style.filled {
            l.fillColor = c.withAlphaComponent(secondary ? 0.3 : 0.45).cgColor
            l.strokeColor = c.withAlphaComponent(0.85).cgColor
            l.lineWidth = 1.5
        } else {
            l.fillColor = nil
            l.strokeColor = c.withAlphaComponent(0.95).cgColor
            l.lineWidth = max(3, d / 12)
            if secondary { l.lineDashPattern = [6, 4] }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.addSublayer(l)
        CATransaction.commit()
        if style.animate {
            let a = CASpringAnimation(keyPath: "transform.scale")
            a.fromValue = 0.4
            a.toValue = 1
            a.damping = 14
            a.initialVelocity = 8
            a.duration = a.settlingDuration
            l.add(a, forKey: "in")
        }
        held = l
        pressedAt = Date()
    }

    func move(to p: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        held?.position = p
        CATransaction.commit()
    }

    /// Fades the highlight out. Quick clicks stay visible at least ~0.2s so they show up in a 30 fps video.
    func release() {
        guard let l = held else { return }
        held = nil
        let linger = max(0, 0.2 - Date().timeIntervalSince(pressedAt))
        if style.animate {
            DispatchQueue.main.asyncAfter(deadline: .now() + linger) {
                CATransaction.begin()
                CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.toValue = 1.35
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.toValue = 0
                let g = CAAnimationGroup()
                g.animations = [scale, fade]
                g.duration = 0.32
                g.timingFunction = CAMediaTimingFunction(name: .easeOut)
                g.fillMode = .forwards
                g.isRemovedOnCompletion = false
                l.add(g, forKey: "out")
                CATransaction.commit()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + linger) { l.removeFromSuperlayer() }
        }
    }
}

/// Click-through overlay on the recorded display that shows our own click highlights.
@MainActor
final class ClickHighlighter {
    private let panel: FloatingPanel
    private let view: ClickRippleView
    private let screen: NSScreen
    private var monitors: [Any] = []

    var windowNumber: Int { panel.windowNumber }

    init(screen: NSScreen) {
        self.screen = screen
        panel = FloatingPanel(rect: screen.frame, level: .screenSaver, interactive: false)
        panel.hasShadow = false
        view = ClickRippleView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = view
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged]
        let handle: (NSEvent) -> Void = { [weak self] e in
            let type = e.type
            MainActor.assumeIsolated { self?.handle(type) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handle) { monitors.append(g) }
        // Clicks on our own windows (camera bubble, controls) don't reach global monitors.
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { handle($0); return $0 }) { monitors.append(l) }
        panel.orderFrontRegardless()
    }

    private func handle(_ type: NSEvent.EventType) {
        let g = NSEvent.mouseLocation
        let p = CGPoint(x: g.x - screen.frame.minX, y: g.y - screen.frame.minY)
        switch type {
        case .leftMouseDown: view.press(at: p)
        case .rightMouseDown: view.press(at: p, secondary: true)
        case .leftMouseDragged, .rightMouseDragged: view.move(to: p)
        default: view.release()
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
    }
}
