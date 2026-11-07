import AppKit
import AVFoundation
import CoreAudio
import IOKit
import ScreenCaptureKit

/// Screen / GIF / Studio recording: setup bar → countdown → HUD (border, controls, camera, keystrokes, clicks)
/// → SCStream → file → post-processing (audio merge, GIF, Studio package) → after-recording actions.
@MainActor
final class Recorder {
    static let shared = Recorder()

    /// Posted (object: Recorder.shared) when recording starts/stops, pauses/resumes, and once per second of elapsed time.
    static let stateDidChange = Notification.Name("DaisyshotRecorderStateDidChange")

    private(set) var isRecording = false {
        didSet { if oldValue != isRecording { notify() } }
    }
    /// Between the shortcut and the first frame (setup bar, countdown).
    private(set) var isStarting = false
    var isPaused: Bool { timeline.isPaused }
    var elapsed: Double { isRecording ? (timeline.position(Recorder.now) - startTime).seconds : 0 }
    private(set) var mode: RecordingMode = .studio

    private struct Session {
        var region: CaptureRegion
        var mode: RecordingMode
        var screen: NSScreen
        var mic: Bool
        var micUID: String?
        var name: String
        var workDir: URL
        var scale: Double = 1          // video pixels per point
        var device: (id: String, name: String)?   // recording an iPhone / iPad instead of the screen
        var after = "editor"           // editor | quickExport | saveFile | copyFile
    }

    private var session: Session?
    private var output: RecordingOutput?
    private var hud: RecordingHUD?
    private var events: StudioEventLogger?
    private var cameraFile: CameraFileRecorder?
    private var timeline = PauseTimeline()
    /// Recording markers (⌥⇧⌘M or the controls bar's flag), in video time; they go into events.json.
    private var markers: [StudioEventsFile.Event] = []
    private var startTime = CMTime.zero
    private var ticker: Timer?
    private var lastSecond = -1
    private var ticks = 0
    private var hidIcons = false
    private var micObserver: NSObjectProtocol?
    /// Bumped by start/stop/cancel/restart: a `begin()` whose generation went stale throws its stream away.
    private var generation = 0

    private init() {
        #if DEBUG
        Recorder.selfTest()
        #endif
    }

