import AppKit
import SwiftUI

extension Prefs.Key {
    static let annotateInverseArrow = Prefs.Key("inverseArrowDirection", false)
    static let annotateSmoothDrawing = Prefs.Key("annotateSmoothDrawing", true)
    static let annotateRememberBackground = Prefs.Key("annotateRestoreBackgroundToolOpenState", false)
    static let annotateBackgroundLastOpened = Prefs.Key("annotateBackgroundLastOpened", false)
    static let annotateExpandCanvas = Prefs.Key("annotateExpandCanvas", false)
    static let annotateAlwaysOnTop = Prefs.Key("annotateAlwaysOnTop", false)
    static let annotateShowDockIcon = Prefs.Key("showDockIconWhenAnnotate", true)
    static let annotateLockCanvas = Prefs.Key("annotateLockCanvas", false)
    static let annotateSnapCrop = Prefs.Key("snapInAnnotateCrop", true)
    static let annotateShowMoreWallpapers = Prefs.Key("annotateShowMoreGradients", false)
    static let annotateLastTool = Prefs.Key("annotateLastTool", "arrow")
    static let annotateArrowStyle = Prefs.Key("annotateLastArrowStyle", "standard")
    static let annotateTextStyle = Prefs.Key("annotateTextStyle", "standard")
    static let annotateRedactStyle = Prefs.Key("annotateLastPixelateStyle", "pixelate")
    static let annotateRedactIntensity = Prefs.Key("annotatePixelateIntensity", 0.5)
    static let annotateSpotShape = Prefs.Key("annotateLastHighlightShape", "rectangle")
    static let annotateCounterStyle = Prefs.Key("annotateLastCounterStyle", "numeric")
    static let annotateLastSaveFolder = Prefs.Key("annotateLastSaveURL", "")
}

// MARK: Annotate

struct AnnotateSettingsPane: View {
    @AppStorage(Prefs.Key.annotateInverseArrow) var inverseArrow: Bool
    @AppStorage(Prefs.Key.annotateSmoothDrawing) var smooth: Bool
    @AppStorage(Prefs.Key.annotateRememberBackground) var rememberBackground: Bool
    @AppStorage(Prefs.Key.annotateShadow) var shadow: Bool
    @AppStorage(Prefs.Key.annotateExpandCanvas) var expand: Bool
    @AppStorage(Prefs.Key.annotateAlwaysOnTop) var onTop: Bool
    @AppStorage(Prefs.Key.annotateShowDockIcon) var dock: Bool
    @AppStorage(Prefs.Key.annotateSnapCrop) var snapCrop: Bool
    @AppStorage(Prefs.Key.annotateColor) var color: String
    @AppStorage(Prefs.Key.annotateLineWidth) var width: Double
    @AppStorage(Prefs.Key.annotateFontSize) var font: Double

    var body: some View {
        DSSections {
            DSCard {
                DSToggleRow("Inverse arrow direction", subtitle: "Press ⌥ (option) when drawing to invert the behavior.", isOn: $inverseArrow)
                Toggle("Smooth drawing", isOn: $smooth)
                Toggle("Reopen the Background panel if it was open last time", isOn: $rememberBackground)
                Toggle("Draw shadow on objects", isOn: $shadow)
                DSToggleRow("Automatically expand canvas", subtitle: "Grows the canvas so annotations near the edge are never cut off.", isOn: $expand)
                DSToggleRow("Snap crop to edges", subtitle: "Hold ⌘ (command) while cropping to invert the behavior.", isOn: $snapCrop)
            }

            DSSectionHeader("Window")
            DSCard {
                Toggle("Always on top", isOn: $onTop)
                DSToggleRow("Show Dock icon", subtitle: "Shows Daisyshot in the Dock and app switcher while an editor is open.", isOn: $dock)
            }

            DSSectionHeader("Defaults")
            DSCard {
                DSRow("Color") {
                    DSSwatches(hex: $color, swatches: ["#E5484D", "#FFC633", "#3E7BFA", "#2FA57A", "#101A33", "#FFFFFF"])
                }
                DSRow("Line width") { slider($width, 1 ... 30) }
                DSRow("Font size") { slider($font, 10 ... 120) }
                preview.padding(.vertical, 14)
            }
        }
        .onChange(of: onTop) { _, _ in AnnotateEditor.applyWindowPrefs() }
        .onChange(of: dock) { _, _ in AnnotateEditor.applyWindowPrefs() }
    }

    private func slider(_ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 14) {
            Slider(value: value, in: range).frame(width: 340)
            Text("\(Int(value.wrappedValue))").monospacedDigit().foregroundStyle(DS.inkSecondary).frame(width: 28, alignment: .trailing)
        }
    }

    /// An arrow (drawn by the editor's renderer) and "Aa" at the current colour, line width, font size and shadow.
    private var preview: some View {
        HStack(spacing: 36) {
            HStack(spacing: 36) {
                Canvas { ctx, size in
                    // Shadow comes from SwiftUI: the renderer's shadow offset assumes the editor's flipped context.
                    let a = Annotation(kind: .arrow, points: [CGPoint(x: 12, y: size.height - 12), CGPoint(x: size.width - 12, y: 14)],
                                       color: color, lineWidth: width, shadow: false, fontSize: font)
                    ctx.withCGContext { AnnotateRenderer.drawAnnotation(a, nil, $0) }
                }
                .frame(width: 170, height: 72)
                Text("Aa").font(.system(size: font, weight: .bold)).foregroundStyle(Color(nsColor: NSColor(hex: color)))
            }
            .shadow(color: .black.opacity(shadow ? 0.45 : 0), radius: 3, y: 2)
            Text("Preview").font(DS.Font.caption).foregroundStyle(DS.inkSecondary)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background(DS.controlBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color(nsColor: .ds("#C6D2E8", "#3A4560")), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
