import AppKit
import UniformTypeIdentifiers

/// Named Studio looks (cursor, keystrokes, camera, background, animation) saved as `.daisyshotpreset` files in
/// Application Support › Studio Presets — applied with one click, shareable as files.
enum StudioPresets {
    static let ext = "daisyshotpreset"

    static var folder: URL {
        let u = Prefs.supportFolder.appendingPathComponent("Studio Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Saved presets, by name.
    static func all() -> [(name: String, url: URL)] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == ext }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The look of `doc` without anything tied to one recording (clips, zooms, masks, typing, audio).
    static func style(of doc: StudioDocument) -> StudioDocument {
        var s = doc
        s.clips = []
        s.zooms = []
        s.masks = []
        s.typingDismissed = []
        s.audio = .init()
        s.music = .init()
        s.layouts = []
        s.crop = .init()
        return s
    }

    /// `doc` with `preset`'s look; its edits (clips, zooms, masks, audio…) stay.
    static func apply(_ preset: StudioDocument, to doc: StudioDocument) -> StudioDocument {
        var d = doc
        d.cursor = preset.cursor
        d.keystrokes.show = preset.keystrokes.show
        d.keystrokes.size = preset.keystrokes.size
        d.keystrokes.light = preset.keystrokes.light
        d.keystrokes.position = preset.keystrokes.position
        d.keystrokes.allKeys = preset.keystrokes.allKeys
        d.camera = preset.camera
        d.background = preset.background
        d.animation = preset.animation
        return d
    }

    /// Custom background images presets use, kept next to them (a project's image can move or go away).
    static var assets: URL {
        let u = folder.appendingPathComponent("Assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    static func save(_ doc: StudioDocument, name: String) throws -> URL {
        let url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var s = style(of: doc)
        // A custom image (not a macOS wallpaper) is copied into the presets' assets.
        let img = s.background.imagePath
        if s.background.kind == .image, !img.isEmpty, !MacWallpapers.isMacWallpaper(img), !img.hasPrefix(assets.path),
           FileManager.default.fileExists(atPath: img) {
            let dst = assets.appendingPathComponent(UUID().uuidString).appendingPathExtension(URL(fileURLWithPath: img).pathExtension)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: img), to: dst)
            s.background.imagePath = dst.path
        }
        guard let data = StudioJSON.encode(s) else { throw StudioError("Couldn't save the preset.") }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A preset file to share: its custom background image goes inside (base64), so another Mac gets the same look.
    static func exportPreset(_ url: URL, to dst: URL) throws {
        guard let data = try? Data(contentsOf: url), var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StudioError("Couldn't save the preset.")
        }
        if let p = load(url), p.background.kind == .image, !MacWallpapers.isMacWallpaper(p.background.imagePath),
           let img = try? Data(contentsOf: URL(fileURLWithPath: p.background.imagePath)) {
            obj["embeddedImage"] = img.base64EncodedString()
            obj["embeddedImageExtension"] = URL(fileURLWithPath: p.background.imagePath).pathExtension
        }
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: dst, options: .atomic)
    }

    /// Copies a preset file into the presets folder, unpacking an embedded background image. Returns the stored preset.
    static func importPreset(_ src: URL) throws -> URL {
        guard let data = try? Data(contentsOf: src), var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              load(src) != nil else { throw StudioError("That isn't a Daisyshot preset.") }
        if let b64 = obj.removeValue(forKey: "embeddedImage") as? String, let img = Data(base64Encoded: b64) {
            let ext = (obj.removeValue(forKey: "embeddedImageExtension") as? String) ?? "png"
            let file = assets.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try img.write(to: file)
            if var bg = obj["background"] as? [String: Any] { bg["imagePath"] = file.path; obj["background"] = bg }
        }
        let dst = Exporter.uniqueURL(in: folder, name: src.deletingPathExtension().lastPathComponent, ext: ext)
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: dst, options: .atomic)
        return dst
    }

    static func load(_ url: URL) -> StudioDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return StudioJSON.decode(StudioDocument.self, from: data, defaults: StudioDocument())
    }

    static var type: UTType { UTType(filenameExtension: ext) ?? .json }

    static func selfTest() {
        var doc = StudioDocument(clips: [.init(start: 0, duration: 5)])
        doc.masks = [.init(start: 0, end: 1)]
        doc.background.padding = 0.2
        doc.keystrokes.hidden = ["⌘C"]
        let s = style(of: doc)
        assert(s.clips.isEmpty && s.masks.isEmpty && s.background.padding == 0.2, "style keeps the look, drops the edits")
        var other = StudioDocument(clips: [.init(start: 0, duration: 9)])
        other.keystrokes.hidden = ["⌘V"]
        let applied = apply(s, to: other)
        assert(applied.clips.count == 1 && applied.clips[0].duration == 9 && applied.background.padding == 0.2)
        assert(applied.keystrokes.hidden == ["⌘V"], "hidden shortcuts belong to the recording")
    }
}
