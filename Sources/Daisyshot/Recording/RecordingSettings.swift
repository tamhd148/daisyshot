import AppKit
import SwiftUI

/// Recording keys owned by this module (core keys like `recFPS`, `recShowCursor`, `recDimScreen` live in Prefs.swift).
extension Prefs.Key {
    static let recMaxResolution = Prefs.Key("recMaxResolution", 0)            // VideoResolution raw value (0 = original)
    static let recDownscaleRetina = Prefs.Key("recDownscaleRetina", false)
    static let recShowControls = Prefs.Key("recShowControls", true)
    static let recRememberArea = Prefs.Key("recRememberArea", false)
    static let recLastArea = Prefs.Key("recLastArea", "")                     // JSON CaptureRegion
    static let recLastRatio = Prefs.Key("recLastRatio", "free")               // RecordingSizePreset id
    static let recLastSource = Prefs.Key("recLastSource", "area")             // RecordingSetup.Source: display / window / area
    static let recLastMode = Prefs.Key("recLastMode", "studio")               // studio (GIF is chosen per shortcut)
    static let studioAfterRecording = Prefs.Key("studioAfterRecording", "editor")   // editor | quickExport | saveFile | copyFile
    static let recSavedSizes = Prefs.Key("recSavedSizes", "")                 // "WxH" points, one per line
    static let recIgnoredWindows = Prefs.Key("recIgnoredWindows", "")         // "app<TAB>title", one per line
    static let studioAutoZoom = Prefs.Key("studioAutoZoom", true)             // new projects get zooms from their clicks
    static let recHideCameraPreview = Prefs.Key("recHideCameraPreview", false)   // Studio: camera recorded, its bubble not on screen
    static let recNotes = Prefs.Key("recNotes", "")                           // speaker notes text
    static let recNotesFontSize = Prefs.Key("recNotesFontSize", 28.0)
    static let recNotesSpeed = Prefs.Key("recNotesSpeed", 1.0)
    static let recNotesOpacity = Prefs.Key("recNotesOpacity", 0.92)
    static let recNotesScrollWhileRecording = Prefs.Key("recNotesScrollWhileRecording", true)
    static let recDeviceID = Prefs.Key("recDeviceID", "")                     // iPhone / iPad (AVCaptureDevice uniqueID) last recorded
    static let recDeviceAudio = Prefs.Key("recDeviceAudio", true)             // record the device's own sound
    static let recDeviceFrame = Prefs.Key("recDeviceFrame", true)             // new device recordings show a device frame
    static let recClickSize = Prefs.Key("recClickSize", 50)
    static let recClickColor = Prefs.Key("recClickColor", "accent")           // HighlightColor
    static let recClickStyle = Prefs.Key("recClickStyle", "filled")           // filled | outline
    static let recClickAnimate = Prefs.Key("recClickAnimate", true)
    static let recKeysSize = Prefs.Key("recKeysSize", 45)
    static let recKeysStyle = Prefs.Key("recKeysStyle", "dark")               // dark | light
    static let recKeysPosition = Prefs.Key("recKeysPosition", 4)              // KeystrokePosition
    static let recKeysAll = Prefs.Key("recKeysAll", false)
    static let recKeysBlur = Prefs.Key("recKeysBlur", true)
    static let recMono = Prefs.Key("recMono", false)
    static let recMergeAudio = Prefs.Key("recMergeAudio", true)               // Audio tracks: single (true) / separate
    static let recMicDeviceID = Prefs.Key("recMicDeviceID", "")               // "" = system default input
    static let recCameraDeviceID = Prefs.Key("recCameraDeviceID", "")
    static let recCameraShape = Prefs.Key("recCameraShape", "circle")         // CameraShape
    static let recCameraSize = Prefs.Key("recCameraSize", "medium")           // CameraSize
    static let recCameraMirror = Prefs.Key("recCameraMirror", true)
    static let recCameraX = Prefs.Key("recCameraX", 1.0)                      // 0 left … 1 right of the free space in the area
    static let recCameraY = Prefs.Key("recCameraY", 1.0)                      // 0 top … 1 bottom
    static let recGIFQuality = Prefs.Key("recGIFQuality", 80)
    static let recGIFOptimize = Prefs.Key("recGIFOptimize", true)
    static let recWarnLowDisk = Prefs.Key("recWarnLowDisk", true)
    static let recCountdownSeconds = Prefs.Key("recCountdownSeconds", 3)     // used while `recCountdown` is on
    static let recSystemAudioApps = Prefs.Key("recSystemAudioApps", "")      // bundle IDs, one per line; "" = all apps
}

