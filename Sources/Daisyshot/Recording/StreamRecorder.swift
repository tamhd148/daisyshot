import AVFoundation
import ScreenCaptureKit

/// What `Recorder` drives: a screen stream (`StreamRecorder`) or a connected iPhone / iPad (`DeviceRecorder`).
protocol RecordingOutput: AnyObject, Sendable {
    var url: URL { get }
    /// Called once when capture or the file writer fails mid-recording.
    var onStop: (@Sendable (Error) -> Void)? { get set }
    /// Called once when the microphone stays silent for the first ~5 seconds.
    var onMicSilence: (@Sendable () -> Void)? { get set }
    /// Host-clock time of the first frame, i.e. video time zero (nil until a frame was written).
    var sessionStart: CMTime? { get }
    var audioTrackCount: Int { get }
    func start() async throws
    func setTimeline(_ t: PauseTimeline)
    func setMicMuted(_ m: Bool)
    func finish(at stopTime: CMTime) async throws
    func discard() async
}

/// One SCStream feeding one `SampleWriter` (video + optional system-audio and microphone tracks).
final class StreamRecorder: NSObject, SCStreamOutput, SCStreamDelegate, RecordingOutput, @unchecked Sendable {
    var url: URL { writer.url }
    var onStop: (@Sendable (Error) -> Void)? {
        get { writer.onStop }
        set { writer.onStop = newValue }
    }
    var onMicSilence: (@Sendable () -> Void)? {
        get { writer.onMicSilence }
        set { writer.onMicSilence = newValue }
    }

    private let writer: SampleWriter
    private var stream: SCStream!
    private var audioStream: SCStream?        // system audio from chosen apps only (the video stream then has none)

    typealias Failure = SampleWriter.Failure

    /// What to capture and how to encode it.
    struct Config {
        var sourceRect: CGRect?         // display-local points; nil = the whole filter (a single-window capture)
        var width: Int                  // output pixels (even)
        var height: Int
        var fps: Int
        var showsCursor: Bool
        var systemAudio: Bool
        var micDeviceID: String?        // nil = no microphone; "" = system default input
        var mono: Bool
        var quality: String             // low | medium | high | max
    }

    /// `audioFilter`: record system audio only from the apps in this filter instead of from the whole video filter.
    init(url: URL, filter: SCContentFilter, audioFilter: SCContentFilter? = nil, config c: Config) throws {
        let fps = max(1, min(120, c.fps))
        let w = c.width, h = c.height
        guard w >= 2, h >= 2 else { throw Failure(errorDescription: "The recording area is too small.") }
        let channels = c.mono ? 1 : 2

        let cfg = SCStreamConfiguration()
        if let r = c.sourceRect { cfg.sourceRect = r }
        cfg.width = w
        cfg.height = h
        cfg.scalesToFit = true
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 6
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = c.showsCursor
        cfg.showMouseClicks = false        // our own ClickHighlighter overlay draws clicks
        cfg.capturesAudio = c.systemAudio && audioFilter == nil
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = channels
        let mic = c.micDeviceID != nil
        cfg.captureMicrophone = mic
        if let id = c.micDeviceID {
            cfg.microphoneCaptureDeviceID = id.isEmpty ? AVCaptureDevice.default(for: .audio)?.uniqueID : id
        }

        writer = try SampleWriter(url: url, size: CGSize(width: w, height: h), fps: fps, quality: c.quality,
                                  audioChannels: c.systemAudio ? channels : nil, mic: mic)
        super.init()
        stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writer.q)
        if c.systemAudio, let audioFilter {
            let ac = SCStreamConfiguration()
            ac.capturesAudio = true
            ac.excludesCurrentProcessAudio = true
            ac.sampleRate = 48000
            ac.channelCount = channels
            ac.width = 2                                         // a video stream is required; keep it tiny and slow
            ac.height = 2
            ac.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let a = SCStream(filter: audioFilter, configuration: ac, delegate: self)
            try a.addStreamOutput(self, type: .audio, sampleHandlerQueue: writer.q)
            audioStream = a
        } else if c.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writer.q)
        }
        if mic { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: writer.q) }
    }

    var sessionStart: CMTime? { writer.sessionStart }
    var audioTrackCount: Int { writer.audioTrackCount }

    func start() async throws {
        do {
            try await stream.startCapture()
            do { try await audioStream?.startCapture() } catch {
                try? await stream.stopCapture()
                throw error
            }
        } catch {
            await writer.discard()
            throw error
        }
    }

    func setTimeline(_ t: PauseTimeline) { writer.setTimeline(t) }
    func setMicMuted(_ m: Bool) { writer.setMicMuted(m) }

    func finish(at stopTime: CMTime) async throws {
        try? await stream.stopCapture()
        try? await audioStream?.stopCapture()
        try await writer.finish(at: stopTime)
    }

    func discard() async {
        try? await stream.stopCapture()
        try? await audioStream?.stopCapture()
        await writer.discard()
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen: if Self.isCompleteFrame(sb) { writer.video(sb) }
        case .audio: writer.audio(sb)
        case .microphone: writer.mic(sb)
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        writer.q.async { [writer] in writer.reportStop(error) }
    }

    private static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    static func peakLevel(_ sb: CMSampleBuffer) -> Float? { SampleWriter.peakLevel(sb) }
}

