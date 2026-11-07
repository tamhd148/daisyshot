import AppKit
import SwiftUI

/// All persisted settings. Each `Prefs.Key` carries its own default, so modules can declare new keys in
/// `extension Prefs.Key { static let myKey = Prefs.Key("myKey", default) }` in their own files — no central registration.
/// SwiftUI binds with `@AppStorage(Prefs.Key.x) var x: Bool`; everything else reads `Prefs.bool(.x)` etc.
enum Prefs {
    struct Key: Hashable {
        let rawValue: String
        let defaultValue: Any
        init(_ rawValue: String, _ defaultValue: Any) {
            self.rawValue = rawValue
            self.defaultValue = defaultValue
        }
        static func == (a: Key, b: Key) -> Bool { a.rawValue == b.rawValue }
        func hash(into h: inout Hasher) { h.combine(rawValue) }
    }

    static let d = UserDefaults.standard

    static func bool(_ k: Key) -> Bool { d.object(forKey: k.rawValue) as? Bool ?? k.defaultValue as? Bool ?? false }
    static func int(_ k: Key) -> Int { (d.object(forKey: k.rawValue) as? NSNumber)?.intValue ?? k.defaultValue as? Int ?? 0 }
    static func double(_ k: Key) -> Double { (d.object(forKey: k.rawValue) as? NSNumber)?.doubleValue ?? (k.defaultValue as? NSNumber)?.doubleValue ?? 0 }
    static func string(_ k: Key) -> String { d.string(forKey: k.rawValue) ?? k.defaultValue as? String ?? "" }
    static func set(_ v: Any?, _ k: Key) { d.set(v, forKey: k.rawValue) }
    static func reset(_ k: Key) { d.removeObject(forKey: k.rawValue) }

