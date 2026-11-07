import AppKit
import AVFoundation
import AVKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Video editor entry point. Opens Studio projects (`.daisyshotvideo` packages: restyled cursor, zooms, camera,
/// keystrokes, backgrounds) and plain videos (trim / split / cut / zoom / background / export) in the same editor.
@MainActor
enum VideoEditor {
    private static var controllers: [URL: StudioWindowController] = [:]
    private static var opening: Set<URL> = []

    /// GIFs are edited through their source video (kept by the recorder) or a temporary video converted from the GIF,
    /// and export back to GIF. `replaceOriginal` picks the default export destination; by default it's on for files
    /// opened from Quick Access (trimming replaces the capture).
    static func open(_ url: URL, replaceOriginal: Bool? = nil) {
        let url = url.standardizedFileURL
        let isGIF = url.pathExtension.lowercased() == "gif"
        let package: StudioPackage?
        do { package = isGIF ? nil : try StudioPackage.open(url) } catch { fail(url, error); return }
        let key = package?.url ?? url
        if let existing = controllers[key] {
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard opening.insert(key).inserted else { return }
        let qaItem = QuickAccess.shared.items.first { $0.url.standardizedFileURL == url }
        let base = StudioOpenOptions(replace: replaceOriginal ?? (qaItem != nil), saved: qaItem?.saved ?? true)
        Task {
            defer { opening.remove(key) }
            var options = base
            do {
                let pkg: StudioPackage
                if let package {
                    pkg = package
                    if !pkg.isStudio { options.original = pkg.videoURL }
                } else {
                    options.original = url
                    options.name = url.deletingPathExtension().lastPathComponent
                    options.format = .gif
                    let source = Recorder.gifSourceURL(for: url)
                    if FileManager.default.fileExists(atPath: source.path) {
                        pkg = try StudioPackage.open(source)
                    } else {
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-GIF-\(UUID().uuidString)", isDirectory: true)
                        options.tempFolder = tmp
                        let video = tmp.appendingPathComponent(options.name!).appendingPathExtension("mp4")
                        NotificationCenter.default.post(name: .daisyshotBusyDidChange, object: true)
                        defer { NotificationCenter.default.post(name: .daisyshotBusyDidChange, object: false) }
                        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                        try await GIFMaker.video(fromGIF: url, to: video)
                        pkg = try StudioPackage.open(video)
                    }
                }
                let sources = try await StudioSources.load(pkg)
                if pkg.isStudio { Prefs.set(pkg.url.path, .studioLastProject); StudioProjects.noteOpened(pkg.url) }
                let c = StudioWindowController(package: pkg, options: options)
                controllers[key] = c
                c.onClose = { controllers[key] = nil }
                c.show(sources)
            } catch {
                if let tmp = options.tempFolder { try? FileManager.default.removeItem(at: tmp) }
                fail(url, error)
            }
        }
    }

    /// Closes the editor showing `url`, if any (renaming a project reopens it under the new name).
    static func close(_ url: URL) {
        controllers[url.standardizedFileURL]?.window.performClose(nil)
    }

    /// The Studio project opened last (shortcut "Open Last Project").
    static func openLastProject() {
        let p = Prefs.string(.studioLastProject)
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p) else { Toast.show("No recent project", isError: true); return }
        open(URL(fileURLWithPath: p))
    }

    private static func fail(_ url: URL, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“%@” can't be opened in the video editor.".loc(url.lastPathComponent)
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Animated GIF → video, for editing GIFs that have no kept source video.
enum GIFMaker {
    /// Frame delay in seconds; like browsers, delays under 2 cs play at 10 cs.
    static func delay(_ props: [CFString: Any]?) -> Double {
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return d < 0.015 ? 0.1 : d
    }

    /// Animated GIF → H.264 video (opaque, white behind transparency), keeping each frame's delay. Used to edit foreign GIFs.
    static func video(fromGIF gif: URL, to dst: URL) async throws {
        guard let src = CGImageSourceCreateWithURL(gif as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw StudioError("The GIF couldn't be read.") }
        let w = (first.width + 1) / 2 * 2, h = (first.height + 1) / 2 * 2   // H.264 wants even dimensions
        try? FileManager.default.removeItem(at: dst)
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StudioError("Couldn't create the video file.") }
        writer.startSession(atSourceTime: .zero)
        var cs: Int64 = 0   // GIF delays are centiseconds, so timestamps are exact at timescale 100
        for i in 0..<CGImageSourceGetCount(src) {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            while !input.isReadyForMoreMediaData {   // ponytail: polling; offline writer drains fast
                guard writer.status == .writing else { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            guard writer.status == .writing, let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(img, in: CGRect(x: 0, y: h - img.height, width: img.width, height: img.height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: cs, timescale: 100)) else { break }
            cs += max(1, Int64((delay(props) * 100).rounded()))
        }
        if writer.status == .writing {
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: cs, timescale: 100))   // the last frame keeps its delay
            await writer.finishWriting()
        }
        guard writer.status == .completed, cs > 0 else {
            try? FileManager.default.removeItem(at: dst)
            throw writer.error ?? StudioError("Couldn't convert the GIF to a video.")
        }
    }
}
