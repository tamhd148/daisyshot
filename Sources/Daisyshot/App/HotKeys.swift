import AppKit
import Carbon.HIToolbox

extension Prefs.Key {
    /// "Capture Area & Copy/Save/Annotate/Pin" shortcuts skip the General › After Capture actions (read by Capture).
    static let ignoreAfterCapture = Prefs.Key("ignoreAfterCapture", true)
}

/// A global keyboard shortcut stored as Carbon key code + Cocoa modifier flags.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt   // NSEvent.ModifierFlags raw value (device-independent)

    init(keyCode: UInt32, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: Int, _ flags: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt32(keyCode), modifiers: flags.rawValue)
    }

    init(keyCode: UInt32, carbonModifiers m: UInt32) {
        var f: NSEvent.ModifierFlags = []
        if m & UInt32(cmdKey) != 0 { f.insert(.command) }
        if m & UInt32(optionKey) != 0 { f.insert(.option) }
        if m & UInt32(controlKey) != 0 { f.insert(.control) }
        if m & UInt32(shiftKey) != 0 { f.insert(.shift) }
        self.init(keyCode: keyCode, modifiers: f.rawValue)
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    var display: String { Shortcut.symbols(flags) + Shortcut.keyName(keyCode) }

    /// "⌃⌥⇧⌘" in macOS's canonical order.
    static func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    /// `keyEquivalent` for showing this shortcut next to an NSMenuItem (nil for keys AppKit can't display).
    var menuKeyEquivalent: String? {
        let fn: [Int: Int] = [kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
                              kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
                              kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
                              kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
                              kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey]
        if let f = fn[Int(keyCode)], let u = UnicodeScalar(f) { return String(Character(u)) }
        switch Int(keyCode) {
        case kVK_Space: return " "
        case kVK_Return: return "\r"
        case kVK_Tab: return "\t"
        case kVK_Delete: return "\u{8}"
        case kVK_Escape: return "\u{1b}"
        default:
            let name = Shortcut.keyName(keyCode)
            return name.count == 1 ? name.lowercased() : nil
        }
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [UInt32: String] = [
            UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Space): "Space", UInt32(kVK_Delete): "⌫",
            UInt32(kVK_Escape): "⎋", UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓", UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
            UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
            UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
            UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        ]
        if let s = special[code] { return s }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        data.withUnsafeBytes { raw in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

/// Every action that can be bound to a global shortcut.
enum HotKeyAction: String, CaseIterable, Identifiable {
    // Screenshots
    case allInOne, captureArea, capturePreviousArea, captureFullscreen, captureWindow, selfTimer, scrollingCapture
    case captureText, captureTextNoLineBreaks, captureTextWithLineBreaks
    case captureAreaCopy, captureAreaSave, captureAreaAnnotate, captureAreaPin
    // Recording
    case recordScreen, recordVideo, recordGIF, recordWindow, pauseResumeRecording, restartRecording, toggleCameraFullscreen, addRecordingMarker
    case toggleSpeakerNotes, toggleTeleprompter, recordArea, recordDisplay, toggleRecordingControls
    // Tools
    case openAnnotate, annotateLastScreenshot, openFromClipboard, pinLastScreenshot, chooseAndPinImage, pinFromClipboard
    case togglePins, closeAllPins, toggleDesktopIcons, openHistory, restoreRecentlyClosed, restoreLastCapture, openLastProject
    // Quick Access Overlay
    case closeAllQuickAccess, saveAllQuickAccess, toggleQuickAccessHidden

    var id: String { rawValue }

    enum Group: String, CaseIterable {
        case screenshots = "Screenshots", recording = "Screen Recording", tools = "Tools", quickAccess = "Quick Access Overlay"
        var symbol: String {
            switch self {
            case .screenshots: return "camera.viewfinder"
            case .recording: return "record.circle"
            case .tools: return "wrench.and.screwdriver"
            case .quickAccess: return "rectangle.stack"
            }
        }
        var actions: [HotKeyAction] { HotKeyAction.allCases.filter { $0.group == self } }
    }

    var group: Group {
        switch self {
        case .allInOne, .captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer, .scrollingCapture,
             .captureText, .captureTextNoLineBreaks, .captureTextWithLineBreaks, .captureAreaCopy, .captureAreaSave, .captureAreaAnnotate, .captureAreaPin: return .screenshots
        case .recordScreen, .recordVideo, .recordGIF, .recordWindow, .pauseResumeRecording, .restartRecording, .toggleCameraFullscreen,
             .addRecordingMarker, .toggleSpeakerNotes, .toggleTeleprompter, .recordArea, .recordDisplay, .toggleRecordingControls: return .recording
        case .closeAllQuickAccess, .saveAllQuickAccess, .toggleQuickAccessHidden: return .quickAccess
        default: return .tools
        }
    }

    var symbol: String {
        switch self {
        case .allInOne: return "square.dashed.inset.filled"
        case .captureArea, .captureAreaCopy, .captureAreaSave, .captureAreaAnnotate, .captureAreaPin: return "rectangle.dashed"
        case .capturePreviousArea: return "arrow.counterclockwise"
        case .captureFullscreen: return "display"
        case .captureWindow: return "macwindow"
        case .selfTimer: return "timer"
        case .scrollingCapture: return "scroll"
        case .captureText, .captureTextNoLineBreaks, .captureTextWithLineBreaks: return "text.viewfinder"
        case .recordScreen, .recordVideo: return "record.circle"
        case .recordGIF: return "photo.stack"
        case .recordWindow: return "macwindow.badge.plus"
        case .pauseResumeRecording: return "pause.circle"
        case .restartRecording: return "arrow.clockwise.circle"
        case .toggleCameraFullscreen: return "web.camera"
        case .addRecordingMarker: return "flag"
        case .toggleSpeakerNotes: return "note.text"
        case .recordArea: return "rectangle.dashed.badge.record"
        case .recordDisplay: return "display"
        case .toggleRecordingControls: return "slider.horizontal.below.rectangle"
        case .toggleTeleprompter: return "text.line.first.and.arrowtriangle.forward"
        case .openAnnotate, .annotateLastScreenshot: return "pencil.tip.crop.circle"
        case .openFromClipboard: return "doc.on.clipboard"
        case .pinLastScreenshot, .chooseAndPinImage, .pinFromClipboard, .togglePins, .closeAllPins: return "pin"
        case .toggleDesktopIcons: return "eye.slash"
        case .openHistory: return "clock.arrow.circlepath"
        case .openLastProject: return "film.stack"
        case .restoreRecentlyClosed, .restoreLastCapture: return "arrow.uturn.backward"
        case .closeAllQuickAccess, .saveAllQuickAccess, .toggleQuickAccessHidden: return "rectangle.stack"
        }
    }

    /// Shown in the app's language (status menu, Settings › Shortcuts, onboarding). Display only.
    var title: String { englishTitle.loc }

    private var englishTitle: String {
        switch self {
        case .allInOne: return "All-In-One"
        case .captureArea: return "Capture Area"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureWindow: return "Capture Window"
        case .selfTimer: return "Self-Timer"
        case .scrollingCapture: return "Scrolling Capture"
        case .captureText: return "Capture Text"
        case .captureTextNoLineBreaks: return "Capture Text Without Line Breaks"
        case .captureTextWithLineBreaks: return "Capture Text With Line Breaks"
        case .captureAreaCopy: return "Capture Area & Copy to Clipboard"
        case .captureAreaSave: return "Capture Area & Save"
        case .captureAreaAnnotate: return "Capture Area & Annotate"
        case .captureAreaPin: return "Capture Area & Pin to the Screen"
        case .recordScreen: return "Record Screen / Stop Recording"
        case .recordVideo: return "Start Video Recording"
        case .recordGIF: return "Start GIF Recording"
        case .recordWindow: return "Record Window"
        case .pauseResumeRecording: return "Pause / Resume Recording"
        case .restartRecording: return "Restart Recording"
        case .toggleCameraFullscreen: return "Toggle Camera Fullscreen"
        case .addRecordingMarker: return "Add Recording Marker"
        case .toggleSpeakerNotes: return "Show / Hide Speaker Notes"
        case .recordArea: return "Record Area"
        case .recordDisplay: return "Record Display"
        case .toggleRecordingControls: return "Show / Hide Recording Controls"
        case .toggleTeleprompter: return "Start / Stop Teleprompter"
        case .openAnnotate: return "Open Annotate Tool"
        case .annotateLastScreenshot: return "Annotate Last Screenshot"
        case .openFromClipboard: return "Open from Clipboard"
        case .pinLastScreenshot: return "Pin Last Screenshot"
        case .chooseAndPinImage: return "Choose and Pin an Image"
        case .pinFromClipboard: return "Pin from Clipboard"
        case .togglePins: return "Toggle Pins Visibility"
        case .closeAllPins: return "Close All Pins"
        case .toggleDesktopIcons: return "Toggle Desktop Icons"
        case .openHistory: return "Open Capture History"
        case .openLastProject: return "Open Last Video Project"
        case .restoreRecentlyClosed: return "Restore Recently Closed"
        case .restoreLastCapture: return "Restore Last Capture"
        case .closeAllQuickAccess: return "Close All Overlays"
        case .saveAllQuickAccess: return "Save All Overlays"
        case .toggleQuickAccessHidden: return "Hide / Show Overlays"
        }
    }

    /// Extra words the Shortcuts search matches besides the title.
    var keywords: String {
        switch self {
        case .captureText, .captureTextNoLineBreaks, .captureTextWithLineBreaks: return "ocr recognize"
        case .allInOne: return "aio"
        case .recordScreen, .recordVideo, .recordWindow: return "video movie"
        case .recordGIF: return "animation"
        case .toggleDesktopIcons: return "hide show"
        case .toggleSpeakerNotes, .toggleTeleprompter: return "teleprompter script notes prompter"
        default: return ""
        }
    }

    /// Defaults avoid macOS's own ⌘⇧3/4/5 so both work out of the box; users can rebind in Settings.
    var defaultShortcut: Shortcut? {
        let ocs: NSEvent.ModifierFlags = [.option, .command, .shift]
        func k(_ code: Int) -> Shortcut { Shortcut(keyCode: code, ocs) }
        switch self {
        case .allInOne: return k(kVK_ANSI_5)
        case .captureArea: return k(kVK_ANSI_4)
        case .captureFullscreen: return k(kVK_ANSI_3)
        case .recordScreen: return k(kVK_ANSI_6)
        case .captureText: return k(kVK_ANSI_2)
        case .capturePreviousArea: return k(kVK_ANSI_7)
        case .scrollingCapture: return k(kVK_ANSI_8)
        case .toggleDesktopIcons: return k(kVK_ANSI_D)
        case .restoreRecentlyClosed: return k(kVK_ANSI_Z)
        case .captureWindow: return k(kVK_ANSI_W)
        default: return nil
        }
    }

    /// Actions that grab the screen and therefore need the Screen Recording permission first.
    var capturesScreen: Bool {
        switch group {
        case .screenshots: return true
        case .recording: return ![.pauseResumeRecording, .restartRecording, .toggleCameraFullscreen, .addRecordingMarker, .toggleSpeakerNotes, .toggleTeleprompter, .toggleRecordingControls].contains(self)
        default: return false
        }
    }

    @MainActor
    func perform() {
        let c = CaptureController.shared
        let rec = Recorder.shared
        if capturesScreen, !rec.isRecording, !Permissions.ensureScreenRecording() { return }
        switch self {
        case .allInOne: c.allInOne()
        case .captureArea: c.captureArea()
        case .capturePreviousArea: c.capturePreviousArea()
        case .captureFullscreen: c.captureFullscreen()
        case .captureWindow: c.captureWindow()
        case .selfTimer: c.selfTimer()
        case .scrollingCapture: ScrollCapture.toggle()
        case .captureText: c.captureText()   // "Keep line breaks" setting
        case .captureTextNoLineBreaks: c.captureText(lineBreaks: false)
        case .captureTextWithLineBreaks: c.captureText(lineBreaks: true)
        case .captureAreaCopy: c.captureArea(action: .copy)
        case .captureAreaSave: c.captureArea(action: .save)
        case .captureAreaAnnotate: c.captureArea(action: .annotate)
        case .captureAreaPin: c.captureArea(action: .pin)
        case .recordScreen: rec.isRecording ? rec.stop() : c.recordScreen()
        case .recordVideo: rec.isRecording ? rec.stop() : c.recordScreen(gif: false)   // explicit video (never Studio)
        case .recordGIF: rec.isRecording ? rec.stop() : c.recordScreen(gif: true)
        case .recordWindow: rec.isRecording ? rec.stop() : c.recordWindow()
        case .pauseResumeRecording: if rec.isRecording { rec.togglePause() }
        case .restartRecording: if rec.isRecording { rec.restart() }
        case .toggleCameraFullscreen: rec.toggleCameraFullscreen()
        case .addRecordingMarker: rec.addMarker()
        case .toggleSpeakerNotes: SpeakerNotes.shared.toggle()
        case .recordArea: rec.isRecording ? rec.stop() : c.recordSource(.area)
        case .recordDisplay: rec.isRecording ? rec.stop() : c.recordSource(.display)
        case .toggleRecordingControls: rec.toggleControls()
        case .toggleTeleprompter: SpeakerNotes.shared.toggleScrolling()
        case .openAnnotate: AppDelegate.openFile()
        case .annotateLastScreenshot:
            if let s = History.shared.lastScreenshot() { AnnotateWindowController.open(shot: s) } else { Toast.show("No screenshot yet", isError: true) }
        case .openFromClipboard: c.openFromClipboard()
        case .pinLastScreenshot:
            if let s = History.shared.lastScreenshot() { PinWindow.pin(s) } else { Toast.show("No screenshot yet", isError: true) }
        case .chooseAndPinImage: PinWindow.chooseAndPin()
        case .pinFromClipboard:
            if let s = Exporter.shotFromPasteboard() { PinWindow.pin(s) } else { Toast.show("No image on the clipboard", isError: true) }
        case .togglePins: PinWindow.toggleVisibility()
        case .closeAllPins: PinWindow.closeAll()
        case .toggleDesktopIcons: DesktopIcons.shared.toggle()
        case .openHistory: History.showWindow()
        case .openLastProject: VideoEditor.openLastProject()
        case .restoreRecentlyClosed: QuickAccess.shared.restoreRecentlyClosed()
        case .restoreLastCapture: History.shared.restoreLast()
        case .closeAllQuickAccess: QuickAccess.shared.closeAll()
        case .saveAllQuickAccess: QuickAccess.shared.saveAll()
        case .toggleQuickAccessHidden: QuickAccess.shared.toggleHidden()
        }
    }
}

@MainActor
final class HotKeys {
    static let shared = HotKeys()
    /// Posted after any binding changes, so menus and settings rows refresh.
    static let didChange = Notification.Name("HotKeys.didChange")

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotKeyAction] = [:]
    private var handlerInstalled = false
    /// Suspended while the shortcut recorder is listening.
    var suspended = false
    /// Actions whose shortcut couldn't be registered (usually already taken by another app).
    private(set) var failed: Set<HotKeyAction> = []

    /// macOS's own screenshot shortcuts, which Daisyshot can take over once they're turned off in System Settings.
    nonisolated static let systemScreenshotShortcuts: [(action: HotKeyAction, shortcut: Shortcut)] = [
        (.captureFullscreen, Shortcut(keyCode: kVK_ANSI_3, [.command, .shift])),
        (.captureArea, Shortcut(keyCode: kVK_ANSI_4, [.command, .shift])),
        (.allInOne, Shortcut(keyCode: kVK_ANSI_5, [.command, .shift])),
    ]

    private func key(_ a: HotKeyAction) -> String { "hotkey." + a.rawValue }

    func shortcut(for a: HotKeyAction) -> Shortcut? {
        if let data = Prefs.d.data(forKey: key(a)) {
            return try? JSONDecoder().decode(Shortcut?.self, from: data)
        }
        return a.defaultShortcut
    }

    func set(_ s: Shortcut?, for a: HotKeyAction) {
        Prefs.d.set(try? JSONEncoder().encode(s), forKey: key(a))
        registerAll()
    }


    func resetToDefault(_ a: HotKeyAction) {
        if let d = a.defaultShortcut, let other = action(using: d, except: a) { Prefs.d.set(try? JSONEncoder().encode(Shortcut?.none), forKey: key(other)) }
        Prefs.d.removeObject(forKey: key(a))
        registerAll()
    }

    func restoreDefaults() {
        HotKeyAction.allCases.forEach { Prefs.d.removeObject(forKey: key($0)) }
        registerAll()
    }

    /// The other action already bound to `s`, if any.
    func action(using s: Shortcut, except: HotKeyAction? = nil) -> HotKeyAction? {
        HotKeyAction.allCases.first { $0 != except && shortcut(for: $0) == s }
    }

    /// Binds `s` to `a`, taking it away from whichever action had it.
    func assign(_ s: Shortcut, to a: HotKeyAction) {
        if let other = action(using: s, except: a) { Prefs.d.set(try? JSONEncoder().encode(Shortcut?.none), forKey: key(other)) }
        set(s, for: a)
    }

    /// ⇧⌘3 / ⇧⌘4 / ⇧⌘5 → Fullscreen / Area / All-In-One. Returns false (changing nothing) while macOS still owns them.
    @discardableResult
    func useSystemScreenshotShortcuts() -> Bool {
        guard !SystemHotKeys.screenshotShortcutsEnabled else { return false }
        for (a, s) in Self.systemScreenshotShortcuts { assign(s, to: a) }
        return true
    }

    var usesSystemScreenshotShortcuts: Bool {
        Self.systemScreenshotShortcuts.allSatisfy { shortcut(for: $0.action) == $0.shortcut }
    }

    func registerAll() {
        installHandler()
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
        failed.removeAll()
        for (i, a) in HotKeyAction.allCases.enumerated() {
            guard let s = shortcut(for: a) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4253_4854), id: UInt32(i)) // 'BSHT'
            if RegisterEventHotKey(s.keyCode, s.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[UInt32(i)] = a
            } else {
                failed.insert(a)
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    fileprivate func fire(_ id: UInt32) {
        guard !suspended, let a = actions[id] else { return }
        a.perform()
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Shortcuts macOS itself owns (System Settings › Keyboard › Keyboard Shortcuts), read from Carbon's symbolic hot keys.
enum SystemHotKeys {
    /// Every system shortcut that is currently enabled.
    static func enabled() -> [Shortcut] {
        var out: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&out) == noErr, let list = out?.takeRetainedValue() as? [[String: Any]] else {
            return HotKeys.systemScreenshotShortcuts.map(\.shortcut)
        }
        return list.compactMap { d in
            guard (d["kHISymbolicHotKeyEnabled"] as? Bool) == true,
                  let code = (d["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value,
                  let mods = (d["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value else { return nil }
            return Shortcut(keyCode: code, carbonModifiers: mods)
        }
    }

    static func isReserved(_ s: Shortcut) -> Bool { enabled().contains(s) }

    /// ⇧⌘3/4/5 and their ⌃ "copy to clipboard" variants — the macOS Screenshots group users can turn off.
    static func isScreenshotShortcut(_ s: Shortcut) -> Bool {
        let codes = [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].map(UInt32.init)
        let f = s.flags.intersection([.command, .shift, .option, .control])
        return codes.contains(s.keyCode) && (f == [.command, .shift] || f == [.command, .shift, .control])
    }

    static var screenshotShortcutsEnabled: Bool {
        let system = enabled()
        return HotKeys.systemScreenshotShortcuts.contains { system.contains($0.shortcut) }
    }

    static func openKeyboardShortcutsSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}
