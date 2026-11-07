import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// "Audio tracks: Single track": mixes every audio track of a recording into one, keeping the video untouched.
enum AudioMixer {
    static func mergeAudioTracks(of url: URL, mono: Bool) async throws {
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count > 1, let video = try await asset.loadTracks(withMediaType: .video).first else { return }
        let channels = mono ? 1 : 2
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".merge-\(UUID().uuidString).mp4")

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        let aOut = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(vOut)
        reader.add(aOut)

        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: try await video.load(.formatDescriptions).first)
        vIn.transform = try await video.load(.preferredTransform)
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000 * channels,
        ])
        writer.add(vIn)
        writer.add(aIn)

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? StreamRecorder.Failure(errorDescription: "Couldn't merge audio tracks.")
        }
        guard let first = vOut.copyNextSampleBuffer() else { throw StreamRecorder.Failure(errorDescription: "The recording has no video.") }
        writer.startSession(atSourceTime: first.presentationTimeStamp)
        vIn.append(first)
        async let v = pump(vOut, into: vIn, writer: writer, label: "video")
        async let a = pump(aOut, into: aIn, writer: writer, label: "audio")
        let (vDone, aDone) = await (v, a)
        if vDone, aDone, writer.status == .writing {
            await writer.finishWriting()
        } else {
            reader.cancelReading()
            writer.cancelWriting()
        }
        guard reader.status == .completed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw writer.error ?? reader.error ?? StreamRecorder.Failure(errorDescription: "Couldn't merge audio tracks.")
        }
        try FileManager.default.replaceRemovingBackup(url, with: tmp)
    }

    /// Copies `out` into `input`. Returns true when the source ran out normally, false if the writer failed or
    /// stalled. Finishes exactly once; a watchdog ends it when the writer stops writing (no more ready callbacks then).
    private static func pump(_ out: AVAssetReaderOutput, into input: AVAssetWriterInput, writer: AVAssetWriter, label: String) async -> Bool {
        final class State: @unchecked Sendable {     // only touched on `q`
            var finished = false
            var lastProgress = Date()
        }
        nonisolated(unsafe) let out = out, input = input, writer = writer
        let q = DispatchQueue(label: "daisyshot.merge.\(label)")
        let state = State()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            func end(_ ok: Bool) {
                guard !state.finished else { return }
                state.finished = true
                if writer.status == .writing { input.markAsFinished() }
                c.resume(returning: ok)
            }
            input.requestMediaDataWhenReady(on: q) {
                while !state.finished, input.isReadyForMoreMediaData {
                    guard writer.status == .writing else { return end(false) }
                    guard let sb = out.copyNextSampleBuffer() else { return end(true) }
                    guard input.append(sb) else { return end(false) }
                    state.lastProgress = Date()
                }
            }
            func watchdog() {
                q.asyncAfter(deadline: .now() + 0.5) {
                    guard !state.finished else { return }
                    if writer.status != .writing || Date().timeIntervalSince(state.lastProgress) > 30 { end(false) } else { watchdog() }
                }
            }
            watchdog()
        }
    }
}

extension FileManager {
    /// `replaceItemAt`, then removes the "<name>.sb-…" backup it can leave next to the file (a second full-size copy of
    /// a recording otherwise stays behind).
    func replaceRemovingBackup(_ url: URL, with new: URL) throws {
        _ = try replaceItemAt(url, withItemAt: new)
        let dir = url.deletingLastPathComponent(), prefix = url.lastPathComponent + ".sb-"
        for f in (try? contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasPrefix(prefix) {
            try? removeItem(at: dir.appendingPathComponent(f))
        }
    }
}

/// Video → animated GIF with ImageIO: frame-accurate delays, quality (color depth) and "Optimize GIFs"
/// (repeated frames merged into one longer frame — screen recordings are mostly static). Used by the recorder and
/// by the video editor's GIF export.
enum GIFEncoder {
    /// Sample times (seconds) for `fps` frames covering `duration`.
    static func frameTimes(duration: Double, fps: Int) -> [Double] {
        let count = max(1, Int((duration * Double(fps) - 1e-6).rounded(.up)))
        return (0..<count).map { Double($0) / Double(fps) }
    }

    /// Per-frame delays. GIF stores centiseconds, so round the cumulative time (not each frame) to avoid drift.
    static func frameDelays(count: Int, fps: Int) -> [Double] {
        (0..<count).map { i in
            ((Double(i + 1) * 100 / Double(fps)).rounded() - (Double(i) * 100 / Double(fps)).rounded()) / 100
        }
    }

    /// Levels per color channel for a quality of 10…100. Fewer levels = smaller, flatter GIF.
    static func levels(quality: Int, optimize: Bool) -> Int {
        let q = min(100, max(10, quality))
        if q >= 100 { return optimize ? 128 : 256 }
        return max(6, Int(pow(2, 3 + 5 * Double(q - 10) / 90).rounded()))
    }

    /// Throws `CancellationError` (and removes `dst`) when the task is cancelled. `progress` gets 0…1 in 1 % steps.
    static func convert(_ src: URL, to dst: URL, fps: Int, maxWidth: Int, quality: Int, optimize: Bool,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await convert(AVURLAsset(url: src), to: dst, fps: fps, maxWidth: maxWidth, quality: quality, optimize: optimize, progress: progress)
    }

