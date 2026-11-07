import AppKit
import AVFoundation
import SwiftUI

enum CaptureItem {
    case image(Shot, fileURL: URL, saved: Bool)
    case video(URL, saved: Bool)
}

extension Prefs.Key {
    /// "Move to active screen" (the screen with the cursor). Reuses the original `qaMultiDisplay` key.
    static let qaMoveToActiveScreen = Prefs.Key.qaMultiDisplay
    static let qaAutoCloseMode = Prefs.Key("qaAutoCloseMode", "close")          // "close" | "saveAndClose"
    static let qaCloseAfterDragging = Prefs.Key("qaCloseAfterDragging", true)
    static let qaAskForDestination = Prefs.Key("qaAskForDestination", false)
    static let qaLastDisplayed = Prefs.Key("qaLastDisplayed", [QuickAccess.Persisted]())
}

/// The Quick Access Overlay: a stack of floating thumbnails at the left/right edge after each capture.
/// Each card is its own borderless panel (so the rest of the screen stays clickable) laid out by this controller.
@MainActor
final class QuickAccess: ObservableObject {
    static let shared = QuickAccess()

    static let autoCloseIntervals: [(seconds: Int, title: String)] = [
        (5, "5 seconds"), (10, "10 seconds"), (15, "15 seconds"), (30, "30 seconds"),
        (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes"), (600, "10 minutes"),
    ]
    nonisolated static let baseWidth: CGFloat = 230

    final class Item: ObservableObject, Identifiable {
        let id = UUID()
        let kind: MediaKind
        var url: URL
        var shot: Shot?
        var saved: Bool
        @Published var thumbnail: NSImage?
        /// Screenshot pixel size, known before its thumbnail is ready (card layout).
        var pixelSize: CGSize?
        @Published var duration: Double?
        @Published var hasAudio = false
        @Published var fileSize: String?
        @Published var hovered = false
        @Published var secretCount = 0    // unredacted secrets found by Auto Redact's background scan (warning dot)
        var remaining: Double = 0          // auto-close countdown (seconds)

        init(kind: MediaKind, url: URL, shot: Shot?, saved: Bool) {
            self.kind = kind
            self.url = url
            self.shot = shot
            self.saved = saved
        }
    }

    struct Persisted: Codable { var path: String; var saved: Bool }

    /// Oldest first; the newest card sits at the bottom of the stack.
    @Published private(set) var items: [Item] = [] { didSet { persist() } }
    @Published private(set) var isHidden = false
    @Published private(set) var optionDown = false
    private var recentlyClosed: [Item] = []
    private var panels: [UUID: QACardPanel] = [:]
    private var screen: NSScreen = .underMouse
    private var ticker: Timer?
    private var flagsMonitor: Any?
    private var restoring = false

    // MARK: Adding

    /// The card kind always follows the file (a GIF passed as `.image` still gets an animated card).
    func add(_ c: CaptureItem) {
        switch c {
        case let .image(shot, url, saved):
            let kind = MediaKind.detect(url)
            insert(Item(kind: kind, url: url, shot: kind == .image ? shot : nil, saved: saved))
        case let .video(url, saved): insert(Item(kind: MediaKind.detect(url), url: url, shot: nil, saved: saved))
        }
    }

    /// Adds any file (screenshot, GIF, video, project) with the right card for its kind. False if it can't be read.
    @discardableResult
    func addFile(_ url: URL, saved: Bool = true) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if MediaKind.detect(url) == .image {
            guard let s = Exporter.loadShot(url) else { return false }
            add(.image(s, fileURL: url, saved: saved))
        } else {
            add(.video(url, saved: saved))
        }
        return true
    }

    private func insert(_ item: Item, animated: Bool = true) {
        if items.isEmpty || Prefs.bool(.qaMoveToActiveScreen) { screen = .underMouse }
        if isHidden { isHidden = false }
        item.remaining = Double(Prefs.int(.qaAutoCloseSeconds))
        loadMedia(item)
        let panel = makePanel(for: item)
        panels[item.id] = panel
        items.append(item)
        layout(entering: animated ? item.id : nil)
        startTimers()
        AutoRedact.watch(item)
    }

    private func loadMedia(_ item: Item) {
        if let shot = item.shot {
            // The card is sized from the pixel size; the thumbnail (a full-size decode + downsample, ~15 ms for 5K)
            // is made off the main thread and pops in during the slide-in.
            let image = shot.image
            item.pixelSize = CGSize(width: image.width, height: image.height)
            Task {
                let thumb = await Task.detached(priority: .userInitiated) { Self.thumbnail(image) }.value
                if item.shot?.image === image { item.thumbnail = thumb }
            }
        } else if item.kind == .gif {
            item.thumbnail = NSImage(contentsOf: item.url)   // NSImageView animates it
            item.duration = MediaInfo.gifDuration(item.url)
        }
        item.fileSize = MediaInfo.fileSize(item.url)
        guard item.shot == nil else { return }
        Task {
            if item.thumbnail == nil {
                item.thumbnail = await MediaInfo.thumbnail(item.url, maxPixels: Self.baseWidth * 1.6 * 2)
                layout()
            }
            if item.kind == .video, let info = await MediaInfo.videoInfo(item.url) {
                item.duration = info.duration
                item.hasAudio = info.hasAudio
            }
        }
    }

