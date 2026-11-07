import AppKit
import CryptoKit
import SwiftUI

extension Prefs.Key {
    static let updateAutoCheck = Prefs.Key("updateAutoCheck", true)
    static let updateLastCheck = Prefs.Key("updateLastCheck", 0.0)     // seconds since 1970
    static let updateSkipped = Prefs.Key("updateSkipped", "")          // a version the user chose to skip
}

/// Updates from the GitHub releases: the latest release's `Daisyshot-<version>.zip` (the app, made by `ditto`) and its
/// `.zip.sig` (Ed25519 signature by `scripts/update-key.swift`). The signature must match the key built into the app,
/// so only archives you signed get installed. The app is swapped after Daisyshot quits, then reopened.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "tamhd148/daisyshot"
    /// Public half of the release signing key (`swift scripts/update-key.swift public`).
    nonisolated static let publicKey = "4lAC85p/10KxUEgUAADjLNBucc7479DpWx7EWV1KRPE="

    struct Release: Equatable {
        var version: String
        var notes: String
        var archive: URL
        var signature: URL
        var page: URL
    }

    enum Phase: Equatable { case idle, checking, downloading, installing, failed(String) }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var available: Release?
    private var window: NSWindow?
    private var timer: Timer?

    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// The latest-release API; `DAISYSHOT_UPDATE_FEED` points at a local copy for testing.
    static var feedURL: URL {
        ProcessInfo.processInfo.environment["DAISYSHOT_UPDATE_FEED"].flatMap(URL.init(string:))
            ?? URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// At launch: a check shortly after, then every few hours (at most one a day) while automatic checks are on.
    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }   // not for unbundled debug runs
        if ProcessInfo.processInfo.environment["DAISYSHOT_UPDATE_TEST_INSTALL"] != nil {
            Task { await testInstall() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard Prefs.bool(.updateAutoCheck), Date().timeIntervalSince1970 - Prefs.double(.updateLastCheck) > 23 * 3600 else { return }
        Task { await check(userInitiated: false) }
    }

    /// Menu, Settings and About: always answers ("up to date" or what went wrong).
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    func check(userInitiated: Bool) async {
        guard phase != .checking else { return }
        phase = .checking
        defer { if phase == .checking { phase = .idle } }
        do {
            var request = URLRequest(url: Self.feedURL, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 { throw UpdateError("No release has been published yet.") }
            guard let release = Self.parse(data) else { throw UpdateError("The update information couldn't be read.") }
            Prefs.set(Date().timeIntervalSince1970, .updateLastCheck)
            guard Self.isNewer(release.version, than: Self.currentVersion) else {
                if userInitiated { Self.tell("You're up to date", "Daisyshot %@ is the newest version.".loc(Self.currentVersion)) }
                return
            }
            if !userInitiated, Prefs.string(.updateSkipped) == release.version { return }
            available = release
            if userInitiated || !Recorder.shared.isRecording { showWindow() }
        } catch {
            if userInitiated { Self.tell("Couldn't check for updates", error.localizedDescription) }
        }
    }

    // MARK: Install

    func install() {
        guard let release = available else { return }
        guard !Recorder.shared.isRecording else {
            Self.tell("Finish recording first", "Daisyshot can update once the recording is stopped.")
            return
        }
        let app = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            phase = .failed("Daisyshot can't replace itself in “%@”. Download the new version from the release page instead.".loc(app.deletingLastPathComponent().path))
            return
        }
        phase = .downloading
        Task {
            do {
                let staged = try await Self.download(release, next: app)
                phase = .installing
                try Self.relaunch(replacing: app, with: staged)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func skip() {
        if let v = available?.version { Prefs.set(v, .updateSkipped) }
        closeWindow()
    }

    func later() { closeWindow() }

    /// Downloads, checks the signature, unpacks and checks the app; returns it, staged on the same volume as `app`.
    private static func download(_ r: Release, next app: URL) async throws -> URL {
        let (archiveFile, _) = try await URLSession.shared.download(from: r.archive)
        let (sigData, _) = try await URLSession.shared.data(from: r.signature)
        let archive = try Data(contentsOf: archiveFile)
        guard verify(archive, signature: sigData) else { throw UpdateError("The update isn't signed by Daisyshot's release key, so it wasn't installed.") }
        let fm = FileManager.default
        let stage = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        let zip = stage.appendingPathComponent("update.zip")
        try archive.write(to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, stage.path])
        guard let new = try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let info = Bundle(url: new)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == r.version
        else { throw UpdateError("The downloaded app isn't the expected Daisyshot version.") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", new.path])
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", new.path])
        return new
    }

    /// Quits; a small shell script waits for this process to end, swaps the bundles (putting the old one back if the
    /// swap fails) and opens Daisyshot again. `open` hands its environment to the app, hence the `unset` (test hooks).
    private static func relaunch(replacing app: URL, with new: URL) throws {
        let old = new.deletingLastPathComponent().appendingPathComponent("Daisyshot-old.app")
        let script = """
        unset DAISYSHOT_UPDATE_TEST_INSTALL DAISYSHOT_UPDATE_FEED
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        if mv "$0" "$2"; then
          if mv "$1" "$0"; then rm -rf "$2"; else mv "$2" "$0"; fi
        fi
        sleep 1    # Launch Services needs a moment to notice the old copy is gone
        open "$0"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, app.path, new.path, old.path]
        try p.run()
        NSApp.terminate(nil)
    }

    // MARK: Pieces

    static func verify(_ data: Data, signature: Data, publicKey: String = publicKey) -> Bool {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sig = Data(base64Encoded: text), let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// "1.2.10" > "1.2.9"; a "v" prefix and missing parts (1.2 = 1.2.0) are fine.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// GitHub's release JSON: the version from the tag, the notes, and the `.zip` with its `.zip.sig`.
    static func parse(_ data: Data) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = o["tag_name"] as? String,
              let assets = o["assets"] as? [[String: Any]] else { return nil }
        let urls = Dictionary(assets.compactMap { a -> (String, URL)? in
            guard let n = a["name"] as? String, let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (n, u)
        }, uniquingKeysWith: { a, _ in a })
        guard let zip = urls.keys.sorted().first(where: { $0.hasSuffix(".zip") }), let archive = urls[zip], let sig = urls[zip + ".sig"] else { return nil }
        let page = (o["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/\(repository)/releases")!
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), notes: o["body"] as? String ?? "",
                       archive: archive, signature: sig, page: page)
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("The update couldn't be prepared (%@).".loc((tool as NSString).lastPathComponent)) }
    }

    private static func tell(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.localize()
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: Window

    private func showWindow() {
        if phase != .checking { phase = .idle }
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Software Update".loc
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: UpdateView(updater: self))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        window?.close()
        window = nil
        if case .failed = phase { phase = .idle }
    }

    /// `DAISYSHOT_UPDATE_TEST_INSTALL`: check the feed and install straight away, no window (end-to-end test).
    private func testInstall() async {
        await check(userInitiated: false)
        window?.orderOut(nil)
        guard available != nil else { print("UPDATE TEST: nothing newer"); exit(1) }
        install()
    }

    // MARK: Self-test

    static func selfTest() {
        assert(isNewer("1.0.10", than: "1.0.9") && isNewer("v1.1", than: "1.0.9") && !isNewer("1.0", than: "1.0.0") && !isNewer("0.9", than: "1.0"))
        let key = Curve25519.Signing.PrivateKey()
        let data = Data("Daisyshot".utf8)
        let sig = Data(try! key.signature(for: data).base64EncodedString().utf8)
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        assert(verify(data, signature: sig, publicKey: pub), "a signed archive passes")
        assert(!verify(Data("Daisyshot!".utf8), signature: sig, publicKey: pub), "a changed archive fails")
        assert(!verify(data, signature: sig), "another key's signature fails")
        let json = #"{"tag_name":"v1.2.0","html_url":"https://example.com/r","body":"Notes","assets":[{"name":"Daisyshot-1.2.0.dmg","browser_download_url":"https://example.com/a.dmg"},{"name":"Daisyshot-1.2.0.zip","browser_download_url":"https://example.com/a.zip"},{"name":"Daisyshot-1.2.0.zip.sig","browser_download_url":"https://example.com/a.zip.sig"}]}"#
        let r = parse(Data(json.utf8))
        assert(r?.version == "1.2.0" && r?.archive.lastPathComponent == "a.zip" && r?.signature.lastPathComponent == "a.zip.sig")
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m.loc }
    var errorDescription: String? { message }
}

private struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A new version of Daisyshot is available").font(.system(size: 15, weight: .semibold))
                    if let r = updater.available {
                        Text("Daisyshot %@ is available — you have %@.".loc(r.version, Updater.currentVersion))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            if let r = updater.available {
                ScrollView {
                    Text(Self.notes(r.notes)).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                Link("Release page", destination: r.page).font(.system(size: 12))
            }
            if case .failed(let message) = updater.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Skip This Version") { updater.skip() }
                Spacer()
                switch updater.phase {
                case .downloading, .installing:
                    ProgressView().controlSize(.small)
                    Text(updater.phase == .downloading ? "Downloading…" : "Installing…").font(.system(size: 12)).foregroundStyle(.secondary)
                default:
                    Button("Remind Me Later") { updater.later() }.keyboardShortcut(.cancelAction)
                    Button("Install and Relaunch") { updater.install() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    private static func notes(_ s: String) -> AttributedString {
        let text = s.isEmpty ? "No release notes.".loc : s
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