/// An AVAssetWriter fed with live sample buffers in host-clock time: video, an optional "system" audio track (the Mac's
/// apps, or the device's sound) and an optional microphone track. Pauses drop samples and close the gap; the last frame
/// is repeated at the stop time. Everything runs on `q` (callers deliver samples on it).
final class SampleWriter: @unchecked Sendable {
    let url: URL
    let q = DispatchQueue(label: "daisyshot.recorder", qos: .userInitiated)
    var onStop: (@Sendable (Error) -> Void)?
    var onMicSilence: (@Sendable () -> Void)?

    private let writer: AVAssetWriter
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var micIn: AVAssetWriterInput?
    private let fps: Int
    private let quality: String
    private let audioChannels: Int?
    private let hasMic: Bool
    private var timeline = PauseTimeline()
    private var micMuted = false
    private var sessionStarted = false
    private var firstFrameTime = CMTime.invalid
    private var lastFrame: CMSampleBuffer?
    private var lastFrameTime = CMTime.invalid
    private var stopReported = false
    private var micCheckStart: CMTime?
    private var micChecked = false

    struct Failure: LocalizedError {
        private let message: String
        init(errorDescription: String) { message = errorDescription }
        var errorDescription: String? { message.loc }
    }

    /// `size` nil: taken from the first frame (a device's size is known only once it streams).
    init(url: URL, size: CGSize?, fps: Int, quality: String, audioChannels: Int?, mic: Bool) throws {
        self.url = url
        self.fps = max(1, min(120, fps))
        self.quality = quality
        self.audioChannels = audioChannels
        hasMic = mic
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        // Fragments keep the partial file playable if the app crashes or the writer fails mid-recording.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        if let size { try setUp(width: Int(size.width), height: Int(size.height)) }
    }

    /// Output video size (pixels), once known.
    private(set) var size: CGSize?