    nonisolated static func thumbnail(_ image: CGImage) -> NSImage {
        let maxPixels = baseWidth * 1.6 * 2
        let f = min(1, maxPixels / CGFloat(max(image.width, 1)))
        let img = f < 1 ? (image.resized(by: f) ?? image) : image
        return NSImage(cgImage: img, size: CGSize(width: img.width, height: img.height))
    }

    // MARK: Closing / hiding / restoring

    func close(_ id: UUID, direction: CGFloat? = nil, remember: Bool = true, relayout: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        if remember {
            recentlyClosed.append(item)
            if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
        }
        if let panel = panels.removeValue(forKey: id) {
            let left = Prefs.string(.qaPosition) != "right"
            let dx = direction ?? (left ? -1 : 1)
            var f = panel.frame
            f.origin.x += dx * (f.width + 40)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(f, display: true)
                panel.fade(to: 0, animated: true)
            }, completionHandler: { panel.orderOut(nil) })
        }
        if relayout { layout() }
        if items.isEmpty { stopTimers() }
    }

    func close(_ item: Item) { close(item.id) }

    func closeAll() {
        guard !items.isEmpty else { return }
        if items.count > 1,
           !confirm("Close every Quick Access overlay?", info: "You can bring them back with Restore Recently Closed or from Capture History.", button: "Close All", id: Self.closeAllWarning) { return }
        items.map(\.id).forEach { close($0) }
    }

    func saveAll() {
        for item in items { if item.saved || saveToExportLocation(item, toast: false) { close(item.id) } }
        Toast.show("Saved to %@".loc(Prefs.exportFolder.lastPathComponent))
    }

    /// Slides every card below the bottom edge (one sliver stays visible to bring them back) — or back up.
    func toggleHidden() {
        guard !items.isEmpty else { isHidden = false; return }
        isHidden.toggle()
        layout()
    }

    func restoreRecentlyClosed() {
        while let last = recentlyClosed.popLast() {
            guard FileManager.default.fileExists(atPath: last.url.path) else { continue }
            last.hovered = false
            insert(last)
            return
        }
        History.shared.restoreLast()
    }

    /// Overlays shown when the app last quit (restored at launch).
    static var persistedPaths: [String] { (Prefs.codable(.qaLastDisplayed, [Persisted].self) ?? []).map(\.path) }

    func restorePersisted() {
        let list = Prefs.codable(.qaLastDisplayed, [Persisted].self) ?? []
        restoring = true
        for p in list where FileManager.default.fileExists(atPath: p.path) {
            let url = URL(fileURLWithPath: p.path)
            let kind = MediaKind.detect(url)
            insert(Item(kind: kind, url: url, shot: kind == .image ? Exporter.loadShot(url) : nil, saved: p.saved))
        }
        restoring = false
        persist()
    }

    private func persist() {
        guard !restoring else { return }
        Prefs.setCodable(items.map { Persisted(path: $0.url.path, saved: $0.saved) }, .qaLastDisplayed)
    }

    // MARK: Actions

    func shot(for item: Item) -> Shot? {
        if item.shot == nil, item.kind == .image { item.shot = Exporter.loadShot(item.url) }
        return item.shot
    }

    func copy(_ item: Item) {
        if let s = shot(for: item) { Exporter.copy(s, fileURL: item.url) } else { Exporter.copyFile(item.url) }
        Toast.show("Copied to clipboard")
        AutoRedact.warnAfterCopy(item)
        close(item.id)
    }

    /// Save button: export location or "Ask for destination" per settings; holding ⌥ inverts. Saved items reveal their file.
    func save(_ item: Item, invert: Bool = NSEvent.modifierFlags.contains(.option)) {
        let ask = Prefs.bool(.qaAskForDestination) != invert
        if ask { saveAs(item); return }
        if item.saved { reveal(item); return }
        if saveToExportLocation(item, toast: true) { close(item.id) }
    }

    @discardableResult
    private func saveToExportLocation(_ item: Item, toast: Bool) -> Bool {
        do {
            let url: URL
            if let s = shot(for: item) {
                url = try Exporter.save(s)
            } else {
                try FileManager.default.createDirectory(at: Prefs.exportFolder, withIntermediateDirectories: true)
                url = Exporter.uniqueURL(in: Prefs.exportFolder, name: item.url.deletingPathExtension().lastPathComponent, ext: item.url.pathExtension)
                try FileManager.default.copyItem(at: item.url, to: url)
            }
            item.url = url
            item.saved = true
            persist()
            if toast { Toast.show("Saved to %@".loc(url.deletingLastPathComponent().lastPathComponent)) }
            return true
        } catch {
            Toast.show("Couldn't save: %@".loc(error.localizedDescription), isError: true)
            return false
        }
    }

    func saveAs(_ item: Item) {
        if let s = shot(for: item) {
            if let url = PinWindow.saveAs(s) { item.url = url; item.saved = true; close(item.id) }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.url.lastPathComponent
        panel.directoryURL = Prefs.exportFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dst = panel.url else { return }
        // Saving over the card's own file: nothing to copy (removing dst first would delete the source).
        guard History.canonicalPath(dst) != History.canonicalPath(item.url) else { close(item.id); return }
        do {
            let fm = FileManager.default
            let tmp = try Self.replacementURL(for: dst)
            defer { try? fm.removeItem(at: tmp.deletingLastPathComponent()) }
            try fm.copyItem(at: item.url, to: tmp)
            try Self.swapIn(tmp, at: dst)
            close(item.id)
        } catch {
            Toast.show("Couldn't save: %@".loc(error.localizedDescription), isError: true)
        }
    }

    /// Annotate (screenshots) or the video editor (recordings).
    func edit(_ item: Item) {
        if let s = shot(for: item) {
            AnnotateWindowController.open(shot: s, fileURL: item.saved ? item.url : nil)
        } else {
            VideoEditor.open(item.url)
        }
        close(item.id)
    }

    /// A temp path on `dst`'s volume (own directory; remove its parent when done) to write before `swapIn`.
    static func replacementURL(for dst: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dst, create: true)
            .appendingPathComponent(dst.lastPathComponent)
    }

    /// Atomically puts `tmp` at `dst` (replacing it if present); `dst` is untouched on failure.
    static func swapIn(_ tmp: URL, at dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { try fm.replaceRemovingBackup(dst, with: tmp) } else { try fm.moveItem(at: tmp, to: dst) }
    }

    func pin(_ item: Item) {
        guard let s = shot(for: item) else { return }
        PinWindow.pin(s)
        close(item.id)
    }

    func quickLook(_ item: Item) { QuickLook.toggle([item.url], from: panels[item.id]) }

    func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func open(_ item: Item, with app: URL) {
        NSWorkspace.shared.open([item.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Moves the file to the Trash (asks first for recordings, per settings).
    func trash(_ item: Item) {
        if item.kind.isMotion,
           !confirm("Move this recording to the Trash?", info: "The file will be moved to the Trash.", button: "Move to Trash", id: Self.videoDeleteWarning) { return }
        History.shared.forget(fileURL: item.url)   // before recycling, while the path still resolves
        NSWorkspace.shared.recycle([item.url]) { _, _ in }
        close(item.id, remember: false)
    }

    func recognizeText(_ item: Item) {
        guard let s = shot(for: item) else { return }
        Task {
            let text = await TextRecognizer.recognize(s.image)
            guard !text.isEmpty else { Toast.show("No text found", isError: true); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show("Copied %d characters".loc(text.count))
        }
    }

    /// Formats an in-place edit can re-encode as themselves (GIF/BMP/HEIF/WebP… would be corrupted or lose frames).
    nonisolated static func inPlaceFormat(_ url: URL) -> ImageFormat? {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpg
        case "heic": return .heic
        case "tif", "tiff": return .tiff
        default: return nil
        }
    }

    func canEditInPlace(_ item: Item) -> Bool { item.kind == .image && Self.inPlaceFormat(item.url) != nil }

    /// Rotate / flip / scale / resize the screenshot and rewrite its file in place (same format, export prefs not applied).
    func transform(_ item: Item, _ f: (Shot) -> Shot?) {
        guard let fmt = Self.inPlaceFormat(item.url), let s = shot(for: item), let out = f(s) else { return }
        guard let data = Exporter.encode(out.image, type: fmt.utType, scale: out.scale, quality: fmt.isLossy ? Prefs.double(.jpegQuality) : nil) else {
            return Toast.show("Couldn't encode the image", isError: true)
        }
        do { try data.write(to: item.url, options: .atomic) } catch {
            return Toast.show("Couldn't save: %@".loc(error.localizedDescription), isError: true)
        }
        item.shot = out
        reloadMedia(item)
    }

    private func reloadMedia(_ item: Item) {
        MediaInfo.invalidateThumbnails()
        item.thumbnail = nil
        loadMedia(item)
        layout()
    }

    /// "Resize…": pixels or percent, proportions locked by default.
    func resize(_ item: Item) {
        guard let s = shot(for: item) else { return }
        let px = CGSize(width: s.image.width, height: s.image.height)
        let model = ResizeModel(base: px)
        let a = NSAlert()
        a.messageText = "Resize Image"
        a.informativeText = "Current size: %d × %d px".loc(Int(px.width), Int(px.height))
        a.addButton(withTitle: "Resize")
        a.addButton(withTitle: "Cancel")
        a.localize()
        let host = NSHostingView(rootView: QAResizeForm(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 70)
        a.accessoryView = host
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let t = model.pixels
        guard t.width >= 1, t.height >= 1, t != px else { return }
        transform(item) { s in
            guard let ctx = CGContext(data: nil, width: Int(t.width), height: Int(t.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: s.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(s.image, in: CGRect(origin: .zero, size: t))
            return ctx.makeImage().map { Shot(image: $0, scale: s.scale) }
        }
    }

    func printImage(_ item: Item) {
        guard let s = shot(for: item) else { return }
        let size = CGSize(width: CGFloat(s.image.width) / s.scale, height: CGFloat(s.image.height) / s.scale)
        let view = NSImageView(frame: CGRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: s.image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        NSApp.activate(ignoringOtherApps: true)
        NSPrintOperation(view: view, printInfo: info).run()
    }

    /// "Mute Audio": re-exports the video tracks only (passthrough) and atomically swaps the card's file for the result.
    func muteAudio(_ item: Item) {
        let src = item.url
        Task {
            let fm = FileManager.default
            var tmp: URL?
            defer { if let tmp { try? fm.removeItem(at: tmp.deletingLastPathComponent()) } }
            do {
                let asset = AVURLAsset(url: src)
                let comp = AVMutableComposition()
                let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
                for track in try await asset.loadTracks(withMediaType: .video) {
                    guard let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    try t.insertTimeRange(range, of: track, at: .zero)
                    t.preferredTransform = try await track.load(.preferredTransform)
                }
                let type: AVFileType = switch src.pathExtension.lowercased() { case "mp4": .mp4; case "m4v": .m4v; default: .mov }
                guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else {
                    throw CocoaError(.featureUnsupported)
                }
                let out = try Self.replacementURL(for: src)
                tmp = out
                try await session.export(to: out, as: type)
                try Self.swapIn(out, at: src)
                item.hasAudio = false
                reloadMedia(item)
                Toast.show("Audio removed")
            } catch {
                Toast.show("Couldn't remove audio: %@".loc(error.localizedDescription), isError: true)
            }
        }
    }

    static let closeAllWarning = "qaCloseAll"
    static let videoDeleteWarning = "qaVideoDelete"

    /// Confirmation with "Don't show again", stored as `suppressWarning.<id>` (reset from Settings › Advanced).
    private func confirm(_ message: String, info: String, button: String, id: String) -> Bool {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        return Warnings.run(id, a) == .alertFirstButtonReturn
    }

    // MARK: Hover, keyboard, gestures (called by the card panel)

    func setHovered(_ item: Item, _ h: Bool) {
        item.hovered = h
        if h, isHidden { return }
        guard let panel = panels[item.id] else { return }
        if h {
            panel.makeKey()   // lets ⌘C / ⌘S / Space… reach the hovered card without activating the app
        } else if panel.isKeyWindow, !NSApp.isActive {
            // Hand keyboard focus back to the app the user was in.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    func handleKey(_ e: NSEvent, for item: Item) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch (e.keyCode, cmd) {
        case (53, _): close(item.id)                                  // Esc
        case (49, false): quickLook(item)                             // Space
        case (51, true), (117, true): trash(item)                     // ⌘⌫ / ⌘⌦
        default:
            guard cmd, let k = e.charactersIgnoringModifiers?.lowercased() else { return false }
            switch k {
            case "c": copy(item)
            case "s": save(item, invert: e.modifierFlags.contains(.option))
            case "e": edit(item)
            case "p": if item.kind == .image { pin(item) }
            case "w": close(item.id)
            default: return false
            }
        }
        return true
    }

    /// Two-finger swipe: sideways dismisses the card (it follows the fingers), down hides all, up shows them again.
    func handleSwipe(_ e: NSEvent, for item: Item) {
        guard let panel = panels[item.id], e.momentumPhase.isEmpty, !e.phase.isEmpty else { return }
        let sign: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        switch e.phase {
        case .began:
            panel.swipe = .zero
        case .changed:
            panel.swipe.x += e.scrollingDeltaX * sign
            panel.swipe.y += e.scrollingDeltaY * sign
            if abs(panel.swipe.x) > abs(panel.swipe.y), !isHidden, let home = panel.home {
                panel.setFrameOrigin(CGPoint(x: home.minX + panel.swipe.x, y: home.minY))
                panel.fade(to: max(0.3, 1 - abs(panel.swipe.x) / 300), animated: false)
            }
        case .ended, .cancelled:
            let s = panel.swipe
            panel.swipe = .zero
            if abs(s.x) > abs(s.y) {
                if abs(s.x) > 70, !isHidden { close(item.id, direction: s.x > 0 ? 1 : -1) } else { layout() }
            } else if s.y > 40, !isHidden {
                toggleHidden()
            } else if s.y < -40, isHidden {
                toggleHidden()
            }
        default: break
        }
    }

    /// Drag-out finished: close unless ⌥ was held (or the opposite, per "Close after dragging").
    func didDragOut(_ item: Item, operation: NSDragOperation) {
        panels[item.id]?.fade(to: 1, animated: false)
        guard operation != [] else { return }
        AutoRedact.warnAfterCopy(item)
        if Prefs.bool(.qaCloseAfterDragging) != NSEvent.modifierFlags.contains(.option) { close(item.id) }
    }

    func doubleClicked(_ item: Item) {
        if isHidden { toggleHidden() } else { edit(item) }
    }

    // MARK: Layout

    var cardWidth: CGFloat { (Self.baseWidth * CGFloat(min(max(Prefs.double(.qaSize), 0.6), 1.8))).rounded() }

    func cardSize(_ item: Item) -> CGSize {
        Self.cardSize(image: item.thumbnail?.size ?? item.pixelSize ?? CGSize(width: 16, height: 10), width: cardWidth)
    }

    private func makePanel(for item: Item) -> QACardPanel {
        let p = QACardPanel(rect: CGRect(origin: .zero, size: cardSize(item)), level: .statusBar)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.animationBehavior = .none
        p.onKey = { [weak self, weak item] e in item.map { self?.handleKey(e, for: $0) ?? false } ?? false }
        p.onScroll = { [weak self, weak item] e in if let item { self?.handleSwipe(e, for: item) } }
        let host = NSHostingView(rootView: QuickAccessCard(item: item, model: self))
        p.contentView = QACardContainer(host: host) { [weak self, weak item] h in if let item { self?.setHovered(item, h) } }
        p.attachShadow()
        return p
    }

    private func layout(entering: UUID? = nil) {
        guard !items.isEmpty else { return }
        let vf = screen.visibleFrame
        let left = Prefs.string(.qaPosition) != "right"
        var (frames, fits) = Self.stackFrames(items.map(cardSize), in: vf, left: left)
        if fits < items.count {
            // Too many to fit: the oldest go to "recently closed" (restorable).
            items.prefix(items.count - fits).map(\.id).forEach { close($0, relayout: false) }
            frames.removeFirst(frames.count - items.count)
        }
        if isHidden { frames = Self.hiddenFrames(frames, screen: screen.frame) }
        for (item, frame) in zip(items, frames) {
            guard let panel = panels[item.id] else { continue }
            panel.home = frame
            if item.id == entering {
                var start = frame
                start.origin.x = left ? vf.minX - frame.width - 10 : vf.maxX + 10
                panel.setFrame(start, display: false)
                panel.fade(to: 0, animated: false)
                panel.orderFrontRegardless()
            }
            if !panel.isVisible { panel.orderFrontRegardless() }
            let resized = panel.frame.size != frame.size
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = item.id == entering ? 0.45 : 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.18, 0.36, 1)   // gentle overshoot, spring-like
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
                panel.fade(to: 1, animated: true)
            } completionHandler: { [weak panel] in
                if resized { MainActor.assumeIsolated { panel?.syncShadow() } }
            }
        }
    }

    /// Every card has the same 16:10 size; the capture is fitted inside it over a blurred copy.
    nonisolated static func cardSize(image: CGSize, width: CGFloat) -> CGSize {
        CGSize(width: width, height: (width * 0.625).rounded())
    }

    /// Frames (oldest first) stacked up from the bottom edge, newest at the bottom; `fits` = how many of the newest fit.
    nonisolated static func stackFrames(_ sizes: [CGSize], in visible: CGRect, left: Bool, margin: CGFloat = 20, spacing: CGFloat = 14) -> (frames: [CGRect], fits: Int) {
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y = visible.minY + margin
        var fits = 0
        for i in sizes.indices.reversed() {
            let s = sizes[i]
            let x = left ? visible.minX + margin : visible.maxX - margin - s.width
            frames[i] = CGRect(x: x, y: y, width: s.width, height: s.height)
            if y + s.height <= visible.maxY - margin || fits == 0 { fits += 1 }
            y += s.height + spacing
        }
        return (frames, fits)
    }

    /// Hidden: everything slides below the screen; only a sliver of the newest card stays visible.
    nonisolated static func hiddenFrames(_ frames: [CGRect], screen: CGRect, peek: CGFloat = 12) -> [CGRect] {
        frames.enumerated().map { i, f in
            var r = f
            r.origin.y = i == frames.count - 1 ? screen.minY - f.height + peek : screen.minY - f.height - 20
            return r
        }
    }

    // MARK: Timers (auto-close, follow the cursor's screen, ⌥ state)

    private func startTimers() {
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { QuickAccess.shared.tick(0.25) }
            }
        }
        if flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
                QuickAccess.shared.optionDown = e.modifierFlags.contains(.option)
                return e
            }
        }
    }

    private func stopTimers() {
        ticker?.invalidate()
        ticker = nil
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        optionDown = false
        isHidden = false
    }

    private var appliedLook = ""

    private func tick(_ dt: Double) {
        // Position / size changed in Settings: re-stack live.
        let look = "\(Prefs.string(.qaPosition))|\(Prefs.double(.qaSize))"
        if look != appliedLook { appliedLook = look; layout() }
        if Prefs.bool(.qaMoveToActiveScreen), !isHidden {
            let s = NSScreen.underMouse
            if s.displayID != screen.displayID { screen = s; layout() }
        }
        if optionDown != NSEvent.modifierFlags.contains(.option) { optionDown.toggle() }
        guard Prefs.bool(.qaAutoClose), !isHidden else { return }
        for item in items where !item.hovered {
            item.remaining -= dt
            guard item.remaining <= 0 else { continue }
            if Prefs.string(.qaAutoCloseMode) == "saveAndClose", !item.saved { saveToExportLocation(item, toast: false) }
            close(item.id)
        }
    }

    // MARK: Context menu

    func menu(for item: Item) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ symbol: String? = nil, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, keyEquivalent: "", action: action)
            if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            m.addItem(i)
        }
        if item.kind == .image {
            add("Open Annotation Tool…", "pencil.tip.crop.circle") { [unowned self] in edit(item) }
            add("Pin to the Screen", "pin") { [unowned self] in pin(item) }
            add("Capture Text", "text.viewfinder") { [unowned self] in recognizeText(item) }
        } else {
            add(item.kind == .gif ? "Open" : "Open Video Editor…", "scissors") { [unowned self] in edit(item) }
        }
        add("Quick Look", "eye") { [unowned self] in quickLook(item) }
        m.addItem(.separator())
        add("Copy", "doc.on.doc") { [unowned self] in copy(item) }
        add("Save", "square.and.arrow.down") { [unowned self] in save(item, invert: false) }
        add("Save As…") { [unowned self] in saveAs(item) }
        add("Show in Finder", "folder") { [unowned self] in reveal(item) }
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
        if !apps.isEmpty {
            let openWith = NSMenuItem(title: "Open With".loc, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for app in apps.prefix(12) {
                let i = ClosureMenuItem(title: FileManager.default.displayName(atPath: app.path), keyEquivalent: "") { [unowned self] in open(item, with: app) }
                let icon = NSWorkspace.shared.icon(forFile: app.path)
                icon.size = CGSize(width: 16, height: 16)
                i.image = icon
                sub.addItem(i)
            }
            openWith.submenu = sub
            m.addItem(openWith)
        }
        m.addItem(NSSharingServicePicker(items: [item.url]).standardShareMenuItem)
        if item.kind == .image {
            add("Print…", "printer") { [unowned self] in printImage(item) }
            m.addItem(.separator())
            // In-place edits only for formats we can re-encode as themselves; disabled otherwise.
            let inPlace = canEditInPlace(item)
            m.autoenablesItems = false
            func inPlaceItem(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
                add(title, symbol, action)
                m.items.last?.isEnabled = inPlace
            }
            inPlaceItem("Resize…", "arrow.up.left.and.arrow.down.right") { [unowned self] in resize(item) }
            inPlaceItem("Auto Redact", "eye.slash") { [unowned self] in autoRedact(item) }
            inPlaceItem("Rotate Left", "rotate.left") { [unowned self] in transform(item) { $0.rotatedLeft() } }
            inPlaceItem("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right") { [unowned self] in transform(item) { $0.flippedHorizontally() } }
            if let s = shot(for: item), s.scale > 1 {
                inPlaceItem("Scale Retina to 1x", "arrow.down.right.and.arrow.up.left") { [unowned self] in transform(item) { $0.scaledTo1x() } }
            }
        } else if item.kind == .video {
            m.addItem(.separator())
            add("Trim…", "timeline.selection") { [unowned self] in edit(item) }
            if item.hasAudio { add("Mute Audio", "speaker.slash") { [unowned self] in muteAudio(item) } }
        }
        m.addItem(.separator())
        add("Move to Trash", "trash") { [unowned self] in trash(item) }
        m.addItem(.separator())
        add("Temporarily Hide") { [unowned self] in toggleHidden() }
        add("Close") { [unowned self] in close(item.id) }
        add("Close All…") { [unowned self] in closeAll() }
        add("Save All…") { [unowned self] in saveAll() }
        return m
    }

    static func selfTest() {
        let vf = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let sizes = [CGSize(width: 200, height: 100), CGSize(width: 200, height: 150)]
        let (frames, fits) = stackFrames(sizes, in: vf, left: true)
        assert(fits == 2)
        assert(frames[1] == CGRect(x: 20, y: 20, width: 200, height: 150))           // newest at the bottom
        assert(frames[0] == CGRect(x: 20, y: 184, width: 200, height: 100))
        let right = stackFrames(sizes, in: vf, left: false).frames
        assert(right[1].maxX == 980)
        let tall = stackFrames([CGSize](repeating: CGSize(width: 200, height: 200), count: 4), in: vf, left: true)
        assert(tall.fits == 2)
        let hidden = hiddenFrames(frames, screen: vf)
        assert(hidden[1].maxY == 12 && hidden[0].maxY < 0)
        assert(cardSize(image: CGSize(width: 1000, height: 100), width: 200).height == 125)  // fixed 16:10 card
        assert(cardSize(image: CGSize(width: 100, height: 1000), width: 200).height == 125)
        let rotated = Shot(image: CGImage.solid(width: 4, height: 2), scale: 2).rotatedLeft()
        assert(rotated?.image.width == 2 && rotated?.image.height == 4)
        assert(inPlaceFormat(URL(fileURLWithPath: "/a/b.JPEG")) == .jpg && inPlaceFormat(URL(fileURLWithPath: "/a/b.tif")) == .tiff)
        assert(inPlaceFormat(URL(fileURLWithPath: "/a/b.gif")) == nil && inPlaceFormat(URL(fileURLWithPath: "/a/b.bmp")) == nil)
        assert(History.canonicalPath(URL(fileURLWithPath: "/tmp/../tmp/x.png")) == History.canonicalPath(URL(fileURLWithPath: "/private/tmp/x.png")))
    }
}