    static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
    static var recordingsFolder: URL {
        let u = Prefs.supportFolder.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// Work directories of running recordings. Anything left here at launch was interrupted (crash, force quit).
    static var inProgressFolder: URL {
        let u = recordingsFolder.appendingPathComponent("InProgress", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// "Remember last selection": the previous recording area, if enabled and its display is still connected.
    static var rememberedRegion: CaptureRegion? {
        guard Prefs.bool(.recRememberArea), let r = Prefs.codable(.recLastArea, CaptureRegion.self), NSScreen.withID(r.displayID) != nil else { return nil }
        return r
    }

    // MARK: Commands

    /// "Start Video Recording" (`gif: false`) / "Start GIF Recording" (`gif: true`): always opens in that mode.
    /// `region` nil = the user picks a display, window or area in the setup first (`source` = which, else the last used).
    /// Every recording is a Studio project — GIF is chosen when exporting — so `gif` (old "Record GIF" entry points) is ignored.
    func start(region: CaptureRegion?, gif: Bool = false, source: RecordingSetup.Source? = nil) async {
        await start(region: region, source: source)
    }

    /// Generic "Record Screen".
    func startUsingLastMode(region: CaptureRegion?) async {
        await start(region: region, source: nil)
    }

    /// Shows the setup for `region` (any area, a window's frame or a whole display), then records.
    private func start(region: CaptureRegion?, source: RecordingSetup.Source?) async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard let setup = await RecordingSetup.run(region: region, source: source) else { return }
        let region = setup.region, mode = setup.mode, device = setup.device
        if Prefs.bool(.recRememberArea), device == nil {
            var area = region
            area.windowID = nil      // remember the area, not a window that may be gone or elsewhere next time
            Prefs.setCodable(area, .recLastArea)
        }
        let screen = NSScreen.withID(region.displayID) ?? .underMouse
        // A device recording has no area on the Mac: the countdown and controls use the whole display.
        let rect = device == nil ? screen.fromDisplayRect(region.rect) : screen.frame

        let mic = mode != .gif && Prefs.bool(.recMicrophone) ? await Self.access(.audio, usage: "NSMicrophoneUsageDescription", name: "Microphone") : false
        // Keystrokes (and Studio key logging) need Accessibility; prompt only when keystrokes are switched on.
        let keys = Prefs.bool(.recShowKeystrokes) && AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if Prefs.bool(.recShowKeystrokes), !keys { Toast.show("Allow Accessibility access to show keystrokes", isError: true) }
        guard Self.preflight(mode: mode, mic: mic, camera: setup.webcam != nil, device: device != nil) else { setup.webcam?.stop(); return }
        if Prefs.bool(.recCountdown) {
            guard await Countdown.run(seconds: max(1, Prefs.int(.recCountdownSeconds)), on: screen, in: rect) else { setup.webcam?.stop(); return }
        }
        // "Hide desktop icons while capturing": a temporary hide (not persisted), restored in teardown.
        // Icons the user hid on purpose (persisted) stay hidden afterwards.
        if Prefs.bool(.hideIconsWhileCapturing), !Prefs.bool(.desktopIconsHidden) {
            hidIcons = true
            if !DesktopIcons.shared.isHidden {
                DesktopIcons.shared.hide(persist: false)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        let work = Self.inProgressFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let micID = Self.micID
        session = Session(region: region, mode: mode, screen: screen, mic: mic,
                          micUID: mic ? (micID.isEmpty ? AVCaptureDevice.default(for: .audio)?.uniqueID : micID) : nil,
                          name: Exporter.fileName(type: mode == .gif ? "GIF" : "Recording"), workDir: work, device: device, after: setup.after)
        self.mode = mode
        let hud = RecordingHUD(screen: screen, rect: rect, mic: mic, webcam: setup.webcam,
                               keystrokes: keys && mode != .studio, clicks: Prefs.bool(.recHighlightClicks) && mode != .studio, studio: mode == .studio,
                               followsWindow: mode == .studio && (region.windowID != nil || device != nil))
        self.hud = hud
        hud.show()
        generation += 1
        let gen = generation
        do {
            try await begin(gen)
            isRecording = true
            if mic { watchMic() }
            startTicker()
            Sounds.start()
        } catch {
            teardown()
            hud.webcam?.stop()
            try? FileManager.default.removeItem(at: work)
            session = nil
            Toast.show(error.localizedDescription, isError: true)
        }
    }

    func stop() {
        guard isRecording, let s = session else { return }
        generation += 1
        let out = output, stopAt = Recorder.now, duration = elapsed
        let pauses = timeline, eventsZero = startTime
        let log = events?.log, shapes = events?.shapes, marks = markers
        events?.stop()
        let cam = cameraFile, webcam = hud?.webcam
        output = nil
        events = nil
        cameraFile = nil
        session = nil
        teardown()
        Sounds.stop()
        guard let out else {
            // Stopped while a restart was still setting up the new stream: nothing was recorded since the restart.
            webcam?.stop()
            Task {
                await cam?.stop()
                try? FileManager.default.removeItem(at: s.workDir)
            }
            return
        }
        Self.setBusy(true)   // quit waits for this to clear before terminating
        Task {
            defer { Self.setBusy(false) }
            do {
                try await out.finish(at: stopAt)
                await cam?.stop()
                webcam?.stop()
                // Events were timed from when capture started, the camera file from its own first frame; the video
                // starts at its first frame. Re-base both on that.
                let zero = out.sessionStart ?? eventsZero
                let sync = StudioSync(eventShift: (eventsZero - zero).seconds,
                                      cameraOffset: cam?.startTime.map { (pauses.position($0) - zero).seconds })
                try? shapes?.write(to: s.workDir)     // without them the editor draws the arrow everywhere, as before
                try await finish(s, video: out.url, audioTracks: out.audioTrackCount, log: log, markers: marks, duration: duration, sync: sync)
            } catch {
                // Never delete the only copy: whatever footage exists is moved to the Recordings folder.
                await cam?.stop()
                webcam?.stop()
                let kept = await Self.salvage(s.workDir, name: s.name)
                if kept.isEmpty {
                    Toast.show("Recording failed: %@".loc(error.localizedDescription), isError: true, seconds: 4)
                } else {
                    Toast.show("Recording failed: %@ — the footage was kept".loc(error.localizedDescription), isError: true, seconds: 5)
                    if !kept.contains(where: \.playable) { NSWorkspace.shared.activateFileViewerSelecting(kept.map(\.url)) }
                }
            }
        }
    }

    /// Discards the recording.
    func cancel() {
        guard isRecording, let s = session else { return }
        generation += 1
        let out = output, cam = cameraFile, webcam = hud?.webcam
        events?.stop()
        output = nil
        events = nil
        cameraFile = nil
        session = nil
        teardown()
        Task {
            await out?.discard()
            await cam?.stop()
            webcam?.stop()
            try? FileManager.default.removeItem(at: s.workDir)
        }
    }

    func togglePause() {
        guard isRecording, let output else { return }
        if timeline.isPaused {
            timeline.resume(at: Recorder.now)
            cameraFile?.resume()
        } else {
            timeline.pause(at: Recorder.now)
            cameraFile?.pause()
        }
        output.setTimeline(timeline)
        hud?.model.paused = timeline.isPaused
        notify()
    }

    func toggleMic() {
        guard let output, let hud, hud.model.hasMic else { return }
        hud.model.micMuted.toggle()
        output.setMicMuted(hud.model.micMuted)
    }

    /// Throws away what was recorded so far and starts again with the same area and options.
    func restart() {
        guard isRecording, let old = output else { return }
        generation += 1
        let gen = generation
        output = nil
        events?.stop()
        events = nil
        let cam = cameraFile
        cameraFile = nil
        Task {
            await old.discard()
            await cam?.stop()
            do { try await begin(gen) } catch {
                guard gen == generation else { return }     // stopped/cancelled meanwhile: already cleaned up
                generation += 1
                let s = session, webcam = hud?.webcam
                session = nil
                teardown()
                webcam?.stop()
                if let s { try? FileManager.default.removeItem(at: s.workDir) }
                Toast.show(error.localizedDescription, isError: true)
            }
            notify()
        }
    }

    /// Controls-bar restart/trash ask first, pausing while the question is up.
    func confirmRestart() {
        if confirm("Restart recording?", "Discard this recording and start over?", action: "Restart") { restart() }
    }

    func confirmCancel() {
        if confirm("Delete recording?", "Move this recording to the Trash?", action: "Delete") { cancel() }
    }

    private func confirm(_ title: String, _ text: String, action: String, other: String = "Continue Recording") -> Bool {
        guard isRecording else { return false }
        let wasPaused = isPaused
        if !wasPaused { togglePause() }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.addButton(withTitle: action)
        a.addButton(withTitle: other)
        a.localize()
        // The alert is modal: hidden behind another app's windows (macOS may not activate us) it would block the controls
        // bar and the menu bar icon, leaving the recording paused with nothing to click. Keep it above everything.
        a.window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        a.window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
        NSApp.activate(ignoringOtherApps: true)
        let ok = a.runModal() == .alertFirstButtonReturn
        if !ok, !wasPaused, isRecording, isPaused { togglePause() }
        return ok
    }

    /// Flags this moment for the editor's timeline.
    func addMarker() {
        guard isRecording, !isPaused else { return }
        let t = (timeline.position(Recorder.now) - startTime).seconds
        markers.append(.init(t: (t * 1000).rounded() / 1000, type: "marker", x: 0, y: 0))
        Toast.show("Marker %d".loc(markers.count))
    }

    /// Shortcut "Show / Hide Recording Controls".
    func toggleControls() { hud?.toggleControls() }

    /// Shortcut "Toggle Camera Fullscreen".
    func toggleCameraFullscreen() {
        hud?.webcam?.toggleFullscreen()
    }

    // MARK: Microphone safety

    private func watchMic() {
        micObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { n in
            let id = (n.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated { Recorder.shared.deviceDisconnected(id) }
        }
    }

    private func deviceDisconnected(_ id: String?) {
        guard isRecording, let s = session, let id, id == s.micUID, hud?.model.micMuted == false else { return }
        if confirm("Microphone disconnected", "The microphone used for this recording was disconnected.",
                   action: "Stop Recording", other: "Continue Without Audio") {
            stop()
        } else if isRecording, hud?.model.micMuted == false {
            toggleMic()     // the microphone track continues as silence
        }
    }

    // MARK: Crash recovery

    /// Called once at launch: work directories left over from a previous run (crash, force quit) are salvaged —
    /// playable movies go to Quick Access, empty leftovers are removed.
    func recoverInterruptedRecordings() {
        let fm = FileManager.default
        var dirs = (try? fm.contentsOfDirectory(at: Self.inProgressFolder, includingPropertiesForKeys: nil)) ?? []
        // Older builds kept work directories in the temporary folder.
        dirs += ((try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Daisyshot-") }
        dirs.removeAll { $0.standardizedFileURL == session?.workDir.standardizedFileURL }
        Self.pruneGIFSources()
        // Leftovers without footage just go.
        dirs.removeAll { d in
            guard !Self.hasFootage(d) else { return false }
            try? fm.removeItem(at: d)
            return true
        }
        guard !dirs.isEmpty else { return }
        let a = NSAlert()
        a.messageText = dirs.count == 1 ? "Recover the unfinished recording?".loc : "Recover %d unfinished recordings?".loc(dirs.count)
        a.informativeText = "Daisyshot quit while recording. Studio recordings come back as projects you can edit."
        a.addButton(withTitle: "Recover")
        a.addButton(withTitle: "Delete")
        a.buttons[1].hasDestructiveAction = true
        a.localize()
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else {
            dirs.forEach { try? fm.removeItem(at: $0) }
            return
        }
        Task { for d in dirs { await Self.recover(d) } }
    }

    /// One interrupted work directory: an editable Studio project when it has a playable video and an event log
    /// (opened in the editor), otherwise its movies are salvaged.
    static func recover(_ dir: URL) async {
        let date = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        let name = Exporter.fileName(type: "Recording", date: date, bumpCounter: false)
        let fm = FileManager.default
        let video = dir.appendingPathComponent(StudioCaptureLayout.video)
        if fm.fileExists(atPath: dir.appendingPathComponent(StudioCaptureLayout.events).path), fm.fileExists(atPath: video.path) {
            let asset = AVURLAsset(url: video)
            let playable = (try? await asset.load(.isPlayable)) ?? false
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            if playable, seconds > 0 {
                let cam = dir.appendingPathComponent(StudioCaptureLayout.camera)
                if ((try? fm.attributesOfItem(atPath: cam.path))?[.size] as? Int ?? 0) == 0 { try? fm.removeItem(at: cam) }
                if let project = try? StudioProjects.store(dir, name: name) {
                    Toast.show("Recovered an unfinished recording")
                    VideoEditor.open(project)
                    return
                }
            }
        }
        let kept = await salvage(dir, name: name)
        let n = kept.filter(\.playable).count
        if n > 0 { Toast.show(n == 1 ? "Recovered an unfinished recording" : "Recovered %d unfinished recordings".loc(n)) }
        else if kept.isEmpty { Toast.show("Nothing could be recovered from that folder", isError: true) }
    }

    /// Settings › Advanced: pick a work folder (they're kept in Application Support › Daisyshot › In Progress) and recover it.
    static func recoverFromFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = inProgressFolder
        p.message = "Choose the folder of an unfinished recording.".loc
        p.prompt = "Recover".loc
        guard p.runModal() == .OK, let dir = p.url else { return }
        Task { await recover(dir) }
    }

    private static func hasFootage(_ dir: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        return files.contains { ["mp4", "mov"].contains($0.pathExtension.lowercased()) && ((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 }
    }

    /// GIF source videos (kept for re-editing a GIF) are deleted after 30 days.
    private static func pruneGIFSources() {
        let fm = FileManager.default
        let dir = gifSourceURL(for: URL(fileURLWithPath: "x.gif")).deletingLastPathComponent()
        let old = Date().addingTimeInterval(-30 * 86400)
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture) < old {
            try? fm.removeItem(at: f)
        }
    }

    /// Moves every non-empty movie in `dir` to the Recordings folder (footage is never deleted), shows playable ones
    /// in Quick Access, and removes `dir` once no footage is left in it.
    private static func salvage(_ dir: URL, name: String) async -> [(url: URL, playable: Bool)] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)) ?? []
        var kept: [(url: URL, playable: Bool)] = []
        var stuck = false
        for f in files where ["mp4", "mov"].contains(f.pathExtension.lowercased()) {
            guard ((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 else { continue }
            let suffix = f.lastPathComponent == StudioCaptureLayout.camera ? " (Camera)" : ""
            let dst = Exporter.uniqueURL(in: recordingsFolder, name: name + suffix, ext: f.pathExtension)
            do { try move(f, to: dst) } catch { stuck = true; continue }
            let asset = AVURLAsset(url: dst)
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            let playable = isPlayable && seconds > 0
            if playable { QuickAccess.shared.add(.video(dst, saved: false)) }
            kept.append((dst, playable))
        }
        if !stuck { try? fm.removeItem(at: dir) }
        return kept
    }

    /// `moveItem`, falling back to copy + delete (a plain move can fail across volumes).
    static func move(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        do { try fm.moveItem(at: src, to: dst) } catch {
            try fm.copyItem(at: src, to: dst)
            try? fm.removeItem(at: src)
        }
    }

    private static func setBusy(_ busy: Bool) {
        NotificationCenter.default.post(name: .daisyshotBusyDidChange, object: busy)
    }

    // MARK: Internals

    /// Builds and starts the stream for the current session. Returns early (discarding anything it started) when
    /// `gen` went stale during an await — e.g. stop() during a restart — so no invisible stream keeps recording.
    private func begin(_ gen: Int) async throws {
        guard gen == generation, var s = session, let hud else { throw CancellationError() }
        if let d = s.device {
            guard let dev = AVCaptureDevice(uniqueID: d.id) else { throw StreamRecorder.Failure(errorDescription: "The device was disconnected.") }
            let out = try DeviceRecorder(url: s.workDir.appendingPathComponent(StudioCaptureLayout.video), device: dev,
                                         deviceAudio: Prefs.bool(.recDeviceAudio), micDeviceID: s.mic ? Self.micID : nil,
                                         fps: Prefs.int(.recFPS), quality: Prefs.string(.recQuality))
            // Events (none: there's no pointer) are in the device's pixels.
            s.region.rect = CGRect(origin: .zero, size: IOSDevices.pixelSize(dev) ?? CGSize(width: 1, height: 1))
            s.scale = 1
            try await started(out, gen, s, hud)
            return
        }
        let content = try await CaptureService.content()
        guard gen == generation, session != nil else { throw CancellationError() }
        let display = try CaptureService.display(s.region.displayID, in: content)
        let window = s.region.windowID.flatMap { id in content.windows.first { $0.windowID == id } }
        // Studio follows a window wherever it moves (cursor, keys and camera are drawn later); videos and GIFs keep the
        // area but show only that window (plus the wallpaper and our click / keystroke / camera overlays), so other
        // windows can't cover it.
        let follow = s.mode == .studio ? window : nil
        let filter = if let follow {
            SCContentFilter(desktopIndependentWindow: follow)
        } else if let window {
            SCContentFilter(display: display, including: [window] + content.windows.filter { w in
                hud.recordedWindowNumbers.contains(Int(w.windowID))
                    || (w.owningApplication?.bundleIdentifier == "com.apple.dock" && (w.title ?? "").hasPrefix("Wallpaper"))
            })
        } else {
            Self.filter(display: display, content: content, recording: hud.recordedWindowNumbers)
        }
        if let follow { s.region.rect.size = follow.frame.size }

        var scale = Prefs.bool(.recDownscaleRetina) ? 1 : CGFloat(filter.pointPixelScale)
        var resolution = VideoResolution(rawValue: Prefs.int(.recMaxResolution)) ?? .original
        if s.mode == .gif {
            // No point capturing more pixels than the GIF keeps.
            scale = min(scale, CGFloat(max(16, Prefs.int(.recGIFMaxWidth))) / max(1, s.region.rect.width))
            resolution = .original
        }
        let size = resolution.fit(points: s.region.rect.size, scale: scale)
        s.scale = Double(size.width) / max(1, s.region.rect.width)
        let url = s.workDir.appendingPathComponent(s.mode == .studio ? StudioCaptureLayout.video : "recording.mp4")
        try? FileManager.default.removeItem(at: url)

        // "System audio from selected apps": a separate audio-only filter over just those apps.
        var audioFilter: SCContentFilter?
        let apps = Prefs.string(.recSystemAudioApps).split(separator: "\n").map(String.init)
        if s.mode != .gif, Prefs.bool(.recSystemAudio), !apps.isEmpty {
            let chosen = content.applications.filter { apps.contains($0.bundleIdentifier) }
            if chosen.isEmpty {
                Toast.show("None of the chosen apps is running — recording sound from all apps", isError: true, seconds: 3)
            } else {
                audioFilter = SCContentFilter(display: display, including: chosen, exceptingWindows: [])
            }
        }
        let out = try StreamRecorder(url: url, filter: filter, audioFilter: audioFilter, config: .init(
            sourceRect: follow == nil ? s.region.rect : nil, width: size.width, height: size.height,
            fps: s.mode == .gif ? Prefs.int(.recGIFFPS) : Prefs.int(.recFPS),
            showsCursor: s.mode != .studio && Prefs.bool(.recShowCursor),
            systemAudio: s.mode != .gif && Prefs.bool(.recSystemAudio),
            micDeviceID: s.mic ? Self.micID : nil,
            mono: Prefs.bool(.recMono),
            quality: Prefs.string(.recQuality)))
        try await started(out, gen, s, hud, follow: follow)
    }

    /// Starts `out` and makes it the live recording (unless `gen` went stale meanwhile); Studio logging and the camera
    /// file start with it.
    private func started(_ out: RecordingOutput, _ gen: Int, _ s: Session, _ hud: RecordingHUD, follow: SCWindow? = nil) async throws {
        out.onStop = { [weak out] error in
            Task { @MainActor in
                // Only the live stream may stop the recording (not one already discarded by a restart).
                guard let out, Recorder.shared.output === out else { return }
                Toast.show("Recording stopped: %@".loc(error.localizedDescription), isError: true)
                Recorder.shared.stop()
            }
        }
        out.onMicSilence = {
            Task { @MainActor in Toast.show("The microphone isn't picking up any sound — check the input device", isError: true, seconds: 4) }
        }
        try await out.start()
        guard gen == generation, session != nil else {
            await out.discard()
            throw CancellationError()
        }
        timeline = PauseTimeline()
        startTime = Recorder.now
        markers = []
        output = out
        session = s
        hud.model.paused = false
        hud.model.micMuted = false

        if s.mode == .studio {
            if s.device == nil {     // a device has no pointer or keys to log
                let log = StudioEventLogger(region: s.region.rect, screen: s.screen, window: follow.map { ($0.windowID, s.region.displayID) }) { [weak self] in
                    guard let self, self.isRecording || self.output != nil, !self.isPaused else { return nil }
                    return (self.timeline.position(Recorder.now) - self.startTime).seconds
                }
                log.start()
                events = log
            }
            if let cam = hud.webcam, let rec = CameraFileRecorder(session: cam.session) {
                rec.start(to: s.workDir.appendingPathComponent(StudioCaptureLayout.camera))
                cameraFile = rec
            }
        }
    }

    /// Every window of ours is left out of the video — also ones opened later (toasts, Quick Access, editors) — except
    /// the ones `CaptureService.ownWindowsToExclude` keeps (pins, desktop-icon covers) and `recording` (camera bubble,
    /// click and keystroke overlays).
    private static func filter(display: SCDisplay, content: SCShareableContent, recording: [Int]) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let excluded = CaptureService.ownWindowsToExclude(in: content, keeping: recording)
        guard let me = content.applications.first(where: { $0.processID == pid }) else {
            return SCContentFilter(display: display, excludingWindows: excluded)
        }
        let ids = Set(excluded.map(\.windowID))
        let excepted = content.windows.filter { $0.owningApplication?.processID == pid && !ids.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: excepted)
    }

    private func teardown() {
        ticker?.invalidate()
        ticker = nil
        hud?.close()
        hud = nil
        if let micObserver { NotificationCenter.default.removeObserver(micObserver) }
        micObserver = nil
        if hidIcons { DesktopIcons.shared.show(); hidIcons = false }
        isRecording = false
    }

    private func startTicker() {
        lastSecond = -1
        ticks = 0
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { Recorder.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let e = elapsed
        // The HUD shows whole seconds: publish only when that changes (not 4×/s).
        if let m = hud?.model, Int(m.elapsed) != Int(e) { m.elapsed = e }
        if Int(e) != lastSecond { lastSecond = Int(e); notify() }
        ticks += 1
        // Studio: the pointer log so far, every 5 s, so a crash still leaves an editable project.
        if ticks % 20 == 0, let s = session, s.mode == .studio, s.device == nil, let log = events?.log {
            let r = s.region.rect
            try? StudioEventsFile(region: .init(x: r.minX, y: r.minY, width: r.width, height: r.height), scale: s.scale, duration: e,
                                  events: (log.events + markers).sorted { $0.t < $1.t })
                .write(to: s.workDir.appendingPathComponent(StudioCaptureLayout.events))
        }
        if ticks % 40 == 0, Prefs.bool(.recWarnLowDisk), let free = Self.freeDiskSpace(), free < 400_000_000 {
            Toast.show("Disk almost full — recording stopped and saved", isError: true, seconds: 4)
            stop()
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Recorder.stateDidChange, object: self)
    }

    private static func freeDiskSpace() -> Int64? {
        (try? inProgressFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Post-processing & delivery

    /// Throws only while the footage is still in the work directory (the caller then salvages it).
    private func finish(_ s: Session, video: URL, audioTracks: Int, log: StudioEventLog?, markers: [StudioEventsFile.Event],
                        duration: Double, sync: StudioSync) async throws {
        let fm = FileManager.default
        let merged = audioTracks > 1 && Prefs.bool(.recMergeAudio)
        if merged {
            Self.setBusy(true)
            do { try await AudioMixer.mergeAudioTracks(of: video, mono: Prefs.bool(.recMono)) } catch {
                Toast.show("Kept separate audio tracks: %@".loc(error.localizedDescription), isError: true)
            }
            Self.setBusy(false)
        }
        switch s.mode {
        case .studio:
            // Studio: what the Start card's "Then:" says (editor, Quick Export, or an automatic MP4).
            let r = s.region.rect
            try StudioEventsFile(region: .init(x: r.minX, y: r.minY, width: r.width, height: r.height), scale: s.scale,
                             duration: max(0, duration + sync.eventShift), events: sync.rebase(((log?.events ?? []) + markers).sorted { $0.t < $1.t }),
                             audioTracks: audioTracks > 1 && !merged ? [s.device == nil ? "system" : "device", "mic"] : nil,
                             cameraOffset: sync.cameraOffset.map { ($0 * 1000).rounded() / 1000 }, device: s.device?.name)
                .write(to: s.workDir.appendingPathComponent(StudioCaptureLayout.events))
            let cam = s.workDir.appendingPathComponent(StudioCaptureLayout.camera)
            if let size = (try? fm.attributesOfItem(atPath: cam.path))?[.size] as? Int, size > 0 {} else { try? fm.removeItem(at: cam) }
            let project = try StudioProjects.store(s.workDir, name: s.name)
            Sounds.done()
            switch s.after {
            case "quickExport": StudioQuickExport.show(project)
            case "saveFile": StudioQuickExport.show(project, export: .mp4)
            case "copyFile": StudioQuickExport.show(project, export: .mp4, copy: true)
            default: VideoEditor.open(project)
            }
        case .gif:
            let gif = s.workDir.appendingPathComponent("recording.gif")
            if await makeGIF(from: video, to: gif) {
                let shown = try deliver(gif, kind: "gif", name: s.name)
                // Keep the source video so the video editor can re-edit / re-export this GIF.
                let source = Recorder.gifSourceURL(for: shown)
                try? fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: source)
                try? Self.move(video, to: source)
            } else {
                try deliver(video, kind: "video", name: s.name)
            }
            try? fm.removeItem(at: s.workDir)
        }
    }

    /// Converts with a progress panel. Returns false when the GIF failed or was cancelled (the caller delivers the video).
    private func makeGIF(from video: URL, to gif: URL) async -> Bool {
        let fps = Prefs.int(.recGIFFPS), width = Prefs.int(.recGIFMaxWidth), quality = Prefs.int(.recGIFQuality), optimize = Prefs.bool(.recGIFOptimize)
        let panel = ProgressPanel(title: "Creating GIF…")
        let model = panel.model
        let task = Task {
            try await GIFEncoder.convert(video, to: gif, fps: fps, maxWidth: width, quality: quality, optimize: optimize) { p in
                Task { @MainActor in model.progress = max(model.progress, p) }
            }
        }
        panel.onCancel = { task.cancel() }
        panel.show()
        Self.setBusy(true)
        defer {
            panel.close()
            Self.setBusy(false)
        }
        do {
            try await task.value
            return true
        } catch is CancellationError {
            Toast.show("GIF cancelled — saved the video instead")
        } catch {
            Toast.show("GIF failed (%@) — saved as video instead".loc(error.localizedDescription), isError: true, seconds: 4)
        }
        return false
    }

    /// Hands a finished file over: moved into History (the single copy) or, with History off, kept in the Recordings
    /// folder; then the After-Recording actions. Returns the URL shown to the user (the saved file when saved).
    /// Throws only when the file couldn't be moved at all (it is then still at `recorded`).
    @discardableResult
    private func deliver(_ recorded: URL, kind: String, name: String) throws -> URL {
        let fm = FileManager.default
        let named = Exporter.uniqueURL(in: Recorder.recordingsFolder, name: name, ext: recorded.pathExtension)
        try Self.move(recorded, to: named)
        let historyURL = History.shared.addFile(named, kind: kind, move: true)
        var file = historyURL ?? named
        Sounds.done()

        var saved = false
        if Prefs.bool(.afterRecordingSave) {
            let saveName = Prefs.bool(.askForNameAfterCapture) ? Exporter.askForName(name) : name
            if let saveName {
                let dst = Exporter.uniqueURL(in: Prefs.exportFolder, name: saveName, ext: file.pathExtension)
                do {
                    try fm.createDirectory(at: Prefs.exportFolder, withIntermediateDirectories: true)
                    // Without History the Recordings copy would be left behind: move it instead of copying.
                    if historyURL == nil { try Self.move(file, to: dst) } else { try fm.copyItem(at: file, to: dst) }
                    file = dst
                    saved = true
                } catch {
                    Toast.show("Couldn't save: %@".loc(error.localizedDescription), isError: true)
                }
            }
        }
        if Prefs.bool(.afterRecordingCopy) { Exporter.copyFile(file) }
        let openEditor = Prefs.bool(.afterRecordingOpenEditor) && kind == "video"
        if openEditor { VideoEditor.open(file) }
        if Prefs.bool(.afterRecordingQuickAccess) {
            QuickAccess.shared.add(.video(file, saved: saved))
        } else if !openEditor, !saved, !Prefs.bool(.afterRecordingCopy) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else if !openEditor {
            Toast.show(saved ? "Saved to %@".loc(file.deletingLastPathComponent().lastPathComponent) : "Copied to clipboard")
        }
        return file
    }

    /// Camera/mic permission. Without the usage string in Info.plist the request would crash the app, so check it first.
    /// The chosen microphone, or "" (the default) when it isn't connected any more.
    static var micID: String {
        let id = Prefs.string(.recMicDeviceID)
        return id.isEmpty || AVCaptureDevice(uniqueID: id) != nil ? id : ""
    }

    /// Things that spoil a recording, said before it starts (each "Don't show again"). False: the user went back.
    private static func preflight(mode: RecordingMode, mic: Bool, camera: Bool, device: Bool) -> Bool {
        var checks: [(id: String, title: String, info: String)] = []
        let chosenMic = Prefs.string(.recMicDeviceID), chosenCamera = Prefs.string(.recCameraDeviceID)
        if mic, !chosenMic.isEmpty, AVCaptureDevice(uniqueID: chosenMic) == nil {
            checks.append(("recMicMissing", "The microphone you chose isn't connected", "The recording uses the default microphone instead."))
        }
        if camera, !chosenCamera.isEmpty, AVCaptureDevice(uniqueID: chosenCamera) == nil {
            checks.append(("recCameraMissing", "The camera you chose isn't connected", "The recording uses the default camera instead."))
        }
        if camera, !mic {
            checks.append(("recCameraNoMic", "The camera is on but the microphone is off",
                           "The recording will show you without your voice. Turn the microphone on in the bar if you want to be heard."))
        }
        if mic, isLidClosed, usesBuiltInMic {
            checks.append(("recLidClosedMic", "The lid is closed",
                           "The built-in microphone is muffled with the lid closed. Pick another microphone in the bar, or open the lid."))
        }
        if mode == .studio, !device, systemCursorSize > 1.05 {
            checks.append(("recCursorSize", "macOS uses a larger pointer",
                           "Studio draws its own pointer at the standard size, so it won't match what you see. Pointer size is in System Settings › Accessibility › Display."))
        }
        // Studio logs keys through Accessibility: without it no typing is found (Speed Up Typing) and no shortcuts show.
        if mode == .studio, !device, !Permissions.accessibility, !Warnings.isSuppressed("recNoAccessibility") {
            let a = NSAlert()
            a.messageText = "Daisyshot can't see your keystrokes"
            a.informativeText = "Without Accessibility access, typing isn't detected (no Speed Up Typing) and shortcuts don't show in the video. Allow Daisyshot in System Settings › Privacy & Security › Accessibility (if it's already on, turn it off and on again)."
            a.addButton(withTitle: "Open Settings")
            a.addButton(withTitle: "Record Anyway")
            a.addButton(withTitle: "Cancel")
            switch Warnings.run("recNoAccessibility", a) {
            case .alertFirstButtonReturn: Permissions.open(.accessibility); return false
            case .alertSecondButtonReturn: break
            default: return false
            }
        }
        for c in checks {
            let a = NSAlert()
            a.messageText = c.title
            a.informativeText = c.info
            a.addButton(withTitle: "Record Anyway")
            a.addButton(withTitle: "Cancel")
            guard Warnings.run(c.id, a) == .alertFirstButtonReturn else { return false }
        }
        return true
    }

    private static var isLidClosed: Bool {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain")
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    private static var usesBuiltInMic: Bool {
        let id = Self.micID
        let dev = id.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: id)
        return dev?.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn)
    }

    /// Accessibility › Display › Pointer size (1 = standard).
    private static var systemCursorSize: Double {
        UserDefaults(suiteName: "com.apple.universalaccess")?.double(forKey: "mouseDriverCursorSize") ?? 1
    }

    static func access(_ type: AVMediaType, usage: String, name: String) async -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: usage) != nil else {
            Toast.show("%@ unavailable: app bundle lacks %@".loc(name.loc, usage), isError: true)
            return false
        }
        let ok = await AVCaptureDevice.requestAccess(for: type)
        if !ok { Toast.show("%@ access denied — enable it in System Settings › Privacy & Security".loc(name.loc), isError: true) }
        return ok
    }

    // MARK: Self-check

    static func selfTest() {
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 1000) }
        var tl = PauseTimeline()
        assert(tl.map(t(5)) == t(5))
        tl.pause(at: t(10))
        assert(tl.isPaused && tl.map(t(12)) == nil && tl.position(t(12)) == t(10))
        tl.resume(at: t(15))
        assert(tl.map(t(14.9)) == nil, "samples captured during the pause are dropped")
        assert(tl.map(t(15)) == t(10) && tl.map(t(20)) == t(15), "later samples shift back by the pause length")
        tl.pause(at: t(30)); tl.resume(at: t(31))
        assert(tl.map(t(40)) == t(34) && tl.map(t(9)) == t(9))

        // Areas saved before window recording existed still load (no window).
        let old = try? JSONDecoder().decode(CaptureRegion.self, from: Data(#"{"displayID":1,"rect":[[10,20],[300,200]]}"#.utf8))
        assert(old?.rect == CGRect(x: 10, y: 20, width: 300, height: 200) && old?.windowID == nil)
        // Replacing a file leaves no "<name>.sb-…" backup behind.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-replace-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let video = dir.appendingPathComponent("video.mp4"), merged = dir.appendingPathComponent(".merge.mp4")
        try? Data("old".utf8).write(to: video); try? Data("new".utf8).write(to: merged)
        try? Data("stale".utf8).write(to: dir.appendingPathComponent("video.mp4.sb-1234-abcd"))
        try? FileManager.default.replaceRemovingBackup(video, with: merged)
        assert((try? String(contentsOf: video, encoding: .utf8)) == "new" && (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) == ["video.mp4"])
        try? FileManager.default.removeItem(at: dir)
        assert(StudioSync(eventShift: 0.05).rebase([.init(t: 1, type: "move", x: 0, y: 0)])[0].t == 1.05)
        GIFEncoder.selfTest()
        KeystrokeFormatter.selfTest()
        RecordingSizePreset.selfTest()
        StudioEventsFile.selfTest()
        CursorShapeRecorder.selfTest()
    }
}

/// Studio timing fix-ups, in seconds: events and the camera file re-based on the video's first frame.
struct StudioSync {
    var eventShift = 0.0
    var cameraOffset: Double?

    func rebase(_ events: [StudioEventsFile.Event]) -> [StudioEventsFile.Event] {
        guard eventShift != 0 else { return events }
        return events.map { e in
            var e = e
            e.t = max(0, ((e.t + eventShift) * 1000).rounded() / 1000)
            return e
        }
    }
}

/// Pause bookkeeping in capture-clock time: samples inside a pause are dropped, later ones shift back by the paused total.
struct PauseTimeline {
    private var gaps: [(start: CMTime, end: CMTime?)] = []

    var isPaused: Bool { gaps.last.map { $0.end == nil } ?? false }

    mutating func pause(at t: CMTime) { if !isPaused { gaps.append((t, nil)) } }
    mutating func resume(at t: CMTime) { if isPaused { gaps[gaps.count - 1].end = max(t, gaps[gaps.count - 1].start) } }

    /// Output time for a sample captured at `t`, or nil if it was captured while paused.
    func map(_ t: CMTime) -> CMTime? {
        let r = resolve(t)
        return r.paused ? nil : r.time
    }

    /// Output time reached at `t` (frozen at the pause point while paused).
    func position(_ t: CMTime) -> CMTime { resolve(t).time }

    private func resolve(_ t: CMTime) -> (time: CMTime, paused: Bool) {
        var offset = CMTime.zero
        for g in gaps where g.start <= t {
            guard let end = g.end, end <= t else { return (g.start - offset, true) }
            offset = offset + (end - g.start)
        }
        return (t - offset, false)
    }
}
