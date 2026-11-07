import AppKit
import ImageIO
import UniformTypeIdentifiers

extension Prefs.Key {
    static let convertToSRGB = Prefs.Key("convertToSRGB", false)
    static let removeIllegalFileChars = Prefs.Key("removeIllegalFileChars", true)
    static let fileNameUTC = Prefs.Key("fileNameUTC", false)
    static let askForNameAfterCapture = Prefs.Key("askForNameAfterCapture", false)
    /// Last number used by the `%i` (auto-increment) token.
    static let fileNameCounter = Prefs.Key("fileNameCounter", 0)
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpg, heic, tiff, webp

    /// WebP is only offered when a `cwebp` encoder is installed (e.g. `brew install webp`).
    static var allCases: [ImageFormat] { WebP.available ? [.png, .jpg, .heic, .tiff, .webp] : [.png, .jpg, .heic, .tiff] }

    /// The format chosen in Settings, falling back to PNG when it isn't available.
    static var current: ImageFormat {
        let f = ImageFormat(rawValue: Prefs.string(.imageFormat)) ?? .png
        return allCases.contains(f) ? f : .png
    }

    var id: String { rawValue }
    var title: String { ["png": "PNG", "jpg": "JPEG", "heic": "HEIC", "tiff": "TIFF", "webp": "WebP"][rawValue]! }
    var isLossy: Bool { self == .jpg || self == .heic || self == .webp }
    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .webp: return .webP
        }
    }
}

/// Window/app the capture came from, for the `%a` / `%t` file-name tokens. Set by the capture pipeline.
struct CaptureContext {
    var app = ""
    var window = ""
}

enum Exporter {
    static var context = CaptureContext()

    /// File-name tokens offered in the "File name format" editor (code, title).
    static let tokens: [(code: String, title: String)] = [
        ("%y", "Year"), ("%m", "Month"), ("%n", "Month name"), ("%d", "Day"), ("%w", "Day of week"),
        ("%t", "Window title"), ("%a", "App name"), ("%H", "Hour"), ("%M", "Minutes"), ("%S", "Seconds"),
        ("%p", "AM/PM"), ("%r", "Random characters"), ("%i", "Auto-increment"),
    ]

    static let illegalCharacters = CharacterSet(charactersIn: "\\\"*?<>%,;=|")

    /// Expands the file-name template. Tokens: %y year, %m month, %n month name, %d day, %w weekday, %H hour
    /// (12-hour when %p is present), %M minutes, %S seconds, %p AM/PM, %r random characters, %i auto-increment,
    /// %a app name, %t window title; legacy %Y, {counter} and {type} are also understood.
    static func fileName(template: String = Prefs.string(.fileNameTemplate), type: String = "Screenshot", date: Date = Date(), bumpCounter: Bool = true) -> String {
        let t = template.isEmpty ? (Prefs.Key.fileNameTemplate.defaultValue as? String ?? "") : template
        let usesCounter = t.contains("%i") || t.contains("{counter}")
        let n = Prefs.int(.fileNameCounter) + 1
        if usesCounter, bumpCounter { Prefs.set(n, .fileNameCounter) }
        return expand(t, type: type, date: date, counter: n, context: context,
                      utc: Prefs.bool(.fileNameUTC), removeIllegal: Prefs.bool(.removeIllegalFileChars))
    }

