import AppKit
import ServiceManagement
import SwiftUI

extension Prefs.Key {
    /// Most recently used export folders (newest first) for the Export location menu.
    static let recentExportFolders = Prefs.Key("recentExportFolders", [String]())
}

struct GeneralPane: View {
    private typealias K = Prefs.Key
    @State private var loginStatus = SMAppService.mainApp.status
    @AppStorage(K.playSounds) var playSounds: Bool
    @AppStorage(K.shutterSound) var shutter: String
    @AppStorage(K.showMenuBarIcon) var showMenuBarIcon: Bool
    @AppStorage(K.hideIconsWhileCapturing) var hideIcons: Bool
    @AppStorage(K.exportFolder) var exportFolder: String
    @AppStorage(K.afterCaptureQuickAccess) var sQA: Bool
    @AppStorage(K.afterCaptureCopy) var sCopy: Bool
    @AppStorage(K.afterCaptureSave) var sSave: Bool
    @AppStorage(K.afterCaptureAnnotate) var sAnnotate: Bool
    @AppStorage(K.afterCapturePin) var sPin: Bool
    @AppStorage(K.afterRecordingQuickAccess) var vQA: Bool
    @AppStorage(K.afterRecordingCopy) var vCopy: Bool
    @AppStorage(K.afterRecordingSave) var vSave: Bool
    @AppStorage(K.menuBarRecordingIndicator) var recIndicator: String
    @State private var atLeastOneAlert = false
    @AppStorage(K.updateAutoCheck) var autoUpdate: Bool
    @AppStorage(K.updateLastCheck) var lastUpdateCheck: Double

    var body: some View {
        DSSections {
            DSCard {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { AppDelegate.setLaunchAtLogin($0); loginStatus = SMAppService.mainApp.status }))
                if loginStatus == .requiresApproval {
                    HStack {
                        SettingsNote("Allow Daisyshot in System Settings › General › Login Items to finish.")
                        Spacer()
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                DSRow("Language") { LanguagePicker() }
                Toggle("Play sounds", isOn: $playSounds)
                DSRow("Shutter sound") {
                    Picker("Shutter sound", selection: $shutter) {
                        ForEach(Sounds.shutterOptions, id: \.id) { Text($0.title.loc).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!playSounds)
                    .onChange(of: shutter) { Sounds.shutter() }
                }
            }

            DSGroupLabel("Appearance")
            DSCard(padding: EdgeInsets(top: 14, leading: DS.Metric.cardPaddingH, bottom: 0, trailing: DS.Metric.cardPaddingH)) {
                AppIconPicker().padding(.bottom, 14)
                DSToggleRow("Show menu bar icon", icon: Image(nsImage: MenuBarIcon.standard),
                            isOn: Binding(get: { showMenuBarIcon }, set: setMenuBarIcon))
                if !showMenuBarIcon {
                    SettingsNote("The menu bar icon is hidden. To get back to Settings, open Daisyshot again from Finder or Spotlight.")
                }
                DSRow("Recording indicator", minHeight: 52) {
                    DSSegmented(selection: $recIndicator, options: [
                        .init(value: "mono", title: "Monochrome", image: MenuBarIcon.recordingImage("mono")),
                        .init(value: "yellow", title: "Yellow centre", image: MenuBarIcon.recordingImage("yellow")),
                    ])
                }
            }

            DSCard {
                Toggle("Hide desktop icons while capturing", isOn: $hideIcons)
                SettingsNote("You can set a custom wallpaper to hide desktop icons in [Wallpaper settings](daisyshot://open-settings?tab=wallpaper).")
                    .environment(\.openURL, OpenURLAction { _ in SettingsWindow.model.tab = .wallpaper; return .handled })
            }

            DSCard {
                DSRow("Export location") { ExportLocationPicker(path: $exportFolder).labelsHidden().fixedSize() }
                SettingsNote("Default save location for the Quick Access Overlay, After Capture and other Save actions. Files never leave this Mac.")
            }

            DSCard {
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                DSRow("Daisyshot %@".loc(Updater.currentVersion), subtitle: lastUpdateCheck > 0
                      ? "Last checked %@".loc(Date(timeIntervalSince1970: lastUpdateCheck).formatted(date: .abbreviated, time: .shortened)) : nil) {
                    Button("Check Now") { Updater.shared.checkNow() }
                }
                SettingsNote("Once a day Daisyshot asks GitHub whether there's a newer release. Nothing about you or your files is sent. Updates are only installed when you choose to, and only if they carry Daisyshot's signature.")
            }

            DSSectionHeader("After capture", subtitle: "Choose what Daisyshot does with each new screenshot or recording.")
            DSCard(padding: EdgeInsets(top: 10, leading: DS.Metric.cardPaddingH, bottom: 12, trailing: DS.Metric.cardPaddingH)) {
                afterCaptureGrid
            }
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in loginStatus = SMAppService.mainApp.status }
        .alert("Keep at least one action on", isPresented: $atLeastOneAlert) {
            Button("OK") {}
        } message: {
            Text("Turn on at least one action so captures don't go nowhere.")
        }
    }

    // MARK: After capture

    private var afterCaptureGrid: some View {
        let shots = [$sQA, $sCopy, $sSave, $sAnnotate, $sPin]
        let videos = [$vQA, $vCopy, $vSave]       // GIFs (video recordings open in the video editor)
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Text("")
                Text("Screenshot").frame(width: 110)
                Text("GIF").frame(width: 110)
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.inkSecondary)
            .padding(.bottom, 4)
            row("Show Quick Access Overlay", guarded($sQA, shots), guarded($vQA, videos))
            row("Copy file to clipboard", guarded($sCopy, shots), guarded($vCopy, videos))
            row("Save", guarded($sSave, shots), guarded($vSave, videos))
            row("Open Annotate tool", guarded($sAnnotate, shots), nil)
            row("Pin to the Screen", guarded($sPin, shots), nil)
        }
    }

    @ViewBuilder private func row(_ title: String, _ shot: Binding<Bool>?, _ video: Binding<Bool>?) -> some View {
        GridRow {
            Text(title.loc).font(DS.Font.body).foregroundStyle(DS.ink).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            cell(shot)
            cell(video)
        }
    }

    @ViewBuilder private func cell(_ b: Binding<Bool>?) -> some View {
        if let b {
            Toggle("", isOn: b).toggleStyle(.checkbox).labelsHidden().frame(width: 110)
        } else {
            Text("—").foregroundStyle(Color(nsColor: NSColor(hex: "#B4BCCB"))).frame(width: 110)
        }
    }

    /// Refuses to turn off the last enabled action of a column.
    private func guarded(_ b: Binding<Bool>, _ column: [Binding<Bool>]) -> Binding<Bool> {
        Binding(get: { b.wrappedValue }, set: { v in
            if !v, column.filter(\.wrappedValue).count <= 1 { atLeastOneAlert = true; return }
            b.wrappedValue = v
        })
    }

    private func setMenuBarIcon(_ on: Bool) {
        if !on {
            let a = NSAlert()
            a.messageText = "Hide the menu bar icon?"
            a.informativeText = "To get back to Settings, open Daisyshot again from Finder or Spotlight."
            a.addButton(withTitle: "Hide Icon")
            a.addButton(withTitle: "Cancel")
            guard Warnings.run("hideMenuBarIcon", a) == .alertFirstButtonReturn else { return }
        }
        showMenuBarIcon = on
    }
}

