import AppKit
import AVFoundation
import SwiftUI

// The Record Screen setup's glass source bar and Start card (design/record-setup/RECORD_SETUP_SPEC.md).

/// Colours of the setup overlay's glass surfaces, light and dark (RecSpec "Màu (token)").
struct RecPalette {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    private static func c(_ hex: String, _ a: Double = 1) -> Color { Color(nsColor: NSColor(hex: hex)).opacity(a) }
    private var ink: Color { Self.c("#101A33") }

    var fg: Color { dark ? Self.c("#F2F3F7") : ink }
    var fg2: Color { dark ? Self.c("#AEB9D3") : Self.c("#55617A") }
    var icon: Color { dark ? Self.c("#D5DBE7") : Self.c("#2A3550") }
    var sep: Color { dark ? .white.opacity(0.12) : ink.opacity(0.12) }
    var selBg: Color { dark ? Self.c("#4A86FF", 0.24) : Self.c("#DCE7FF") }
    var selFg: Color { dark ? Self.c("#A9C7FF") : Self.c("#1A3FA8") }
    var onIcon: Color { dark ? Self.c("#7FB0FF") : Self.c("#2B5FE0") }
    var control: Color { dark ? .white.opacity(0.07) : ink.opacity(0.06) }
    var closeBg: Color { dark ? .white.opacity(0.12) : ink.opacity(0.08) }
    var hover: Color { dark ? .white.opacity(0.08) : ink.opacity(0.06) }
    var pressed: Color { dark ? .white.opacity(0.14) : ink.opacity(0.11) }
    var meterTrack: Color { dark ? .white.opacity(0.16) : ink.opacity(0.12) }
    var fill: Color { dark ? Self.c("#1C202C", 0.5) : Self.c("#FAFBFE", 0.52) }
    var solid: Color { dark ? Self.c("#1C202C") : .white }
    var stroke: Color { .white.opacity(dark ? 0.18 : 0.55) }
    var highlight: Color { .white.opacity(dark ? 0.16 : 0.9) }
    var shadow: Color { dark ? .black.opacity(0.45) : ink.opacity(0.28) }
    var shadowNear: Color { dark ? .black.opacity(0.3) : ink.opacity(0.14) }
    static let yellow = c("#FFC633")
    static let record = c("#2B5FE0")
}

/// The overlay's glass: Liquid Glass on macOS 26, else a behind-window blur under a tinted fill; solid when the user
/// asks for more contrast or less transparency. 1 pt border, a bright top edge and a soft shadow.
struct RecGlass: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var opaque

    func body(content: Content) -> some View {
        let p = RecPalette(scheme)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let solid = opaque || contrast == .increased
        content
            .background {
                if solid {
                    shape.fill(p.solid)
                } else if #available(macOS 26, *) {
                    Color.clear.glassEffect(.regular.tint(p.fill), in: shape)
                } else {
                    ZStack {
                        BlurView(material: p.dark ? .hudWindow : .popover)
                        p.fill
                    }
                    .clipShape(shape)
                }
            }
            .overlay(shape.strokeBorder(solid ? p.fg.opacity(0.4) : p.stroke, lineWidth: 1))
            .overlay(alignment: .top) {
                if !solid { p.highlight.frame(height: 1).padding(.horizontal, radius).padding(.top, 1) }
            }
            .shadow(color: p.shadowNear, radius: 1.5, y: 1)
            .shadow(color: p.shadow, radius: 16, y: 12)
    }
}

private struct BlurView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Source-bar tile: transparent, hover / pressed wash, `accentTint` when selected.
private struct TileStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View { TileBody(configuration: configuration, selected: selected) }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hover = false
        @Environment(\.colorScheme) private var scheme
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            let p = RecPalette(scheme)
            configuration.label
                .background(selected ? p.selBg : configuration.isPressed ? p.pressed : hover && enabled ? p.hover : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.38)
                .onHover { hover = $0 }
        }
    }
}

// MARK: - Source bar

/// Top of the screen: Cancel · Screen / Window / Area / Device · Camera / Microphone / System audio · Settings.
struct SourceBar: View {
    @ObservedObject var model: RecordingSetup.Model
    @AppStorage(Prefs.Key.recMicrophone) var mic: Bool
    @AppStorage(Prefs.Key.recMicDeviceID) var micID: String
    @AppStorage(Prefs.Key.recSystemAudio) var systemAudio: Bool
    @AppStorage(Prefs.Key.recSystemAudioApps) var audioApps: String
    @AppStorage(Prefs.Key.recWebcam) var camera: Bool
    @AppStorage(Prefs.Key.recCameraDeviceID) var cameraID: String
    @AppStorage(Prefs.Key.recDeviceAudio) var deviceAudio: Bool
    @Environment(\.colorScheme) private var scheme

