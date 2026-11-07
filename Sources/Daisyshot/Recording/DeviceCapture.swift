import AppKit
import AVFoundation
import CoreMediaIO

/// iPhone / iPad screens over a cable. Once CoreMediaIO is allowed to publish screen-capture devices, a connected,
/// unlocked and trusted device shows up as an external muxed (video + its sound) `AVCaptureDevice`. All public API.
/// Cable only: there is no public API for capturing a device over Wi-Fi.
enum IOSDevices {
    /// Asks CoreMediaIO to publish iOS screen devices (they appear a moment later; watch `wasConnectedNotification`).
    static func enable() {
        var prop = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// Connected iPhones / iPads (muxed external devices; webcams and Continuity Camera are video-only).
    static func list() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }

    /// The chosen device if still connected, else the first one.
    static func chosen() -> AVCaptureDevice? {
        let all = list()
        return all.first { $0.uniqueID == Prefs.string(.recDeviceID) } ?? all.first
    }

    static func isPad(_ d: AVCaptureDevice) -> Bool { d.modelID.lowercased().contains("ipad") || d.localizedName.lowercased().contains("ipad") }

    /// Native pixel size of what the device streams now (portrait / landscape follows the device).
    static func pixelSize(_ d: AVCaptureDevice) -> CGSize? {
        let dims = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
        return dims.width > 0 && dims.height > 0 ? CGSize(width: Int(dims.width), height: Int(dims.height)) : nil
    }
}

/// Live preview of a device's screen (setup overlay): an AVCaptureSession drawing into a preview layer, reporting the
/// stream's size as the device rotates.
final class DevicePreviewView: NSView {
    private let session = AVCaptureSession()
    private let preview: AVCaptureVideoPreviewLayer
    private var observer: NSKeyValueObservation?
    let deviceID: String
    /// Pixel size of the stream; called on the main thread whenever it changes.
    var onSize: ((CGSize) -> Void)?

    init?(device: AVCaptureDevice) {
        deviceID = device.uniqueID
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return nil }
        session.addInput(input)
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(preview)
        layer?.masksToBounds = true
        observer = input.observe(\.device.activeFormat, options: [.initial, .new]) { [weak self] i, _ in
            let size = IOSDevices.pixelSize(i.device)
            DispatchQueue.main.async { if let size { self?.onSize?(size) } }
        }
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }
    required init?(coder: NSCoder) { nil }

    /// Screen corner radius; the video ignores `cornerRadius` / `masksToBounds`, so a mask layer cuts it.
    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }
    private let mask = CAShapeLayer()

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        let r = min(cornerRadius, bounds.width / 2, bounds.height / 2)
        mask.path = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        preview.mask = mask
        CATransaction.commit()
    }

    func stop() {
        observer = nil
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
    }
}