    /// Pure token expansion (see `fileName`). `random` is injectable for tests.
    static func expand(_ template: String, type: String, date: Date, counter: Int, context: CaptureContext, utc: Bool, removeIllegal: Bool,
                       locale: Locale = .current, random: () -> String = { String((0..<6).map { _ in "abcdefghijkmnpqrstuvwxyz23456789".randomElement()! }) }) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = utc ? TimeZone(identifier: "UTC") : .current
        func fmt(_ p: String) -> String { f.dateFormat = p; return f.string(from: date) }
        let twelveHour = template.contains("%p")
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            let next = template.index(after: i)
            if c == "{", template[i...].hasPrefix("{counter}") { out += String(counter); i = template.index(i, offsetBy: 9); continue }
            if c == "{", template[i...].hasPrefix("{type}") { out += type; i = template.index(i, offsetBy: 6); continue }
            guard c == "%", next < template.endIndex else { out.append(c); i = next; continue }
            let rep: String?
            switch template[next] {
            case "y", "Y": rep = fmt("yyyy")
            case "m": rep = fmt("MM")
            case "n": rep = fmt("MMMM")
            case "d": rep = fmt("dd")
            case "w": rep = fmt("EEEE")
            case "H": rep = fmt(twelveHour ? "hh" : "HH")
            case "M": rep = fmt("mm")
            case "S": rep = fmt("ss")
            case "p": rep = fmt("a")
            case "r": rep = random()
            case "i": rep = String(counter)
            case "a": rep = context.app
            case "t": rep = context.window
            case "%": rep = "%"
            default: rep = nil
            }
            if let rep { out += rep; i = template.index(after: next) } else { out.append(c); i = next }
        }
        var name = out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        if removeIllegal { name = name.components(separatedBy: illegalCharacters).joined() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() } // no hidden files
        return name.isEmpty ? type : name
    }

    /// "Name each capture before saving": returns the chosen name, or nil when cancelled.
    @MainActor
    static func askForName(_ suggested: String) -> String? {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Save Screenshot As"
        a.informativeText = "Enter a name for this capture."
        let field = NSTextField(string: suggested)
        field.frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.localize()
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? suggested : name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
    }

    /// Picks a non-colliding URL in `folder`.
    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) (\(i))").appendingPathExtension(ext)
            i += 1
        }
        return url
    }

    static func encode(_ shot: Shot, format: ImageFormat = .current) -> Data? {
        var image = shot.image
        var scale = shot.scale
        if Prefs.bool(.downscaleRetina), scale > 1, let small = image.resized(by: 1 / scale) {
            image = small
            scale = 1
        }
        if Prefs.bool(.convertToSRGB) || format == .webp, let srgb = image.convertedToSRGB() { image = srgb }
        if format == .webp {
            guard let png = encode(image, type: .png, scale: scale) else { return nil }
            return WebP.encode(png: png, quality: Prefs.double(.jpegQuality))
        }
        return encode(image, type: format.utType, scale: scale, quality: format.isLossy ? Prefs.double(.jpegQuality) : nil)
    }

    /// ImageIO encode with Retina metadata (144 dpi for 2x) so other apps show screenshots at their point size.
    static func encode(_ image: CGImage, type: UTType, scale: CGFloat, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFXResolution: dpi, kCGImagePropertyTIFFYResolution: dpi,
                                             kCGImagePropertyTIFFResolutionUnit: 2, kCGImagePropertyTIFFSoftware: "Daisyshot"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Screenshot"],
        ]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    @discardableResult
    static func save(_ shot: Shot, to folder: URL = Prefs.exportFolder, name: String? = nil) throws -> URL {
        let format = ImageFormat.current
        let url = try exportURL(for: shot, in: folder, name: name, format: format)
        guard let data = encode(shot, format: format) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        markAsScreenCapture(url)
        return url
    }

    /// `save` without blocking: the name is reserved with an empty file and returned at once; encoding (~150 ms for a
    /// 5K PNG) and writing happen on a background queue. On failure the placeholder is removed and an error is shown.
    @MainActor @discardableResult
    static func saveInBackground(_ shot: Shot, to folder: URL = Prefs.exportFolder, name: String? = nil) throws -> URL {
        let format = ImageFormat.current
        let url = try exportURL(for: shot, in: folder, name: name, format: format)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
        write(shot, format: format, to: url) { ok in
            if ok { markAsScreenCapture(url) } else { Toast.show("Couldn't save %@".loc(url.lastPathComponent), isError: true) }
        }
        return url
    }

    /// Encodes and atomically writes `shot` on a background queue, then calls `done` on the main actor. A failed write
    /// removes the file at `url` (the caller's placeholder).
    static func write(_ shot: Shot, format: ImageFormat, to url: URL, done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = encode(shot, format: format).map { (try? $0.write(to: url, options: .atomic)) != nil } ?? false
            if !ok { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
    }

    private static func exportURL(for shot: Shot, in folder: URL, name: String?, format: ImageFormat) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var base = name ?? fileName()
        if Prefs.bool(.add2xSuffix), shot.scale > 1, !Prefs.bool(.downscaleRetina) { base += "@\(Int(shot.scale))x" }
        return uniqueURL(in: folder, name: base, ext: format.rawValue)
    }

    /// Spotlight/Finder "Screenshot" flag, like files written by the system screenshot tool.
    static func markAsScreenCapture(_ url: URL) {
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0) else { return }
        _ = url.withUnsafeFileSystemRepresentation { path in
            plist.withUnsafeBytes { setxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, plist.count, 0, 0) }
        }
    }

    /// Copies per the "Copy to clipboard" setting: image data, a file reference, or both. Never blocks on encoding:
    /// the temp file is written in the background and the PNG / TIFF data are promised (`PasteboardImage`).
    @MainActor
    static func copy(_ shot: Shot, fileURL: URL? = nil) {
        let mode = Prefs.string(.copyBehaviour)
        let pb = NSPasteboard.general
        pb.clearContents()
        if mode != "image" {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot", isDirectory: true)
            let url = fileURL ?? (try? saveInBackground(shot, to: temp, name: fileName(bumpCounter: false)))
            if let url {
                pb.writeObjects([url as NSURL])
                if mode == "file" { return }
            }
        }
        pb.addTypes([.png, .tiff], owner: PasteboardImage(shot))
    }

    static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    /// "Save As…" panel; returns the chosen URL.
    @MainActor
    static func saveAs(_ shot: Shot) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName()
        panel.directoryURL = Prefs.exportFolder
        panel.allowedContentTypes = [ImageFormat.current.utType] + ImageFormat.allCases.filter { $0 != .current }.map(\.utType)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let ext = url.pathExtension.lowercased()
        let fmt = ImageFormat.allCases.first { $0.rawValue == ext || $0.utType.preferredFilenameExtension == ext } ?? (ext == "jpeg" ? .jpg : .png)
        do {
            guard let data = encode(shot, format: fmt) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: url, options: .atomic)
            markAsScreenCapture(url)
            return url
        } catch {
            Toast.show("Couldn't save: %@".loc(error.localizedDescription), isError: true)
            return nil
        }
    }

    static func loadShot(_ url: URL) -> Shot? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return Shot(image: img, scale: max(1, CGFloat(dpi / 72).rounded()))
    }

    static func shotFromPasteboard() -> Shot? {
        guard let img = NSImage(pasteboard: .general), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return Shot(image: cg, scale: max(1, (CGFloat(cg.width) / max(1, img.size.width)).rounded()))
    }

    /// Runnable check for the token expander.
    static func selfTest() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2024, month: 3, day: 7, hour: 15, minute: 4, second: 9))!
        let ctx = CaptureContext(app: "Safari", window: "Docs: A/B")
        let en = Locale(identifier: "en_US_POSIX")
        func x(_ t: String, illegal: Bool = true) -> String {
            expand(t, type: "Screenshot", date: date, counter: 12, context: ctx, utc: true, removeIllegal: illegal, locale: en, random: { "abc123" })
        }
        assert(x("Daisyshot %y-%m-%d at %H.%M.%S") == "Daisyshot 2024-03-07 at 15.04.09")
        assert(x("%Y %n %w") == "2024 March Thursday")
        assert(x("%H.%M %p") == "03.04 PM")
        assert(x("%a - %t") == "Safari - Docs. A-B")
        assert(x("shot %i %r {counter} {type}") == "shot 12 abc123 12 Screenshot")
        assert(x("a*b?c|d %q") == "abcd q")
        assert(x("a*b %q", illegal: false) == "a*b %q")
        assert(x("   ") == "Screenshot")
    }
}

