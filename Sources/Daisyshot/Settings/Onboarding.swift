import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

extension Prefs.Key {
    /// Set once the welcome guide has been closed; it then only opens from Settings › About.
    static let onboarded = Prefs.Key("onboarded", false)
}

/// First-launch welcome guide: welcome → permissions → shortcuts → workflow → menu bar & Quick Access → done.
@MainActor
enum Onboarding {
    enum Slide: Int, CaseIterable { case welcome, permissions, shortcuts, workflow, menuBar, done }

    private static var window: NSWindow?
    private static let model = OnboardingModel()

    static func show(slide: Slide = .welcome) {
        model.forward = true
        model.slide = slide
        if window == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Welcome to Daisyshot".loc
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(model: model))
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                Prefs.set(true, .onboarded)
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

final class OnboardingModel: ObservableObject {
    @Published var slide = Onboarding.Slide.welcome
    var forward = true

    func go(_ s: Onboarding.Slide) {
        forward = s.rawValue >= slide.rawValue
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) { slide = s }
    }
    func next() { if let s = Onboarding.Slide(rawValue: slide.rawValue + 1) { go(s) } }
    func back() { if let s = Onboarding.Slide(rawValue: slide.rawValue - 1) { go(s) } }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                slide
                    .id(model.slide)
                    .transition(.asymmetric(
                        insertion: .offset(x: model.forward ? 60 : -60).combined(with: .opacity),
                        removal: .offset(x: model.forward ? -60 : 60).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 36)

            Divider()
            HStack {
                PageDots(count: Onboarding.Slide.allCases.count, current: model.slide.rawValue)
                Spacer()
                if model.slide != .welcome && model.slide != .done {
                    Button("Back", action: model.back).controlSize(.large)
                }
                if model.slide == .done {
                    Button("Open Settings") { Onboarding.close(); SettingsWindow.show() }.controlSize(.large)
                }
                primaryButton.controlSize(.large).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
        }
        .frame(width: 640, height: 520)
        .background(VisualEffect(material: .windowBackground).ignoresSafeArea())
    }

    @ViewBuilder private var slide: some View {
        switch model.slide {
        case .welcome: WelcomeSlide()
        case .permissions: PermissionsSlide()
        case .shortcuts: ShortcutsSlide()
        case .workflow: WorkflowSlide()
        case .menuBar: MenuBarSlide()
        case .done: DoneSlide()
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch model.slide {
        case .welcome: Button("Get Started", action: model.next).buttonStyle(.borderedProminent)
        case .done: Button("Finish") { Onboarding.close() }.buttonStyle(.borderedProminent)
        default: Button("Continue", action: model.next).buttonStyle(.borderedProminent)
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i == current ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: i == current ? 18 : 7, height: 7)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
    }
}

/// Title + description block shared by the slides.
private struct SlideHeader: View {
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            Text(title.loc).font(.system(size: 26, weight: .bold)).multilineTextAlignment(.center)
            Text(text.loc).font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Slides

private struct WelcomeSlide: View {
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 190, height: 190).blur(radius: 30)
                    .scaleEffect(appeared ? 1 : 0.6)
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 140, height: 140)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                    .scaleEffect(appeared ? 1 : 0.7)
                    .rotationEffect(.degrees(appeared ? 0 : -8))
            }
            .opacity(appeared ? 1 : 0)
            SlideHeader(title: "Welcome to Daisyshot",
                        text: "A few quick choices to set Daisyshot up\nthe way you work.")
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
            Spacer()
        }
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.7).delay(0.1)) { appeared = true } }
    }
}