    /// Codable values (arrays, structs) stored as JSON data.
    static func codable<T: Codable>(_ k: Key, _ type: T.Type) -> T? {
        guard let data = d.data(forKey: k.rawValue) else { return k.defaultValue as? T }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func setCodable<T: Codable>(_ v: T?, _ k: Key) { d.set(v.flatMap { try? JSONEncoder().encode($0) }, forKey: k.rawValue) }

    static var exportFolder: URL { URL(fileURLWithPath: string(.exportFolder), isDirectory: true) }

    /// Private storage for captures, history and recordings.
    static var supportFolder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Daisyshot", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Core keys. Feature modules add their own in their own files.
extension Prefs.Key {
    /// Shared between modules: General settings pane (shell) ↔ capture / recording pipelines.
    static let shutterSound = Prefs.Key("shutterSound", "system")          // one of Sounds.shutterOptions ids
    static let afterCapturePin = Prefs.Key("afterCapturePin", false)
    static let afterRecordingOpenEditor = Prefs.Key("afterRecordingOpenEditor", false)
    static let recShowTimeInMenuBar = Prefs.Key("recShowTimeInMenuBar", true)
    static let playSounds = Prefs.Key("playSounds", true)
    static let showMenuBarIcon = Prefs.Key("showMenuBarIcon", true)
    static let hideIconsWhileCapturing = Prefs.Key("hideIconsWhileCapturing", false)
    static let afterCaptureQuickAccess = Prefs.Key("afterCaptureQuickAccess", true)
    static let afterCaptureCopy = Prefs.Key("afterCaptureCopy", false)
    static let afterCaptureSave = Prefs.Key("afterCaptureSave", false)
    static let afterCaptureAnnotate = Prefs.Key("afterCaptureAnnotate", false)
    static let afterRecordingQuickAccess = Prefs.Key("afterRecordingQuickAccess", true)
    static let afterRecordingCopy = Prefs.Key("afterRecordingCopy", false)
    static let afterRecordingSave = Prefs.Key("afterRecordingSave", true)
    static let exportFolder = Prefs.Key("exportFolder", FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].path)
    static let fileNameTemplate = Prefs.Key("fileNameTemplate", "Daisyshot %Y-%m-%d at %H.%M.%S")
    static let imageFormat = Prefs.Key("imageFormat", "png")
    static let jpegQuality = Prefs.Key("jpegQuality", 0.9)
    static let downscaleRetina = Prefs.Key("downscaleRetina", false)
    static let windowShadow = Prefs.Key("windowShadow", true)
    static let freezeScreen = Prefs.Key("freezeScreen", false)
    static let showMagnifier = Prefs.Key("showMagnifier", true)
    static let selfTimerSeconds = Prefs.Key("selfTimerSeconds", 5)
    static let captureAllDisplays = Prefs.Key("captureAllDisplays", false)
    static let qaPosition = Prefs.Key("qaPosition", "left")
    static let qaAutoClose = Prefs.Key("qaAutoClose", false)
    static let qaAutoCloseSeconds = Prefs.Key("qaAutoCloseSeconds", 30)
    static let qaSize = Prefs.Key("qaSize", 1.0)
    static let qaMultiDisplay = Prefs.Key("qaMultiDisplay", true)
    static let recFPS = Prefs.Key("recFPS", 60)
    static let recShowCursor = Prefs.Key("recShowCursor", true)
    static let recHighlightClicks = Prefs.Key("recHighlightClicks", false)
    static let recMicrophone = Prefs.Key("recMicrophone", false)
    static let recSystemAudio = Prefs.Key("recSystemAudio", false)
    static let recCountdown = Prefs.Key("recCountdown", true)
    static let recGIFFPS = Prefs.Key("recGIFFPS", 15)
    static let recGIFMaxWidth = Prefs.Key("recGIFMaxWidth", 800)
    static let recShowKeystrokes = Prefs.Key("recShowKeystrokes", false)
    static let recWebcam = Prefs.Key("recWebcam", false)
    static let recQuality = Prefs.Key("recQuality", "high")
    static let annotateColor = Prefs.Key("annotateColor", "#E5484D")
    static let annotateLineWidth = Prefs.Key("annotateLineWidth", 7.0)
    static let annotateFontSize = Prefs.Key("annotateFontSize", 24.0)
    static let annotateShadow = Prefs.Key("annotateShadow", true)
    static let desktopIconsHidden = Prefs.Key("desktopIconsHidden", false)
    static let desktopCoverStyle = Prefs.Key("desktopCoverStyle", "wallpaper")
    static let desktopCoverColor = Prefs.Key("desktopCoverColor", "#1E1E1E")
    static let historyEnabled = Prefs.Key("historyEnabled", true)
    static let historyDays = Prefs.Key("historyDays", 30)
    static let ocrKeepLineBreaks = Prefs.Key("ocrKeepLineBreaks", true)
    static let ocrLanguage = Prefs.Key("ocrLanguage", "")
    static let allowURLSchemes = Prefs.Key("allowURLSchemes", true)
    static let urlSchemeConsented = Prefs.Key("urlSchemeConsented", false)
    static let add2xSuffix = Prefs.Key("add2xSuffix", false)
    static let copyBehaviour = Prefs.Key("copyBehaviour", "both")
    static let screenshotCursor = Prefs.Key("screenshotCursor", false)
    static let addBorder = Prefs.Key("addBorder", false)
    static let pinBorder = Prefs.Key("pinBorder", true)
    static let pinShadow = Prefs.Key("pinShadow", true)
    static let pinRounded = Prefs.Key("pinRounded", true)
    static let recDimScreen = Prefs.Key("recDimScreen", true)
}

extension AppStorage where Value == Bool {
    init(_ k: Prefs.Key) { self.init(wrappedValue: k.defaultValue as? Bool ?? false, k.rawValue) }
}
extension AppStorage where Value == Int {
    init(_ k: Prefs.Key) { self.init(wrappedValue: k.defaultValue as? Int ?? 0, k.rawValue) }
}
extension AppStorage where Value == Double {
    init(_ k: Prefs.Key) { self.init(wrappedValue: (k.defaultValue as? NSNumber)?.doubleValue ?? 0, k.rawValue) }
}
extension AppStorage where Value == String {
    init(_ k: Prefs.Key) { self.init(wrappedValue: k.defaultValue as? String ?? "", k.rawValue) }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let a = Int(round(c.alphaComponent * 255))
        let rgb = String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
        return a == 255 ? rgb : rgb + String(format: "%02X", a)
    }
}
