import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Right after a Studio recording (Settings › Screen Recording › After a Studio recording): a small panel to export the
/// project straight away — MP4, GIF or copy — with the default look (last style, auto zooms) and the last export
/// options, or to open it in the editor.
@MainActor
final class StudioQuickExport: ObservableObject {
    private static var current: StudioQuickExport?

    let project: URL
    let name: String
    @Published var thumbnail: CGImage?
    @Published var duration = 0.0
    @Published var progress: Double?
    @Published var working: StudioExportFormat?
    private var panel: FloatingPanel?
    private var editor: StudioEditor?
    private var sink: AnyCancellable?

    /// `export`: starts that export straight away (the panel shows its progress, then closes).
    static func show(_ project: URL, export: StudioExportFormat? = nil, copy: Bool = false) {
        current?.close()
        let q = StudioQuickExport(project: project)
        current = q
        q.present()
        if let export { q.export(export, copy: copy) }
    }

    private init(project: URL) {
        self.project = project
        name = project.deletingPathExtension().lastPathComponent
    }

    /// After a Quick Export, when "Keep the project" is off: keep it for editing later, or delete it for good.
    private static func askToKeep(_ project: URL) {
        let a = NSAlert()
        a.messageText = "Keep the project?"
        a.informativeText = "Keep it to edit or export again later, or delete it (the exported video stays)."
        a.addButton(withTitle: "Keep Project")
        a.addButton(withTitle: "Delete Project").hasDestructiveAction = true
        a.localize()
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertSecondButtonReturn else { return }
        do { try FileManager.default.removeItem(at: project) } catch { Toast.show(error.localizedDescription, isError: true); return }
        History.shared.forget(fileURL: project)
        if Prefs.string(.studioLastProject) == project.path { Prefs.reset(.studioLastProject) }
    }

    /// What the export buttons will make: size, quality, frame rate and the look new projects get.
    var summary: String {
        let res = StudioResolution(rawValue: Prefs.int(.studioExportResolution)) ?? .original
        let q = StudioQuality(rawValue: Prefs.int(.studioExportQuality)) ?? .high
        let fps = Prefs.int(.studioExportFPS)
        let style = Prefs.string(.studioDefaultPreset)
        return [res.title.loc, q.title.loc, fps > 0 ? "\(fps) fps" : "Original fps".loc, style.isEmpty ? "Last used style".loc : style].joined(separator: " · ")
    }

    func setting(_ change: () -> Void) {
        change()
        objectWillChange.send()
    }

    private func present() {
        let host = NSHostingView(rootView: QuickExportView(model: self))
        let size = host.fittingSize
        let vf = NSScreen.underMouse.visibleFrame
        let p = FloatingPanel(rect: CGRect(x: vf.maxX - size.width - 16, y: vf.minY + 16, width: size.width, height: size.height))
        p.hasShadow = false        // the glass draws its own
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
        Task {
            guard let pkg = try? StudioPackage.open(project) else { return }
            let asset = AVURLAsset(url: pkg.videoURL)
            duration = (try? await asset.load(.duration).seconds) ?? 0
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 200)
            thumbnail = try? await gen.image(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)).image
        }
    }

    func close() {
        editor?.cancelExport()
        editor?.close()
        editor = nil
        panel?.orderOut(nil)
        panel = nil
        if Self.current === self { Self.current = nil }
    }

    func edit() {
        close()
        VideoEditor.open(project)
    }

    /// Exports through an editor that's never shown: the same document, renderer and export as the editor's.
    func export(_ format: StudioExportFormat, copy: Bool = false) {
        guard working == nil else { return }
        working = format
        progress = 0
        Task {
            defer { working = nil; progress = nil }
            do {
                let pkg = try StudioPackage.open(project)
                let src = try await StudioSources.load(pkg)
                let ed = StudioEditor(package: pkg)
                editor = ed
                ed.load(src)
                sink = ed.$exportProgress.sink { [weak self] p in if let p { self?.progress = p } }
                ed.export(.last(format: format, mono: ed.doc.audio.mono, copy: copy))
                while ed.isExporting { try await Task.sleep(for: .milliseconds(100)) }
                sink = nil
                ed.close()
                editor = nil
                let project = self.project
                close()       // the export shows in Quick Access (or failed with a message)
                if !Prefs.bool(.studioQuickExportKeep) { Self.askToKeep(project) }
            } catch {
                Toast.show(error.localizedDescription, isError: true)
            }
        }
    }
}