/// Image data promised to the pasteboard. The PNG starts encoding on a background queue at copy time; a reader (AppKit
/// asks on the main thread when someone pastes, or at quit) waits only for what's left. TIFF is built only if asked for.
private final class PasteboardImage: NSObject, NSPasteboardTypeOwner, @unchecked Sendable {
    /// The pasteboard doesn't retain its owner; the latest one is kept until another app takes the pasteboard over.
    @MainActor private static var current: PasteboardImage?
    private let shot: Shot
    private let encoded = DispatchGroup()
    private var png: Data?

    @MainActor
    init(_ shot: Shot) {
        self.shot = shot
        super.init()
        Self.current = self
        encoded.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            png = Exporter.encode(shot, format: .png)
            encoded.leave()
        }
    }

    func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .png {
            encoded.wait()
            if let png { sender.setData(png, forType: .png) }
        } else if type == .tiff {
            let size = CGSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
            if let tiff = NSImage(cgImage: shot.image, size: size).tiffRepresentation { sender.setData(tiff, forType: .tiff) }
        }
    }

    func pasteboardChangedOwner(_ sender: NSPasteboard) {
        DispatchQueue.main.async { MainActor.assumeIsolated { if Self.current === self { Self.current = nil } } }
    }
}

/// WebP output through an installed `cwebp` (ImageIO can read WebP but not write it).
enum WebP {
    static let binary: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return (path + ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"])
            .map { ($0 as NSString).appendingPathComponent("cwebp") }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var available: Bool { binary != nil }

    /// Quality 1.0 = lossless.
    static func encode(png: Data, quality: Double) -> Data? {
        guard let binary else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-webp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("in.png"), dst = dir.appendingPathComponent("out.webp")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: src, options: .atomic)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = (quality >= 1 ? ["-lossless"] : ["-q", String(Int(quality * 100))]) + ["-quiet", "-metadata", "icc", src.path, "-o", dst.path]
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? try Data(contentsOf: dst) : nil
        } catch {
            return nil
        }
    }
}

