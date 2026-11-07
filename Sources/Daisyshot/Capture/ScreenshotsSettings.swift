import AppKit
import SwiftUI

private typealias K = Prefs.Key

// MARK: Screenshots

struct ScreenshotsSettingsPane: View {
    @AppStorage(K.imageFormat.rawValue) var format = "png"
    @AppStorage(K.jpegQuality.rawValue) var quality = 0.9
    @AppStorage(K.downscaleRetina.rawValue) var downscale = false
    @AppStorage(K.convertToSRGB) var srgb: Bool
    @AppStorage(K.addBorder.rawValue) var addBorder = false
    @AppStorage(K.screenshotCursor.rawValue) var cursor = false
    @AppStorage(K.selfTimerSeconds.rawValue) var timer = 5
    @AppStorage(K.captureAllDisplays.rawValue) var allDisplays = false
    @AppStorage(K.freezeScreen.rawValue) var freeze = false
    @AppStorage(K.crosshairStyle) var crosshair: Int
    @AppStorage(K.showMagnifier.rawValue) var magnifier = true
    @AppStorage(K.windowShadow.rawValue) var shadow = true
    @AppStorage(K.windowBackgroundTransparent) var transparent: Bool
    @AppStorage(K.windowPaddingAmount) var padding: Double
    @AppStorage(K.scrollAutoSpeed) var scrollSpeed: Int

