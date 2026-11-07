import AppKit
import ScreenCaptureKit

extension Prefs.Key {
    /// Wallpaper source: "wallpaper" (desktop picture), "custom" (image copied into the support folder) or "color".
    /// Reuses the original `desktopCoverStyle` key so existing choices carry over.
    static let wallpaperSource = Prefs.Key.desktopCoverStyle
    static let wallpaperColor = Prefs.Key.desktopCoverColor
    static let customWallpaperFileName = Prefs.Key("customWallpaperFileName", "")
    static let wallpaperUpdateOnSpaceChange = Prefs.Key("wallpaperUpdateOnSpaceChange", true)
}

/// Contract: the wallpaper chosen in Settings › Wallpaper (desktop picture, custom image or plain color),
/// rendered for a whole screen exactly like the Desktop draws it (fill / fit / stretch / center + fill color).
/// Used to hide desktop icons and as the background behind window screenshots.
@MainActor
enum WallpaperProvider {
    /// Posted when the wallpaper may look different (settings, Space or display change). Listeners re-query `image(for:)`.
    static let didChange = Notification.Name("WallpaperProvider.didChange")

    private static var cache: [CGDirectDisplayID: NSImage] = [:]
    /// Desktop pictures captured from the Dock's wallpaper window, for wallpapers without a readable file
    /// (folders/shuffle, Aerials, dynamic system wallpapers on some versions).
    private static var captured: [CGDirectDisplayID: CGImage] = [:]
    private static var observers: [NSObjectProtocol] = []

    /// Screen-sized wallpaper image (points = `screen.frame.size`, pixels at the screen's backing scale).
    static func image(for screen: NSScreen) -> NSImage? {
        startObserving()
        if let img = cache[screen.displayID], img.size == screen.frame.size { return img }
        let img = render(for: screen)
        cache[screen.displayID] = img
        return img
    }

    /// `image(for:)` without blocking the main thread when it isn't rendered yet (Settings previews).
    static func load(for screen: NSScreen) async -> NSImage? {
        startObserving()
        if let img = cache[screen.displayID], img.size == screen.frame.size { return img }
        let gen = generation, job = plan(for: screen)
        let img = await Task.detached(priority: .userInitiated) { compose(job) }.value
        if gen == generation { cache[screen.displayID] = img }
        return img
    }