/// Every video recording is a Studio project (opened in the video editor); GIFs are recorded straight to a file.
enum RecordingMode: String {
    case gif, studio
}

/// "Max resolution": output is scaled down to fit a 16:9 box of this height (either orientation).
enum VideoResolution: Int, CaseIterable, Identifiable {
    case original = 0, p480 = 480, p720 = 720, p1080 = 1080, p1440 = 1440, p4k = 2160
    var id: Int { rawValue }
    var title: String { self == .original ? "Original" : self == .p4k ? "4K" : "\(rawValue)p" }

    /// Even pixel size for a `points` area captured at `scale`, limited to this resolution.
    func fit(points: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        var w = points.width * scale, h = points.height * scale
        if self != .original, w > 0, h > 0 {
            let short = CGFloat(rawValue), long = (short * 16 / 9).rounded()
            let f = min(1, long / max(w, h), short / min(w, h))
            w *= f
            h *= f
        }
        return (Int(w.rounded()) & ~1, Int(h.rounded()) & ~1)
    }
}

enum HighlightColor: String, CaseIterable, Identifiable {
    case accent, blue, purple, pink, red, orange, yellow, green, gray
    var id: String { rawValue }
    var title: String { self == .accent ? "System Accent Color" : rawValue.capitalized }
    var nsColor: NSColor {
        switch self {
        case .accent: return .controlAccentColor
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .gray: return .systemGray
        }
    }
}

enum KeystrokePosition: Int, CaseIterable, Identifiable {
    case topLeft, top, topRight, bottomLeft, bottom, bottomRight
    var id: Int { rawValue }
    var title: String { ["Top Left", "Top Center", "Top Right", "Bottom Left", "Bottom Center", "Bottom Right"][rawValue] }
    var isTop: Bool { rawValue < 3 }
    /// 0 left, 0.5 center, 1 right.
    var horizontal: CGFloat { [0, 0.5, 1][rawValue % 3] }
}

enum CameraShape: String, CaseIterable, Identifiable {
    case circle, square, rectangle, vertical
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String { ["circle": "circle", "square": "square", "rectangle": "rectangle", "vertical": "rectangle.portrait"][rawValue]! }
    /// Bubble size for a base side length.
    func size(_ side: CGFloat) -> CGSize {
        switch self {
        case .circle, .square: return CGSize(width: side, height: side)
        case .rectangle: return CGSize(width: side * 16 / 9, height: side)
        case .vertical: return CGSize(width: side * 3 / 4, height: side * 4 / 3)
        }
    }
    func cornerRadius(_ size: CGSize) -> CGFloat { self == .circle ? min(size.width, size.height) / 2 : min(size.width, size.height) * 0.12 }
}

enum CameraSize: String, CaseIterable, Identifiable {
    case small, medium, large, huge
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var side: CGFloat { ["small": 120, "medium": 180, "large": 260, "huge": 360][rawValue]! }
}

// MARK: Settings pane

