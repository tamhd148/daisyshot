import AppKit
import UserNotifications

/// A parsed `daisyshot://<command>?<params>` request. Parameters:
/// `action` (copy|save|annotate|pin), `x`,`y`,`width`,`height` (points, top-left origin) + `display` (1-based),
/// `start`/`autoscroll`/`linebreaks` (true|1|false|0), `filepath`, `tab`.
struct URLCommand {
    let name: String
    let params: [String: String]

    /// Hand-offs from our own share extensions: they skip the consent prompt.
    static let internalCommands: Set<String> = ["share-extension-annotate", "share-extension-pin"]
    /// Commands that read the screen (need Screen Recording, and trigger the "another app captured" notification).
    static let captureCommands: Set<String> = [
        "capture-area", "capture-previous-area", "capture-fullscreen", "capture-window", "scrolling-capture",
        "self-timer", "record-screen", "capture-text", "all-in-one",
    ]

    static let scheme = "daisyshot"

    init?(_ url: URL) {
        guard let s = url.scheme?.lowercased(), s == Self.scheme else { return nil }
        let raw = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !raw.isEmpty else { return nil }
        name = raw.lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        params = Dictionary(items.map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { $1 })
    }

    static func parseBool(_ s: String?) -> Bool? {
        switch s?.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    func bool(_ k: String) -> Bool? { Self.parseBool(params[k]) }
    func number(_ k: String) -> Double? { params[k].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }

    /// After-capture action override; nil = the user's After Capture settings.
    var action: OverlayAction? {
        switch params["action"]?.lowercased() {
        case "copy": return .copy
        case "save": return .save
        case "annotate": return .annotate
        case "pin": return .pin
        default: return nil   // includes "upload", which this offline app doesn't have
        }
    }

    /// 1-based display index.
    var displayIndex: Int? { number("display").map(Int.init) }

    /// All four of x/y/width/height, positive size.
    var rect: CGRect? {
        guard let x = number("x"), let y = number("y"), let w = number("width"), let h = number("height"), w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Reads the screen (needs Screen Recording; triggers the "another app captured" notification).
    /// `capture-text?filepath=` only runs OCR on a file.
    var capturesScreen: Bool { Self.captureCommands.contains(name) && !(name == "capture-text" && fileURL != nil) }

    /// Share extensions hand off a PNG written to their own sandbox tmp dir:
    /// `~/Library/Containers/app.daisyshot.mac.<Extension>/Data/tmp/<file>`. Anything else is refused.
    static func isShareExtensionTempFile(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard url.isFileURL else { return false }
        let h = home.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let p = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard p.count == h.count + 6, Array(p.prefix(h.count)) == h else { return false }
        let rest = Array(p.dropFirst(h.count))
        return rest[0] == "Library" && rest[1] == "Containers" && rest[2].hasPrefix("app.daisyshot.mac.") && rest[2].count > "app.daisyshot.mac.".count
            && rest[3] == "Data" && rest[4] == "tmp"
    }

    /// `filepath`, accepting plain paths, `~/…` and `file://` URLs.
    var fileURL: URL? {
        guard let p = params["filepath"], !p.isEmpty else { return nil }
        if p.hasPrefix("file://") { return URL(string: p) }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    static func selfTest() {
        let a = URLCommand(URL(string: "daisyshot://capture-area?x=10&y=20&width=300&height=200&display=2&action=PIN")!)!
        assert(a.name == "capture-area" && a.rect == CGRect(x: 10, y: 20, width: 300, height: 200) && a.displayIndex == 2 && a.action == .pin)
        let b = URLCommand(URL(string: "daisyshot://scrolling-capture?start=1&autoscroll=false")!)!
        assert(b.bool("start") == true && b.bool("autoscroll") == false && b.bool("missing") == nil && b.rect == nil)
        assert(URLCommand(URL(string: "daisyshot://capture-area?x=1&y=1&width=0&height=5")!)!.rect == nil)
        assert(URLCommand(URL(string: "daisyshot://capture-area?action=upload")!)!.action == nil)
        assert(URLCommand(URL(string: "daisyshot:open-history")!)?.name == "open-history")
        assert(URLCommand(URL(string: "other://capture-area")!) == nil)
        assert(parseBool("TRUE") == true && parseBool("0") == false && parseBool("yes") == nil)
        let f = URLCommand(URL(string: "daisyshot://pin?filepath=~/Desktop/a%20b.png")!)!
        assert(f.fileURL?.path == (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/a b.png"))
        assert(URLCommand(URL(string: "daisyshot://capture-text?filepath=/tmp/a.png")!)!.capturesScreen == false)
        assert(URLCommand(URL(string: "daisyshot://capture-text")!)!.capturesScreen && !URLCommand(URL(string: "daisyshot://open-history")!)!.capturesScreen)
        let home = URL(fileURLWithPath: "/Users/x")
        func share(_ p: String) -> Bool { isShareExtensionTempFile(URL(fileURLWithPath: p), home: home) }
        assert(share("/Users/x/Library/Containers/app.daisyshot.mac.PinShareExtension/Data/tmp/a.png"))
        assert(!share("/Users/x/Library/Containers/app.daisyshot.mac.PinShareExtension/Data/tmp/../../../../../.ssh/id"))
        assert(!share("/Users/x/Library/Containers/app.daisyshot.mac.PinShareExtension/Data/tmp/sub/a.png"))
        assert(!share("/Users/x/Library/Containers/com.other.app/Data/tmp/a.png"))
        assert(!share("/Users/x/Library/Containers/app.daisyshot.mac./Data/tmp/a.png"))
        assert(!share("/Users/x/Desktop/a.png"))
    }
}

/// `daisyshot://` automation API: consent, permission check, notification, dispatch.
@MainActor
enum URLCommands {
    static func handle(_ url: URL) {
        guard let cmd = URLCommand(url) else { return }
        guard Prefs.bool(.allowURLSchemes) else {
            Toast.show("Daisyshot's URL scheme API is turned off in Settings › Advanced", isError: true)
            return
        }
        if URLCommand.internalCommands.contains(cmd.name) {
            // Anyone can open daisyshot:// URLs, so only files our own share extensions wrote are accepted.
            guard let f = cmd.fileURL, URLCommand.isShareExtensionTempFile(f) else { return }
            run(cmd)
            return
        }
        if !Prefs.bool(.urlSchemeConsented) {
            Prefs.set(true, .urlSchemeConsented)
            guard askConsent(url) else { Prefs.set(false, .allowURLSchemes); return }
        }
        if cmd.capturesScreen {
            guard Recorder.shared.isRecording || Permissions.ensureScreenRecording() else { return }
            notifyExternalCapture()
        }
        run(cmd)
    }

    private static func askConsent(_ url: URL) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Another app is asking to control Daisyshot"
        a.informativeText = """
            An app sent Daisyshot this command:
            "%@"

            Let other apps run Daisyshot commands, including screen captures? \
            You can change this later in Settings › Advanced.
            """.loc(url.absoluteString)
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Don't Allow")
        a.localize()
        return a.runModal() == .alertFirstButtonReturn
    }

    /// "Your screen was captured at another app's request". Silently skipped when notifications are unavailable
    /// (unbundled debug runs) or denied.
    private static func notifyExternalCapture() {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "Your screen was captured at another app's request".loc
            c.body = "You can turn off the URL scheme API in Settings › Advanced.".loc
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }

    // MARK: Dispatch

    private static func run(_ cmd: URLCommand) {
        let c = CaptureController.shared
        let action = cmd.action
        let screen = cmd.displayIndex.flatMap { $0 >= 1 && $0 <= NSScreen.screens.count ? NSScreen.screens[$0 - 1] : nil }
        let region = cmd.rect.map { CaptureRegion(displayID: (screen ?? NSScreen.screens[0]).displayID, rect: $0) }
        let file = cmd.fileURL.flatMap { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if let given = cmd.fileURL, file == nil { return Toast.show("File not found: %@".loc(given.lastPathComponent), isError: true) }

        switch cmd.name {
        case "capture-area":
            if let region { c.captureRect(region, action: action ?? .screenshot) } else { c.captureArea(action: action) }
        case "capture-previous-area":
            if let action, let r = lastRegion { c.captureRect(r, action: action) } else { c.capturePreviousArea() }
        case "capture-fullscreen":
            if let action {
                let s = screen ?? .underMouse
                c.captureRect(CaptureRegion(displayID: s.displayID, rect: CGRect(origin: .zero, size: s.frame.size)), action: action)
            } else {
                c.captureFullscreen(displayID: screen?.displayID)
            }
        case "capture-window": c.captureWindow(action: action)
        case "self-timer":
            if let region { c.captureRect(region, action: .timer) } else { c.selfTimer(action: action) }
        case "scrolling-capture":
            ScrollCapture.pendingOptions = (cmd.bool("start") ?? false, cmd.bool("autoscroll") ?? false)
            if let region { c.captureRect(region, action: .scroll) } else { c.scrollingCapture() }
        case "capture-text":
            let lineBreaks = cmd.bool("linebreaks") ?? Prefs.bool(.ocrKeepLineBreaks)
            c.ocrLineBreaks = lineBreaks
            if let file {
                guard let s = Exporter.loadShot(file) else { return badFile(file) }
                c.deliver(s, action: .text)
            } else if let region {
                c.captureRect(region, action: .text)
            } else {
                c.captureText(lineBreaks: lineBreaks)
            }
        case "record-screen":
            if Recorder.shared.isRecording { Recorder.shared.stop() }
            else if let region { c.captureRect(region, action: .video) }
            else { c.recordScreen() }
        case "all-in-one": c.allInOne(rect: region)
        case "toggle-desktop-icons": DesktopIcons.shared.toggle()
        case "hide-desktop-icons": DesktopIcons.shared.hide()
        case "show-desktop-icons": DesktopIcons.shared.show()
        case "open-history": History.showWindow()
        case "restore-recently-closed": QuickAccess.shared.restoreRecentlyClosed()
        case "open-from-clipboard": c.openFromClipboard()
        case "pin":
            if let file {
                guard let s = Exporter.loadShot(file) else { return badFile(file) }
                PinWindow.pin(s)
            } else {
                PinWindow.chooseAndPin()
            }
        case "open-annotate":
            if let file { (NSApp.delegate as? AppDelegate)?.application(NSApp, open: [file]) } else { AppDelegate.openFile() }
        case "share-extension-pin", "share-extension-annotate":
            guard let file else { return }
            guard let s = takeSharedShot(file) else { return badFile(file) }
            // Untitled: the temp file is deleted, so Save asks for a location.
            if cmd.name == "share-extension-pin" { PinWindow.pin(s) } else { AnnotateWindowController.open(shot: s) }
        case "add-quick-access-overlay":
            guard let file else { return }
            if !QuickAccess.shared.addFile(file) { badFile(file) }
        case "open-settings": SettingsWindow.show(tab: cmd.params["tab"])
        // Extras beyond the reference API.
        case "stop-recording": Recorder.shared.stop()
        case "close-all-overlays": QuickAccess.shared.closeAll()
        default:
            Toast.show("Unknown Daisyshot command: %@".loc(cmd.name), isError: true)
        }
    }

    /// Reads a share-extension hand-off fully into memory, then deletes the temp file.
    private static func takeSharedShot(_ file: URL) -> Shot? {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let dpi = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyDPIWidth] as? Double ?? 72
        return Shot(image: img, scale: max(1, CGFloat(dpi / 72).rounded()))
    }

    private static func badFile(_ url: URL) {
        Toast.show("Can't open %@".loc(url.lastPathComponent), isError: true)
    }

    /// The area remembered by Capture for "Capture Previous Area".
    private static var lastRegion: CaptureRegion? {
        Prefs.d.data(forKey: "lastRegion").flatMap { try? JSONDecoder().decode(CaptureRegion.self, from: $0) }
    }
}
