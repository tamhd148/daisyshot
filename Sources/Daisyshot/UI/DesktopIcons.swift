import AppKit

/// Hides desktop icons by covering them with a window per display that shows the wallpaper from
/// `WallpaperProvider` (drawn exactly like the Desktop), sitting just above the icon layer — Finder's own setting is left untouched.
/// Follows display changes, Space switches and wallpaper setting changes.
@MainActor
final class DesktopIcons {
    static let shared = DesktopIcons()
    private var covers: [CGDirectDisplayID: NSWindow] = [:]
    private var observers: [NSObjectProtocol] = []

    var isHidden: Bool { !covers.isEmpty }

    func toggle() { isHidden ? show() : hide() }

    /// CONTRACT: `persist: false` for temporary hides (while capturing/recording) so a crash or quit
    /// doesn't leave icons hidden on next launch.
    func hide(persist: Bool = true) {
        guard covers.isEmpty else { return }
        rebuild()
        if persist { Prefs.set(true, .desktopIconsHidden) }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DesktopIcons.shared.rebuild() }
            },
            nc.addObserver(forName: WallpaperProvider.didChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DesktopIcons.shared.refreshImages() }
            },
        ]
    }

    func show() {
        covers.values.forEach { $0.orderOut(nil) }
        covers.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        Prefs.set(false, .desktopIconsHidden)
    }

    var windowIDs: [Int] { covers.values.map(\.windowNumber) }

    /// One cover per connected display; stale ones (unplugged displays) are dropped, moved/resized ones re-framed.
    private func rebuild() {
        let screens = NSScreen.screens
        for (id, w) in covers where !screens.contains(where: { $0.displayID == id }) {
            w.orderOut(nil)
            covers[id] = nil
        }
        for screen in screens {
            let w = covers[screen.displayID] ?? makeCover()
            covers[screen.displayID] = w
            w.setFrame(screen.frame, display: false)
            w.contentView?.layer?.contents = WallpaperProvider.image(for: screen)
            w.orderFront(nil)
        }
    }

    private func refreshImages() {
        for screen in NSScreen.screens {
            guard let layer = covers[screen.displayID]?.contentView?.layer else { continue }
            let t = CATransition()
            t.duration = 0.25
            layer.add(t, forKey: "contents")
            layer.contents = WallpaperProvider.image(for: screen)
        }
    }

    private func makeCover() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.hasShadow = false
        w.animationBehavior = .none
        let v = NSView()
        v.wantsLayer = true
        v.layer?.contentsGravity = .resize   // provider images are already screen-sized and laid out like the Desktop
        w.contentView = v
        return w
    }
}
