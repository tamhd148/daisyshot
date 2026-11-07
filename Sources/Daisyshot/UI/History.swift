import AppKit
import SwiftUI

extension Prefs.Key {
    /// "Keep history": number of days captures are kept; 0 = Never (history disabled). Replaces historyEnabled/historyDays.
    static let historyCapacity = Prefs.Key("historyCapacity", 7)
    /// Path of the newest screenshot written by `History.add`, kept even when history is "Never" (Annotate/Pin Last Screenshot).
    static let lastShotURL = Prefs.Key("lastShotURL", "")
    /// Files `add` wrote into the History folder while history was off (not indexed); the only ones orphan cleanup may trash.
    static let historyUnindexed = Prefs.Key("historyUnindexed", [String]())
}

/// Every capture is kept in Application Support/Daisyshot/History for the "Keep history" window.
@MainActor
final class History: ObservableObject {
    static let shared = History()

    static let capacityOptions: [(days: Int, title: String)] = [(0, "Never"), (1, "1 day"), (3, "3 days"), (7, "1 week"), (30, "1 month")]

    struct Entry: Codable, Identifiable, Hashable {
        var id = UUID()
        var file: String
        var date: Date
        var kind: String   // MediaKind raw value: "image" | "video" | "gif" | "project"
        var app: String?   // bundle id of the app that was frontmost when capturing

        var mediaKind: MediaKind { MediaKind(rawValue: kind) ?? .image }
    }