    private func setUp(width w: Int, height h: Int) throws {
        // H.264 hardware encoding tops out at 4096×2304; bigger (5K/6K Retina) areas need HEVC.
        let hevc = quality == "max" || w > 4096 || h > 2304
        let bitsPerPixel: Double = ["low": 0.03, "medium": 0.06, "max": 0.2][quality] ?? 0.1
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(Double(w * h * fps) * bitsPerPixel),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ]
        if !hevc { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        v.expectsMediaDataInRealTime = true
        writer.add(v)
        videoIn = v
        func audioInput(channels: Int) -> AVAssetWriterInput {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000 * channels,
            ])
            i.expectsMediaDataInRealTime = true
            writer.add(i)
            return i
        }
        // Always written as separate tracks (system first, then microphone); "Single track" merges them afterwards.
        if let audioChannels { audioIn = audioInput(channels: audioChannels) }
        if hasMic { micIn = audioInput(channels: 1) }
        guard writer.startWriting() else { throw writer.error ?? Failure(errorDescription: "Couldn't create the video file.") }
        size = CGSize(width: w, height: h)
    }

    /// Host-clock time of the first frame, i.e. video time zero (nil until a frame was written).
    var sessionStart: CMTime? { q.sync { sessionStarted ? firstFrameTime : nil } }

    /// Number of audio tracks this file will have.
    var audioTrackCount: Int { (audioChannels == nil ? 0 : 1) + (hasMic ? 1 : 0) }

    func setTimeline(_ t: PauseTimeline) { q.async { self.timeline = t } }
    func setMicMuted(_ m: Bool) { q.async { self.micMuted = m } }

    // MARK: Samples (on `q`)

    func video(_ sb: CMSampleBuffer) {
        defer { reportWriterFailure() }
        if videoIn == nil, let img = sb.imageBuffer {
            do { try setUp(width: CVPixelBufferGetWidth(img) / 2 * 2, height: CVPixelBufferGetHeight(img) / 2 * 2) } catch { reportStop(error); return }
        }
        guard sb.isValid, writer.status == .writing, let videoIn, let t = timeline.map(sb.presentationTimeStamp),
              !lastFrameTime.isValid || t > lastFrameTime,
              videoIn.isReadyForMoreMediaData, let out = Self.retimed(sb, by: sb.presentationTimeStamp - t) else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: t)
            sessionStarted = true
            firstFrameTime = t
        }
        videoIn.append(out)
        lastFrame = sb
        lastFrameTime = t
    }

    func audio(_ sb: CMSampleBuffer) {
        guard sb.isValid, writer.status == .writing, let t = timeline.map(sb.presentationTimeStamp) else { return }
        append(sb, at: t, to: audioIn)
    }

    func mic(_ sb: CMSampleBuffer) {
        guard sb.isValid, writer.status == .writing, let t = timeline.map(sb.presentationTimeStamp) else { return }
        checkMicSilence(sb, at: t)
        // Muted: write silence rather than nothing, so the track stays continuous and in sync.
        if micMuted, let data = sb.dataBuffer {
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0, dataLength: CMBlockBufferGetDataLength(data))
        }
        append(sb, at: t, to: micIn)
    }

    // MARK: Finish

    /// Finalizes the file. The last frame is repeated at `stopTime`, because a static screen sends no frames and the
    /// video would end early.
    func finish(at stopTime: CMTime) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            q.async { [self] in
                guard sessionStarted, writer.status == .writing, let videoIn else {
                    // A failed writer leaves its last fragments on disk: keep them for the caller to salvage.
                    if writer.status != .failed {
                        writer.cancelWriting()
                        try? FileManager.default.removeItem(at: url)
                    }
                    c.resume(throwing: writer.error ?? Failure(errorDescription: "Nothing was recorded."))
                    return
                }
                let end = timeline.position(stopTime)
                if let lastFrame, end > lastFrameTime, videoIn.isReadyForMoreMediaData,
                   let copy = Self.retimed(lastFrame, by: lastFrame.presentationTimeStamp - end) {
                    videoIn.append(copy)
                }
                videoIn.markAsFinished()
                audioIn?.markAsFinished()
                micIn?.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed { c.resume() } else { c.resume(throwing: writer.error ?? Failure(errorDescription: "Couldn't finish the video file.")) }
                }
            }
        }
    }

    func discard() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            q.async { [self] in
                if writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: url)
                c.resume()
            }
        }
    }

    func reportStop(_ error: Error) {
        guard !stopReported else { return }
        stopReported = true
        onStop?(error)
    }

    private func reportWriterFailure() {
        if writer.status == .failed { reportStop(writer.error ?? Failure(errorDescription: "The video file couldn't be written.")) }
    }

    /// Warns once if the first ~5 s of (unmuted) microphone input are all silence (peak below -60 dB).
    private func checkMicSilence(_ sb: CMSampleBuffer, at t: CMTime) {
        guard !micChecked else { return }
        if micMuted { micChecked = true; return }
        let start = micCheckStart ?? t
        micCheckStart = start
        if Self.peakLevel(sb).map({ $0 > 0.001 }) ?? true {
            micChecked = true                     // sound (or a format we can't read): no warning
        } else if (t - start).seconds >= 5 {
            micChecked = true
            onMicSilence?()
        }
    }

    /// Peak sample magnitude (0…1) of a 32-bit float or 16-bit integer PCM buffer.
    static func peakLevel(_ sb: CMSampleBuffer) -> Float? {
        guard let asbd = sb.formatDescription?.audioStreamBasicDescription, asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let float = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard (float && asbd.mBitsPerChannel == 32) || (!float && asbd.mBitsPerChannel == 16) else { return nil }
        return try? sb.withAudioBufferList { list, _ in
            var peak: Float = 0
            for b in list {
                guard let p = b.mData else { continue }
                if float {
                    for v in UnsafeBufferPointer(start: p.assumingMemoryBound(to: Float.self), count: Int(b.mDataByteSize) / 4) { peak = max(peak, abs(v)) }
                } else {
                    for v in UnsafeBufferPointer(start: p.assumingMemoryBound(to: Int16.self), count: Int(b.mDataByteSize) / 2) { peak = max(peak, abs(Float(v) / 32768)) }
                }
            }
            return peak
        }
    }

    private func append(_ sb: CMSampleBuffer, at t: CMTime, to input: AVAssetWriterInput?) {
        guard sessionStarted, let input, input.isReadyForMoreMediaData,
              let out = Self.retimed(sb, by: sb.presentationTimeStamp - t) else { return }
        input.append(out)
    }

    #if DEBUG
    /// A writer sized by its first frame records 1 s of frames with a 0.5 s pause in the middle, and the last frame is
    /// held to the stop time: 1.2 s − 0.5 s = 0.7 s of 640 × 360 video.
    static func selfTest() async -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DaisyshotWriterTest-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let w = try SampleWriter(url: url, size: nil, fps: 30, quality: "medium", audioChannels: nil, mic: false)
            func t(_ s: Double) -> CMTime { CMTime(seconds: 100 + s, preferredTimescale: 600) }
            var timeline = PauseTimeline()
            timeline.pause(at: t(0.3))
            timeline.resume(at: t(0.8))
            w.setTimeline(timeline)
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            guard let pb, let fmt = try? CMVideoFormatDescription(imageBuffer: pb) else { return "no pixel buffer" }
            for i in 0..<30 {
                let sb = try CMSampleBuffer(imageBuffer: pb, formatDescription: fmt, sampleTiming: CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: t(Double(i) / 30), decodeTimeStamp: .invalid))
                w.q.sync { w.video(sb) }
                try await Task.sleep(for: .milliseconds(15))   // a real-time input drops frames that arrive all at once
            }
            guard w.sessionStart == t(0) else { return "session starts at \(w.sessionStart?.seconds ?? -1)" }
            try await w.finish(at: t(1.2))
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let size = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
            guard abs(duration - 0.7) < 0.05, size == CGSize(width: 640, height: 360) else { return "\(duration) s, \(String(describing: size))" }
            return nil
        } catch { return error.localizedDescription }
    }
    #endif

    /// Copy of `sb` with every timestamp moved earlier by `offset`.
    static func retimed(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sb }
        guard var timing = try? sb.sampleTimingInfos() else { return nil }
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset }
        }
        return try? CMSampleBuffer(copying: sb, withNewTiming: timing)
    }
}