    private var onDevice: Bool { model.source == .device }
    private var deviceKind: String { model.deviceIsPad ? "iPad" : "iPhone" }

    var body: some View {
        let p = RecPalette(scheme)
        HStack(spacing: 2) {
            Button { model.owner?.finish(record: false) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(p.icon)
                    .frame(width: 28, height: 28)
                    .background(p.closeBg, in: Circle())
                    .frame(width: 40, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)".loc)
            separator(p)
            source(.display, "Screen", "display", help: "Record the entire screen")
            source(.window, "Window", "macwindow", help: "Record a window (Space switches Window ⇄ Area)")
            source(.area, "Area", "rectangle.dashed", help: "Drag to record an area")
            source(.device, "Device", "ipad.and.iphone", help: "Record an iPhone or iPad connected with a cable")
            separator(p)
            device(camera ? cameraName : "No camera".loc, symbol: camera ? "video" : "video.slash", on: camera,
                   help: camera ? "Camera: %@".loc(cameraName) : "Record camera".loc, action: cameraMenu)
            device(mic ? micName : "No microphone".loc, symbol: mic ? "mic" : "mic.slash", on: mic,
                   help: mic ? "Microphone: %@".loc(micName) : "Record microphone".loc, action: micMenu) {
                if mic { MeterView(level: model.micLevel, track: p.meterTrack).frame(width: 56, height: 3) }
            }
            if onDevice {
                device(deviceAudio ? "%@ audio".loc(deviceKind) : "No device audio".loc, symbol: deviceAudio ? "speaker.wave.2" : "speaker.slash",
                       on: deviceAudio, help: "Record the sound playing on the %@".loc(deviceKind)) { deviceAudio.toggle() }
            } else {
                device(!systemAudio ? "No system audio".loc : chosenApps.isEmpty ? "System audio".loc : chosenAppNames,
                       symbol: systemAudio ? "speaker.wave.2" : "speaker.slash", on: systemAudio,
                       help: !systemAudio ? "Record system audio".loc : chosenApps.isEmpty ? "System audio: all apps".loc : "System audio: %@".loc(chosenAppNames),
                       action: audioMenu)
            }
            separator(p)
            Button { SpeakerNotes.shared.toggle() } label: {
                Image(systemName: "note.text")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(p.icon)
                    .frame(width: 40, height: 52)
            }
            .buttonStyle(TileStyle())
            .help("Speaker notes — a teleprompter only you see".loc)
            Button { model.owner?.openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(p.icon)
                    .frame(width: 40, height: 52)
            }
            .buttonStyle(TileStyle())
            .help("Recording settings".loc)
        }
        .padding(6)
        .modifier(RecGlass(radius: 16))
        .padding(PaddedHostingView<SourceBar>.pad)
        .fixedSize()
        .onChange(of: mic) { model.owner?.devicesChanged() }
        .onChange(of: micID) { model.owner?.devicesChanged() }
        .onChange(of: camera) { model.owner?.devicesChanged() }
        .onChange(of: cameraID) { model.owner?.devicesChanged() }
    }

    private func separator(_ p: RecPalette) -> some View { p.sep.frame(width: 1, height: 32).padding(.horizontal, 4) }

    private func source(_ s: RecordingSetup.Source, _ title: String, _ symbol: String, help: String) -> some View {
        let on = model.source == s
        let p = RecPalette(scheme)
        return Button {
            // The Device tile also opens the device picker.
            if s != .device || model.source != .device { model.owner?.pick(s) }
            if s == .device { model.owner?.deviceMenu() }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                    .foregroundStyle(on ? p.selFg : p.icon)
                Text(title.loc).font(.system(size: 11, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? p.selFg : p.fg2)
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 64, minHeight: 52)
        }
        .buttonStyle(TileStyle(selected: on))
        .help(help.loc)
    }

    private func device(_ title: String, symbol: String, on: Bool, help: String, action: @escaping () -> Void,
                        @ViewBuilder below: () -> some View = { EmptyView() }) -> some View {
        let p = RecPalette(scheme)
        return Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                    .foregroundStyle(on ? p.onIcon : p.icon)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(on ? p.selFg : p.fg2)
                    .frame(maxWidth: 108)
                below()
            }
            .padding(.horizontal, 8)
            .frame(minWidth: 76, maxWidth: 124, minHeight: 52)
        }
        .buttonStyle(TileStyle())
        .help(help)
    }

    private var micName: String { MicLevelMonitor.devices().first { $0.uniqueID == micID }?.localizedName ?? "Default".loc }
    private var cameraName: String { WebcamBubble.devices().first { $0.uniqueID == cameraID }?.localizedName ?? "Default".loc }

    // MARK: Menus

    private var chosenApps: [String] { audioApps.split(separator: "\n").map(String.init) }
    private var chosenAppNames: String {
        chosenApps.map { id in NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? id }.joined(separator: ", ")
    }

    /// System audio: off, every app, or only the ticked apps (running apps with windows, plus chosen ones not running).
    private func audioMenu() {
        let chosen = chosenApps
        var items = [checked(ClosureMenuItem(title: "Do Not Record System Audio", keyEquivalent: "") { systemAudio = false }, !systemAudio),
                     checked(ClosureMenuItem(title: "All Apps", keyEquivalent: "") { audioApps = ""; systemAudio = true }, systemAudio && chosen.isEmpty),
                     .separator(), disabledItem("Only These Apps")]
        let me = Bundle.main.bundleIdentifier
        var apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != me }
            .map { ($0.bundleIdentifier!, $0.localizedName ?? $0.bundleIdentifier!) }
        apps += chosen.filter { id in !apps.contains { $0.0 == id } }.map { ($0, $0) }
        for (id, name) in apps.sorted(by: { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }) {
            items.append(checked(ClosureMenuItem(title: name, keyEquivalent: "") {
                var list = chosenApps
                if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
                audioApps = list.joined(separator: "\n")
                systemAudio = true
            }, systemAudio && chosen.contains(id)))
        }
        popUpMenu(items)
    }

    private func micMenu() {
        var items = [checked(ClosureMenuItem(title: "Do Not Record Microphone", keyEquivalent: "") { mic = false }, !mic)]
        items.append(.separator())
        let devices = MicLevelMonitor.devices()
        for d in devices {
            items.append(checked(ClosureMenuItem(title: d.localizedName, keyEquivalent: "") {
                micID = d.uniqueID
                Task { if await Recorder.access(.audio, usage: "NSMicrophoneUsageDescription", name: "Microphone") { mic = true; model.owner?.devicesChanged() } }
            }, mic && (micID == d.uniqueID || (micID.isEmpty && d == AVCaptureDevice.default(for: .audio)))))
        }
        if devices.isEmpty { items.append(disabledItem("No microphones found")) }
        popUpMenu(items)
    }

    private func cameraMenu() {
        var items = [checked(ClosureMenuItem(title: "Don't Record Camera", keyEquivalent: "") { camera = false }, !camera)]
        items.append(.separator())
        let devices = WebcamBubble.devices()
        for d in devices {
            items.append(checked(ClosureMenuItem(title: d.localizedName, keyEquivalent: "") {
                cameraID = d.uniqueID
                Task { if await Recorder.access(.video, usage: "NSCameraUsageDescription", name: "Camera") { camera = true; model.owner?.devicesChanged() } }
            }, camera && (cameraID == d.uniqueID || (cameraID.isEmpty && d == AVCaptureDevice.default(for: .video)))))
        }
        if devices.isEmpty { items.append(disabledItem("No cameras found")) }
        items.append(.separator())
        let shape = NSMenuItem(title: "Shape".loc, action: nil, keyEquivalent: "")
        shape.submenu = NSMenu()
        for s in CameraShape.allCases {
            shape.submenu?.addItem(checked(ClosureMenuItem(title: s.title, keyEquivalent: "") { Prefs.set(s.rawValue, .recCameraShape); restartCamera() },
                                           Prefs.string(.recCameraShape) == s.rawValue))
        }
        let size = NSMenuItem(title: "Size".loc, action: nil, keyEquivalent: "")
        size.submenu = NSMenu()
        for s in CameraSize.allCases {
            size.submenu?.addItem(checked(ClosureMenuItem(title: s.title, keyEquivalent: "") { Prefs.set(s.rawValue, .recCameraSize); restartCamera() },
                                          Prefs.string(.recCameraSize) == s.rawValue))
        }
        items += [shape, size, checked(ClosureMenuItem(title: "Mirror Camera", keyEquivalent: "") {
            Prefs.set(!Prefs.bool(.recCameraMirror), .recCameraMirror); restartCamera()
        }, Prefs.bool(.recCameraMirror)), checked(ClosureMenuItem(title: "Hide Camera Preview While Recording", keyEquivalent: "") {
            Prefs.set(!Prefs.bool(.recHideCameraPreview), .recHideCameraPreview)
        }, Prefs.bool(.recHideCameraPreview))]
        popUpMenu(items)
    }

    private func restartCamera() {
        let was = camera
        camera = false
        model.owner?.devicesChanged()
        camera = was
        model.owner?.devicesChanged()
    }
}