/// Resize dialog body for Quick Access (Annotate's `ResizeForm` minus its "Flatten Annotations" option).
struct QAResizeForm: View {
    @ObservedObject var model: ResizeModel

    private func field(_ v: Binding<Int>) -> some View {
        TextField("", text: Binding(get: { String(v.wrappedValue) }, set: { if let n = Int($0.filter(\.isNumber)), n > 0 { v.wrappedValue = min(n, 30000) } }))
            .frame(width: 90)
            .multilineTextAlignment(.trailing)
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .trailing, spacing: 8) {
                HStack { Text("Width:"); field($model.width) }
                HStack { Text("Height:"); field($model.height) }
            }
            Button { model.lock.toggle() } label: {
                Image(systemName: model.lock ? "lock.fill" : "lock.open").frame(width: 18, height: 40)
            }
            .buttonStyle(.borderless)
            .help(model.lock ? "Proportions locked".loc : "Proportions unlocked".loc)
            Picker("", selection: $model.percent) {
                Text("pixels").tag(false)
                Text("percent").tag(true)
            }
            .labelsHidden()
            .frame(width: 96)
        }
        .padding(4)
    }
}

// MARK: - Card window

/// Borderless card panel. Keys and trackpad swipes are routed to the controller; the window shadow follows the rounded card.
final class QACardPanel: QuickLookPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onScroll: ((NSEvent) -> Void)?
    var home: CGRect?
    var swipe = CGPoint.zero

    static let cornerRadius: CGFloat = 18
    private static let shadowPad: CGFloat = 36

    /// Soft drop shadow drawn by a click-through child window just below the card. The card's own window stays
    /// card-sized, so the shadow never swallows clicks meant for the card underneath it.
    private let shadowWindow: NSWindow = {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        w.contentView = QACardShadowView()
        return w
    }()

    /// Call once the panel exists: puts the shadow under it.
    func attachShadow() {
        hasShadow = false
        shadowWindow.level = level
        addChildWindow(shadowWindow, ordered: .below)
        syncShadow()
    }

    /// The shadow is a child window, so AppKit moves it with the card; only a size change needs this.
    /// (Don't override setFrame/alphaValue instead: AppKit's animator proxy calls those overrides and crashes.)
    func syncShadow() {
        let pad = Self.shadowPad
        shadowWindow.setFrame(frame.insetBy(dx: -pad, dy: -pad), display: true)
    }

    /// Card and shadow fade together (don't override `alphaValue`: AppKit's animator proxy would call into it).
    func fade(to a: CGFloat, animated: Bool) {
        if animated {
            animator().alphaValue = a
            shadowWindow.animator().alphaValue = a
        } else {
            alphaValue = a
            shadowWindow.alphaValue = a
        }
    }

    override func sendEvent(_ e: NSEvent) {
        switch e.type {
        case .keyDown where onKey?(e) == true: return
        case .scrollWheel: onScroll?(e); return
        default: super.sendEvent(e)
        }
    }
}

