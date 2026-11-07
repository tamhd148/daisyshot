import AppKit
import Vision

/// One recognised line of text. `rect(for:)` gives the box of any substring, so callers can act on part of a line.
struct ScannedLine: @unchecked Sendable {   // VNRecognizedText is immutable once produced
    let text: String
    let rect: CGRect           // image points, top-left origin
    let confidence: Float
    fileprivate let observation: VNRecognizedText
    fileprivate let size: CGSize

    /// Box of `range` (a range of `text`) in image points, top-left origin.
    func rect(for range: Range<String.Index>) -> CGRect? {
        guard let box = try? observation.boundingBox(for: range) else { return nil }
        return TextScan.convert(box.boundingBox, size)
    }
}

/// On-device OCR for Auto Redact. Results are cached per image and concurrent callers share one scan, so an image is
/// recognised at most once.
@MainActor
enum TextScan {
    private struct Entry { let image: CGImage; let task: Task<[ScannedLine], Never> }
    private static var cache: [Entry] = []

    /// `size` is the image size in points (`DocState.imageSize`); boxes come back in that space.
    static func lines(_ image: CGImage, size: CGSize) async -> [ScannedLine] {
        if let hit = cache.first(where: { $0.image === image }) { return await hit.task.value }
        let task = Task.detached(priority: .userInitiated) { scan(image, size: size) }
        cache.append(Entry(image: image, task: task))   // holds the image, so its identity can't be reused
        if cache.count > 6 { cache.removeFirst() }
        return await task.value
    }

    nonisolated private static func scan(_ image: CGImage, size: CGSize) -> [ScannedLine] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false   // keep tokens, keys and numbers exactly as drawn
        req.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap { o in
            guard let t = o.topCandidates(1).first else { return nil }
            return ScannedLine(text: t.string, rect: convert(o.boundingBox, size), confidence: t.confidence, observation: t, size: size)
        }
    }

    /// Vision's normalised, bottom-left rect → image points, top-left origin.
    nonisolated static func convert(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
    }
}