private struct QuickExportView: View {
    @ObservedObject var model: StudioQuickExport
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = RecPalette(scheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Group {
                    if let t = model.thumbnail { Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill) } else { p.control }
                }
                .frame(width: 88, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording saved").font(.system(size: 13, weight: .semibold)).foregroundStyle(p.fg)
                    Text(model.name).font(.system(size: 11.5)).foregroundStyle(p.fg2).lineLimit(1).truncationMode(.middle)
                    Text(StudioQuickExport.time(model.duration)).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(p.fg2)
                }
                Spacer(minLength: 0)
                Button { model.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(p.icon)
                        .frame(width: 22, height: 22).background(p.closeBg, in: Circle())
                }
                .buttonStyle(.plain).help("Close")
                .disabled(model.working != nil)
            }
            HStack(spacing: 6) {
                Text(model.summary).font(.system(size: 11)).foregroundStyle(p.fg2).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Menu {
                    Picker("Resolution", selection: Binding(get: { Prefs.int(.studioExportResolution) }, set: { v in model.setting { Prefs.set(v, .studioExportResolution) } })) {
                        ForEach(StudioResolution.allCases) { Text($0.title.loc).tag($0.rawValue) }
                    }
                    Picker("Quality", selection: Binding(get: { Prefs.int(.studioExportQuality) }, set: { v in model.setting { Prefs.set(v, .studioExportQuality) } })) {
                        ForEach(StudioQuality.allCases, id: \.rawValue) { Text($0.title.loc).tag($0.rawValue) }
                    }
                    Picker("Frame Rate", selection: Binding(get: { Prefs.int(.studioExportFPS) }, set: { v in model.setting { Prefs.set(v, .studioExportFPS) } })) {
                        Text("Original").tag(0)
                        ForEach(StudioExportOptions.fpsChoices, id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
                    }
                    Picker("Style", selection: Binding(get: { Prefs.string(.studioDefaultPreset) }, set: { v in model.setting { Prefs.set(v, .studioDefaultPreset) } })) {
                        Text("Last Used Style").tag("")
                        ForEach(StudioPresets.all(), id: \.name) { Text($0.name).tag($0.name) }
                    }
                    Divider()
                    Toggle("Keep the Project After Exporting", isOn: Binding(get: { Prefs.bool(.studioQuickExportKeep) }, set: { v in model.setting { Prefs.set(v, .studioQuickExportKeep) } }))
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(p.icon)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Quick Export settings (shared with the editor's export)")
                .disabled(model.working != nil)
            }
            if let progress = model.progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress).tint(Color(nsColor: NSColor(hex: "#4A86FF")))
                    Text("\(Int(progress * 100))%").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(p.fg2).frame(width: 34, alignment: .trailing)
                    Button("Cancel") { model.close() }.controlSize(.small)
                }
                .frame(height: 32)
            } else {
                HStack(spacing: 6) {
                    action("Edit", "slider.horizontal.3", primary: false) { model.edit() }
                    action("MP4", "film", primary: true) { model.export(.mp4) }
                    action("GIF", "photo.stack", primary: false) { model.export(.gif) }
                    action("Copy", "doc.on.doc", primary: false) { model.export(.mp4, copy: true) }
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .modifier(RecGlass(radius: 16))
        .padding(PaddedHostingView<SourceBar>.pad)
        .environment(\.colorScheme, .dark)
    }

    private func action(_ title: String, _ symbol: String, primary: Bool, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title.loc, systemImage: symbol)
                .font(.system(size: 12, weight: primary ? .semibold : .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(primary ? Color(nsColor: NSColor(hex: "#2B5FE0")) : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title == "Edit" ? "Open in the editor".loc : title == "Copy" ? "Export an MP4 and copy it".loc : "Export %@".loc(title))
    }
}

extension StudioQuickExport {
    #if DEBUG
    static func debugExportMP4() { current?.export(.mp4) }
    #endif

    nonisolated static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