/// Draws the card's soft drop shadow (the card itself covers the shape that casts it).
final class QACardShadowView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pad: CGFloat = 36, r = QACardPanel.cornerRadius
        let card = bounds.insetBy(dx: pad + 1, dy: pad + 1)   // 1pt inside so nothing peeks past the card's corners
        ctx.setShadow(offset: CGSize(width: 0, height: -7), blur: 26, color: NSColor.black.withAlphaComponent(0.42).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
    }
}

/// Hosts the SwiftUI card and tracks hover in AppKit (reliable even over embedded AppKit views).
final class QACardContainer: NSView {
    let host: NSView
    private let onHover: (Bool) -> Void

    init(host: NSView, onHover: @escaping (Bool) -> Void) {
        self.host = host
        self.onHover = onHover
        super.init(frame: .zero)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

// MARK: - Card view

struct QuickAccessCard: View {
    @ObservedObject var item: QuickAccess.Item
    @ObservedObject var model: QuickAccess

    var body: some View {
        ZStack {
            Color(white: 0.11)
            QADragSource(item: item, model: model)
            if item.kind.isMotion && !item.hovered { mediaBadges }
            if item.secretCount > 0 && !item.hovered { SecretDot(count: item.secretCount) }
            if item.hovered && !model.isHidden { controls.transition(.opacity) }
        }
        .clipShape(RoundedRectangle(cornerRadius: QACardPanel.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: QACardPanel.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: item.hovered)
        .environment(\.colorScheme, .dark)
    }

    private var mediaBadges: some View {
        ZStack {
            if item.kind == .video || item.kind == .project {
                Image(systemName: "play.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(.black.opacity(0.45), in: Circle())
                    .allowsHitTesting(false)
            }
            HStack(spacing: 5) {
                if item.kind == .gif { Text("GIF").fontWeight(.heavy) }
                if let d = item.duration { Text(MediaInfo.durationString(d)) }
                if item.hasAudio { Image(systemName: "speaker.wave.2.fill") }
                if let s = item.fileSize { Text("· \(s)").foregroundStyle(.white.opacity(0.75)) }
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(7)
            .allowsHitTesting(false)
        }
    }

    private var saveTitle: String {
        let ask = Prefs.bool(.qaAskForDestination) != model.optionDown
        return ask ? "Save As…" : item.saved ? "Show in Finder" : "Save"
    }

    private var controls: some View {
        ZStack {
            Color.black.opacity(0.42).allowsHitTesting(false)
            VStack(spacing: 8) {
                Button("Copy") { model.copy(item) }.help("Copy to clipboard (⌘C)")
                Button(saveTitle.loc) { model.save(item) }.help(Prefs.bool(.qaAskForDestination) ? "Save as… (⌘S) — hold ⌥ to save to export location".loc : "Save to export location (⌘S) — hold ⌥ to choose a destination".loc)
            }
            .buttonStyle(QAPillButtonStyle())
            VStack {
                HStack {
                    corner("xmark", "Close (Esc)") { model.close(item) }
                    Spacer()
                    if item.kind == .image {
                        corner("pencil", "Open Annotate tool (⌘E)") { model.edit(item) }
                    } else {
                        corner("scissors", item.kind == .gif ? "Open (⌘E)" : "Open Video Editor (⌘E)") { model.edit(item) }
                    }
                }
                Spacer()
                HStack {
                    if item.kind == .image {
                        corner("pin", "Pin to the screen (⌘P)") { model.pin(item) }
                    } else {
                        corner("eye", "Open Quick Look (Space)") { model.quickLook(item) }
                    }
                    Spacer()
                    corner("trash", "Move to Trash (⌘⌫)") { model.trash(item) }
                }
            }
            .padding(7)
        }
    }

    private func corner(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(QAPressStyle())
        .help(help.loc)
    }
}

/// White capsule button used on Quick Access cards and in Capture History.
struct QAPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black)
            .frame(minWidth: 84)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(.white.opacity(configuration.isPressed ? 0.75 : 0.96), in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct QAPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Thumbnail (AppKit: aspect-fill image that animates GIFs, drag source, double-click, context menu)

struct QADragSource: NSViewRepresentable {
    @ObservedObject var item: QuickAccess.Item
    let model: QuickAccess

    func makeNSView(context: Context) -> QADragView { QADragView(item: item, model: model) }

    func updateNSView(_ v: QADragView, context: Context) {
        if v.imageView.image !== item.thumbnail {
            v.imageView.image = item.thumbnail
            v.backdrop.image = QADragView.blurred(item.thumbnail)
            v.needsLayout = true
        }
    }
}

final class QADragView: NSView, NSDraggingSource {
    let imageView = NSImageView()
    /// The same image, enlarged, blurred and dimmed, filling the space the fitted image leaves.
    let backdrop = NSImageView()
    private let item: QuickAccess.Item
    private unowned let model: QuickAccess
    private var downPoint: CGPoint?

    init(item: QuickAccess.Item, model: QuickAccess) {
        self.item = item
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.image = item.thumbnail
        imageView.unregisterDraggedTypes()
        backdrop.imageScaling = .scaleAxesIndependently
        backdrop.image = Self.blurred(item.thumbnail)
        backdrop.alphaValue = 0.55
        backdrop.unregisterDraggedTypes()
        addSubview(backdrop)
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The capture is fitted (whole image visible) with a small inset; the blurred backdrop covers the card (aspect fill).
    override func layout() {
        super.layout()
        guard let s = imageView.image?.size, s.width > 0, s.height > 0 else { imageView.frame = bounds; backdrop.frame = bounds; return }
        func place(_ v: NSView, _ k: CGFloat) {
            let w = s.width * k, h = s.height * k
            v.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        }
        let inner = bounds.insetBy(dx: 6, dy: 6)
        place(imageView, min(inner.width / s.width, inner.height / s.height))
        place(backdrop, max(bounds.width / s.width, bounds.height / s.height))
    }

    /// A tiny, heavily blurred copy (cheap to make and to draw scaled up).
    static func blurred(_ img: NSImage?) -> NSImage? {
        guard let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let k = 48 / CGFloat(max(cg.width, cg.height, 1))
        let ci = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: k, y: k))
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: ci.extent)
        guard let small = blurContext.createCGImage(out, from: ci.extent) else { return nil }
        return NSImage(cgImage: small, size: CGSize(width: small.width, height: small.height))
    }

    private static let blurContext = CIContext(options: [.useSoftwareRenderer: false])

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        downPoint = e.locationInWindow
        if e.clickCount == 2 { downPoint = nil; model.doubleClicked(item) }
        else if model.isHidden { downPoint = nil; model.toggleHidden() }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let p = downPoint, hypot(e.locationInWindow.x - p.x, e.locationInWindow.y - p.y) > 4 else { return }
        downPoint = nil
        let di = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        di.setDraggingFrame(bounds, contents: item.thumbnail ?? NSWorkspace.shared.icon(forFile: item.url.path))
        let session = beginDraggingSession(with: [di], event: e, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        (window as? QACardPanel)?.fade(to: 0.5, animated: false)
    }

    override func mouseUp(with e: NSEvent) { downPoint = nil }

    override func menu(for event: NSEvent) -> NSMenu? { model.menu(for: item) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        model.didDragOut(item, operation: operation)
    }
}

// MARK: - Image transforms (context menu)

extension Shot {
    private func redraw(width: Int, height: Int, _ draw: (CGContext) -> Void) -> Shot? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage().map { Shot(image: $0, scale: scale) }
    }

    func rotatedLeft() -> Shot? {
        let w = image.width, h = image.height
        return redraw(width: h, height: w) { ctx in
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    func flippedHorizontally() -> Shot? {
        redraw(width: image.width, height: image.height) { ctx in
            ctx.translateBy(x: CGFloat(image.width), y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    func scaledTo1x() -> Shot? {
        guard scale > 1, let small = image.resized(by: 1 / scale) else { return nil }
        return Shot(image: small, scale: 1)
    }
}

extension CGImage {
    /// Solid test image.
    static func solid(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
