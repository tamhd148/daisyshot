import AppKit
import SwiftUI
import Vision

extension Prefs.Key {
    static let ocrAutoDetectLanguage = Prefs.Key("ocrAutoDetectLanguage", true)
    static let ocrDetectLinks = Prefs.Key("ocrDetectLinks", true)
    static let ocrDetectCodes = Prefs.Key("ocrDetectCodes", true)
}

struct OCRResult {
    var text = ""
    /// QR / barcode payloads.
    var codes: [String] = []
    var links: [URL] = []

    /// What gets copied: a code's payload wins over the surrounding text.
    var clipboard: String { codes.isEmpty ? text : codes.joined(separator: "\n") }
}

enum TextRecognizer {
    /// On-device OCR (Vision) using the "keep line breaks" setting.
    static func recognize(_ image: CGImage) async -> String {
        await recognize(image, lineBreaks: Prefs.bool(.ocrKeepLineBreaks), codes: false).text
    }

    /// Text (accurate, language-corrected, primary language + optional auto-detect), QR/barcodes and links.
    static func recognize(_ image: CGImage, lineBreaks: Bool, codes: Bool = Prefs.bool(.ocrDetectCodes)) async -> OCRResult {
        let language = Prefs.string(.ocrLanguage)
        let autoDetect = Prefs.bool(.ocrAutoDetectLanguage)
        let detectLinks = Prefs.bool(.ocrDetectLinks)
        return await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = autoDetect || language.isEmpty
            if !language.isEmpty { text.recognitionLanguages = [language] }
            let barcodes = VNDetectBarcodesRequest()
            try? VNImageRequestHandler(cgImage: image).perform(codes ? [text, barcodes] : [text])

            var r = OCRResult()
            let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            r.text = lineBreaks ? lines.joined(separator: "\n") : join(lines)
            if codes {
                var seen = Set<String>()
                r.codes = (barcodes.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
            }
            if detectLinks { r.links = links(in: r.clipboard) }
            return r
        }.value
    }

    /// Joins lines into running text, re-joining words hyphenated across a line break.
    static func join(_ lines: [String]) -> String {
        var out = ""
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if out.hasSuffix("-"), let f = line.first, f.isLowercase { out.removeLast(); out += line; continue }
            out += out.isEmpty ? line : " " + line
        }
        return out
    }

    static func links(in s: String) -> [URL] {
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<URL>()
        return d.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap(\.url).filter { seen.insert($0).inserted }
    }

    static var supportedLanguages: [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
    }

    static func selfTest() {
        assert(join(["Hello wor-", "ld and", "  more  "]) == "Hello world and more")
        assert(join(["Self-", "Timer"]) == "Self- Timer")
        assert(links(in: "see https://example.com/a and www.apple.com").count == 2)
        assert(OCRResult(text: "abc", codes: ["https://x.y"]).clipboard == "https://x.y")
    }
}

/// Result card after Capture Text: copies the result, previews it, and offers to open detected links.
@MainActor
enum OCRResultHUD {
    private static var panel: FloatingPanel?
    private static var dismiss: DispatchWorkItem?

    static func show(_ result: OCRResult) {
        close()
        let content = result.clipboard
        if content.isEmpty {
            Sounds.error()
            Toast.show("No text detected", isError: true)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        Sounds.ocr()

        let host = NSHostingView(rootView: OCRCard(result: result, close: close, hover: { inside in
            if inside { dismiss?.cancel() } else { scheduleDismiss(after: 3) }
        }))
        let size = host.fittingSize
        let s = NSScreen.underMouse.visibleFrame
        let p = FloatingPanel(rect: CGRect(x: s.midX - size.width / 2, y: s.minY + 60, width: size.width, height: size.height), level: .statusBar)
        p.hasShadow = false
        p.contentView = host
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        panel = p
        scheduleDismiss(after: result.links.isEmpty ? 3.5 : 7)
    }

    private static func scheduleDismiss(after seconds: Double) {
        dismiss?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { close() } }
        dismiss = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    static func close() {
        dismiss?.cancel()
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}

private struct OCRCard: View {
    let result: OCRResult
    let close: () -> Void
    let hover: (Bool) -> Void
    @State private var copiedText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: result.codes.isEmpty ? "text.viewfinder" : "qrcode.viewfinder")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.green)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text(copiedText ? result.text : result.clipboard)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if !result.links.isEmpty || (!result.codes.isEmpty && !result.text.isEmpty) {
                HStack(spacing: 6) {
                    if let url = result.links.first {
                        Button { result.links.forEach { NSWorkspace.shared.open($0) }; close() } label: {
                            Label(result.links.count > 1 ? "Open %d Links".loc(result.links.count) : "Open Link".loc, systemImage: "safari")
                        }
                        .help(url.absoluteString)
                    }
                    if !result.codes.isEmpty, !result.text.isEmpty, !copiedText {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result.text, forType: .string)
                            copiedText = true
                        } label: { Label("Copy Text Instead", systemImage: "doc.on.doc") }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 360)
        .hudBox(radius: 14)
        .padding(12)
        .environment(\.colorScheme, .dark)
        .onHover(perform: hover)
    }

    private var title: String {
        if copiedText { return "Text copied".loc }
        if !result.codes.isEmpty { return result.codes.count > 1 ? "%d codes copied".loc(result.codes.count) : "QR code copied".loc }
        return "Text copied · %d characters".loc(result.text.count)
    }
}
