import AppKit
import AVFoundation
import QuickLookThumbnailing
import SwiftUI

/// What a captured file is. History stores the raw value in `History.Entry.kind`.
enum MediaKind: String, CaseIterable {
    case image, video, gif, project

    static let projectExtension = "daisyshotvideo"

    static func detect(_ url: URL) -> MediaKind {
        switch url.pathExtension.lowercased() {
        case "gif": return .gif
        case projectExtension: return .project
        case "mov", "mp4", "m4v": return .video
        default: return .image
        }
    }

    var isMotion: Bool { self != .image }
}

/// Thumbnails and metadata for captures (images, videos, GIFs, video projects).
enum MediaInfo {
    private static let cache = NSCache<NSString, NSImage>()

    /// Quick Look thumbnail (works for any file type, packages included); falls back to the Finder icon.
    static func thumbnail(_ url: URL, maxPixels: CGFloat = 600) async -> NSImage {
        let key = "\(url.path)#\(Int(maxPixels))" as NSString
        if let img = cache.object(forKey: key) { return img }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxPixels, height: maxPixels), scale: 1, representationTypes: .thumbnail)
        let img = (try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req))?.nsImage
            ?? NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(img, forKey: key)
        return img
    }

    /// Call after rewriting a file in place (rotate / flip / scale) so stale thumbnails aren't shown.
    static func invalidateThumbnails() { cache.removeAllObjects() }

    struct VideoInfo { var duration: Double; var hasAudio: Bool }

    static func videoInfo(_ url: URL) async -> VideoInfo? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration) else { return nil }
        let audio = (try? await asset.loadTracks(withMediaType: .audio))?.isEmpty == false
        return VideoInfo(duration: d.seconds.isFinite ? d.seconds : 0, hasAudio: audio)
    }

    /// GIF duration from its frame delays.
    static func gifDuration(_ url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var total = 0.0
        for i in 0..<CGImageSourceGetCount(src) {
            let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let g = p?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            total += (g?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (g?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        }
        return total
    }

    static func fileSize(_ url: URL) -> String? {
        guard let n = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])).flatMap({ $0.fileSize ?? $0.totalFileAllocatedSize }) else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// 75.4 → "1:15", 3725 → "1:02:05".
    static func durationString(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func selfTest() {
        assert(durationString(75.4) == "1:15")
        assert(durationString(3725) == "1:02:05")
        assert(durationString(0.2) == "0:00")
        assert(MediaKind.detect(URL(fileURLWithPath: "/a/b.GIF")) == .gif)
        assert(MediaKind.detect(URL(fileURLWithPath: "/a/b.daisyshotvideo")) == .project)
        assert(MediaKind.detect(URL(fileURLWithPath: "/a/b.mp4")) == .video)
    }
}

/// Light/dark checkerboard drawn behind thumbnails so transparency is visible.
struct Checkerboard: View {
    var cell: CGFloat = 8
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let dark = scheme == .dark
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dark ? Color(white: 0.22) : .white))
            var p = Path()
            for row in 0..<Int(ceil(size.height / cell)) {
                for col in 0..<Int(ceil(size.width / cell)) where (row + col) % 2 == 0 {
                    p.addRect(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            ctx.fill(p, with: .color(dark ? Color(white: 0.3) : Color(white: 0.88)))
        }
    }
}