    @Published private(set) var entries: [Entry] = []
    let folder = Prefs.supportFolder.appendingPathComponent("History", isDirectory: true)
    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    var isEnabled: Bool { Prefs.int(.historyCapacity) > 0 }

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.migrateLegacyPrefs()
        #if DEBUG
        QuickAccess.selfTest(); WallpaperProvider.selfTest(); MediaInfo.selfTest(); HistorySearch.selfTest()
        #endif
        if let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = list
            prune()
            removeOrphans()
        } else {
            // Missing or unreadable/corrupt index: keep a corrupt one aside (index.json.corrupt) and rebuild from the files
            // on disk instead of treating them all as orphans. Nothing is pruned or trashed in this run.
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try? FileManager.default.moveItem(at: indexURL, to: Exporter.uniqueURL(in: folder, name: "index.json", ext: "corrupt"))
            }
            entries = rebuildFromDisk()
            persist()
        }
        // The app touches History.shared at launch; bring back the overlays that were on screen when it quit.
        DispatchQueue.main.async { QuickAccess.shared.restorePersisted() }
    }

    func url(_ e: Entry) -> URL { folder.appendingPathComponent(e.file) }

    /// Stores a PNG copy of the shot and returns its URL (always returned, even if history is off, so Quick Access can drag it).
    /// Returns at once: the name is reserved with an empty file and the PNG (~150 ms for a 5K capture) is encoded and
    /// written in the background; the history entry is recorded once the file is there.
    @discardableResult
    func add(_ shot: Shot) -> URL {
        let url = Exporter.uniqueURL(in: folder, name: Exporter.fileName(bumpCounter: false), ext: "png")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        Prefs.set(url.path, .lastShotURL)
        let entry = isEnabled ? Entry(file: url.lastPathComponent, date: Date(), kind: MediaKind.image.rawValue, app: Self.frontApp()) : nil
        if entry == nil {
            Prefs.set((Prefs.codable(.historyUnindexed, [String].self) ?? []) + [url.lastPathComponent], .historyUnindexed)
        }
        Exporter.write(shot, format: .png, to: url) { [weak self] ok in
            guard ok, let self, let entry else { return }
            self.entries.insert(entry, at: self.entries.firstIndex { $0.date < entry.date } ?? self.entries.endIndex)
            self.prune()
        }
        return url
    }

    /// Copies a recording, GIF or `.daisyshotvideo` project into history. `kind` is a `MediaKind` raw value;
    /// projects are detected from the extension whatever is passed.
    /// CONTRACT: with `move: true` the file is moved (not copied) into history and the stored URL is returned,
    /// so callers can point Quick Access / the editor at the single canonical copy. Returns nil when not stored.
    @discardableResult
    func addFile(_ src: URL, kind: String, move: Bool = false) -> URL? {
        guard isEnabled else { return nil }
        let dst = Exporter.uniqueURL(in: folder, name: src.deletingPathExtension().lastPathComponent, ext: src.pathExtension)
        let fm = FileManager.default
        guard (try? (move ? fm.moveItem(at: src, to: dst) : fm.copyItem(at: src, to: dst))) != nil else { return nil }
        record(dst, kind: MediaKind.detect(src) == .project ? MediaKind.project.rawValue : kind)
        return dst
    }

    private func record(_ url: URL, kind: String) {
        entries.insert(Entry(file: url.lastPathComponent, date: Date(), kind: kind, app: Self.frontApp()), at: 0)
        prune()
    }

    /// Bundle id of the frontmost app unless it is us.
    private static func frontApp() -> String? {
        let front = NSWorkspace.shared.frontmostApplication
        return front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front?.bundleIdentifier
    }

    /// The newest screenshot: the one `add` last wrote (works with history off), else the newest image entry.
    func lastScreenshot() -> Shot? {
        let last = Prefs.string(.lastShotURL)
        if !last.isEmpty, let s = Exporter.loadShot(URL(fileURLWithPath: last)) { return s }
        return entries.first { $0.kind == MediaKind.image.rawValue }.flatMap { Exporter.loadShot(url($0)) }
    }

    /// Renames a file (a project folder too) and its history entry; returns the new URL.
    func rename(_ url: URL, to name: String) throws -> URL {
        let dst = Exporter.uniqueURL(in: url.deletingLastPathComponent(), name: name, ext: url.pathExtension)
        try FileManager.default.moveItem(at: url, to: dst)
        let old = Self.canonicalPath(url)
        if let i = entries.firstIndex(where: { Self.canonicalPath(self.url($0)) == old }) {
            entries[i].file = dst.lastPathComponent
            persist()
        }
        return dst
    }

    /// Moves the files to the Trash (recoverable) and drops the entries.
    func delete(_ list: [Entry]) {
        let ids = Set(list.map(\.id))
        let urls = list.map(url)
        NSWorkspace.shared.recycle(urls) { _, _ in }
        entries.removeAll { ids.contains($0.id) }
        persist()
    }

    func delete(_ e: Entry) { delete([e]) }

    /// Drops the entry pointing at `fileURL` (when Quick Access trashed the file itself).
    func forget(fileURL: URL) {
        let target = Self.canonicalPath(fileURL)
        entries.removeAll { Self.canonicalPath(url($0)) == target }
        persist()
    }

    /// Standardized + symlink-resolved path (`/var/…` vs `/private/var/…`, `..` components). Uses realpath (on the parent
    /// when the file is already gone) because `resolvingSymlinksInPath` is inconsistent about `/private` for missing files.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        let u = url.standardizedFileURL
        func real(_ p: String) -> String? {
            guard let r = realpath(p, nil) else { return nil }
            defer { free(r) }
            return String(cString: r)
        }
        return real(u.path) ?? real(u.deletingLastPathComponent().path).map { ($0 as NSString).appendingPathComponent(u.lastPathComponent) } ?? u.path
    }

    func clear() { delete(entries) }

    /// Asks first (unless turned off with "Don't ask again"), then deletes.
    func confirmAndDelete(_ list: [Entry]) {
        guard !list.isEmpty else { return }
        if !Warnings.isSuppressed(Self.deleteWarning) {
            let a = NSAlert()
            a.messageText = list.count == 1 ? "Are you sure you want to delete \"%@\" from history?".loc(list[0].file)
                : list.count == entries.count ? "Delete every file in Capture History?"
                : "Are you sure you want to delete %d files from history?".loc(list.count)
            a.informativeText = "The files will be moved to the Trash."
            a.addButton(withTitle: "Delete")
            a.addButton(withTitle: "Cancel")
            guard Warnings.run(Self.deleteWarning, a) == .alertFirstButtonReturn else { return }
        }
        delete(list)
    }

    /// Puts an entry back on the Quick Access Overlay (projects open in the editor instead).
    func restore(_ e: Entry) {
        let u = url(e)
        switch e.mediaKind {
        case .image:
            guard let s = Exporter.loadShot(u) else { return }
            QuickAccess.shared.add(.image(s, fileURL: u, saved: false))
        case .video, .gif: QuickAccess.shared.add(.video(u, saved: false))
        case .project: VideoEditor.open(u)
        }
    }

    /// "Restore Last Capture".
    func restoreLast() {
        guard let e = entries.first(where: { FileManager.default.fileExists(atPath: url($0).path) }) else {
            Toast.show(isEnabled ? "Can't restore any files" : "Capture History is off.", isError: true)
            return
        }
        restore(e)
    }

    /// Opens an entry in its editor (Annotate for screenshots, the video editor for recordings and projects).
    func open(_ e: Entry) {
        let u = url(e)
        switch e.mediaKind {
        case .image: if let s = Exporter.loadShot(u) { AnnotateWindowController.open(shot: s) }
        case .video, .project: VideoEditor.open(u)
        case .gif: NSWorkspace.shared.open(u)
        }
    }

    /// Applies "Keep history": drops entries older than the window and those whose file is gone. "Never" keeps what's there
    /// (nothing new is recorded) so switching it off doesn't silently destroy captures — use Clear History for that.
    func prune() {
        let days = Prefs.int(.historyCapacity)
        let cutoff = days > 0 ? Date().addingTimeInterval(-Double(days) * 86400) : .distantPast
        let old = entries.filter { $0.date < cutoff }
        old.forEach { try? FileManager.default.removeItem(at: url($0)) }
        entries.removeAll { $0.date < cutoff || !FileManager.default.fileExists(atPath: url($0).path) }
        persist()
    }

    /// Files `add` wrote for Quick Access while history was off are never indexed; move them to the Trash after a day
    /// unless still on screen or the last screenshot. Only files listed in `historyUnindexed` (ours) are ever touched.
    private func removeOrphans() {
        let known = Set(entries.map(\.file))
        let keep = Set((QuickAccess.persistedPaths + [Prefs.string(.lastShotURL)]).map { Self.canonicalPath(URL(fileURLWithPath: $0)) })
        let dayAgo = Date().addingTimeInterval(-86400)
        var pending: [String] = [], trash: [URL] = []
        for name in Prefs.codable(.historyUnindexed, [String].self) ?? [] where !known.contains(name) {
            let u = folder.appendingPathComponent(name)
            guard let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue } // gone
            if date < dayAgo, !keep.contains(Self.canonicalPath(u)) { trash.append(u) } else { pending.append(name) }
        }
        if !trash.isEmpty { NSWorkspace.shared.recycle(trash) { _, _ in } }
        Prefs.setCodable(pending, .historyUnindexed)
    }

    /// Recovery for a corrupt index: one entry per capture file on disk (kind from the extension, date from creation).
    private func rebuildFromDisk() -> [Entry] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return files.filter { !$0.lastPathComponent.hasPrefix("index.json") }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Entry(file: u.lastPathComponent, date: v?.creationDate ?? v?.contentModificationDate ?? Date(), kind: MediaKind.detect(u).rawValue)
        }
        .sorted { $0.date > $1.date }
    }

    private func persist() {
        try? JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
    }

    static let deleteWarning = "historyDelete"

    private static func migrateLegacyPrefs() {
        // Old "Don't ask again" keys → `suppressWarning.<id>` so Settings › Advanced › Reset All Warning Dialogs covers them.
        for (old, id) in [("confirmHistoryDelete", deleteWarning), ("qaConfirmCloseAll", QuickAccess.closeAllWarning),
                          ("qaConfirmVideoDelete", QuickAccess.videoDeleteWarning)] where Prefs.d.object(forKey: old) != nil {
            if !Prefs.d.bool(forKey: old) { Prefs.d.set(true, forKey: Warnings.prefix + id) }
            Prefs.d.removeObject(forKey: old)
        }
        guard Prefs.d.object(forKey: Prefs.Key.historyCapacity.rawValue) == nil,
              Prefs.d.object(forKey: Prefs.Key.historyEnabled.rawValue) != nil || Prefs.d.object(forKey: Prefs.Key.historyDays.rawValue) != nil
        else { return }
        let days = Prefs.int(.historyDays)
        let choices: [Int] = [1, 3, 7, 30]
        let snapped = choices.min { (a: Int, b: Int) -> Bool in abs(a - days) < abs(b - days) } ?? 7
        Prefs.set(Prefs.bool(.historyEnabled) ? snapped : 0, .historyCapacity)
    }

    // MARK: Window

    private static var window: NSWindow?

    static func showWindow() {
        if window == nil {
            let w = QuickLookWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                                    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Capture History".loc
            w.minSize = CGSize(width: 560, height: 380)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HistoryView(history: shared))
            w.setFrameAutosaveName("CaptureHistory")
            if !w.setFrameUsingName("CaptureHistory") { w.center() }
            window = w
        }
        shared.prune()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static var windowRef: NSWindow? { window }
}