/// Folder popup: current folder, recent folders, common folders, then "Choose…".
/// Settings › General › Appearance › App icon: Handles (bundle icon), Crosshair, Viewfinder.
struct AppIconPicker: View {
    @AppStorage(Prefs.Key.appIcon) private var choice: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App icon").font(DS.Font.body).foregroundStyle(DS.ink)
            HStack(spacing: 12) {
                ForEach(AppIcon.allCases, id: \.self) { icon in
                    DSTile(selected: icon.rawValue == choice) { choice = icon.rawValue; AppIcon.apply() } label: {
                        VStack(spacing: 6) {
                            if let img = icon.image { Image(nsImage: img).resizable().interpolation(.high).frame(width: 76, height: 76) }
                            Text(icon.title.loc).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.ink)
                            Text((icon == .handles ? "Default" : "Alternate").loc).font(DS.Font.caption).foregroundStyle(DS.inkSecondary)
                        }
                        .padding(.top, 10).padding(.bottom, 12).padding(.horizontal, 6)
                    }
                }
            }
        }
    }
}

struct ExportLocationPicker: View {
    @Binding var path: String
    private static let choose = "\u{0}choose"

    private var folders: [String] {
        let fm = FileManager.default
        let common = [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory, .picturesDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first?.path }
        var seen = Set<String>()
        return ([path] + (Prefs.d.stringArray(forKey: Prefs.Key.recentExportFolders.rawValue) ?? []) + common)
            .filter { !$0.isEmpty && fm.fileExists(atPath: $0) && seen.insert($0).inserted }
    }

    var body: some View {
        Picker("Export location", selection: Binding(get: { path }, set: { $0 == Self.choose ? pick() : select($0) })) {
            ForEach(folders, id: \.self) { p in
                Label { Text(FileManager.default.displayName(atPath: p)) } icon: { Image(nsImage: Self.icon(p)) }
                    .help((p as NSString).abbreviatingWithTildeInPath)
                    .tag(p)
            }
            Divider()
            Text("Choose…").tag(Self.choose)
        }
        .help((path as NSString).abbreviatingWithTildeInPath)
    }

    private static func icon(_ p: String) -> NSImage {
        let i = NSWorkspace.shared.icon(forFile: p)
        i.size = CGSize(width: 16, height: 16)
        return i
    }

    private func select(_ p: String) {
        path = p
        var recent = Prefs.d.stringArray(forKey: Prefs.Key.recentExportFolders.rawValue) ?? []
        recent.removeAll { $0 == p }
        recent.insert(p, at: 0)
        Prefs.d.set(Array(recent.prefix(5)), forKey: Prefs.Key.recentExportFolders.rawValue)
    }

    private func pick() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose".loc
        p.directoryURL = URL(fileURLWithPath: path)
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { select(u.path) }
    }
}

extension Prefs.Key {
    /// Settings › General › Appearance › App icon (`AppIcon` raw value).
    static let appIcon = Prefs.Key("appIcon", AppIcon.handles.rawValue)
}

/// Runtime app icon (Dock, app switcher, About). Finder keeps the bundle icon, which is Handles; the signed bundle is
/// never modified.
enum AppIcon: String, CaseIterable {
    case handles, crosshair, viewfinder

    var title: String { rawValue.capitalized }
    @MainActor var image: NSImage? { DS.image("AppIcons/\(rawValue).png") }

    @MainActor
    static func apply() {
        let icon = AppIcon(rawValue: Prefs.string(.appIcon)) ?? .handles
        NSApp.applicationIconImage = icon == .handles ? nil : icon.image   // nil restores the bundle icon
    }
}
