import AppKit
import SwiftUI

extension Prefs.Key {
    /// Settings › Screenshots: preset applied to every capture ("" = none). Hold ⇧ while capturing to skip (capture's job).
    static let backgroundPresetID = Prefs.Key("backgroundPresetID", "")
    static let annotateBackgroundPresets = Prefs.Key("annotateBackgroundPresets", [BackgroundPreset]())
    /// The last background used in the editor ("Apply Previous Settings").
    static let annotateLastBackground = Prefs.Key("annotateLastBackground", BackgroundSettings())
}

/// A saved set of Background-tool settings.
struct BackgroundPreset: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var settings: BackgroundSettings

    @MainActor var thumbnail: NSImage { BackgroundPresets.thumbnail(settings) }
}

/// Observable list of presets, persisted in Prefs.
@MainActor
final class PresetStore: ObservableObject {
    static let shared = PresetStore()
    @Published var presets: [BackgroundPreset] = Prefs.codable(.annotateBackgroundPresets, [BackgroundPreset].self) ?? [] {
        didSet { Prefs.setCodable(presets, .annotateBackgroundPresets) }
    }
}

/// Contract used by capture: applies the Background-tool preset chosen in Settings › Screenshots ("apply to all screenshots").
@MainActor
enum BackgroundPresets {
    static var all: [BackgroundPreset] { PresetStore.shared.presets }

    static func preset(_ id: String) -> BackgroundPreset? { all.first { $0.id == id } }

    static func applyAutoPreset(_ shot: Shot) -> Shot {
        guard let p = preset(Prefs.string(.backgroundPresetID)) else { return shot }
        return apply(p.settings, to: shot)
    }

    static func apply(_ settings: BackgroundSettings, to shot: Shot) -> Shot {
        guard settings.isActive else { return shot }
        return AnnotateRenderer.flatten(DocState(image: shot.image, scale: shot.scale, background: settings))
    }

    @discardableResult
    static func add(_ name: String, _ settings: BackgroundSettings) -> BackgroundPreset {
        let p = BackgroundPreset(name: name, settings: settings)
        PresetStore.shared.presets.append(p)
        return p
    }

    static func update(_ id: String, name: String? = nil, settings: BackgroundSettings? = nil) {
        guard let i = PresetStore.shared.presets.firstIndex(where: { $0.id == id }) else { return }
        if let name { PresetStore.shared.presets[i].name = name }
        if let settings { PresetStore.shared.presets[i].settings = settings }
    }

    static func delete(_ id: String) {
        PresetStore.shared.presets.removeAll { $0.id == id }
        if Prefs.string(.backgroundPresetID) == id { Prefs.set("", .backgroundPresetID) }
    }

    // MARK: Thumbnails

    private static var thumbs: [String: NSImage] = [:]

    /// A mock window rendered with `settings`, for menus and the Settings picker.
    static func thumbnail(_ settings: BackgroundSettings, height: CGFloat = 100) -> NSImage {
        let key = "\(height)|\(settings)"
        if let hit = thumbs[key] { return hit }
        let out = apply(settings, to: Shot(image: sample, scale: 1)).image
        let k = height / CGFloat(out.height)
        let img = NSImage(cgImage: out.resized(by: min(1, k * 2)) ?? out, size: CGSize(width: CGFloat(out.width) * k, height: height))
        thumbs[key] = img
        return img
    }

    /// 640×400 generic app window.
    private static let sample: CGImage = {
        let w = 640, h = 400
        let ctx = AnnotateRenderer.bitmapContext(w, h)!
        ctx.setFillColor(NSColor(white: 0.98, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: h - 44, width: w, height: 44))
        for (i, c) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
            ctx.setFillColor(NSColor(hex: c).cgColor)
            ctx.fillEllipse(in: CGRect(x: 18 + i * 22, y: h - 29, width: 14, height: 14))
        }
        ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 150, height: h - 44))
        ctx.setFillColor(NSColor(white: 0.8, alpha: 1).cgColor)
        for i in 0 ..< 7 {
            ctx.fill(CGRect(x: 180, y: h - 90 - i * 40, width: 420 - (i % 3) * 90, height: 14))
            ctx.fill(CGRect(x: 20, y: h - 80 - i * 36, width: 100 - (i % 2) * 30, height: 10))
        }
        return ctx.makeImage()!
    }()
}

/// Settings › Screenshots: "Background preset — apply Background Tool preset to all screenshots".
struct BackgroundPresetPicker: View {
    @AppStorage(Prefs.Key.backgroundPresetID) var presetID: String
    @ObservedObject private var store = PresetStore.shared
    var title = "Background preset"

    var body: some View {
        Picker(title.loc, selection: $presetID) {
            Text("None").tag("")
            if !store.presets.isEmpty { Divider() }
            ForEach(store.presets) { p in
                Label { Text(p.name) } icon: { Image(nsImage: BackgroundPresets.thumbnail(p.settings, height: 16)) }
                    .tag(p.id)
            }
            if !presetID.isEmpty, BackgroundPresets.preset(presetID) == nil { Text("Missing preset").tag(presetID) }
        }
        .help("Apply a Background Tool preset to all screenshots. Create presets in the Annotate editor's Background tool. Hold ⇧ while capturing to skip it.")
    }
}
