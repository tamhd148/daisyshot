// One binary for both Quick Look extensions (QuickLookExtension, QuickLookThumbnailingExtension) of `.daisyshot` files
// and `.daisyshotvideo` packages.
// A `.daisyshot` file is JSON. Newer files carry rendered `previewPNG` / `thumbnailPNG` (base64); older ones only have
// the original screenshot in `image`, which we show as-is (annotations are not rendered here).
// A `.daisyshotvideo` package holds `video.mp4` (or `video.mov`): previewed as that movie, thumbnailed by its first frame.
import AppKit
import AVFoundation
import QuickLookThumbnailing
import QuickLookUI
import UniformTypeIdentifiers

enum DaisyshotDocument {
    /// PNG bytes plus the document's pixels-per-point `scale`.
    static func png(at url: URL, thumbnail: Bool) throws -> (data: Data, scale: CGFloat) {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let keys = thumbnail ? ["thumbnailPNG", "previewPNG", "image"] : ["previewPNG", "image"]
        for key in keys {
            if let s = json?[key] as? String, let data = Data(base64Encoded: s), !data.isEmpty {
                return (data, max(1, json?["scale"] as? CGFloat ?? 1))
            }
        }
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
    }

    static func image(at url: URL, thumbnail: Bool) throws -> CGImage {
        let data = try png(at: url, thumbnail: thumbnail).data
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        return img
    }
}

enum DaisyshotVideoProject {
    static func isProject(_ url: URL) -> Bool { url.pathExtension.lowercased() == "daisyshotvideo" }

    static func video(in package: URL) throws -> URL {
        let found = ["video.mp4", "video.mov"].map { package.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let found else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: package.path]) }
        return found
    }

    static func firstFrame(of package: URL, maxPixels: CGSize) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: try video(in: package)))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maxPixels
        return try await gen.image(at: .zero).image
    }
}

@objc(DaisyshotPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        // Video project: hand Quick Look the package's movie, which it plays with its own player.
        if DaisyshotVideoProject.isProject(request.fileURL) { return QLPreviewReply(fileURL: try DaisyshotVideoProject.video(in: request.fileURL)) }
        let (data, scale) = try DaisyshotDocument.png(at: request.fileURL, thumbnail: false)
        let px = NSBitmapImageRep(data: data).map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? CGSize(width: 800, height: 600)
        let size = CGSize(width: px.width / scale, height: px.height / scale) // points, so Retina shots aren't 2× too big
        return QLPreviewReply(dataOfContentType: .png, contentSize: size) { _ in data }
    }
}

@objc(DaisyshotThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard DaisyshotVideoProject.isProject(request.fileURL) else {
            return Self.reply(request, handler) { try DaisyshotDocument.image(at: request.fileURL, thumbnail: true) }
        }
        let px = CGSize(width: request.maximumSize.width * request.scale, height: request.maximumSize.height * request.scale)
        Task {
            do {
                let img = try await DaisyshotVideoProject.firstFrame(of: request.fileURL, maxPixels: px)
                Self.reply(request, handler) { img }
            } catch {
                handler(nil, error)
            }
        }
    }

    /// Draws the image aspect-fit into the requested maximum size (never upscaled).
    private static func reply(_ request: QLFileThumbnailRequest, _ handler: (QLThumbnailReply?, Error?) -> Void, _ image: () throws -> CGImage) {
        do {
            let img = try image()
            let w = CGFloat(img.width), h = CGFloat(img.height)
            let k = min(request.maximumSize.width / w, request.maximumSize.height / h, 1)
            let size = CGSize(width: max(1, w * k), height: max(1, h * k))
            handler(QLThumbnailReply(contextSize: size) { ctx in
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(origin: .zero, size: size))
                return true
            }, nil)
        } catch {
            handler(nil, error)
        }
    }
}