struct RecordingSettingsPane: View {
    @AppStorage(Prefs.Key.recFPS) var fps: Int
    @AppStorage(Prefs.Key.recMaxResolution) var maxResolution: Int
    @AppStorage(Prefs.Key.recDownscaleRetina) var downscale: Bool
    @AppStorage(Prefs.Key.recQuality) var quality: String
    @AppStorage(Prefs.Key.recShowControls) var showControls: Bool
    @AppStorage(Prefs.Key.recShowTimeInMenuBar) var timeInMenuBar: Bool
    @AppStorage(Prefs.Key.recDimScreen) var dim: Bool
    @AppStorage(Prefs.Key.recRememberArea) var rememberArea: Bool
    @AppStorage(Prefs.Key.recCountdown) var countdown: Bool
    @AppStorage(Prefs.Key.recCountdownSeconds) var countdownSeconds: Int
    @AppStorage(Prefs.Key.recWarnLowDisk) var warnDisk: Bool
    @AppStorage(Prefs.Key.recShowCursor) var cursor: Bool
    @AppStorage(Prefs.Key.recHighlightClicks) var clicks: Bool
    @AppStorage(Prefs.Key.recShowKeystrokes) var keys: Bool
    @AppStorage(Prefs.Key.recSystemAudio) var systemAudio: Bool
    @AppStorage(Prefs.Key.recMono) var mono: Bool
    @AppStorage(Prefs.Key.studioAfterRecording) var afterStudio: String
    @AppStorage(Prefs.Key.studioAutoZoom) var autoZoom: Bool
    @AppStorage(Prefs.Key.studioQuickExportKeep) var keepQuick: Bool
    @AppStorage(Prefs.Key.studioProjectsFolder) var projectsFolder: String
    @AppStorage(Prefs.Key.recMergeAudio) var merge: Bool
    @AppStorage(Prefs.Key.recCameraShape) var cameraShape: String
    @AppStorage(Prefs.Key.recCameraSize) var cameraSize: String
    @AppStorage(Prefs.Key.recCameraMirror) var mirror: Bool
    @AppStorage(Prefs.Key.recGIFFPS) var gifFPS: Int
    @AppStorage(Prefs.Key.recGIFMaxWidth) var gifWidth: Int
    @AppStorage(Prefs.Key.recGIFOptimize) var optimize: Bool
    @AppStorage(Prefs.Key.recGIFQuality) var gifQuality: Int
    @AppStorage(Prefs.Key.menuBarRecordingIndicator) var recIndicator: String
    @State private var clickOptions = false
    @State private var keyOptions = false

