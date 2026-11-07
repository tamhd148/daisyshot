import AppKit
import ImageIO

/// macOS desktop pictures installed on this Mac (/System/Library/Desktop Pictures) as Studio backgrounds.
/// Wallpapers macOS only downloads on demand, or draws live (Ventura, Monterey, Sequoia, Tahoe), aren't offered.
enum MacWallpapers {
    struct Item: Identifiable, Hashable, Sendable {
        let id: String              // "Sonoma", "iMac Blue"
        let file: URL
        let thumbnail: URL
    }

    static let systemFolder = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)

    /// Sonoma (the landscape) first, then alphabetical.
    static let all: [Item] = {
        let thumbs = systemFolder.appendingPathComponent(".thumbnails", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: systemFolder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.filter { ["heic", "jpg", "png"].contains($0.pathExtension.lowercased()) }
            .map { f in
                let id = f.deletingPathExtension().lastPathComponent
                let t = thumbs.appendingPathComponent(id).appendingPathExtension("heic")
                return Item(id: id, file: f, thumbnail: FileManager.default.fileExists(atPath: t.path) ? t : f)
            }
            .sorted { ($0.id == "Sonoma" ? 0 : 1, $0.id.lowercased()) < ($1.id == "Sonoma" ? 0 : 1, $1.id.lowercased()) }
    }()

    static func isMacWallpaper(_ path: String) -> Bool { path.hasPrefix(systemFolder.path + "/") }

    private static let thumbLock = NSLock()
    nonisolated(unsafe) private static var thumbs: [URL: CGImage] = [:]

    /// A small preview of any picture (decoded once, never the 6K original on every redraw).
    static func thumbnail(_ url: URL, maxSide: Int = 160) -> CGImage? {
        if let hit = thumbLock.withLock({ thumbs[url] }) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary)
        else { return nil }
        thumbLock.withLock { thumbs[url] = img }
        return img
    }

    static func selfTest() {
        if let first = all.first { assert(thumbnail(first.thumbnail) != nil, "thumbnail \(first.id)") }
        assert(isMacWallpaper(systemFolder.appendingPathComponent("Sonoma.heic").path) && !isMacWallpaper("/Users/x/a.png"))
    }
}
