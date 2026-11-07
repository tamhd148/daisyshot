import AVFoundation
import CoreImage

// MARK: - Export options

enum StudioExportFormat: String, CaseIterable { case mp4, gif }

enum StudioResolution: Int, CaseIterable, Identifiable {
    case original = 0, r4k = 2160, r1440 = 1440, r1080 = 1080, r720 = 720, r480 = 480, r360 = 360, r240 = 240
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .r4k: return "4K"
        default: return "\(rawValue)p"
        }
    }

    /// "1080p" = 1080 pixels on the short side, keeping the canvas aspect. Never upscales. Even dimensions for H.264.
    func size(for canvas: CGSize) -> CGSize {
        let k = self == .original ? 1 : min(1, CGFloat(rawValue) / max(1, min(canvas.width, canvas.height)))
        return CGSize(width: max(2, (canvas.width * k / 2).rounded() * 2), height: max(2, (canvas.height * k / 2).rounded() * 2))
    }

    /// Choices that actually shrink `canvas` (bigger ones would render the original size again).
    static func choices(for canvas: CGSize) -> [StudioResolution] {
        allCases.filter { $0 == .original || CGFloat($0.rawValue) < min(canvas.width, canvas.height) }
    }
}

enum StudioQuality: Int, CaseIterable {
    case veryLow, low, medium, high, best
    var title: String { ["Very Low", "Low", "Medium", "High", "Best"][rawValue] }
    /// H.264 bits per pixel per frame; screen content compresses well, so these stay modest.
    var bitsPerPixel: Double { [0.025, 0.045, 0.075, 0.11, 0.18][rawValue] }
    var gifFPS: Int { [8, 10, 15, 20, 25][rawValue] }

    func bitrate(_ size: CGSize, fps: Double) -> Int {
        Int(max(400_000, size.width * size.height * fps * bitsPerPixel))
    }
}

struct StudioExportOptions {
    var format = StudioExportFormat.mp4
    var resolution = StudioResolution.original
    var quality = StudioQuality.high
    var includeAudio = true
    var mono = false
    var replaceOriginal = false
    var fps = 0                     // MP4 frame rate; 0 = the recording's (never above it)
    var copyToClipboard = false
    var gifLoop = true              // false: the GIF plays once
    var aspect: StudioAspect?       // an extra version: this frame shape, filled by the recording, following the cursor

    static let fpsChoices = [60, 50, 30, 25, 24, 20, 10]

    /// The export sheet's last settings (one-key exports, Quick Export).
    @MainActor
    static func last(format: StudioExportFormat, mono: Bool, copy: Bool) -> StudioExportOptions {
        let p = Prefs.self
        return StudioExportOptions(format: format, resolution: StudioResolution(rawValue: p.int(.studioExportResolution)) ?? .original,
                                   quality: StudioQuality(rawValue: p.int(.studioExportQuality)) ?? .high,
                                   includeAudio: p.bool(.studioExportAudio), mono: mono,
                                   fps: fpsChoices.contains(p.int(.studioExportFPS)) ? p.int(.studioExportFPS) : 0,
                                   copyToClipboard: copy, gifLoop: p.bool(.studioExportGIFLoop))
    }

    func frameRate(source: Double) -> Double { fps > 0 ? min(source, Double(fps)) : source }

    func estimatedBytes(canvas: CGSize, duration: Double, fps: Double, hasAudio: Bool) -> Double {
        let size = resolution.size(for: canvas)
        switch format {
        case .mp4:
            let audio = includeAudio && hasAudio ? (mono ? 96_000.0 : 160_000) : 0
            return (Double(quality.bitrate(size, fps: frameRate(source: fps))) + audio) * duration / 8
        case .gif:
            return size.width * size.height * 0.22 * Double(quality.gifFPS) * duration
        }
    }
}

// MARK: - Engine