    var body: some View {
        DSSections {
            DSSectionHeader("Video")
            DSCard {
                DSRow("Frame rate") {
                    Picker("Frame rate", selection: $fps) { ForEach([10, 15, 24, 25, 30, 48, 50, 60], id: \.self) { Text("\($0) fps").tag($0) } }
                        .labelsHidden().fixedSize()
                }
                DSRow("Max resolution", subtitle: "Set maximum resolution to reduce file size.") {
                    Picker("Max resolution", selection: $maxResolution) {
                        ForEach(VideoResolution.allCases) { Text($0.title.loc).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                Toggle("Scale Retina videos to 1x", isOn: $downscale)
                DSRow("Quality") {
                    Picker("Quality", selection: $quality) {
                        Text("Low").tag("low"); Text("Medium").tag("medium"); Text("High").tag("high"); Text("Maximum (HEVC)").tag("max")
                    }
                    .labelsHidden().fixedSize()
                }
                DSRow("Save new projects in") {
                    HStack(spacing: 8) {
                        Text(projectsFolder.isEmpty ? "Daisyshot Library".loc : (projectsFolder as NSString).lastPathComponent)
                            .lineLimit(1).truncationMode(.middle).help(projectsFolder)
                        Button("Change…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { projectsFolder = u.path }
                        }
                        if !projectsFolder.isEmpty { Button("Use Library") { projectsFolder = "" } }
                    }
                }
                DSRow("After recording") {
                    Picker("After recording", selection: $afterStudio) {
                        Text("Open the editor").tag("editor")
                        Text("Show Quick Export").tag("quickExport")
                        Text("Export MP4 Automatically").tag("saveFile")
                        Text("Export and Copy MP4 Automatically").tag("copyFile")
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsNote("Quick Export exports MP4 or GIF straight away with your last style and export settings; Edit opens the editor. The Start card's Then: menu changes this too.")
                Toggle("Keep the project after Quick Export", isOn: $keepQuick)
                    .help("Off: after a Quick Export you're asked whether to keep the project or delete it")
                Toggle("Create zooms automatically", isOn: $autoZoom)
            }

            DSSectionHeader("Controls")
            DSCard {
                Toggle("Show controls while recording", isOn: $showControls)
                Toggle(isOn: $timeInMenuBar) {
                    HStack(spacing: 10) {
                        Text("Show elapsed time in the menu bar")
                        menuBarTimeChip
                    }
                }
                Toggle("Dim screen while recording", isOn: $dim)
                Toggle("Remember last selection", isOn: $rememberArea)
                DSRow("Countdown") {
                    Picker("Countdown", selection: Binding(get: { countdown ? countdownSeconds : 0 },
                                                           set: { countdown = $0 > 0; if $0 > 0 { countdownSeconds = $0 } })) {
                        Text("Off").tag(0)
                        ForEach([3, 5, 10], id: \.self) { Text("%d seconds".loc($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                DSToggleRow("Stop recording when disk space is low",
                            subtitle: "Keeps the recording intact instead of failing when the disk fills up.", isOn: $warnDisk)
            }

            DSSectionHeader("Cursor & keystrokes")
            DSCard {
                Toggle("Show cursor", isOn: $cursor)
                DSRow("Highlight clicks") {
                    HStack(spacing: 10) {
                        DSSwitch(isOn: $clicks)
                        Button("Options…") { clickOptions = true }
                    }
                }
                DSRow("Show keystrokes") {
                    HStack(spacing: 10) {
                        DSSwitch(isOn: $keys)
                        Button("Options…") { keyOptions = true }
                    }
                }
            }

            DSSectionHeader("Audio")
            DSCard {
                DSToggleRow("Record system audio",
                            subtitle: "Captures audio playing from other apps.", isOn: $systemAudio)
                Toggle("Record audio in mono", isOn: $mono)
                DSRow("Audio tracks",
                      subtitle: "Separate tracks let you mix the microphone and system audio independently in a video editor.") {
                    Picker("Audio tracks", selection: $merge) {
                        Text("Single track").tag(true)
                        Text("Separate tracks").tag(false)
                    }
                    .labelsHidden().fixedSize()
                }
            }

            DSSectionHeader("Camera")
            DSCard {
                DSRow("Shape") {
                    Picker("Shape", selection: $cameraShape) {
                        ForEach(CameraShape.allCases) { Label($0.title.loc, systemImage: $0.symbol).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                DSRow("Size") {
                    Picker("Size", selection: $cameraSize) { ForEach(CameraSize.allCases) { Text($0.title.loc).tag($0.rawValue) } }
                        .labelsHidden().fixedSize()
                }
                Toggle("Mirror camera", isOn: $mirror)
                SettingsNote("Drag the camera to move it. Click it to toggle full screen.")
            }

            DSSectionHeader("GIF")
            DSCard {
                DSRow("Frame rate") {
                    Picker("Frame rate", selection: $gifFPS) { ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0) fps").tag($0) } }
                        .labelsHidden().fixedSize()
                }
                DSRow("Max size") {
                    Picker("Max size", selection: $gifWidth) {
                        ForEach([1200, 960, 800, 640, 500, 480, 320, 256, 200], id: \.self) { Text($0 == 800 ? "%d x auto (default)".loc($0) : "%d x auto".loc($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                DSToggleRow("Optimize GIFs",
                            subtitle: "Merges repeated frames and reduces color noise for much smaller files.", isOn: $optimize)
                DSRow("Quality") {
                    HStack(spacing: 12) {
                        Text("Low").fixedSize().font(DS.Font.sub).foregroundStyle(DS.inkSecondary)
                        Slider(value: Binding(get: { Double(gifQuality) }, set: { gifQuality = Int($0) }), in: 10...100, step: 10)
                            .labelsHidden().frame(width: 300)
                        Text("High").fixedSize().font(DS.Font.sub).foregroundStyle(DS.inkSecondary)
                    }
                }
            }
        }
        .sheet(isPresented: $clickOptions) { ClickHighlightOptions { clickOptions = false } }
        .sheet(isPresented: $keyOptions) { KeystrokeOptions { keyOptions = false } }
    }

    /// Preview of the menu bar while recording: the current recording glyph and a sample time.
    private var menuBarTimeChip: some View {
        HStack(spacing: 6) {
            Image(nsImage: MenuBarIcon.recordingImage(recIndicator)).resizable().frame(width: 14, height: 14)
            Text("00:42").monospacedDigit()
        }
        .font(DS.Font.caption)
        .foregroundStyle(DS.inkSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            shape.fill(DS.controlBg).overlay(shape.strokeBorder(DS.controlBorder))
        }
        .accessibilityHidden(true)
    }
}

struct ClickHighlightOptions: View {
    var done: () -> Void
    @AppStorage(Prefs.Key.recClickSize) var size: Int
    @AppStorage(Prefs.Key.recClickColor) var color: String
    @AppStorage(Prefs.Key.recClickStyle) var style: String
    @AppStorage(Prefs.Key.recClickAnimate) var animate: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("Size") { Slider(value: Binding(get: { Double(size) }, set: { size = Int($0) }), in: 20...120) }
                Picker("Color", selection: $color) {
                    ForEach(HighlightColor.allCases) { c in
                        Label { Text(c.title.loc) } icon: { Image(nsImage: Self.swatch(c.nsColor)) }.tag(c.rawValue)
                    }
                }
                Picker("Style", selection: $style) { Text("Filled").tag("filled"); Text("Outline").tag("outline") }.pickerStyle(.segmented)
                Toggle("Animate clicks", isOn: $animate)
                ClickPreview(size: size, color: color, style: style, animate: animate)
                    .frame(height: 140)
                    .listRowInsets(EdgeInsets())
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)   // sheets stay native forms; override the window's row style
            HStack { Spacer(); Button("Done", action: done).buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction) }.padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .tint(DS.accent)
    }

    static func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: CGSize(width: 12, height: 12), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
    }
}

/// "Click to try it": the real highlight view, so the preview always matches the recording.
private struct ClickPreview: NSViewRepresentable {
    var size: Int, color: String, style: String, animate: Bool

    func makeNSView(context: Context) -> PreviewView { PreviewView(frame: .zero) }
    func updateNSView(_ v: PreviewView, context: Context) { v.ripple.style = .current }

    final class PreviewView: NSView {
        let ripple = ClickRippleView(frame: .zero)
        private let label = NSTextField(labelWithString: "Click to try it".loc)
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
            ripple.autoresizingMask = [.width, .height]
            addSubview(ripple)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); ripple.frame = bounds }
        override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
        override func mouseDown(with e: NSEvent) { ripple.press(at: convert(e.locationInWindow, from: nil)) }
        override func mouseDragged(with e: NSEvent) { ripple.move(to: convert(e.locationInWindow, from: nil)) }
        override func mouseUp(with e: NSEvent) { ripple.release() }
    }
}

struct KeystrokeOptions: View {
    var done: () -> Void
    @AppStorage(Prefs.Key.recKeysSize) var size: Int
    @AppStorage(Prefs.Key.recKeysStyle) var style: String
    @AppStorage(Prefs.Key.recKeysPosition) var position: Int
    @AppStorage(Prefs.Key.recKeysAll) var all: Bool
    @AppStorage(Prefs.Key.recKeysBlur) var blur: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("Size") { Slider(value: Binding(get: { Double(size) }, set: { size = Int($0) }), in: 24...96) }
                Picker("Style", selection: $style) { Text("Dark").tag("dark"); Text("Light").tag("light") }.pickerStyle(.segmented)
                Picker("Position", selection: $position) { ForEach(KeystrokePosition.allCases) { Text($0.title.loc).tag($0.rawValue) } }
                Picker("Keys", selection: $all) {
                    Text("Show only command keys").tag(false)
                    Text("Show all keys").tag(true)
                }
                .pickerStyle(.radioGroup)
                if all {
                    Label("Everything you type will be visible in the recording, including passwords.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Blur background", isOn: $blur)
                HStack {
                    Spacer()
                    KeystrokeBadge(text: all ? "Hello ⌘S".loc : "⌘⇧S", size: CGFloat(size), light: style == "light", blur: blur)
                    Spacer()
                }
                .padding(.vertical, 8)
                .background(LinearGradient(colors: [.blue.opacity(0.5), .purple.opacity(0.5)], startPoint: .leading, endPoint: .trailing))
                .listRowInsets(EdgeInsets())
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)   // sheets stay native forms; override the window's row style
            HStack { Spacer(); Button("Done", action: done).buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction) }.padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .tint(DS.accent)
    }
}