    /// Forget cached renders (and captured desktop pictures) and tell listeners. When the wallpaper is in use (cached),
    /// the new one is rendered off the main thread first, so listeners re-querying on `didChange` don't block (a large
    /// wallpaper takes ~170 ms to decode and scale; this runs on every Space switch).
    static func invalidate(recapture: Bool = true) {
        let inUse = Set(cache.keys)
        cache.removeAll()
        if recapture { captured.removeAll() }
        generation += 1
        guard !inUse.isEmpty else { NotificationCenter.default.post(name: didChange, object: nil); return }
        let gen = generation
        let jobs = NSScreen.screens.filter { inUse.contains($0.displayID) }.map { ($0.displayID, plan(for: $0)) }
        Task {
            for (id, job) in jobs {
                let img = await Task.detached(priority: .userInitiated) { compose(job) }.value
                guard gen == generation else { return }
                if cache[id] == nil { cache[id] = img }
            }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    private static var generation = 0

    static var customWallpaperURL: URL? {
        let name = Prefs.string(.customWallpaperFileName)
        return name.isEmpty ? nil : Prefs.supportFolder.appendingPathComponent(name)
    }

    /// Copies a user-chosen image into the support folder (so it survives the original being moved) and selects it.
    static func setCustomWallpaper(from src: URL) throws {
        guard NSImage(contentsOf: src) != nil else { throw CocoaError(.fileReadCorruptFile) }
        if let old = customWallpaperURL { try? FileManager.default.removeItem(at: old) }
        let name = "Wallpaper-\(UUID().uuidString.prefix(8)).\(src.pathExtension.isEmpty ? "png" : src.pathExtension)"
        try FileManager.default.copyItem(at: src, to: Prefs.supportFolder.appendingPathComponent(name))
        Prefs.set(name, .customWallpaperFileName)
        Prefs.set("custom", .wallpaperSource)
        invalidate()
    }

    @MainActor
    static func chooseCustomWallpaper() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "Choose a wallpaper image".loc
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        do { try setCustomWallpaper(from: url) } catch { Toast.show("Couldn't use this image: %@".loc(error.localizedDescription), isError: true) }
    }

    // MARK: Rendering

    private static func render(for screen: NSScreen) -> NSImage? { compose(plan(for: screen)) }

    /// What to draw for a screen. Cheap (settings, file header); the decoding happens in `compose`, which is thread-safe.
    private struct Plan: @unchecked Sendable {
        var size: CGSize, scale: CGFloat, fill: NSColor, image: CGImage?, scaling: NSImageScaling, clip: Bool
    }

    private static func plan(for screen: NSScreen) -> Plan {
        let size = screen.frame.size, scale = screen.backingScaleFactor
        let color = NSColor(hex: Prefs.string(.wallpaperColor))
        switch Prefs.string(.wallpaperSource) {
        case "color":
            return Plan(size: size, scale: scale, fill: color, image: nil, scaling: .scaleNone, clip: true)
        case "custom":
            if let url = customWallpaperURL, let src = cgImage(at: url) {
                return Plan(size: size, scale: scale, fill: color, image: src, scaling: .scaleProportionallyUpOrDown, clip: true)
            }
            fallthrough
        default:
            let ws = NSWorkspace.shared
            let opts = ws.desktopImageOptions(for: screen) ?? [:]
            let fill = opts[.fillColor] as? NSColor ?? .black
            let scaling = (opts[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
            let clip = (opts[.allowClipping] as? NSNumber)?.boolValue ?? true
            if let url = ws.desktopImageURL(for: screen), let src = cgImage(at: url) {
                return Plan(size: size, scale: scale, fill: fill, image: src, scaling: scaling, clip: clip)
            }
            if let cap = captured[screen.displayID] {
                return Plan(size: size, scale: scale, fill: fill, image: cap, scaling: .scaleAxesIndependently, clip: true)
            }
            captureDesktopPicture(screen)
            return Plan(size: size, scale: scale, fill: fill, image: nil, scaling: .scaleNone, clip: true)
        }
    }

    nonisolated private static func compose(_ p: Plan) -> NSImage? {
        compose(size: p.size, scale: p.scale, fill: p.fill, image: p.image, scaling: p.scaling, clip: p.clip)
    }

    /// First frame of an image file (HEIC dynamic wallpapers included); nil for folders/videos. Decoded lazily (when drawn).
    private static func cgImage(at url: URL) -> CGImage? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    nonisolated private static func compose(size: CGSize, scale: CGFloat, fill: NSColor, image: CGImage?, scaling: NSImageScaling, clip: Bool) -> NSImage? {
        let pw = max(1, Int(size.width * scale)), ph = max(1, Int(size.height * scale))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.setFillColor(fill.usingColorSpace(.sRGB)?.cgColor ?? fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        if let image {
            ctx.interpolationQuality = .high
            let r = drawRect(image: CGSize(width: image.width, height: image.height), in: CGSize(width: pw, height: ph), scaling: scaling, clip: clip)
            ctx.draw(image, in: r)
        }
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    /// Where the Desktop draws a picture of `image` pixels inside `canvas`.
    /// Proportional + clipping = Fill Screen, proportional without clipping = Fit to Screen,
    /// axes independently = Stretch, none = Center (image drawn at 1 pixel per pixel).
    nonisolated static func drawRect(image: CGSize, in canvas: CGSize, scaling: NSImageScaling, clip: Bool) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let s: CGFloat
        switch scaling {
        case .scaleAxesIndependently: return CGRect(origin: .zero, size: canvas)
        case .scaleNone: s = 1
        case .scaleProportionallyDown: s = min(1, canvas.width / image.width, canvas.height / image.height)
        default:
            let sx = canvas.width / image.width, sy = canvas.height / image.height
            s = clip ? max(sx, sy) : min(sx, sy)
        }
        let w = image.width * s, h = image.height * s
        return CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
    }

    // MARK: Desktop picture capture (fallback)

    private static var capturing: Set<CGDirectDisplayID> = []

    /// Grabs the Dock's "Wallpaper-" window for the screen (only the wallpaper — no icons, no windows).
    /// Needs Screen Recording permission, which the app asks for anyway; silently gives up otherwise.
    private static func captureDesktopPicture(_ screen: NSScreen) {
        guard CGPreflightScreenCaptureAccess() else { return }
        let id = screen.displayID, frame = screen.frame, scale = screen.backingScaleFactor
        guard !capturing.contains(id) else { return }
        capturing.insert(id)
        Task {
            defer { capturing.remove(id) }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == id }) else { return }
            let walls = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.apple.dock" && ($0.title ?? "").hasPrefix("Wallpaper")
                    && $0.windowLayer == Int(CGWindowLevelForKey(.desktopWindow)) && NSScreen.fromCGGlobal($0.frame).intersects(frame)
            }
            guard !walls.isEmpty else { return }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(frame.width * scale)
            cfg.height = Int(frame.height * scale)
            cfg.showsCursor = false
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: walls), configuration: cfg) else { return }
            captured[id] = img
            invalidate(recapture: false)
        }
    }

    // MARK: Change tracking

    private static func startObserving() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default, wnc = NSWorkspace.shared.notificationCenter
        observers = [
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { invalidate() }
            },
            wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if Prefs.bool(.wallpaperUpdateOnSpaceChange) { invalidate() } }
            },
            // Posted by System Settings when the desktop picture changes.
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.desktop"), object: "BackgroundChanged", queue: .main) { _ in
                MainActor.assumeIsolated { invalidate() }
            },
        ]
    }

    static func selfTest() {
        let img = CGSize(width: 200, height: 100), canvas = CGSize(width: 100, height: 100)
        assert(drawRect(image: img, in: canvas, scaling: .scaleProportionallyUpOrDown, clip: true) == CGRect(x: -50, y: 0, width: 200, height: 100))
        assert(drawRect(image: img, in: canvas, scaling: .scaleProportionallyUpOrDown, clip: false) == CGRect(x: 0, y: 25, width: 100, height: 50))
        assert(drawRect(image: img, in: canvas, scaling: .scaleAxesIndependently, clip: true) == CGRect(origin: .zero, size: canvas))
        assert(drawRect(image: CGSize(width: 50, height: 50), in: canvas, scaling: .scaleNone, clip: true) == CGRect(x: 25, y: 25, width: 50, height: 50))
    }
}