/// Renders a composition through the Studio compositor into an MP4 (reader → writer, so bitrate and mono are controllable).
final class StudioExportJob: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    func writeMP4(_ comp: AVComposition, video vc: AVVideoComposition, audioMix: AVAudioMix?, options: StudioExportOptions,
                  fps: Double, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let reader = try AVAssetReader(asset: comp)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: comp.tracks(withMediaType: .video).filter { !$0.segments.isEmpty },
                                                           videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = vc
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        let channels = options.mono ? 1 : 2
        let audioTracks = comp.tracks(withMediaType: .audio).filter { !$0.segments.isEmpty }
        var audioOut: AVAssetReaderAudioMixOutput?
        if options.includeAudio, !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            o.audioMix = audioMix
            o.audioTimePitchAlgorithm = .spectral          // sped-up clips keep their pitch
            reader.add(o)
            audioOut = o
        }

        let size = vc.renderSize
        let fileType: AVFileType = switch url.pathExtension.lowercased() { case "mov": .mov; case "m4v": .m4v; default: .mp4 }
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.quality.bitrate(size, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: options.mono ? 96_000 : 160_000,
            ])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            audioIn = a
        }

        guard reader.startReading() else { throw reader.error ?? StudioError("Couldn't read the recording.") }
        guard writer.startWriting() else { throw writer.error ?? StudioError("Couldn't create the video file.") }
        writer.startSession(atSourceTime: .zero)
        let duration = max(0.001, comp.duration.seconds)

        // Both pumps and the finish run on one serial queue, so nothing appends after the writer is torn down.
        // A failed writer stops calling back the other input; the watchdog notices and ends the wait.
        let queue = DispatchQueue(label: "app.daisyshot.studio.export")
        let state = PumpState(open: audioIn == nil ? 1 : 2)
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            state.done = done
            let shouldStop = { [self] in isCancelled || writer.status != .writing || reader.status == .failed }
            watchdog.schedule(deadline: .now() + 0.25, repeating: 0.25)
            watchdog.setEventHandler {
                guard shouldStop() else { return }
                reader.cancelReading()      // unblocks a pending copyNextSampleBuffer
                queue.async { state.finish() }
            }
            watchdog.resume()
            pump(videoIn, videoOut, reader: reader, queue: queue, state: state, shouldStop: shouldStop) { pts in progress(min(1, pts / duration)) }
            if let audioIn, let audioOut { pump(audioIn, audioOut, reader: reader, queue: queue, state: state, shouldStop: shouldStop) { _ in } }
        }
        watchdog.cancel()

        if isCancelled || reader.status == .failed || writer.status != .writing {
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            if isCancelled { throw CancellationError() }
            throw writer.error ?? reader.error ?? StudioError("Rendering failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? StudioError("Couldn't finish the video file.")
        }
    }

    /// Wait state shared by the pumps; only touched on the export queue.
    private final class PumpState: @unchecked Sendable {
        var open: Int
        var done: CheckedContinuation<Void, Never>?
        init(open: Int) { self.open = open }

        /// Resumes the export exactly once.
        func finish() {
            done?.resume()
            done = nil
        }
    }

    private func pump(_ input: AVAssetWriterInput, _ output: AVAssetReaderOutput, reader: AVAssetReader, queue: DispatchQueue, state: PumpState,
                      shouldStop: @escaping () -> Bool, onSample: @escaping (Double) -> Void) {
        var finished = false
        input.requestMediaDataWhenReady(on: queue) {
            guard !finished, state.done != nil else { return }
            while input.isReadyForMoreMediaData {
                let next = shouldStop() || reader.status != .reading ? nil : output.copyNextSampleBuffer()
                guard let sb = next, input.append(sb) else {
                    finished = true
                    if !shouldStop() { input.markAsFinished() }
                    state.open -= 1
                    if state.open == 0 || shouldStop() { state.finish() }
                    return
                }
                onSample(CMSampleBufferGetPresentationTimeStamp(sb).seconds)
            }
        }
    }

    /// One fully rendered frame of the composition at output time `t`.
    static func frame(_ comp: AVComposition, video vc: AVVideoComposition, at t: Double) async throws -> CGImage {
        let gen = AVAssetImageGenerator(asset: comp)
        gen.videoComposition = vc
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: min(max(0, t), max(0, comp.duration.seconds - 0.001)), preferredTimescale: 60_000)
        return try await gen.image(at: time).image
    }
}

// MARK: - Audio waveform

enum StudioWaveform {
    static let binsPerSecond = 50.0

    /// Peak amplitude per bin (0…1) of all audio tracks mixed down, for the timeline.
    static func peaks(asset: AVAsset, tracks: [AVAssetTrack]) async -> [Float] {
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: asset) else { return [] }
        let rate = 8_000.0
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        guard reader.startReading() else { return [] }
        let per = Int(rate / binsPerSecond)
        var peaks: [Float] = [], current: Float = 0, count = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            let n = length / 4
            ptr.withMemoryRebound(to: Float.self, capacity: n) { f in
                for i in 0..<n {
                    current = max(current, abs(f[i]))
                    count += 1
                    if count == per { peaks.append(current); current = 0; count = 0 }
                }
            }
        }
        if count > 0 { peaks.append(current) }
        let top = max(0.05, peaks.max() ?? 1)
        return peaks.map { min(1, $0 / top) }
    }
}
