import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()
    private var shownState: (recording: Bool, paused: Bool, time: String, busy: Bool)?
    /// Runs only while recording, so the elapsed time ticks even if the recorder posts less often.
    private var elapsedTimer: Timer?
    /// Nesting count of `.daisyshotBusyDidChange` (true +1, false −1); > 0 animates the menu bar glyph.
    private var busyCount = 0
    private var busyTimer: Timer?
    /// Set when any busy notification arrives; lets quit tell "still post-processing" from "recorder never reports busy".
    private var sawBusy = false

    func applicationDidFinishLaunching(_ n: Notification) {
        // Tooltips (`.help`) appear after 0.5 s instead of AppKit's ~1 s. Registered, so a user override still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
        #if DEBUG
        URLCommand.selfTest()
        if ProcessInfo.processInfo.environment["DAISYSHOT_SELFTEST"] != nil {
            setvbuf(stdout, nil, _IOLBF, 0)     // a line at a time, also into a pipe (CI shows where it stopped)
            Task { @MainActor in
                let tests: [(String, () -> Void)] = [
                    ("URLCommand", URLCommand.selfTest), ("Exporter", Exporter.selfTest), ("SelectionGeometry", SelectionGeometry.selfTest),
                    ("TextRecognizer", TextRecognizer.selfTest), ("QuickAccess", QuickAccess.selfTest), ("WallpaperProvider", WallpaperProvider.selfTest),
                    ("MediaInfo", MediaInfo.selfTest), ("HistorySearch", HistorySearch.selfTest), ("Geo", Geo.selfTest),
                    ("ImageAnalysis", ImageAnalysis.selfTest), ("AnnotateEditor", AnnotateEditor.selfTest),
                    ("Recorder+GIF+Keystroke+SizePreset+StudioEvents", Recorder.selfTest), ("StudioDocument", StudioDocument.selfTest),
                    ("StudioTracks", StudioTracks.selfTest), ("StudioMaskFinder", StudioMaskFinder.selfTest), ("MacWallpapers", MacWallpapers.selfTest), ("StudioPresets", StudioPresets.selfTest), ("SpeakerNotes", SpeakerNotes.selfTest), ("Updater", Updater.selfTest),
                ]
                for (name, run) in tests { print("RUN \(name)"); run(); print("PASS \(name)") }
                /// One async check; a watchdog names it and stops the run if it hangs (CI shows where).
                func check(_ name: String, _ run: () async -> String?) async {
                    print("RUN \(name)")
                    let watchdog = DispatchWorkItem { print("FAIL \(name) timed out after 180 s"); exit(1) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: watchdog)
                    let r = await run()
                    watchdog.cancel()
                    print(r == nil ? "PASS \(name)" : "FAIL \(name) \(r!)")
                }
                await check("SensitiveMatcher") { let m = SensitiveScanner.matcherSelfTest(); return m.isEmpty ? nil : "\(m)" }
                await check("SensitiveScanner OCR") { let o = await SensitiveScanner.ocrSelfTest(); return o.isEmpty ? nil : "\(o)" }
                await check("Stitch") { await Task.detached { Stitch.selfTest() }.value }
                await check("StudioComposition") { await StudioComposer.compositionSelfTest() }
                await check("StudioMaskFinder OCR") { await StudioMaskFinder.ocrSelfTest() }
                await check("StudioAudio") { await StudioAudioFX.selfTest() }
                await check("SampleWriter") { await SampleWriter.selfTest() }
                await check("StudioProjects") { await StudioProjects.selfTest() }
                exit(0)
            }
            return
        }
        if ProcessInfo.processInfo.environment["DAISYSHOT_STUDIO_BENCH"] != nil { DebugSnap.studioBench(); return }
        if ProcessInfo.processInfo.environment["DAISYSHOT_STUDIO_DRAG"] != nil { DebugSnap.studioDrag(); return }
        if let dir = ProcessInfo.processInfo.environment["DAISYSHOT_STUDIO_SNAP"] {
            DebugSnap.studio(dir)
            return
        }
        if let dir = ProcessInfo.processInfo.environment["DAISYSHOT_SETUP_SNAP"] { DebugSnap.recordingSetup(dir); return }
        if let dir = ProcessInfo.processInfo.environment["DAISYSHOT_QUICK_EXPORT"] { DebugSnap.quickExport(dir); return }
        if let src = ProcessInfo.processInfo.environment["DAISYSHOT_SETUP_HOLD"] {   // open the Record Screen setup and leave it up
            Task { @MainActor in _ = await RecordingSetup.run(region: nil, source: RecordingSetup.Source(rawValue: src)); exit(0) }
            return
        }
        if let dir = ProcessInfo.processInfo.environment["DAISYSHOT_SNAP"] {
            DispatchQueue.main.async { DebugSnap.run(dir) }
            return
        }
        #endif
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        NSApp.mainMenu = Self.makeMainMenu()
        AppIcon.apply()
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false
        HotKeys.shared.registerAll()
        // Only persistent hides write this pref (temporary hides while capturing don't), so a crash can't leave icons hidden.
        if Prefs.bool(.desktopIconsHidden) { DesktopIcons.shared.hide(persist: true) }
        _ = History.shared
        if !Prefs.bool(.onboarded) { Onboarding.show() }
        Prefs.d.addObserver(self, forKeyPath: Prefs.Key.showMenuBarIcon.rawValue, options: [], context: nil)
        Prefs.d.addObserver(self, forKeyPath: Prefs.Key.recShowTimeInMenuBar.rawValue, options: [], context: nil)
        Prefs.d.addObserver(self, forKeyPath: Prefs.Key.menuBarRecordingIndicator.rawValue, options: [], context: nil)
        let nc = NotificationCenter.default
        nc.addObserver(forName: Recorder.stateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.updateStatusItem() }
        }
        nc.addObserver(forName: .daisyshotBusyDidChange, object: nil, queue: .main) { n in
            let busy = n.object as? Bool ?? false
            MainActor.assumeIsolated {
                guard let d = NSApp.delegate as? AppDelegate else { return }
                d.busyCount = max(0, d.busyCount + (busy ? 1 : -1))
                if busy { d.sawBusy = true }
                d.updateStatusItem()
            }
        }
        updateStatusItem()
        Recorder.shared.recoverInterruptedRecordings()
        Updater.shared.start()
        // `--capture-area`, `--all-in-one`, `--record-screen` (e.g. `open -a Daisyshot --args --capture-area`).
        let launchActions: [String: HotKeyAction] = ["--capture-area": .captureArea, "--all-in-one": .allInOne, "--record-screen": .recordScreen]
        if let a = ProcessInfo.processInfo.arguments.lazy.compactMap({ launchActions[$0] }).first {
            DispatchQueue.main.async { a.perform() }
        }
    }

    // MARK: Quit

    /// Guards unsaved work: a running recording (stopped and finished first), editors with unsaved changes
    /// (their `windowShouldClose`), and Studio's debounced autosave (`DaisyshotWillTerminate`, then a short wait).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let rec = Recorder.shared
        if rec.isRecording {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "Stop recording and quit?"
            a.informativeText = "The recording is stopped and saved before Daisyshot quits."
            a.addButton(withTitle: "Stop and Quit")
            a.addButton(withTitle: "Cancel")
            a.localize()
            guard a.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        for w in NSApp.windows where w.isVisible {
            if let d = w.delegate, d.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))), d.windowShouldClose?(w) == false {
                return .terminateCancel
            }
        }
        let wasRecording = rec.isRecording
        sawBusy = false
        if wasRecording { rec.stop() }
        NotificationCenter.default.post(name: Notification.Name("DaisyshotWillTerminate"), object: nil)
        // Wait ≥ 0.3 s for autosaves. After a recording, wait until it is written: busy posted and cleared again
        // (or 5 s if the recorder never reports busy), giving up after 60 s.
        let start = Date()
        let t = Timer(timeInterval: 0.1, repeats: true) { t in
            MainActor.assumeIsolated {
                guard let d = NSApp.delegate as? AppDelegate else { return }
                let waited = Date().timeIntervalSince(start)
                let pending = wasRecording && (rec.isRecording || d.busyCount > 0 || (!d.sawBusy && waited < 5))
                guard waited >= 60 || (waited >= 0.3 && !pending) else { return }
                t.invalidate()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)   // .terminateLater runs the loop in the modal panel mode
        return .terminateLater
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.shownState = nil; self.updateStatusItem() } }
    }

    /// Launching the app again (Finder, Spotlight, login) while it runs shows Settings — the only way back in when the
    /// menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.show()
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == URLCommand.scheme { URLCommands.handle(url); continue }
            switch url.pathExtension.lowercased() {
            case "daisyshot": AnnotateWindowController.open(documentURL: url)
            case "mov", "mp4", "m4v", MediaKind.projectExtension: VideoEditor.open(url)
            default:
                // Saving back in place only works for formats we can write; anything else (GIF, PDF, BMP…) opens untitled.
                let writable = UTType(filenameExtension: url.pathExtension).map { t in ImageFormat.allCases.contains { $0.utType == t } } ?? false
                if let s = Exporter.loadShot(url) { AnnotateWindowController.open(shot: s, fileURL: writable ? url : nil) }
                else { Toast.show("Can't open %@".loc(url.lastPathComponent), isError: true) }
            }
        }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        URLCommands.handle(url)
    }

    // MARK: Status item

    /// Normal: template glyph + menu (animated while busy). Recording: stop (or resume when paused) glyph plus elapsed
    /// time; a click stops, a right-click shows recording controls. Shown while recording even if the icon is hidden in Settings.
    /// Driven by `Recorder.stateDidChange`, `.daisyshotBusyDidChange` and the two prefs (no idle polling).
    func updateStatusItem() {
        let rec = Recorder.shared
        let recording = rec.isRecording
        let busy = busyCount > 0 && !recording
        let visible = Prefs.bool(.showMenuBarIcon) || recording
        setTimer(&elapsedTimer, on: recording, interval: 1) { $0.updateStatusItem() }
        setTimer(&busyTimer, on: busy && visible, interval: 0.08) { $0.advanceBusyFrame() }
        guard visible else {
            if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }
            statusItem = nil
            shownState = nil
            return
        }
        let time = recording && Prefs.bool(.recShowTimeInMenuBar) ? Self.format(rec.elapsed) : ""
        let state = (recording, recording && rec.isPaused, time, busy)
        if statusItem != nil, let s = shownState, s == state { return }
        shownState = state

        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.autosaveName = "DaisyshotStatusItem"
        guard let button = item.button else { return }
        button.setAccessibilityLabel(recording ? "Stop Recording".loc : "Daisyshot")
        if recording {
            item.menu = nil
            button.image = state.1 ? MenuBarIcon.resume : MenuBarIcon.recording
            button.imagePosition = time.isEmpty ? .imageOnly : .imageTrailing   // time sits left of the glyph
            button.attributedTitle = NSAttributedString(string: time.isEmpty ? "" : time + " ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
            button.target = self
            button.action = #selector(recordingIconClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = (state.1 ? "Resume Recording" : "Stop Recording").loc
        } else {
            button.image = busy ? MenuBarIcon.busyFrames[busyFrame % MenuBarIcon.busyFrames.count] : MenuBarIcon.standard
            button.toolTip = busy ? "Daisyshot is working…".loc : nil
            button.imagePosition = .imageOnly
            button.title = ""
            button.action = nil
            item.menu = statusMenu
        }
    }

    private var busyFrame = 0

    private func advanceBusyFrame() {
        busyFrame += 1
        guard let button = statusItem?.button, shownState?.busy == true else { return }
        button.image = MenuBarIcon.busyFrames[busyFrame % MenuBarIcon.busyFrames.count]
    }

    /// Starts/stops a repeating main-run-loop timer that calls `tick` on the app delegate.
    private func setTimer(_ timer: inout Timer?, on: Bool, interval: TimeInterval, _ tick: @escaping @MainActor @Sendable (AppDelegate) -> Void) {
        guard on != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { if let d = NSApp.delegate as? AppDelegate { tick(d) } }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    @objc private func recordingIconClicked() {
        let rec = Recorder.shared
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let m = NSMenu()
            m.addItem(ClosureMenuItem(title: "Stop Recording", keyEquivalent: "") { rec.stop() })
            m.addItem(ClosureMenuItem(title: rec.isPaused ? "Resume Recording" : "Pause Recording", keyEquivalent: "") { rec.togglePause() })
            m.addItem(ClosureMenuItem(title: "Restart Recording", keyEquivalent: "") { rec.restart() })
            m.addItem(ClosureMenuItem(title: SpeakerNotes.shared.isShown ? "Hide Speaker Notes" : "Speaker Notes", keyEquivalent: "") { SpeakerNotes.shared.toggle() })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(title: "Cancel Recording", keyEquivalent: "") { rec.cancel() })
            statusItem?.menu = m
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else if rec.isPaused {
            rec.togglePause()
        } else {
            rec.stop()
        }
        shownState = nil
        updateStatusItem()
    }

    // MARK: Status menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ symbol: String, image: NSImage? = nil, shortcut: HotKeyAction? = nil, _ run: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, keyEquivalent: "", action: run)
            i.image = image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let a = shortcut, let s = HotKeys.shared.shortcut(for: a), let key = s.menuKeyEquivalent {
                i.keyEquivalent = key
                i.keyEquivalentModifierMask = s.flags
            }
            menu.addItem(i)
        }
        func action(_ a: HotKeyAction, _ title: String? = nil, _ symbol: String? = nil, image: NSImage? = nil) {
            item(title ?? a.title, symbol ?? a.symbol, image: image, shortcut: a) { a.perform() }
        }

        let header = NSMenuItem()
        header.view = StatusMenuHeader.make()
        menu.addItem(header)
        action(.allInOne, image: MenuBarIcon.markGlyph)
        action(.captureArea)
        action(.capturePreviousArea)
        action(.captureFullscreen)
        action(.captureWindow)
        action(.scrollingCapture)
        action(.selfTimer)
        action(.captureText)
        menu.addItem(.separator())
        action(.recordScreen, Recorder.shared.isRecording ? "Stop Recording" : "Record Screen", image: MenuBarIcon.recordGlyph)
        action(.toggleSpeakerNotes, SpeakerNotes.shared.isShown ? "Hide Speaker Notes" : "Speaker Notes")
        let recent = StudioProjects.recent
        if !recent.isEmpty {
            let sub = NSMenu()
            for url in recent { sub.addItem(ClosureMenuItem(title: url.deletingPathExtension().lastPathComponent, keyEquivalent: "") { VideoEditor.open(url) }) }
            sub.addItem(.separator())
            sub.addItem(ClosureMenuItem(title: "Clear Menu", keyEquivalent: "") { Prefs.set("", .studioRecentProjects) })
            let i = NSMenuItem(title: "Recent Projects".loc, action: nil, keyEquivalent: "")
            i.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            i.submenu = sub
            menu.addItem(i)
        }
        item("Create Project from Video…", "film.stack") { StudioProjects.chooseVideo() }
        menu.addItem(.separator())
        let hidden = DesktopIcons.shared.isHidden
        action(.toggleDesktopIcons, hidden ? "Show Desktop Icons" : "Hide Desktop Icons", hidden ? "eye" : "eye.slash")
        menu.addItem(.separator())
        action(.openAnnotate, "Open…", "folder")
        action(.openFromClipboard)
        action(.chooseAndPinImage, "Pin to the Screen…", "pin")
        if PinWindow.hasLocked { item("Unlock Pins", "lock.open") { PinWindow.unlockAll() } }
        menu.addItem(.separator())
        action(.openHistory, "Capture History…")
        action(.restoreRecentlyClosed)
        menu.addItem(.separator())
        let about = ClosureMenuItem(title: "About Daisyshot", keyEquivalent: "") { SettingsWindow.show(tab: SettingsTab.about.rawValue) }
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Check for Updates…", keyEquivalent: "") { Updater.shared.checkNow() })
        menu.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { SettingsWindow.show() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit Daisyshot", keyEquivalent: "q") { NSApp.terminate(nil) })
    }

    // MARK: Main menu (only active while one of our windows is key; gives text fields copy/paste/undo)

    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let title = title.loc
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
        }
        func i(_ title: String, _ sel: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let it = NSMenuItem(title: title.loc, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.tag = tag
            return it
        }
        func group(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let title = title.loc
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            return host
        }
        let find = #selector(NSResponder.performTextFinderAction(_:))
        sub("Daisyshot", [
            ClosureMenuItem(title: "About Daisyshot", keyEquivalent: "") { SettingsWindow.show(tab: SettingsTab.about.rawValue) },
            ClosureMenuItem(title: "Check for Updates…", keyEquivalent: "") { Updater.shared.checkNow() },
            .separator(),
            ClosureMenuItem(title: "Settings…", keyEquivalent: ",") { SettingsWindow.show() },
            .separator(),
            i("Hide Daisyshot", #selector(NSApplication.hide(_:)), "h"),
            i("Quit Daisyshot", #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub("Edit", [
            i("Undo", Selector(("undo:")), "z"),
            i("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            i("Cut", #selector(NSText.cut(_:)), "x"),
            i("Copy", #selector(NSText.copy(_:)), "c"),
            i("Paste", #selector(NSText.paste(_:)), "v"),
            i("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            i("Delete", #selector(NSText.delete(_:)), ""),
            i("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            group("Find", [
                i("Find…", find, "f", tag: NSTextFinder.Action.showFindInterface.rawValue),
                i("Find and Replace…", find, "f", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue),
                i("Find Next", find, "g", tag: NSTextFinder.Action.nextMatch.rawValue),
                i("Find Previous", find, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue),
                i("Use Selection for Find", find, "e", tag: NSTextFinder.Action.setSearchString.rawValue),
                i("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j"),
            ]),
            group("Spelling and Grammar", [
                i("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
                i("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
                .separator(),
                i("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)), ""),
                i("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:)), ""),
                i("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), ""),
            ]),
            group("Substitutions", [
                i("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:)), ""),
                .separator(),
                i("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:)), ""),
                i("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), ""),
                i("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:)), ""),
                i("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:)), ""),
                i("Data Detectors", #selector(NSTextView.toggleAutomaticDataDetection(_:)), ""),
                i("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:)), ""),
            ]),
            group("Transformations", [
                i("Make Upper Case", #selector(NSResponder.uppercaseWord(_:)), ""),
                i("Make Lower Case", #selector(NSResponder.lowercaseWord(_:)), ""),
                i("Capitalize", #selector(NSResponder.capitalizeWord(_:)), ""),
            ]),
            group("Speech", [
                i("Start Speaking", #selector(NSTextView.startSpeaking(_:)), ""),
                i("Stop Speaking", #selector(NSTextView.stopSpeaking(_:)), ""),
            ]),
        ])
        sub("Window", [
            i("Close", #selector(NSWindow.performClose(_:)), "w"),
            i("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }

    // MARK: Helpers

    static func openFile() {
        let p = NSOpenPanel()
        let doc = UTType(filenameExtension: "daisyshot"), project = UTType(filenameExtension: MediaKind.projectExtension, conformingTo: .package)
        p.allowedContentTypes = [.image, .movie] + [doc, project].compactMap { $0 }
        p.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        (NSApp.delegate as? AppDelegate)?.application(NSApp, open: p.urls)
    }

    /// Registers/unregisters the app as a login item. Returns the resulting state.
    @discardableResult
    static func setLaunchAtLogin(_ on: Bool) -> Bool {
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {
            Toast.show("Launch at login: %@".loc(error.localizedDescription), isError: true)
        }
        return SMAppService.mainApp.status == .enabled
    }
}
