import AppKit
import ScreenCaptureKit

/// A rectangle on one display, in that display's points with a top-left origin (ScreenCaptureKit's convention).
struct CaptureRegion: Codable, Equatable {
    var displayID: CGDirectDisplayID
    var rect: CGRect
    /// Set when the area is exactly one window: recordings then show only that window (and Studio follows it).
    var windowID: CGWindowID?
}

/// A captured bitmap plus the backing scale it was taken at (2 on Retina).
struct Shot {
    var image: CGImage
    var scale: CGFloat
}

enum CaptureError: LocalizedError {
    case noDisplay, noWindow, permission
    var errorDescription: String? {
        let s: String
        switch self {
        case .noDisplay: s = "Display not found."
        case .noWindow: s = "Window not found."
        case .permission: s = "Daisyshot needs Screen Recording permission. Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch."
        }
        return s.loc
    }
}

enum CaptureService {
    static func content() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permission
        }
    }

    static func display(_ id: CGDirectDisplayID, in c: SCShareableContent) throws -> SCDisplay {
        guard let d = c.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noDisplay }
        return d
    }

    /// CONTRACT: our own windows that must never appear in captures (Quick Access cards, toasts, HUDs, editors…),
    /// i.e. every window of this process except pinned screenshots, desktop-icon covers and `keeping`.
    @MainActor
    static func ownWindowsToExclude(in c: SCShareableContent, keeping: [Int] = []) -> [SCWindow] {
        let pid = ProcessInfo.processInfo.processIdentifier
        let keep = Set(PinWindow.windowNumbers + DesktopIcons.shared.windowIDs + keeping)
        return c.windows.filter { $0.owningApplication?.processID == pid && !keep.contains(Int($0.windowID)) }
    }

    /// Whole-display image at native pixel resolution. Our own UI (see `ownWindowsToExclude`) is always left out,
    /// plus `excludingWindowNumbers`. Pass `content` when grabbing several displays in a row to skip re-querying.
    @MainActor
    static func displayShot(_ id: CGDirectDisplayID, excludingWindowNumbers: [Int] = [], showCursor: Bool = false,
                            content: SCShareableContent? = nil) async throws -> Shot {
        let c: SCShareableContent
        if let content { c = content } else { c = try await self.content() }
        let display = try display(id, in: c)
        let own = Set(ownWindowsToExclude(in: c).map(\.windowID))
        let excluded = c.windows.filter { own.contains($0.windowID) || excludingWindowNumbers.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(CGFloat(display.width) * scale)
        cfg.height = Int(CGFloat(display.height) * scale)
        cfg.showsCursor = showCursor
        cfg.captureResolution = .best
        cfg.colorSpaceName = colorSpaceName(for: id)
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return Shot(image: img, scale: scale)
    }

    /// sRGB when "Convert to sRGB profile" is on, otherwise Display P3 on wide-gamut displays (keeps colours exact).
    static func colorSpaceName(for id: CGDirectDisplayID) -> CFString {
        if Prefs.bool(.convertToSRGB) { return CGColorSpace.sRGB }
        return CGDisplayCopyColorSpace(id).isWideGamutRGB ? CGColorSpace.displayP3 : CGColorSpace.sRGB
    }

    @MainActor
    static func shot(of region: CaptureRegion, excludingWindowNumbers: [Int] = [], showCursor: Bool = false) async throws -> Shot {
        let full = try await displayShot(region.displayID, excludingWindowNumbers: excludingWindowNumbers, showCursor: showCursor)
        return crop(full, to: region.rect)
    }

    static func crop(_ shot: Shot, to rect: CGRect) -> Shot {
        let px = CGRect(x: rect.minX * shot.scale, y: rect.minY * shot.scale,
                        width: rect.width * shot.scale, height: rect.height * shot.scale).integral
        return Shot(image: shot.image.cropping(to: px) ?? shot.image, scale: shot.scale)
    }

    /// A single window, independent of what overlaps it. Transparent corners/shadow are preserved.
    static func windowShot(_ windowID: CGWindowID, shadow: Bool) async throws -> Shot {
        let c = try await content()
        guard let w = c.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.ignoreShadowsSingleWindow = !shadow
        cfg.shouldBeOpaque = false
        cfg.showsCursor = false
        cfg.captureResolution = .best
        cfg.colorSpaceName = Prefs.bool(.convertToSRGB) ? CGColorSpace.sRGB : CGColorSpace.displayP3
        cfg.width = Int(filter.contentRect.width * scale)
        cfg.height = Int(filter.contentRect.height * scale)
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return Shot(image: img, scale: scale)
    }

    /// A window's current frame in global CG coordinates (top-left origin), or nil once it's gone.
    static func windowFrame(_ id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }

    /// Resizes another app's window through Accessibility (needs that permission) and returns its new frame (CG
    /// global). Apps may clamp the size; the returned frame is what they settled on.
    static func resizeWindow(_ id: CGWindowID, to size: CGSize) async -> CGRect? {
        guard AXIsProcessTrusted(), let w = visibleWindows().first(where: { $0.id == id }) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(w.pid), kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return nil }
        func frame(_ e: AXUIElement) -> CGRect? {
            var p: CFTypeRef?, s: CFTypeRef?
            var origin = CGPoint.zero, size = CGSize.zero
            guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
                  AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: origin, size: size)
        }
        // The AX window whose frame matches the CG window (AX has no public window number).
        guard let ax = list.first(where: { frame($0).map { abs($0.minX - w.frame.minX) + abs($0.minY - w.frame.minY) + abs($0.width - w.frame.width) < 4 } ?? false })
        else { return nil }
        var target = size
        guard let v = AXValueCreate(.cgSize, &target), AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v) == .success else { return nil }
        try? await Task.sleep(for: .milliseconds(150))     // let the app lay out at its new size
        return windowFrame(id)
    }

    /// Normal app windows on screen, front to back, in global CG coordinates (top-left origin).
    static func visibleWindows() -> [(id: CGWindowID, frame: CGRect, owner: String, title: String, pid: pid_t)] {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int32) != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b),
                  frame.width > 20, frame.height > 20,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0
            else { return nil }
            return (id, frame, info[kCGWindowOwnerName as String] as? String ?? "", info[kCGWindowName as String] as? String ?? "",
                    info[kCGWindowOwnerPID as String] as? pid_t ?? 0)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func withID(_ id: CGDirectDisplayID) -> NSScreen? { screens.first { $0.displayID == id } }

    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }

    /// Converts a rect in this screen's AppKit coordinates (bottom-left, global) to display-local top-left points.
    func toDisplayRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    func fromDisplayRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX + frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Global CG (top-left of primary display) → global AppKit (bottom-left of primary display).
    static func fromCGGlobal(_ r: CGRect) -> CGRect {
        let h = screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}

extension Shot {
    /// Window screenshot centred on a canvas `padding` points larger on every side, over `background`
    /// (aspect-filled wallpaper) or transparent when nil.
    func composedWindow(padding: CGFloat, background: CGImage?) -> Shot {
        let pad = Int((max(0, padding) * scale).rounded())
        if pad == 0, background == nil { return self }
        let w = image.width + pad * 2, h = image.height + pad * 2
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        ctx.interpolationQuality = .high
        if let bg = background {
            let s = max(CGFloat(w) / CGFloat(bg.width), CGFloat(h) / CGFloat(bg.height))
            let bw = CGFloat(bg.width) * s, bh = CGFloat(bg.height) * s
            ctx.draw(bg, in: CGRect(x: (CGFloat(w) - bw) / 2, y: (CGFloat(h) - bh) / 2, width: bw, height: bh))
        }
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))
        return Shot(image: ctx.makeImage() ?? image, scale: scale)
    }
}