extension CGImage {
    func resized(by factor: CGFloat) -> CGImage? {
        let w = max(1, Int(CGFloat(width) * factor)), h = max(1, Int(CGFloat(height) * factor))
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Re-renders into sRGB ("Convert to sRGB profile"); nil when already sRGB.
    func convertedToSRGB() -> CGImage? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard colorSpace?.name != srgb.name,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    var nsImage: NSImage { NSImage(cgImage: self, size: CGSize(width: width, height: height)) }
}

enum Sounds {
    /// Shutter sound choices (id, title). Played from macOS system sounds — no third-party audio is bundled.
    static let shutterOptions: [(id: String, title: String)] = [
        ("system", "System Default"), ("grab", "Classic"), ("shutter", "Shutter"), ("pop", "Pop"), ("tink", "Tink"),
        ("glass", "Glass"), ("morse", "Morse"), ("none", "None"),
    ]

    private static let systemDir = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"

    static func shutter() { if Prefs.bool(.playSounds) { preview(Prefs.string(.shutterSound)) } }
    static func done() { play(nil, fallback: "Glass") }
    static func start() { play(nil, fallback: "Pop") }
    static func stop() { play(nil, fallback: "Bottle") }
    /// Text recognized / QR code read.
    static func ocr() { play(nil, fallback: "Purr") }
    /// One tick of the self-timer countdown.
    static func countdown() { play(nil, fallback: "Tink") }
    static func error() { play(nil, fallback: "Funk") }

    /// Plays a shutter option regardless of the "Play sounds" setting (used by the settings picker).
    static func preview(_ id: String) {
        switch id {
        case "none": return
        case "grab": play(systemDir + "Grab.aif", fallback: "Tink", force: true)
        case "shutter": play(systemDir + "Shutter.aif", fallback: "Tink", force: true)
        case "pop", "tink", "glass", "morse": play(nil, fallback: id.capitalized, force: true)
        default: play(systemDir + "Screen Capture.aif", fallback: "Tink", force: true)
        }
    }

    private static func play(_ path: String?, fallback: String, force: Bool = false) {
        guard force || Prefs.bool(.playSounds) else { return }
        if let path, let s = NSSound(contentsOfFile: path, byReference: true) { s.play() } else { NSSound(named: fallback)?.play() }
    }
}
