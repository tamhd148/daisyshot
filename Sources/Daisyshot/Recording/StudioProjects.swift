import AppKit
import AVFoundation

extension Prefs.Key {
    static let studioProjectsFolder = Prefs.Key("studioProjectsFolder", "")   // empty = Daisyshot's library (History)
    static let studioRecentProjects = Prefs.Key("studioRecentProjects", "")   // newest first, one path per line
}

/// Where Studio projects live, the recently opened ones, projects made from plain videos, and raw-file extraction.
@MainActor
enum StudioProjects {
    /// The folder chosen in Settings, when it still exists.
    static var customFolder: URL? {
        let p = Prefs.string(.studioProjectsFolder)
        var isDir: ObjCBool = false
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    /// Moves a finished project folder to its home: the chosen folder, else Daisyshot's library (History when it's on).
    static func store(_ dir: URL, name: String) throws -> URL {
        let fm = FileManager.default
        if let folder = customFolder {
            let pkg = Exporter.uniqueURL(in: folder, name: name, ext: StudioCaptureLayout.ext)
            try fm.moveItem(at: dir, to: pkg)
            return pkg
        }
        let pkg = Exporter.uniqueURL(in: Recorder.recordingsFolder, name: name, ext: StudioCaptureLayout.ext)
        try fm.moveItem(at: dir, to: pkg)
        // One copy: moved into History when it's on, otherwise it stays in the Recordings folder.
        return History.shared.addFile(pkg, kind: "project", move: true) ?? pkg
    }

    // MARK: Recent

    static var recent: [URL] {
        Prefs.string(.studioRecentProjects).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func noteOpened(_ url: URL) {
        let list = [url] + recent.filter { $0.standardizedFileURL != url.standardizedFileURL }
        Prefs.set(list.prefix(10).map(\.path).joined(separator: "\n"), .studioRecentProjects)
    }

    // MARK: From a video

    /// Chooses a video and opens it as a new Studio project.
    static func chooseVideo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie]
        p.message = "Choose a video to make a Studio project from (background, zooms, crop, music…).".loc
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        createProject(from: url)
    }

    static func createProject(from video: URL) {
        Task {
            do { VideoEditor.open(try await project(from: video)) } catch { Toast.show(error.localizedDescription, isError: true) }
        }
    }

    /// A project around a copy of `video`: no pointer or keys (nothing was logged), everything else editable.
    static func project(from video: URL) async throws -> URL {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError("The file has no video.") }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let size = natural.applying(transform)
        let duration = try await asset.load(.duration).seconds
        let fm = FileManager.default
        let work = Recorder.inProgressFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let ext = video.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
            try fm.copyItem(at: video, to: work.appendingPathComponent("video." + ext))
            try StudioEventsFile(region: .init(x: 0, y: 0, width: abs(size.width), height: abs(size.height)), scale: 1, duration: duration, events: [])
                .write(to: work.appendingPathComponent(StudioCaptureLayout.events))
            return try store(work, name: video.deletingPathExtension().lastPathComponent)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    // MARK: Raw files

    /// Copies a project's recorded files (screen video with its audio tracks, camera, events, music) into a new folder.
    static func extractRawFiles(_ project: URL) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Extract".loc
        p.message = "Choose where to put the recording's raw files.".loc
        guard p.runModal() == .OK, let folder = p.url else { return }
        let fm = FileManager.default
        let name = project.deletingPathExtension().lastPathComponent
        var dst = folder.appendingPathComponent("%@ (raw files)".loc(name), isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dst.path) { dst = folder.appendingPathComponent("%@ (raw files)".loc(name) + " \(n)", isDirectory: true); n += 1 }
        do {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)
            // Not the edits (project.json) or files the editor derives (noise-reduced audio).
            for item in items where item.lastPathComponent != "project.json" && !item.lastPathComponent.hasPrefix(".")
                && !item.lastPathComponent.hasSuffix("-clean.m4a") {
                let renamed: String
                switch item.lastPathComponent {
                case "video.mp4", "video.mov": renamed = "\(name) - screen.\(item.pathExtension)"
                case "camera.mov", "camera.mp4": renamed = "\(name) - camera.\(item.pathExtension)"
                default: renamed = item.lastPathComponent
                }
                try fm.copyItem(at: item, to: dst.appendingPathComponent(renamed))
            }
            NSWorkspace.shared.activateFileViewerSelecting([dst])
        } catch {
            Toast.show(error.localizedDescription, isError: true)
        }
    }
}

extension StudioProjects {
    /// A plain video becomes a Studio project in the chosen folder; nil when it works, else what went wrong.
    static func selfTest() async -> String? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-projects-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let saved = Prefs.string(.studioProjectsFolder)
        defer { Prefs.set(saved, .studioProjectsFolder); try? FileManager.default.removeItem(at: tmp) }
        Prefs.set(tmp.path, .studioProjectsFolder)
        guard let sample = try? await StudioSample.make(in: tmp, seconds: 2), let pkg = try? StudioPackage.open(sample) else { return "no sample" }
        do {
            let project = try await project(from: pkg.videoURL)
            guard project.deletingLastPathComponent().standardizedFileURL == tmp.standardizedFileURL else { return "stored in \(project.path)" }
            let p = try StudioPackage.open(project)
            guard p.isStudio, p.events?.events.isEmpty == true, abs((p.events?.duration ?? 0) - 2) < 0.2 else { return "not a Studio project" }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
