import AppKit
import SwiftUI

// MARK: Advanced

struct AdvancedPane: View {
    @AppStorage(Prefs.Key.allowURLSchemes) var allowURLs: Bool
    @State private var resetDone = false

    var body: some View {
        DSSections {
            CaptureAdvancedSections()
            LibraryAdvancedSections()

            DSSectionHeader("API")
            DSCard {
                Toggle("Allow URL scheme API", isOn: $allowURLs)
                SettingsNote("Disable this option to prevent external apps from controlling Daisyshot via the \(code("daisyshot://")) URL scheme API, e.g. \(code("daisyshot://capture-area?action=copy")).")
            }

            DSCard {
                DSRow("Warning dialogs", subtitle: "Show every dialog you turned off with \"Don't show again\".") {
                    Button("Reset All Warning Dialogs") { Warnings.resetAll(); resetDone = true }
                }
                DSRow("Unfinished recordings", subtitle: "Recover a recording that was interrupted (Daisyshot also offers this when it starts).") {
                    Button("Recover from Folder…") { Recorder.recoverFromFolder() }
                }
                DSRow("All settings", subtitle: "Every setting back to how it was the first time. Your captures, recordings, history and presets stay.") {
                    Button("Reset All Settings…") { Self.resetAllSettings() }
                }
            }
        }
        .alert("Warning dialogs are back on.", isPresented: $resetDone) {
            Button("OK") {}
        } message: {
            Text("Every dialog you silenced with “Don't show again” will appear again the next time it applies.")
        }
    }

    private static func resetAllSettings() {
        let a = NSAlert()
        a.messageText = "Reset all settings?"
        a.informativeText = "Daisyshot relaunches with every setting at its default, including shortcuts. Your files stay."
        a.addButton(withTitle: "Reset and Relaunch")
        a.addButton(withTitle: "Cancel")
        a.localize()
        guard a.runModal() == .alertFirstButtonReturn, let id = Bundle.main.bundleIdentifier else { return }
        Prefs.d.removePersistentDomain(forName: id)
        Prefs.set(true, .onboarded)     // permissions are already granted; no second onboarding
        Prefs.d.synchronize()
        Permissions.relaunch()
    }

    /// `DSCode` colours as an inline run: a pill view can't sit inside wrapping text.
    private func code(_ s: String) -> AttributedString {
        var a = AttributedString("\u{2009}\(s)\u{2009}")
        a.font = .system(size: 12, design: .monospaced)
        a.foregroundColor = DS.accentText
        a.backgroundColor = DS.accentTint
        return a
    }
}

// MARK: About

struct AboutPane: View {
    @Environment(\.colorScheme) private var scheme

    private var version: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = i?["CFBundleVersion"] as? String
        return b == nil || b == v ? "Version %@".loc(v) : "Version %@ (%@)".loc(v, b!)
    }

    var body: some View {
        ZStack {
            // At least the visible page height, so the column centres and the footer sits at the bottom.
            Color.clear.containerRelativeFrame(.vertical) { h, _ in h - DS.Metric.contentPaddingTop - DS.Metric.contentPaddingBottom }
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: 220, height: 220)
                    .frame(width: 260, height: 260)
                    .background(ViewfinderCorners())
                if let logo = DS.image(scheme == .dark ? "Logo/logotype-white.svg" : "Logo/logotype-ink.svg") {
                    Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit).frame(width: 230)
                        .padding(.top, 8)
                        .accessibilityLabel("Daisyshot")
                }
                Text(version).font(.system(size: 14)).foregroundStyle(DS.inkSecondary).textSelection(.enabled)
                Text("Screenshots, recordings and annotations for macOS.").font(.system(size: 15)).foregroundStyle(DS.ink)
                    .padding(.top, 10)
                DSChip("Works offline. Nothing about you or your files leaves your Mac.")
                HStack(spacing: 12) {
                    Button("Welcome Guide…") { Onboarding.show() }.buttonStyle(.dsPrimary)
                    Button("Permissions…") { Onboarding.show(slide: .permissions) }
                    Button("Check for Updates…") { Updater.shared.checkNow() }
                    Button("Support Folder") { NSWorkspace.shared.open(Prefs.supportFolder) }
                }
                .padding(.top, 18)
                // Free and open source: donations keep it going.
                Link(destination: URL(string: "https://ko-fi.com/tamhd")!) { Label("Support on Ko-fi", systemImage: "cup.and.saucer") }
                .font(.system(size: 13))
                .padding(.top, 6)
                .help("Daisyshot is free and open source. If it helps you, you can support its development.")
            }
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Text("© 2026 Tam Hoang · Free and open source under the MIT License")
                .font(DS.Font.caption).foregroundStyle(DS.inkSecondary)
        }
    }
}

/// Four faint viewfinder corners framing the About icon.
private struct ViewfinderCorners: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color(nsColor: .ds("#BFD3F7", "#2F4775")), lineWidth: 3)
            .mask {
                ZStack {
                    let corners: [Alignment] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]
                    ForEach(corners.indices, id: \.self) {
                        Rectangle().frame(width: 34, height: 34).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corners[$0])
                    }
                }
            }
    }
}
