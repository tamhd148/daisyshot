import AppKit
import ScreenCaptureKit

extension Prefs.Key {
    /// Window screenshots: transparent background instead of the wallpaper (⇧ inverts at capture time).
    static let windowBackgroundTransparent = Prefs.Key("windowBackgroundTransparent", false)
    /// Points of padding around window screenshots (on top of the shadow).
    static let windowPaddingAmount = Prefs.Key("windowPaddingAmount", 40.0)
    /// [displayID: rect] of the last captured area on each display (Capture Previous Area).
    static let previousAreas = Prefs.Key("previousAreas", "")
}

/// Entry point for every capture command (menu, hotkeys, URL scheme).
@MainActor
final class CaptureController {
    static let shared = CaptureController()
    private var busy = false
    /// App that was frontmost before the overlay took focus; re-activated afterwards.
    private var previousApp: NSRunningApplication?
    /// Desktop icons were hidden by the capture in progress ("Hide desktop icons while capturing").
    private var iconsHiddenForCapture = false

    private init() {
        #if DEBUG
        Exporter.selfTest()
        SelectionGeometry.selfTest()
        TextRecognizer.selfTest()
        SensitiveScanner.selfTest()
        Task.detached(priority: .background) {
            if let failure = Stitch.selfTest() { assertionFailure("Stitch self-test: \(failure)") }
        }
        #endif
    }