/// Records a device's screen (and optionally its sound) plus the Mac's microphone into one `SampleWriter`, in host-clock
/// time like the screen recorder. A rotation mid-recording letterboxes into the size the recording started with.
final class DeviceRecorder: NSObject, RecordingOutput, AVCaptureVideoDataOutputSampleBufferDelegate,
                            AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
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
    private let session = AVCaptureSession()
    private let videoOut = AVCaptureVideoDataOutput()
    private var deviceAudioOut: AVCaptureAudioDataOutput?
    private var micOut: AVCaptureAudioDataOutput?
    private let host = CMClockGetHostTimeClock()
    private var observer: NSObjectProtocol?
    private lazy var ci = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?

    init(url: URL, device: AVCaptureDevice, deviceAudio: Bool, micDeviceID: String?, fps: Int, quality: String) throws {
        writer = try SampleWriter(url: url, size: nil, fps: fps, quality: quality, audioChannels: deviceAudio ? 2 : nil, mic: micDeviceID != nil)
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SampleWriter.Failure(errorDescription: "Couldn't open the device.") }
        session.addInputWithNoConnections(input)

        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.alwaysDiscardsLateVideoFrames = true
        videoOut.setSampleBufferDelegate(self, queue: writer.q)
        session.addOutputWithNoConnections(videoOut)
        if let port = input.ports.first(where: { $0.mediaType == .video }) {
            session.addConnection(AVCaptureConnection(inputPorts: [port], output: videoOut))
        }
        if deviceAudio, let port = input.ports.first(where: { $0.mediaType == .audio }) {
            let out = AVCaptureAudioDataOutput()
            out.audioSettings = Self.pcm(channels: 2)
            out.setSampleBufferDelegate(self, queue: writer.q)
            session.addOutputWithNoConnections(out)
            session.addConnection(AVCaptureConnection(inputPorts: [port], output: out))
            deviceAudioOut = out
        }
        if let id = micDeviceID,
           let mic = (id.isEmpty ? nil : AVCaptureDevice(uniqueID: id)) ?? AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput),
           let port = micInput.ports.first(where: { $0.mediaType == .audio }) {
            session.addInputWithNoConnections(micInput)
            let out = AVCaptureAudioDataOutput()
            out.audioSettings = Self.pcm(channels: 1)
            out.setSampleBufferDelegate(self, queue: writer.q)
            session.addOutputWithNoConnections(out)
            session.addConnection(AVCaptureConnection(inputPorts: [port], output: out))
            micOut = out
        }
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [writer] n in
            let error = (n.userInfo?[AVCaptureSessionErrorKey] as? Error) ?? SampleWriter.Failure(errorDescription: "The device stopped sending video.")
            writer.q.async { writer.reportStop(error) }
        }
    }

    private static func pcm(channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels,
         AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
    }

    var sessionStart: CMTime? { writer.sessionStart }
    var audioTrackCount: Int { writer.audioTrackCount }

    func start() async throws {
        let s = session
        await Task.detached { s.startRunning() }.value
        if !s.isRunning {
            // The setup's preview may still be letting go of the device.
            try? await Task.sleep(for: .milliseconds(600))
            await Task.detached { s.startRunning() }.value
        }
        guard session.isRunning else {
            await writer.discard()
            throw SampleWriter.Failure(errorDescription: "Couldn't start recording the device. Unlock it and try again.")
        }
    }

    func setTimeline(_ t: PauseTimeline) { writer.setTimeline(t) }
    func setMicMuted(_ m: Bool) { writer.setMicMuted(m) }

    func finish(at stopTime: CMTime) async throws {
        stopSession()
        try await writer.finish(at: stopTime)
    }

    func discard() async {
        stopSession()
        await writer.discard()
    }

    private func stopSession() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        session.stopRunning()
    }

    // MARK: Samples (on the writer's queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let sb = onHostClock(sb) else { return }
        if output === videoOut { writer.video(fitted(sb) ?? sb) }
        else if output === deviceAudioOut { writer.audio(sb) }
        else if output === micOut { writer.mic(sb) }
    }

    /// The session's clock can be the device's: move timestamps onto the host clock the pause timeline and the camera use.
    private func onHostClock(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard let clock = session.synchronizationClock, !CFEqual(clock, host) else { return sb }
        let pts = sb.presentationTimeStamp
        let converted = CMSyncConvertTime(pts, from: clock, to: host)
        return SampleWriter.retimed(sb, by: pts - converted)
    }

    /// After a rotation the device streams the other way round: scale it into the size the recording started with.
    private func fitted(_ sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard let size = writer.size, let img = sb.imageBuffer else { return nil }
        let w = CVPixelBufferGetWidth(img), h = CVPixelBufferGetHeight(img)
        guard abs(CGFloat(w) - size.width) > 2 || abs(CGFloat(h) - size.height) > 2 else { return nil }
        if pool == nil {
            CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: Int(size.width),
                                               kCVPixelBufferHeightKey: Int(size.height), kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pool)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        let k = min(size.width / CGFloat(w), size.height / CGFloat(h))
        let src = CIImage(cvPixelBuffer: img)
        let placed = src.transformed(by: CGAffineTransform(scaleX: k, y: k)
            .concatenating(CGAffineTransform(translationX: (size.width - CGFloat(w) * k) / 2, y: (size.height - CGFloat(h) * k) / 2)))
        ci.render(placed.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))), to: out)
        guard let fmt = try? CMVideoFormatDescription(imageBuffer: out) else { return nil }
        return try? CMSampleBuffer(imageBuffer: out, formatDescription: fmt, sampleTiming: CMSampleTimingInfo(
            duration: sb.duration, presentationTimeStamp: sb.presentationTimeStamp, decodeTimeStamp: .invalid))
    }
}

/// The device preview in the setup: the live screen in a generic dark device body (no product artwork), its corners
/// scaled from the design's 620 pt tall frame (bezel 10, body radius 46, screen radius 37).
final class DeviceStageView: NSView {
    private let screen: DevicePreviewView
    var onSize: ((CGSize) -> Void)? {
        get { screen.onSize }
        set { screen.onSize = newValue }
    }

    init?(device: AVCaptureDevice) {
        guard let s = DevicePreviewView(device: device) else { return nil }
        screen = s
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: "#0E1018").cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 30
        layer?.shadowOffset = CGSize(width: 0, height: -24)
        s.layer?.backgroundColor = NSColor.black.cgColor
        addSubview(s)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let k = min(bounds.width, bounds.height) / 286    // the design's frame is 286 × 620 pt
        layer?.cornerRadius = 46 * k
        screen.frame = bounds.insetBy(dx: 10 * k, dy: 10 * k)
        screen.cornerRadius = 37 * k
    }

    func stop() { screen.stop() }
}