    var body: some View {
        DSSections {
            DSCard {
                DSRow("File format") {
                    Picker("File format", selection: Binding(get: { ImageFormat.current.rawValue }, set: { format = $0 })) {
                        ForEach(ImageFormat.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                if !WebP.available {
                    SettingsNote("To save WebP, install the cwebp encoder (brew install webp).")
                }
                if ImageFormat.current.isLossy {
                    DSRow("Quality") { SliderValue(value: $quality, range: 0.3...1, step: 0.05, label: "\(Int(quality * 100))%") }
                }
                DSToggleRow("Scale Retina screenshots to 1x", subtitle: "Smaller files, but less detail on Retina displays.", isOn: $downscale)
                Toggle("Convert to sRGB profile", isOn: $srgb)
                Toggle("Outline every screenshot with a 1 px border", isOn: $addBorder)
            }

            DSCard {
                DSRow("Self-Timer interval") {
                    Picker("Self-Timer interval", selection: $timer) {
                        ForEach([2, 3, 5, 10, 15], id: \.self) { Text("%d seconds".loc($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                DSToggleRow("Show cursor on screenshots", subtitle: "Applies to Fullscreen and Self-Timer captures.", isOn: $cursor)
                Toggle("Capture all displays in Fullscreen mode", isOn: $allDisplays)
            }

            DSSectionHeader("Area selection")
            DSCard {
                Toggle("Freeze the screen while selecting", isOn: $freeze)
                DSRow("Crosshair Mode") {
                    Picker("Crosshair Mode", selection: $crosshair) {
                        ForEach(CrosshairMode.allCases, id: \.rawValue) { Text($0.title.loc).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                magnifierRow
            }

            DSSectionHeader("Background preset")
            DSCard {
                DSRow("Apply to all screenshots") {
                    BackgroundPresetPicker(title: "Apply to all screenshots").labelsHidden().fixedSize()
                }
                SettingsNote("Apply a Background Tool preset to all screenshots. You can create presets in Annotate. Hold ⇧ Shift while capturing a screenshot to disable this option.")
            }

            DSSectionHeader("Window screenshots")
            DSCard {
                Toggle("Capture window shadow", isOn: $shadow)
                HStack(alignment: .top, spacing: 12) {
                    DSRowLabel(title: "Background")
                    Spacer(minLength: 12)
                    HStack(spacing: 14) {
                        BackgroundChoice(title: "Transparent", selected: transparent) { transparent = true } preview: { Checkerboard(cell: 6) }
                        BackgroundChoice(title: "With wallpaper", selected: !transparent) { transparent = false } preview: { WallpaperThumb() }
                    }
                }
                .padding(.vertical, 14)
                DSRow("Padding") { SliderValue(value: $padding, range: 0...120, step: 2, label: "\(Int(padding)) pt") }
                SettingsNote(transparent ? "Hold ⇧ Shift while taking a screenshot to capture the window with wallpaper."
                                         : "Hold ⇧ Shift while taking a screenshot to get a transparent background.")
                SettingsNote("For no padding at all, turn off the window shadow too.")
            }

            AutoRedactSettings()

            DSSectionHeader("Scrolling capture")
            DSCard {
                DSRow("Auto-scroll speed") {
                    Picker("Auto-scroll speed", selection: $scrollSpeed) {
                        Text("Slow").tag(0); Text("Normal").tag(1); Text("Fast").tag(2)
                    }
                    .labelsHidden().fixedSize()
                }
            }        }
    }

    /// Dimmed with a hint while Crosshair Mode is off.
    private var magnifierRow: some View {
        let off = crosshair == CrosshairMode.disabled.rawValue
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show magnifier").font(DS.Font.body).foregroundStyle(off ? DS.inkTertiary : DS.ink)
                if off {
                    Text("Turn on Crosshair Mode to use the magnifier.").font(DS.Font.sub).foregroundStyle(DS.inkSecondary)
                }
            }
            Spacer(minLength: 12)
            DSSwitch(isOn: $magnifier).disabled(off)
        }
        .frame(minHeight: DS.Metric.rowMinHeight)
        .padding(.vertical, off ? 8 : 0)
    }
}

/// 320 pt slider with its value right-aligned in `inkSecondary`.
private struct SliderValue: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String

    var body: some View {
        HStack(spacing: 14) {
            Slider(value: $value, in: range, step: step).frame(width: 320)
            Text(label).monospacedDigit().foregroundStyle(DS.inkSecondary).frame(width: 44, alignment: .trailing)
        }
    }
}

/// 100×64 thumbnail with a mock window; 2 pt `accent` ring when selected.
private struct BackgroundChoice<Preview: View>: View {
    let title: String
    let selected: Bool
    let select: () -> Void
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                ZStack {
                    preview()
                    RoundedRectangle(cornerRadius: 4).fill(.white).frame(width: 44, height: 26)
                        .shadow(color: Color(nsColor: NSColor(hex: "#101A33")).opacity(0.25), radius: 3, y: 2)
                }
                .frame(width: 100, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? DS.accent : DS.controlBorder, lineWidth: 2))
                Text(title.loc).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DS.ink : DS.inkSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct WallpaperThumb: View {
    @State private var img: NSImage?

    var body: some View {
        Group {
            if let img {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [DS.skyLight, DS.accent], startPoint: .top, endPoint: .bottom)
            }
        }
        .task { if let s = NSScreen.main { img = await WallpaperProvider.load(for: s) } }   // first render is ~170 ms
    }
}

/// Sections shown in Settings › Advanced that belong to capture (file naming, clipboard, OCR, All-In-One).
struct CaptureAdvancedSections: View {
    @AppStorage(K.fileNameTemplate.rawValue) var template = ""
    @AppStorage(K.askForNameAfterCapture) var askForName: Bool
    @AppStorage(K.add2xSuffix.rawValue) var suffix = false
    @AppStorage(K.copyBehaviour.rawValue) var copy = "both"
    @AppStorage(K.ocrAutoDetectLanguage) var autoDetect: Bool
    @AppStorage(K.ocrLanguage.rawValue) var language = ""
    @AppStorage(K.ocrKeepLineBreaks.rawValue) var lineBreaks = true
    @AppStorage(K.ocrDetectLinks) var detectLinks: Bool
    @AppStorage(K.ocrDetectCodes) var detectCodes: Bool
    @AppStorage(K.rememberAllInOneArea) var rememberAIO: Bool
    // Re-render the preview when the editor changes these.
    @AppStorage(K.fileNameUTC) var utc: Bool
    @AppStorage(K.removeIllegalFileChars) var removeIllegal: Bool

    /// A plain `Group` so the headers and cards flatten into `AdvancedPane`'s `DSSections`.
    var body: some View {
        Group {
            DSSectionHeader("File naming")
            DSCard {
                DSRow("File name format") {
                    HStack(spacing: 12) {
                        DSCode(Exporter.fileName(template: template, date: Date(), bumpCounter: false) + "." + ImageFormat.current.rawValue)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Change…") { FileNameEditor.show() }
                    }
                }
                Toggle("Name each capture before saving", isOn: $askForName)
                DSToggleRow("Add \"@2x\" suffix to Retina screenshots",
                            subtitle: "Helps apps that would otherwise show Retina images at double size.", isOn: $suffix)
            }

            DSSectionHeader("Clipboard")
            DSCard {
                DSRow("Copy to clipboard") {
                    Picker("Copy to clipboard", selection: $copy) {
                        Text("File & Image (default)").tag("both"); Text("Image only").tag("image"); Text("File only").tag("file")
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsNote("Change this if some apps or clipboard managers paste your captures incorrectly.")
            }

            DSSectionHeader("Text recognition")
            DSCard {
                Toggle("Automatically detect language", isOn: $autoDetect)
                DSRow("Primary language") {
                    Picker("Primary language", selection: $language) {
                        Text("Automatic").tag("")
                        ForEach(TextRecognizer.supportedLanguages, id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Toggle("Keep line breaks", isOn: $lineBreaks)
                Toggle("Detect links", isOn: $detectLinks)
                Toggle("Read QR codes & barcodes", isOn: $detectCodes)
            }

            DSSectionHeader("All-In-One")
            DSCard {
                Toggle("Remember last selection", isOn: $rememberAIO)
            }
        }
    }
}

// MARK: File name editor

/// "File name format" window: token chips (click or drag into the field), live preview, options.
@MainActor
enum FileNameEditor {
    private static var window: NSWindow?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 480), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "File name format".loc
        w.isReleasedWhenClosed = false
        // The window follows the view's size (it grows when the auto-increment row appears).
        let host = NSHostingController(rootView: FileNameEditorView(close: close))
        host.sizingOptions = .preferredContentSize
        w.contentViewController = host
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }

    static func close() {
        window?.close()
        window = nil
    }
}

private struct FileNameEditorView: View {
    let close: () -> Void
    @State private var draft = Prefs.string(.fileNameTemplate)
    @State private var removeIllegal = Prefs.bool(.removeIllegalFileChars)
    @State private var utc = Prefs.bool(.fileNameUTC)
    @State private var next = Prefs.int(.fileNameCounter) + 1

    private var preview: String {
        Exporter.expand(draft, type: "Screenshot", date: Date(), counter: next, context: CaptureContext(app: "Finder", window: "Downloads"),
                        utc: utc, removeIllegal: removeIllegal) + "." + ImageFormat.current.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Build a name from text and tokens:").font(DS.Font.body).foregroundStyle(DS.ink)
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, design: .monospaced))
                .dropDestination(for: String.self) { items, _ in
                    draft += items.joined()
                    return true
                }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Preview:").font(.system(size: 13)).foregroundStyle(DS.inkSecondary)
                DSCode(preview).lineLimit(2)
            }
            DSCard(padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 8) {
                    ForEach(Exporter.tokens, id: \.code) { t in
                        TokenChip(title: t.title, code: t.code) { draft += t.code }
                    }
                }
            }
            Text("Click a token to append it, or drag it into the field.").font(DS.Font.caption).foregroundStyle(DS.inkSecondary)
            HStack(spacing: 18) {
                Toggle("Remove illegal characters", isOn: $removeIllegal)
                Toggle("Use UTC time zone", isOn: $utc)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 13)).foregroundStyle(DS.ink)
            if draft.contains("%i") {
                HStack {
                    Text("Next counter value:").font(.system(size: 13)).foregroundStyle(DS.ink)
                    TextField("", value: $next, format: .number.grouping(.never)).frame(width: 80)
                }
            }
            HStack {
                Button("Restore Defaults") {
                    draft = Prefs.Key.fileNameTemplate.defaultValue as? String ?? ""
                    removeIllegal = true
                    utc = false
                }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("OK") {
                    Prefs.set(draft, .fileNameTemplate)
                    Prefs.set(removeIllegal, .removeIllegalFileChars)
                    Prefs.set(utc, .fileNameUTC)
                    Prefs.set(max(0, next - 1), .fileNameCounter)
                    close()
                }
                .buttonStyle(.dsPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.windowBg)
        .buttonStyle(DSButtonStyle())
        .tint(DS.accent)
    }
}

private struct TokenChip: View {
    let title: String
    let code: String
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(DS.inkTertiary)
            Text(title.loc).font(.system(size: 13)).foregroundStyle(DS.accentText)
            Spacer(minLength: 4)
            Text(code).font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.inkSecondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(DS.accentTint))
        .overlay(Capsule().strokeBorder(hover ? DS.accent : DS.accentTint))
        .contentShape(Capsule())
        .onHover { hover = $0 }
        .onTapGesture(perform: tap)
        .draggable(code)
        .help("Click to append %@".loc(code))
    }
}
