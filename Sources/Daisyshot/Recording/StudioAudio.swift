import AVFoundation

/// Microphone clean-up for Studio: Apple's on-device voice isolation (AUSoundIsolation) and loudness normalization.
enum StudioAudioFX {
    static let sampleRate = 48_000.0
    static let targetLoudness = -16.0     // ≈ LUFS, what podcasts and most web video aim for

    /// Writes a noise-reduced, mono copy of `track` to `url` (AAC). The copy starts at the track's own start time.
    static func denoise(_ track: AVAssetTrack, of asset: AVAsset, to url: URL) async throws {
        let range = try await track.load(.timeRange)
        let feed = try Feed(track, of: asset, range: range)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let engine = AVAudioEngine()
        let fx = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: 0x766F_6973 /* 'vois', AUSoundIsolation */,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        let source = AVAudioSourceNode(format: fmt) { _, _, frames, abl in
            feed.fill(UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self), Int(frames))
            return noErr
        }
        engine.attach(source)
        engine.attach(fx)
        engine.connect(source, to: fx, format: fmt)
        engine.connect(fx, to: engine.mainMixerNode, format: fmt)
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }

        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try AVAudioFile(forWriting: tmp, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        // The isolation runs ~56 ms behind its input: drop that much from the start and render as much extra at the end.
        var skip = Int((fx.auAudioUnit.latency * sampleRate).rounded())
        var left = Int((range.duration.seconds * sampleRate).rounded())
        while left > 0 {
            try Task.checkCancellation()
            guard try engine.renderOffline(4096, to: out) == .success else { throw StudioError("Couldn't reduce the noise.") }
            let drop = min(skip, Int(out.frameLength))
            skip -= drop
            let keep = min(left, Int(out.frameLength) - drop)
            guard keep > 0 else { continue }
            if drop > 0 { memmove(out.floatChannelData![0], out.floatChannelData![0] + drop, keep * 4) }
            out.frameLength = AVAudioFrameCount(keep)
            try file.write(from: out)
            left -= keep
        }
        file.close()
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    /// The volume factor that brings `track` to `targetLoudness` without pushing its peaks past −1 dBFS.
    static func normalizingGain(_ track: AVAssetTrack, of asset: AVAsset) async throws -> Float {
        let feed = try Feed(track, of: asset, range: try await track.load(.timeRange))
        let block = Int(sampleRate * 0.4)
        var powers: [Double] = [], buf = [Float](repeating: 0, count: block)
        var histogram = [Int](repeating: 0, count: 2048)
        while !feed.finished {
            try Task.checkCancellation()
            let n = buf.withUnsafeMutableBufferPointer { feed.fill($0.baseAddress!, block) }
            guard n > 0 else { break }
            var sum = 0.0
            for x in buf[0..<n] {
                sum += Double(x * x)
                histogram[min(2047, Int(abs(x) * 2047))] += 1
            }
            powers.append(sum / Double(n))
        }
        return gain(blockPowers: powers, histogram: histogram)
    }

    /// Gated loudness (BS.1770's −10 dB relative gate over 400 ms blocks) → volume factor. The absolute gate is −50 dBFS
    /// rather than −70, so a track with no speech (just a quiet room) is left alone instead of having its hiss boosted.
    /// ponytail: no K-weighting filter, so bass-heavy audio reads ≈1–2 dB louder than true LUFS; add the filter if that matters.
    static func gain(blockPowers: [Double], histogram: [Int]) -> Float {
        let loud = blockPowers.filter { $0 > 1e-5 }
        guard !loud.isEmpty else { return 1 }
        let mean = loud.reduce(0, +) / Double(loud.count)
        let gated = loud.filter { $0 > mean * 0.1 }
        let level = 10 * log10(gated.reduce(0, +) / Double(gated.count))
        // Peak = the 99.99th percentile, so a lone click doesn't hold the whole recording down.
        let total = histogram.reduce(0, +)
        var seen = 0, peak = 1.0
        for (i, c) in histogram.enumerated().reversed() {
            seen += c
            if Double(seen) > Double(total) * 0.0001 { peak = Double(i + 1) / 2047; break }
        }
        let db = min(15, max(-20, targetLoudness - level), -1 - 20 * log10(max(peak, 1e-4)))
        return Float(pow(10, db / 20))
    }

    /// Decodes one track to mono float samples, placed by timestamp (gaps become silence).
    private final class Feed: @unchecked Sendable {
        private let reader: AVAssetReader
        private let output: AVAssetReaderAudioMixOutput
        private let start: CMTime
        private var pending: [Float] = []
        private var offset = 0          // read position in `pending`
        private var placed = 0          // samples decoded so far (the end of `pending` on the track's timeline)
        private(set) var finished = false

        init(_ track: AVAssetTrack, of asset: AVAsset, range: CMTimeRange) throws {
            reader = try AVAssetReader(asset: asset)
            reader.timeRange = range
            start = range.start
            output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: StudioAudioFX.sampleRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? StudioError("Couldn't read the audio.") }
        }

        /// Fills `dst` with up to `n` samples; past the end it pads with silence and returns how many were real.
        @discardableResult
        func fill(_ dst: UnsafeMutablePointer<Float>, _ n: Int) -> Int {
            var got = 0
            while got < n {
                if offset == pending.count, !refill() { break }
                let k = min(n - got, pending.count - offset)
                pending.withUnsafeBufferPointer { (dst + got).update(from: $0.baseAddress! + offset, count: k) }
                offset += k
                got += k
            }
            if got < n { (dst + got).update(repeating: 0, count: n - got) }
            return got
        }

        private func refill() -> Bool {
            guard !finished, let sb = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) else {
                finished = true
                return false
            }
            let len = CMBlockBufferGetDataLength(block) / 4
            // A buffer that starts later than where we are leaves a gap in the track: fill it with silence.
            let at = Int(((CMSampleBufferGetPresentationTimeStamp(sb) - start).seconds * StudioAudioFX.sampleRate).rounded())
            let gap = max(0, at - placed)
            placed += gap + len
            pending = [Float](repeating: 0, count: gap + len)
            pending.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len * 4, destination: $0.baseAddress! + gap * 4) }
            offset = 0
            return true
        }
    }

    #if DEBUG
    /// Speech over hiss and hum comes out with the hiss ≥ 20 dB lower, the speech kept and in sync; the gain math lands on target.
    static func selfTest() async -> String? {
        // Gain: a −30 dB block level wants +14 dB; a near-full-scale peak caps it.
        var hist = [Int](repeating: 0, count: 2048)
        hist[100] = 10_000
        let g = gain(blockPowers: [Double](repeating: 0.001, count: 50), histogram: hist)
        guard abs(20 * log10(Double(g)) - 14) < 0.1 else { return "gain \(20 * log10(Double(g))) dB, want 14" }
        hist[2000] = 100
        let capped = 20 * log10(Double(gain(blockPowers: [Double](repeating: 0.001, count: 50), histogram: hist)))
        guard capped < 0 else { return "peak cap gave \(capped) dB" }
        guard gain(blockPowers: [Double](repeating: 1e-6, count: 50), histogram: hist) == 1 else { return "a silent room got boosted" }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DaisyshotAudioTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let speech = await synthesizedSpeech()
            guard speech.count > Int(sampleRate) else { return "no synthesized speech" }
            // 0.5 s of hiss, the speech, 1 s of hiss; hiss and 120 Hz hum throughout.
            var x = [Float](repeating: 0, count: speech.count + Int(sampleRate * 1.5))
            for i in speech.indices { x[i + Int(sampleRate / 2)] = speech[i] * 0.5 }
            for i in x.indices { x[i] += Float.random(in: -0.03...0.03) + 0.02 * sin(Float(i) * 2 * .pi * 120 / Float(sampleRate)) }
            let noisy = dir.appendingPathComponent("noisy.caf")
            let f = try AVAudioFile(forWriting: noisy, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                                                  AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
            let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(x.count))!
            b.frameLength = b.frameCapacity
            x.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
            try f.write(from: b)
            f.close()

            let asset = AVURLAsset(url: noisy)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return "no track" }
            let clean = dir.appendingPathComponent("clean.m4a")
            try await denoise(track, of: asset, to: clean)
            let ca = AVURLAsset(url: clean)
            guard let ct = try await ca.loadTracks(withMediaType: .audio).first else { return "no clean track" }
            let y = try Feed(ct, of: ca, range: try await ct.load(.timeRange))
            var out = [Float](repeating: 0, count: x.count)
            out.withUnsafeMutableBufferPointer { _ = y.fill($0.baseAddress!, x.count) }

            func rms(_ a: ArraySlice<Float>) -> Double { (a.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, a.count))).squareRoot() }
            let tail = (x.count - Int(sampleRate * 0.8))..<(x.count - Int(sampleRate * 0.1))
            let talk = Int(sampleRate / 2)..<(Int(sampleRate / 2) + speech.count)
            let hiss = 20 * log10(rms(out[tail]) / rms(x[tail]))
            guard hiss < -20 else { return "hiss only \(hiss) dB lower" }
            guard rms(out[talk]) > rms(x[talk]) * 0.5 else { return "speech \(rms(x[talk])) → \(rms(out[talk]))" }
            // In sync: the clean copy lines up best with the input at (almost) no delay.
            var best = (lag: 0, score: -Double.infinity)
            for lag in stride(from: -2400, through: 2400, by: 24) {
                var s = 0.0
                for i in stride(from: talk.lowerBound + 2400, to: talk.upperBound - 2400, by: 3) { s += Double(x[i]) * Double(out[i + lag]) }
                if s > best.score { best = (lag, s) }
            }
            guard abs(best.lag) <= 240 else { return "clean audio is \(Double(best.lag) / sampleRate * 1000) ms off" }
            return nil
        } catch { return error.localizedDescription }
    }

    private static func synthesizedSpeech() async -> [Float] {
        let synth = AVSpeechSynthesizer()
        let u = AVSpeechUtterance(string: "We record the screen and talk about the new product, step by step.")
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        var samples: [Float] = [], rate = sampleRate
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            synth.write(u) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    if !finished { finished = true; done.resume() }
                    return
                }
                rate = pcm.format.sampleRate
                if let f = pcm.floatChannelData { samples += UnsafeBufferPointer(start: f[0], count: Int(pcm.frameLength)) }
                else if let i = pcm.int16ChannelData { samples += UnsafeBufferPointer(start: i[0], count: Int(pcm.frameLength)).map { Float($0) / 32768 } }
            }
        }
        _ = synth
        // Resample (linear) to 48 kHz.
        let n = Int(Double(samples.count) * sampleRate / rate)
        return (0..<n).map { i in
            let p = Double(i) * rate / sampleRate, j = Int(p), t = Float(p - Double(j))
            return j + 1 < samples.count ? samples[j] * (1 - t) + samples[j + 1] * t : 0
        }
    }
    #endif
}

/// A mouse-click sound made in code (no recorded sample to license): a short noise snap over a damped 2.2 kHz ping and a
/// soft low knock, 70 ms, written once to Caches.
enum StudioClickSound {
    static var url: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Daisyshot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent("click-v1.caf")
        if !FileManager.default.fileExists(atPath: u.path) { try? write(to: u) }
        return u
    }

    static func samples(rate: Double = 48_000) -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<Int(rate * 0.07)).map { i in
            let t = Double(i) / rate
            let snap = exp(-t / 0.0025) * Double.random(in: -1...1, using: &g)
            let ping = exp(-t / 0.01) * sin(2 * .pi * 2200 * t)
            let knock = exp(-t / 0.018) * sin(2 * .pi * 140 * t)
            return Float(0.55 * snap + 0.35 * ping + 0.3 * knock) * Float(min(1, t / 0.0004))   // 0.4 ms attack: no pop
        }
    }

    private static func write(to url: URL) throws {
        let x = samples()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                                            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count))!
        b.frameLength = b.frameCapacity
        x.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        try f.write(from: b)
        f.close()
    }
}