    private var lastRegion: CaptureRegion? {
        get { Prefs.d.data(forKey: "lastRegion").flatMap { try? JSONDecoder().decode(CaptureRegion.self, from: $0) } }
        set { Prefs.d.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastRegion") }
    }

    private var previousAreas: [String: CGRect] {
        get { Prefs.codable(.previousAreas, [String: CGRect].self) ?? [:] }
        set { Prefs.setCodable(newValue, .previousAreas) }
    }

    /// Line-break mode for the pending OCR capture (set by the two shortcut variants; nil = use the setting).
    var ocrLineBreaks: Bool?

    // MARK: Commands

    func captureArea(action: OverlayAction? = nil) { run { try await self.selectAndCapture(mode: .area, forced: action) } }
    /// Window picker; `action` (copy / save / annotate / pin…) replaces the after-capture actions for the picked window.
    func captureWindow(action: OverlayAction? = nil) { run { try await self.selectAndCapture(mode: .window, forced: action) } }
    /// `rect` pre-seeds the All-In-One selection (URL API) and starts in the adjusting state.
    func allInOne(rect: CaptureRegion? = nil) { run { try await self.selectAndCapture(mode: .allInOne, forced: nil, seed: rect) } }

    /// `lineBreaks` nil = the "Keep line breaks" setting.
    func captureText(lineBreaks: Bool? = nil) {
        run {
            self.ocrLineBreaks = lineBreaks
            try await self.selectAndCapture(mode: .area, forced: .text, hint: "Select the text to recognize · Space: window · Esc: cancel")
        }
    }

    func recordWindow() { run { await self.startRecording(region: nil, gif: false, source: .window) } }
    func recordSource(_ source: RecordingSetup.Source) { run { await self.startRecording(region: nil, gif: false, source: source) } }
    func scrollingCapture() {
        let opts = ScrollCapture.takePendingOptions()
        run {
            try await self.selectAndCapture(mode: .area, forced: .scroll, hint: "Drag over the area that scrolls. Leave out fixed headers and scroll bars.",
                                            scroll: opts)
        }
    }
    /// `gif`: true = GIF, false = video, nil = the mode last used in the recorder's setup bar (generic "Record Screen").
    func recordScreen(gif: Bool? = nil) {
        run {
            self.useLastRecordingMode = gif == nil
            // The setup's source bar picks the display, window or area ("Remember last selection" starts from the last area).
            await self.startRecording(region: Recorder.rememberedRegion, gif: gif == true)
        }
    }

    private var useLastRecordingMode = false

    private func startRecording(region: CaptureRegion?, gif: Bool, source: RecordingSetup.Source? = nil) async {
        let last = useLastRecordingMode
        useLastRecordingMode = false
        if last { await Recorder.shared.startUsingLastMode(region: region) } else { await Recorder.shared.start(region: region, gif: gif, source: source) }
    }

    /// `action` = what to do once the timer fires (URL API); nil = a plain screenshot with the after-capture actions.
    func selfTimer(action: OverlayAction? = nil) {
        run {
            try await self.selectAndCapture(mode: .area, forced: .timer, hint: "Select an area for the self-timer · click for full screen · Space: window",
                                            afterTimer: action ?? .screenshot)
        }
    }

    func captureFullscreen(displayID: CGDirectDisplayID? = nil) {
        run {
            let ids = displayID.map { [$0] } ?? (Prefs.bool(.captureAllDisplays) ? NSScreen.screens.map(\.displayID) : [NSScreen.underMouse.displayID])
            self.setContext(windowID: nil)
            await self.hideIconsForCapture()
            defer { self.restoreIcons() }
            let content = try await CaptureService.content()
            var shots: [Shot] = []
            for id in ids { shots.append(try await CaptureService.displayShot(id, showCursor: Prefs.bool(.screenshotCursor), content: content)) }
            self.restoreIcons()
            for shot in shots { self.process(shot, action: .screenshot, shift: false) }
        }
    }

    /// The last area captured on the display under the pointer (else the last area anywhere).
    func capturePreviousArea() {
        let screen = NSScreen.underMouse
        let region = previousAreas[String(screen.displayID)].map { CaptureRegion(displayID: screen.displayID, rect: $0) } ?? lastRegion
        guard let region, NSScreen.withID(region.displayID) != nil else { captureArea(); return }
        run {
            self.setContext(windowID: nil)
            await self.hideIconsForCapture()
            defer { self.restoreIcons() }
            let shot = try await CaptureService.shot(of: region)
            self.restoreIcons()
            self.process(shot, action: .screenshot, shift: false)
        }
    }

    /// URL-scheme / automation variant: capture an explicit rect without UI.
    func captureRect(_ region: CaptureRegion, action: OverlayAction = .screenshot) {
        let opts = ScrollCapture.takePendingOptions()
        run {
            self.setContext(windowID: nil)
            await self.hideIconsForCapture()
            defer { self.restoreIcons() }
            try await self.perform(action, region: region, overlay: nil, scroll: opts)
        }
    }

    /// Lets another module (e.g. Annotate's "Add New Screenshot") ask the user for an area and get the image back,
    /// without running after-capture actions.
    func selectShot() async -> Shot? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }
        let overlay = SelectionOverlay(mode: .area)
        switch await overlay.run() {
        case .cancelled:
            return nil
        case let .window(id, _):
            defer { overlay.close() }
            // Same treatment as a normal window capture, including the background preset `process` would add.
            guard let shot = try? await windowShot(id, shift: overlay.shiftHeld) else { return nil }
            return presetApplies(shift: overlay.shiftHeld) ? BackgroundPresets.applyAutoPreset(shot) : shot
        case let .region(region, _):
            defer { overlay.close() }
            if let frozen = overlay.frozenShot(for: region) { return frozen }
            return try? await CaptureService.shot(of: region, excludingWindowNumbers: overlay.windowNumbers)
        }
    }

    func openFromClipboard() {
        guard let shot = Exporter.shotFromPasteboard() else { Toast.show("No image on the clipboard", isError: true); return }
        AnnotateWindowController.open(shot: shot)
    }

    // MARK: Pipeline

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy, !Recorder.shared.isRecording else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await body() } catch {
                Toast.show(error.localizedDescription, isError: true)
            }
        }
    }

    /// "Hide desktop icons while capturing": temporary (non-persisted) hide, undone by `restoreIcons`.
    private func hideIconsForCapture() async {
        guard Prefs.bool(.hideIconsWhileCapturing), !DesktopIcons.shared.isHidden else { return }
        DesktopIcons.shared.hide(persist: false)
        iconsHiddenForCapture = true
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func restoreIcons() {
        guard iconsHiddenForCapture else { return }
        iconsHiddenForCapture = false
        DesktopIcons.shared.show()
    }

    private typealias ScrollOptions = (begin: Bool, autoscroll: Bool)

    private func selectAndCapture(mode: OverlayMode, forced: OverlayAction?, hint: String? = nil, seed: CaptureRegion? = nil,
                                  afterTimer: OverlayAction = .screenshot, scroll: ScrollOptions = (false, false)) async throws {
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        setContext(windowID: nil)
        await hideIconsForCapture()
        defer { restoreIcons() }

        let overlay = SelectionOverlay(mode: mode, hint: hint)
        overlay.clickCapturesFullscreen = [.timer, .video, .gif].contains(forced)
        overlay.seed = seed
        let result = await overlay.run()
        switch result {
        case .cancelled:
            ocrLineBreaks = nil
            restoreFocus()
        case let .window(id, action):
            var action = forced ?? action
            setContext(windowID: id)
            if [.video, .gif, .scroll].contains(action), let region = windowRegion(id) {
                try await perform(action, region: region, overlay: overlay, scroll: scroll)
                return
            }
            overlay.close()
            restoreFocus()
            if action == .timer {
                let screen = NSScreen.underMouse
                let frame = CaptureService.visibleWindows().first { $0.id == id }.map { NSScreen.fromCGGlobal($0.frame) }
                guard await SelfTimerOverlay.run(seconds: Prefs.int(.selfTimerSeconds), on: screen, highlight: frame) else { return }
                action = afterTimer == .timer ? .screenshot : afterTimer
                if [.video, .gif, .scroll].contains(action), let region = windowRegion(id) {
                    try await perform(action, region: region, overlay: nil, scroll: scroll)
                    return
                }
            }
            let shot = try await windowShot(id, shift: overlay.shiftHeld)
            process(shot, action: action, shift: overlay.shiftHeld)
        case let .region(region, action):
            lastRegion = region
            previousAreas[String(region.displayID)] = region.rect
            try await perform(forced ?? action, region: region, overlay: overlay, afterTimer: afterTimer, scroll: scroll)
        }
    }

    /// A window's frame as a region on the display it is mostly on (recording / scrolling a window).
    private func windowRegion(_ id: CGWindowID) -> CaptureRegion? {
        guard let w = CaptureService.visibleWindows().first(where: { $0.id == id }) else { return nil }
        let frame = NSScreen.fromCGGlobal(w.frame)
        guard let screen = NSScreen.screens.max(by: { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }) else { return nil }
        return CaptureRegion(displayID: screen.displayID, rect: screen.toDisplayRect(frame.intersection(screen.frame)).integral, windowID: id)
    }

    private func perform(_ action: OverlayAction, region: CaptureRegion, overlay: SelectionOverlay?,
                         afterTimer: OverlayAction = .screenshot, scroll: ScrollOptions = (false, false)) async throws {
        let shift = overlay?.shiftHeld ?? false
        switch action {
        case .video, .gif:
            overlay?.close()
            restoreFocus()
            restoreIcons() // the recorder hides them again itself after its countdown
            await startRecording(region: region, gif: action == .gif)
        case .scroll:
            overlay?.close()
            restoreFocus()
            // Icons stay hidden for the whole scroll session; the session shows them again when it ends.
            let ownsIcons = iconsHiddenForCapture
            iconsHiddenForCapture = false
            ScrollCapture.start(region: region, begin: scroll.begin, autoscroll: scroll.autoscroll) {
                if ownsIcons { DesktopIcons.shared.show() }
            }
        case .timer:
            overlay?.close()
            restoreFocus()
            let screen = NSScreen.withID(region.displayID) ?? .underMouse
            let full = region.rect.size == screen.frame.size
            guard await SelfTimerOverlay.run(seconds: Prefs.int(.selfTimerSeconds), on: screen, highlight: full ? nil : screen.fromDisplayRect(region.rect)) else { return }
            let next = afterTimer == .timer ? .screenshot : afterTimer
            if [.video, .gif, .scroll].contains(next) {
                try await perform(next, region: region, overlay: nil, scroll: scroll)
                return
            }
            let shot = try await CaptureService.shot(of: region, showCursor: Prefs.bool(.screenshotCursor))
            process(shot, action: next, shift: shift)
        default:
            let shot: Shot
            do {
                defer { overlay?.close(); restoreFocus() } // also when the capture throws
                if let overlay, let frozen = overlay.frozenShot(for: region) {
                    shot = frozen
                } else {
                    shot = try await CaptureService.shot(of: region, excludingWindowNumbers: overlay?.windowNumbers ?? [])
                }
            }
            process(shot, action: action, shift: shift)
        }
    }

    /// Window image with the shadow / padding / background options. ⇧ inverts the background choice; when the
    /// background preset will be applied the window stays transparent so the preset supplies the backdrop.
    private func windowShot(_ id: CGWindowID, shift: Bool) async throws -> Shot {
        let shot = try await CaptureService.windowShot(id, shadow: Prefs.bool(.windowShadow))
        if presetApplies(shift: shift) { return shot }
        let transparent = Prefs.bool(.windowBackgroundTransparent) != shift
        let wallpaper = transparent ? nil : await WallpaperProvider.load(for: NSScreen.underMouse)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let padding = Prefs.double(.windowPaddingAmount)
        return await Task.detached(priority: .userInitiated) { shot.composedWindow(padding: padding, background: wallpaper) }.value
    }

    /// The Settings background preset exists, actually draws something, and ⇧ isn't skipping it.
    private func presetApplies(shift: Bool) -> Bool {
        !shift && BackgroundPresets.preset(Prefs.string(.backgroundPresetID))?.settings.isActive == true
    }

    /// Post-processing shared by every still capture (1px border, background preset — ⇧ skips the preset), then delivery.
    func process(_ shot: Shot, action: OverlayAction, shift: Bool) {
        var shot = shot
        if action != .text {
            if Prefs.bool(.addBorder) { shot = shot.bordered() }
            if presetApplies(shift: shift) { shot = BackgroundPresets.applyAutoPreset(shot) }
            if Prefs.bool(.autoRedactAfterCapture) {
                Task { [shot] in deliver(await AutoRedact.afterCapture(shot), action: action) }
                return
            }
        }
        deliver(shot, action: action)
    }

    /// Re-activates the app the user was in before the overlay took focus.
    private func restoreFocus() {
        previousApp?.activate()
        previousApp = nil
    }

    /// App name / window title for the `%a` / `%t` file-name tokens.
    private func setContext(windowID: CGWindowID?) {
        let wins = CaptureService.visibleWindows()
        if let windowID, let w = wins.first(where: { $0.id == windowID }) {
            Exporter.context = CaptureContext(app: w.owner, window: w.title)
            return
        }
        let front = previousApp ?? NSWorkspace.shared.frontmostApplication
        let w = wins.first { $0.pid == front?.processIdentifier }
        Exporter.context = CaptureContext(app: front?.localizedName ?? "", window: w?.title ?? "")
    }

    /// After-capture actions for a still image.
    func deliver(_ shot: Shot, action: OverlayAction) {
        if action == .text {
            recognizeText(in: shot)
            return
        }
        let explicit: [OverlayAction] = [.copy, .save, .annotate, .pin]
        let ignoreAfterCapture = Prefs.d.object(forKey: "ignoreAfterCapture") as? Bool ?? true
        var copy = action == .copy, save = action == .save, annotate = action == .annotate, pin = action == .pin
        var quickAccess = false
        if !explicit.contains(action) || !ignoreAfterCapture {
            quickAccess = Prefs.bool(.afterCaptureQuickAccess)
            copy = copy || Prefs.bool(.afterCaptureCopy)
            save = save || Prefs.bool(.afterCaptureSave)
            annotate = annotate || Prefs.bool(.afterCaptureAnnotate)
            pin = pin || Prefs.bool(.afterCapturePin)
        }
        if !(copy || save || annotate || pin || quickAccess) { copy = true } // something must happen

        // Nothing here waits for encoding: History, the saved file and the clipboard all encode in the background,
        // so the Quick Access card / editor appear immediately.
        Sounds.shutter()
        let historyURL = History.shared.add(shot)
        var savedURL: URL?
        if save {
            var name: String?
            if Prefs.bool(.askForNameAfterCapture) { name = Exporter.askForName(Exporter.fileName(bumpCounter: false)) }
            if !Prefs.bool(.askForNameAfterCapture) || name != nil {
                do { savedURL = try Exporter.saveInBackground(shot, name: name) } catch {
                    Toast.show("Couldn't save: %@".loc(error.localizedDescription), isError: true)
                }
            }
        }
        // Copy after saving so a "file" clipboard entry points at the saved file.
        if copy { Exporter.copy(shot, fileURL: savedURL) }
        if pin { PinWindow.pin(shot) }
        if annotate { AnnotateWindowController.open(shot: shot, fileURL: savedURL) }
        if quickAccess { QuickAccess.shared.add(.image(shot, fileURL: savedURL ?? historyURL, saved: savedURL != nil)) }

        if !quickAccess, !annotate {
            if let savedURL { Toast.show("Saved %@".loc(savedURL.lastPathComponent)) } else if copy { Toast.show("Copied to clipboard") }
        }
    }

    private func recognizeText(in shot: Shot) {
        let lineBreaks = ocrLineBreaks ?? Prefs.bool(.ocrKeepLineBreaks)
        ocrLineBreaks = nil
        Task {
            let result = await TextRecognizer.recognize(shot.image, lineBreaks: lineBreaks)
            OCRResultHUD.show(result)
        }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

extension Shot {
    /// 1px hairline border (the "Add 1px border" option).
    func bordered() -> Shot {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: r)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(r)
        return Shot(image: ctx.makeImage() ?? image, scale: scale)
    }

    /// Window captures with an even transparent margin.
    func padded(_ points: CGFloat = 40) -> Shot { composedWindow(padding: points, background: nil) }
}