    /// With a `videoComposition` (video editor export) frames are rendered through it at its render size.
    /// `loop` false: plays once (no NETSCAPE loop block).
    static func convert(_ asset: AVAsset, videoComposition: AVVideoComposition? = nil, to dst: URL, fps: Int, maxWidth: Int,
                        quality: Int, optimize: Bool, loop: Bool = true, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let fps = min(max(fps, 1), 50)   // delays under 2cs get slowed to 10cs by most viewers
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw StreamRecorder.Failure(errorDescription: "No video track.") }
        let natural = if let videoComposition { videoComposition.renderSize } else { try await track.load(.naturalSize) }
        let duration = try await asset.load(.duration).seconds
        let times = frameTimes(duration: duration, fps: fps).map { CMTime(seconds: $0, preferredTimescale: 6000) }
        let delays = frameDelays(count: times.count, fps: fps)

        let scale = min(1, Double(max(16, maxWidth)) / max(1, natural.width))
        let w = max(1, Int(natural.width * scale)), h = max(1, Int(natural.height * scale))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.videoComposition = videoComposition
        gen.maximumSize = CGSize(width: w, height: h)
        let tolerance = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance

        guard let dest = CGImageDestinationCreateWithURL(dst as CFURL, UTType.gif.identifier as CFString, times.count, nil),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let pixels = ctx.data
        else { throw StreamRecorder.Failure(errorDescription: "Couldn't create the GIF file.") }
        if loop { CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary) }

        let lut = posterizeTable(levels: levels(quality: quality, optimize: optimize))
        let byteCount = w * h * 4
        var previous = [UInt8]()
        var pending: (image: CGImage, delay: Double)?
        var written = 0
        func flush() {
            guard let p = pending else { return }
            let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: p.delay, kCGImagePropertyGIFUnclampedDelayTime: p.delay]]
            CGImageDestinationAddImage(dest, p.image, props as CFDictionary)
            written += 1
        }

        var i = 0
        var last: CGImage?
        var percent = -1
        for await result in gen.images(for: times) {
            if Task.isCancelled { break }
            guard i < delays.count, let image = (try? result.image) ?? last else { continue }
            if let progress, Int(Double(i) * 100 / Double(delays.count)) != percent {
                percent = Int(Double(i) * 100 / Double(delays.count))
                progress(Double(percent) / 100)
            }
            last = image
            let delay = delays[i]
            i += 1
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let buf = pixels.bindMemory(to: UInt8.self, capacity: byteCount)
            if let lut { for j in 0..<byteCount { buf[j] = lut[Int(buf[j])] } }
            if optimize, pending != nil, previous.count == byteCount, memcmp(previous, buf, byteCount) == 0 {
                pending!.delay += delay
                continue
            }
            flush()
            if optimize { previous = Array(UnsafeBufferPointer(start: buf, count: byteCount)) }
            guard let frame = ctx.makeImage() else { continue }
            pending = (frame, delay)
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: dst)
            throw CancellationError()
        }
        flush()
        guard written > 0, CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: dst)
            throw StreamRecorder.Failure(errorDescription: "Couldn't render GIF frames.")
        }
    }

    private static func posterizeTable(levels: Int) -> [UInt8]? {
        guard levels < 256 else { return nil }
        let n = Double(levels - 1)
        return (0..<256).map { UInt8((Double($0) / 255 * n).rounded() / n * 255) }
    }

    static func selfTest() {
        assert(frameTimes(duration: 1, fps: 15).count == 15)
        assert(frameTimes(duration: 1.01, fps: 10).count == 11)
        for fps in [1, 7, 10, 15, 24, 30, 45, 50] {
            let d = frameDelays(count: 97, fps: fps)
            assert(d.allSatisfy { $0 >= 0.02 }, "browsers slow down GIF frames shorter than 2cs")
            assert(abs(d.reduce(0, +) - (97.0 / Double(fps) * 100).rounded() / 100) < 1e-9, "no cumulative drift")
        }
        assert(levels(quality: 100, optimize: false) == 256 && levels(quality: 10, optimize: false) == 8)
        assert(levels(quality: 50, optimize: false) < levels(quality: 80, optimize: false))
        let t = posterizeTable(levels: 8)!
        assert(t[0] == 0 && t[255] == 255 && Set(t).count == 8)
    }
}

/// Small floating progress bar with Cancel (GIF conversion).
@MainActor
final class ProgressPanel {
    @MainActor final class Model: ObservableObject {
        @Published var progress = 0.0
    }

    let model = Model()
    let title: String
    var onCancel: (() -> Void)?
    private var panel: FloatingPanel?

    init(title: String) { self.title = title }

    func show() {
        let view = NSHostingView(rootView: ProgressPanelView(title: title, model: model) { [weak self] in self?.onCancel?() })
        let size = view.fittingSize
        let s = NSScreen.underMouse.visibleFrame
        let p = FloatingPanel(rect: CGRect(x: s.midX - size.width / 2, y: s.minY + 80, width: size.width, height: size.height), level: .statusBar)
        p.contentView = view
        p.orderFrontRegardless()
        panel = p
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ProgressPanelView: View {
    let title: String
    @ObservedObject var model: ProgressPanel.Model
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.loc).font(.system(size: 13, weight: .medium))
                ProgressView(value: model.progress).frame(width: 200)
            }
            Button("Cancel", action: cancel)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark)
    }
}