private struct PermissionsSlide: View {
    @State private var screen = Permissions.screenRecording
    @State private var ax = Permissions.accessibility
    @State private var mic = Permissions.status(.audio)
    @State private var cam = Permissions.status(.video)
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 22) {
            SlideHeader(title: "Permissions", text: "Daisyshot works entirely on your Mac. Grant the access it needs —\noptional ones can wait until you use the feature.")
            VStack(spacing: 0) {
                row("rectangle.dashed.badge.record", .red, "Screen Recording", "Required to take screenshots and record your screen.",
                    granted: screen, required: true) { Permissions.requestScreenRecording(); Permissions.open(.screenRecording) }
                Divider().padding(.leading, 52)
                row("accessibility", .blue, "Accessibility", "Shows keystrokes in recordings and auto-scrolls during scrolling capture.",
                    granted: ax) { Permissions.requestAccessibility(); Permissions.open(.accessibility) }
                Divider().padding(.leading, 52)
                row("mic.fill", .orange, "Microphone", "Optional. Record your voice with screen recordings.",
                    granted: mic == .authorized, undecided: mic == .notDetermined) { Permissions.request(.audio) }
                Divider().padding(.leading, 52)
                row("video.fill", .green, "Camera", "Optional. Show your webcam while recording.",
                    granted: cam == .authorized, undecided: cam == .notDetermined) { Permissions.request(.video) }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            if !screen {
                HStack(spacing: 4) {
                    Text("Already turned it on? macOS applies it after a restart.").font(.callout).foregroundStyle(.secondary)
                    Button("Relaunch Daisyshot") { Prefs.set(false, .onboarded); Permissions.relaunch() }.buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }
        .onReceive(poll) { _ in
            withAnimation(.snappy) {
                screen = Permissions.screenRecording
                ax = Permissions.accessibility
                mic = Permissions.status(.audio)
                cam = Permissions.status(.video)
            }
        }
    }

    private func row(_ symbol: String, _ color: Color, _ title: String, _ text: String, granted: Bool, required: Bool = false, undecided: Bool = false,
                     grant: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title.loc).font(.system(size: 13, weight: .semibold))
                    if required { Text("Required").font(.caption2.weight(.semibold)).foregroundStyle(.red) }
                }
                Text(text.loc).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button((undecided ? "Allow…" : "Open System Settings").loc, action: grant).controlSize(.small)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

private struct ShortcutsSlide: View {
    @State private var showGuide = false
    @State private var version = 0
    private let shown: [HotKeyAction] = [.allInOne, .captureArea, .captureFullscreen, .recordScreen, .captureText]

    var body: some View {
        VStack(spacing: 20) {
            if showGuide {
                SystemShortcutsGuide(onDone: { withAnimation(.snappy) { showGuide = false; version += 1 } })
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                SlideHeader(title: "Make Daisyshot your screenshot tool?",
                            text: "These shortcuts work anywhere. Change them any time in Settings › Shortcuts.")
                VStack(spacing: 8) {
                    ForEach(shown) { a in
                        HStack {
                            Image(systemName: a.symbol).frame(width: 22).foregroundStyle(.secondary)
                            Text(a.title)
                            Spacer()
                            if let s = HotKeys.shared.shortcut(for: a) { KeyCaps(s) } else { Text("—").foregroundStyle(.tertiary) }
                        }
                    }
                }
                .id(version)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                if HotKeys.shared.usesSystemScreenshotShortcuts {
                    Label("Daisyshot now uses ⇧⌘3, ⇧⌘4 and ⇧⌘5.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    VStack(spacing: 6) {
                        Text("Take over ⇧⌘3, ⇧⌘4 and ⇧⌘5?").font(.headline)
                        Button("Use ⇧⌘3 / ⇧⌘4 / ⇧⌘5…") { withAnimation(.snappy) { showGuide = true } }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct WorkflowSlide: View {
    @State private var login = SMAppService.mainApp.status == .enabled
    @AppStorage(Prefs.Key.hideIconsWhileCapturing) var hideIcons: Bool
    @AppStorage(Prefs.Key.playSounds) var sounds: Bool

    var body: some View {
        VStack(spacing: 22) {
            SlideHeader(title: "Make it yours", text: "Everything here, and every shortcut,\ncan be changed later in Settings.")
            VStack(spacing: 0) {
                toggle("power", .green, "Launch at login", "Start Daisyshot when you log in.",
                       Binding(get: { login }, set: { login = AppDelegate.setLaunchAtLogin($0) }))
                Divider().padding(.leading, 52)
                toggle("eye.slash.fill", .indigo, "Hide desktop icons", "Keeps your desktop clean in every capture.", $hideIcons)
                Divider().padding(.leading, 52)
                toggle("speaker.wave.2.fill", .pink, "Play sounds", "A shutter sound after each capture.", $sounds)
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            Spacer(minLength: 0)
        }
    }

    private func toggle(_ symbol: String, _ color: Color, _ title: String, _ text: String, _ b: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.loc).font(.system(size: 13, weight: .semibold))
                Text(text.loc).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: b).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

private struct MenuBarSlide: View {
    @State private var pulse = false
    @State private var overlayIn = false

    var body: some View {
        VStack(spacing: 22) {
            SlideHeader(title: "Find Daisyshot in the menu bar",
                        text: "Every capture mode lives behind this icon. After each capture, the Quick Access Overlay lets you drag, copy, save, annotate or pin the result.")
            ZStack(alignment: .topTrailing) {
                // Desktop
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [.indigo.opacity(0.55), .teal.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
                // Menu bar strip with our icon
                HStack(spacing: 14) {
                    Spacer()
                    Image(nsImage: MenuBarIcon.standard).renderingMode(.template)
                        .padding(4)
                        .background(Circle().fill(.white.opacity(0.25)).scaleEffect(pulse ? 1.5 : 1).opacity(pulse ? 0 : 1))
                    Image(systemName: "wifi"); Image(systemName: "battery.75"); Text("9:41").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(.black.opacity(0.25))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous))
                // Quick Access card
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.9)).frame(width: 130, height: 78)
                        .overlay(Image(systemName: "photo").font(.title).foregroundStyle(.secondary))
                    HStack(spacing: 6) {
                        chip("Copy"); chip("Save")
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.45)))
                .shadow(radius: 8, y: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(14)
                .offset(x: overlayIn ? 0 : -190)
            }
            .frame(width: 440, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.35)) { overlayIn = true }
        }
    }

    private func chip(_ t: String) -> some View {
        Text(t.loc).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.2)))
    }
}

private struct DoneSlide: View {
    @State private var drawn = false
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(Color.green.gradient).frame(width: 110, height: 110)
                    .scaleEffect(drawn ? 1 : 0.5).opacity(drawn ? 1 : 0)
                CheckShape().trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    .frame(width: 50, height: 40)
            }
            SlideHeader(title: "You're all set — Daisyshot is ready.",
                        text: "Open it from the menu bar icon\nor with your keyboard shortcuts.")
            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { drawn = true }
        }
    }
}

private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}