private struct MeterView: View {
    @ObservedObject var level: LiveValue<Float>
    let track: Color
    var body: some View {
        let l = CGFloat(level.value)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(track)
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: NSColor(hex: l > 0.85 ? "#E5484D" : "#2FA57A")))
                    .frame(width: g.size.width * l)
            }
        }
        .animation(.linear(duration: 0.08), value: l)
    }
}

// MARK: - Start card

/// In the middle of the target: what will be recorded, the output size, and Start Recording.
struct StartCardView: View {
    @ObservedObject var card: RecordingSetup.Card
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = RecPalette(scheme)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if card.kind == .window, let icon = card.icon {
                        Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                    } else {
                        Image(systemName: card.kind == .display ? "display" : card.kind == .device ? "iphone" : "rectangle.dashed")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(p.selFg)
                    }
                }
                .frame(width: 40, height: 40)
                .background(card.kind == .window && card.icon != nil ? .clear : p.selBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.fg).lineLimit(1).truncationMode(.tail)
                    Text(card.sub).font(.system(size: 12)).monospacedDigit().foregroundStyle(p.fg2)
                        .lineLimit(card.canStart ? 1 : 2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let chip = card.chip {
                    Text(chip).font(.system(size: 11, weight: .semibold)).foregroundStyle(p.selFg)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(p.selBg, in: Capsule())
                        .fixedSize()
                }
            }
            Button(action: card.sizeMenu) {
                HStack(spacing: 7) {
                    Image(systemName: "aspectratio").font(.system(size: 13, weight: .medium)).foregroundStyle(p.icon)
                    Text(card.size).font(.system(size: 12.5, weight: .medium)).monospacedDigit().foregroundStyle(p.fg).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.fg2)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(p.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Output size and presets".loc)
            Button(action: card.start) {
                HStack(spacing: 10) {
                    Circle().fill(RecPalette.yellow).frame(width: 12, height: 12)
                        .background(Circle().fill(RecPalette.yellow.opacity(0.3)).padding(-3))
                    Text("Start Recording".loc).font(.system(size: 15, weight: .semibold))
                    Text(verbatim: "↩").font(.system(size: 12, weight: .medium)).opacity(0.7)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(StartStyle())
            .disabled(!card.canStart)
            .opacity(card.canStart ? 1 : 0.5)
            .help("Start recording (Return)".loc)
            Button(action: card.afterMenu) {
                HStack(spacing: 4) {
                    Text("Then:".loc).foregroundStyle(p.fg2)
                    Text(card.after).foregroundStyle(p.fg)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(p.fg2)
                }
                .font(.system(size: 11.5, weight: .medium))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -6)
            .help("What happens when you stop recording".loc)
        }
        .padding(16)
        .frame(width: 340)
        .modifier(RecGlass(radius: 18))
        .padding(PaddedHostingView<StartCardView>.pad)
        .fixedSize()
    }
}

/// accentStrong button; darker on hover and press.
private struct StartStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StartBody(configuration: configuration) }
    private struct StartBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            let fill = Color(nsColor: NSColor(hex: configuration.isPressed ? "#1F46AE" : hover ? "#2552C9" : "#2B5FE0"))
            configuration.label
                .background(fill, in: shape)
                .overlay(alignment: .top) { Color.white.opacity(0.2).frame(height: 1).padding(.horizontal, 12) }
                .shadow(color: Color(nsColor: NSColor(hex: "#2B5FE0")).opacity(0.45), radius: 4, y: 2)
                .contentShape(shape)
                .onHover { hover = $0 }
        }
    }
}
