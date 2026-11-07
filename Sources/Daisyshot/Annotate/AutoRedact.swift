import AppKit
import SwiftUI

extension Prefs.Key {
    /// Redaction style Auto Redact applies (pixelated text can be recovered, so black out by default).
    static let autoRedactStyle = Prefs.Key("autoRedactStyle", RedactStyle.blackout.rawValue)
    static let autoRedactAfterCapture = Prefs.Key("autoRedactAfterCapture", false)
    /// Warn when an image with unredacted secrets / passwords / cards is copied, dragged or shared.
    static let autoRedactWarnOnCopy = Prefs.Key("autoRedactWarnOnCopy", false)
    /// One pattern per line: a keyword or `/regex/` (see `SensitiveMatcher.customRegex`).
    static let autoRedactCustomPatterns = Prefs.Key("autoRedactCustomPatterns", "")
    static let autoRedactProjectNoteShown = Prefs.Key("autoRedactProjectNoteShown", false)
}

/// Auto Redact outside the editor UI: building redactions from findings, Quick Access, after-capture and the copy warning.
@MainActor
enum AutoRedact {
    nonisolated static var defaultStyle: RedactStyle { RedactStyle(rawValue: Prefs.string(.autoRedactStyle)) ?? .blackout }

    /// Ordinary Redact annotations (editable, one per finding).
    static func annotations(_ found: [SensitiveFinding], style: RedactStyle = defaultStyle,
                            intensity: CGFloat = CGFloat(Prefs.double(.annotateRedactIntensity))) -> [Annotation] {
        found.map { f in
            var a = Annotation(kind: .redact, points: [f.rect.origin, CGPoint(x: f.rect.maxX, y: f.rect.maxY)], color: "#000000", lineWidth: 0, shadow: false, fontSize: 0)
            a.redactStyle = style
            a.intensity = intensity
            return a
        }
    }

    /// Findings not already under a redaction.
    static func uncovered(_ found: [SensitiveFinding], in annotations: [Annotation]) -> [SensitiveFinding] {
        let covered = annotations.filter { $0.kind == .redact }.map(\.rect)
        return found.filter { f in
            let core = f.rect.insetBy(dx: SensitiveScanner.padding, dy: SensitiveScanner.padding)
            return !covered.contains { $0.contains(core) }
        }
    }

    /// Scans with the enabled groups and renders the redacted image. nil when nothing was found.
    static func redact(_ shot: Shot) async -> (shot: Shot, doc: DocState, count: Int)? {
        var doc = DocState(image: shot.image, scale: shot.scale)
        let found = await SensitiveScanner.scan(shot.image, size: doc.imageSize).filter(\.kind.isEnabled)
        guard !found.isEmpty else { return nil }
        doc.annotations = annotations(found)
        let out = AnnotateRenderer.flatten(doc)
        remember(doc, for: out.image)
        return (out, doc, found.count)
    }

    // MARK: Keeping auto redactions editable

    /// Flattened output → the original with its redactions, so opening it in Annotate keeps them editable.
    /// ponytail: last few in memory only; a capture reopened after relaunch opens flattened.
    private static var editable: [(image: CGImage, doc: DocState)] = []

    static func remember(_ doc: DocState, for image: CGImage) {
        editable.append((image, doc))
        if editable.count > 4 { editable.removeFirst() }
    }

    static func editableDoc(for image: CGImage) -> DocState? { editable.last { $0.image === image }?.doc }

    // MARK: After capture (Settings › Screenshots)

    /// The image every after-capture action gets (Quick Access, clipboard, file, History).
    static func afterCapture(_ shot: Shot) async -> Shot {
        await redact(shot)?.shot ?? shot
    }

    // MARK: Copy / drag / share warning

    /// Background scan of a new Quick Access card, for its warning dot. Only while the warning is on.
    static func watch(_ item: QuickAccess.Item) {
        guard Prefs.bool(.autoRedactWarnOnCopy), let shot = item.shot else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))   // after the card's slide-in and thumbnail
            let n = await dangerous(shot.image, scale: shot.scale, existing: []).count
            if item.shot?.image === shot.image { item.secretCount = n }
        }
    }

    private static func dangerous(_ image: CGImage, scale: CGFloat, existing: [Annotation]) async -> [SensitiveFinding] {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let found = await SensitiveScanner.scan(image, size: size).filter { $0.kind.isDangerous && $0.kind.isEnabled }
        return uncovered(found, in: existing)
    }

    /// "This image has 2 API keys and 1 password not redacted." Nil when nothing dangerous.
    static func warning(_ found: [SensitiveFinding]) -> String? {
        let parts = SensitiveKind.allCases.compactMap { k -> String? in
            let n = found.filter { $0.kind == k }.count
            return n > 0 ? k.noun(n) : nil
        }
        guard !parts.isEmpty else { return nil }
        return "This image has %@ not redacted.".loc(parts.joined(separator: " and ".loc))
    }

    /// The editor's image just went out (copy, drag, share): offer a redacted copy. Never blocks the copy itself.
    static func warnAfterCopy(_ e: AnnotateEditor) {
        guard Prefs.bool(.autoRedactWarnOnCopy) else { return }
        let doc = e.doc
        Task {
            let found = await dangerous(doc.image, scale: doc.scale, existing: doc.annotations)
            guard let text = warning(found) else { return }
            ActionBanner.show(text, warning: true, near: e.window, actions: [("Redact & Copy Again", {
                let marks = annotations(found)
                if AnnotateEditor.editors.contains(where: { $0 === e }), e.doc.image === doc.image {
                    e.mutate { $0.annotations += marks }
                    Exporter.copy(e.flattened())
                } else {
                    var d = doc
                    d.annotations += marks
                    Exporter.copy(AnnotateRenderer.flatten(d))
                }
                Toast.show("Redacted copy on the clipboard")
            }), ("Ignore", {})])
        }
    }

    static func warnAfterCopy(_ item: QuickAccess.Item) {
        guard Prefs.bool(.autoRedactWarnOnCopy), let shot = item.shot else { return }
        Task {
            guard let text = warning(await dangerous(shot.image, scale: shot.scale, existing: [])) else { return }
            ActionBanner.show(text, warning: true, actions: [("Redact & Copy Again", {
                Task {
                    guard let out = await redact(shot) else { return }
                    Exporter.copy(out.shot)
                    Toast.show("Redacted copy on the clipboard")
                }
            }), ("Ignore", {})])
        }
    }

    /// Saving a `.daisyshot` that has redactions: once, explain that the original pixels are still in the file.
    static func noteProjectSave(_ doc: DocState) {
        guard !Prefs.bool(.autoRedactProjectNoteShown), doc.annotations.contains(where: { $0.kind == .redact }) else { return }
        Prefs.set(true, .autoRedactProjectNoteShown)
        ActionBanner.show("A .daisyshot file keeps the original image under redactions. Send PNG or JPG to others.", warning: false,
                          near: NSApp.keyWindow, actions: [("OK", {})], seconds: 8)
    }
}

// MARK: - Quick Access

extension QuickAccess {
    /// Context menu "Auto Redact": redacts the enabled groups in place, with Undo.
    func autoRedact(_ item: Item) {
        guard let original = shot(for: item) else { return }
        Task {
            guard let out = await AutoRedact.redact(original) else { return Toast.show("No sensitive info found") }
            let dot = item.secretCount
            transform(item) { _ in out.shot }
            item.secretCount = 0
            ActionBanner.show((out.count == 1 ? "Redacted %d item" : "Redacted %d items").loc(out.count), warning: false, actions: [("Undo", { [weak self] in
                self?.transform(item) { _ in original }
                item.secretCount = dot
            })])
        }
    }
}

/// Orange dot on a Quick Access card whose image has unredacted secrets.
struct SecretDot: View {
    let count: Int
    var body: some View {
        Circle().fill(Color.orange).frame(width: 10, height: 10)
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .help(count == 1 ? "1 unredacted secret — right-click › Auto Redact".loc : "%d unredacted secrets — right-click › Auto Redact".loc(count))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(9)
    }
}

// MARK: - Annotate editor

/// One editor's Auto Redact run: findings shown as dashed boxes on the canvas plus the panel under the Auto button.
/// Its own observable object, so scanning and ticking boxes never re-render the editor's bars.
@MainActor
final class AutoRedactSession: ObservableObject {
    private weak var editor: AnnotateEditor?
    @Published private(set) var scanning = false
    @Published private(set) var findings: [SensitiveFinding] = []
    @Published var picked: [Bool] = [] { didSet { editor?.canvas?.needsDisplay = true } }
    @Published var style = AutoRedact.defaultStyle
    let anchor = AnchorBox()
    private var popover: NSPopover?
    private var autoClose: DispatchWorkItem?

    init(editor: AnnotateEditor) { self.editor = editor }

    var kinds: [SensitiveKind] { SensitiveKind.allCases.filter { k in findings.contains { $0.kind == k } } }
    var pickedCount: Int { picked.filter { $0 }.count }

    /// Auto button / ⇧⌘R. Scans off the main thread; the canvas stays live meanwhile.
    func start() {
        guard !scanning, let editor else { return }
        if editor.tool != .redact { editor.tool = .redact }
        let doc = editor.doc
        scanning = true
        Task {
            let all = await SensitiveScanner.scan(doc.image, size: doc.imageSize)
            scanning = false
            guard let editor = self.editor, editor.doc.image === doc.image else { return }   // closed / rotated meanwhile
            findings = AutoRedact.uncovered(all, in: editor.doc.annotations)
            picked = findings.map(\.kind.isEnabled)
            style = AutoRedact.defaultStyle
            showPanel(in: editor)
        }
    }

    func setGroup(_ k: SensitiveKind, _ on: Bool) {
        picked = zip(findings, picked).map { $0.kind == k ? on : $1 }
    }

    /// All findings as Redact annotations: one undo step.
    func apply() {
        let chosen = zip(findings, picked).filter(\.1).map(\.0)
        close()
        guard let editor else { return }
        let marks = AutoRedact.annotations(chosen, style: style, intensity: editor.intensity)
        editor.mutate { $0.annotations += marks }
    }

    func close() {
        autoClose?.cancel()
        findings = []
        picked = []
        popover?.performClose(nil)
        popover = nil   // its view holds this session
    }

    private func showPanel(in editor: AnnotateEditor) {
        let p = popover ?? {
            let p = NSPopover()
            p.contentViewController = NSHostingController(rootView: AutoRedactPanel(session: self))
            (p.contentViewController as? NSHostingController<AutoRedactPanel>)?.sizingOptions = .preferredContentSize
            p.behavior = .applicationDefined   // stays open while boxes are clicked on the canvas
            p.animates = true
            return p
        }()
        popover = p
        if let v = anchor.view, v.window === editor.window {
            p.show(relativeTo: v.bounds, of: v, preferredEdge: .minY)
        } else if let v = editor.window.contentView {
            p.show(relativeTo: CGRect(x: v.bounds.midX, y: v.bounds.maxY - 52, width: 1, height: 1), of: v, preferredEdge: .minY)
        }
        if findings.isEmpty {
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close() } }
            autoClose = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        }
    }

    // MARK: Canvas

    /// Dashed red boxes (unticked ones faded), in image coordinates.
    func drawPreview(_ ctx: CGContext, zoom: CGFloat) {
        guard !findings.isEmpty else { return }
        ctx.saveGState()
        ctx.setLineWidth(1.5 / zoom)
        ctx.setLineDash(phase: 0, lengths: [5 / zoom, 3 / zoom])
        for (f, on) in zip(findings, picked) {
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(on ? 0.12 : 0).cgColor)
            ctx.fill(f.rect)
            ctx.setStrokeColor(on ? NSColor.systemRed.cgColor : NSColor.systemGray.withAlphaComponent(0.6).cgColor)
            ctx.stroke(f.rect)
        }
        ctx.restoreGState()
    }

    /// A click on a box ticks / unticks just that item.
    func toggle(at p: CGPoint) -> Bool {
        guard let i = findings.indices.last(where: { findings[$0].rect.contains(p) }) else { return false }
        picked[i].toggle()
        return true
    }
}

private let styleChoices: [(RedactStyle, String)] = [(.blackout, "Black Out"), (.secureBlur, "Secure Blur"), (.smoothBlur, "Smooth Blur"), (.pixelate, "Pixelate")]
private let pixelateNote = "Pixelated text can be recovered. Use Black Out or Secure Blur for secrets."

struct AutoRedactPanel: View {
    @ObservedObject var session: AutoRedactSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.findings.isEmpty {
                Label("No sensitive info found", systemImage: "checkmark.shield").font(.system(size: 13, weight: .medium))
            } else {
                Text(session.findings.count == 1 ? "Found 1 sensitive item".loc : "Found %d sensitive items".loc(session.findings.count))
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(session.kinds, id: \.self) { k in
                        let items = zip(session.findings, session.picked).filter { $0.0.kind == k }
                        Toggle(isOn: Binding(get: { items.contains { $0.1 } }, set: { session.setGroup(k, $0) })) {
                            HStack {
                                Text(k.title.loc)
                                Spacer()
                                Text("\(items.count)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                Picker("Style", selection: $session.style) {
                    ForEach(styleChoices, id: \.0) { Text($0.1.loc).tag($0.0) }
                }
                .pickerStyle(.menu)
                if session.style == .pixelate, zip(session.findings, session.picked).contains(where: { $0.0.kind == .secret && $0.1 }) {
                    Text(pixelateNote.loc).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Skip") { session.close() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(session.pickedCount == 1 ? "Redact 1 Item".loc : "Redact %d Items".loc(session.pickedCount)) { session.apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(session.pickedCount == 0)
                }
            }
        }
        .padding(14)
        .frame(width: 270)
    }
}

/// "Auto" next to the redaction style: finds and previews sensitive info.
struct AutoRedactButton: View {
    @ObservedObject var session: AutoRedactSession
    @State private var hover = false

    var body: some View {
        Capsuled {
            Button { session.start() } label: {
                HStack(spacing: 5) {
                    if session.scanning {
                        ProgressView().controlSize(.mini).frame(width: 15)
                    } else {
                        Image(systemName: "wand.and.sparkles").font(.system(size: 13, weight: .semibold))
                    }
                    Text("Auto").font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
        .background(AnchorView(box: session.anchor))
        .help("Auto Redact: find emails, keys, passwords, card numbers…".loc + EditorShortcuts.hint("annotate.autoRedact"))
    }
}

// MARK: - Banner with actions

/// Toast with buttons (Undo, Redact & Copy Again…). Never steals focus; disappears on its own.
@MainActor
enum ActionBanner {
    private static var panel: FloatingPanel?
    private static var work: DispatchWorkItem?

    /// `near`: sits over the bottom of that window (the editor's action bar); otherwise at the bottom of the screen.
    static func show(_ text: String, warning: Bool, near window: NSWindow? = nil, actions: [(String, () -> Void)], seconds: Double = 7) {
        let text = text.loc
        dismiss()
        let view = NSHostingView(rootView: HStack(spacing: 10) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(warning ? .orange : .green)
            Text(text).font(.system(size: 13, weight: .medium)).frame(width: min(360, textWidth(text)), alignment: .leading)
            ForEach(actions.indices, id: \.self) { i in
                Button(actions[i].0.loc) { dismiss(); actions[i].1() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .fixedSize()
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .environment(\.colorScheme, .dark))
        let size = view.fittingSize
        let area = window?.frame ?? NSScreen.underMouse.visibleFrame
        let y = window == nil ? area.minY + 130 : area.minY + 58
        let p = FloatingPanel(rect: CGRect(x: area.midX - size.width / 2, y: y, width: size.width, height: size.height), level: .statusBar)
        p.contentView = view
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p
        let w = DispatchWorkItem { MainActor.assumeIsolated { dismiss() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private static func textWidth(_ s: String) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width) + 2
    }

    static func dismiss() {
        work?.cancel()
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}

// MARK: - Settings (Screenshots pane)

struct AutoRedactSettings: View {
    @AppStorage(Prefs.Key.autoRedactStyle) private var style: String
    @AppStorage(Prefs.Key.autoRedactAfterCapture) private var afterCapture: Bool
    @AppStorage(Prefs.Key.autoRedactWarnOnCopy) private var warn: Bool
    @AppStorage(Prefs.Key.autoRedactCustomPatterns) private var patterns: String
    @State private var draft = ""

    private var list: [String] { patterns.split(whereSeparator: \.isNewline).map(String.init) }

    /// A plain `Group` so the header and card flatten into the Screenshots pane's `DSSections`.
    var body: some View {
        Group {
            DSSectionHeader("Sensitive info (Auto Redact)", trailing: AnyView(DSChip("On-device")))
            DSCard {
                ForEach(SensitiveKind.allCases.filter { $0 != .custom }, id: \.self) { KindToggle(kind: $0) }
                DSRow("Redaction style") {
                    Picker("Redaction style", selection: $style) {
                        ForEach(styleChoices, id: \.0) { s, title in
                            Label { Text(title.loc) } icon: { Image(nsImage: Self.swatch(s)) }.tag(s.rawValue)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                if style == RedactStyle.pixelate.rawValue { SettingsNote(LocalizedStringKey(pixelateNote)) }
                DSToggleRow("Automatically redact after capture",
                            subtitle: "Quick Access, the clipboard and saved files get the redacted image. Redactions stay editable in Annotate.",
                            isOn: $afterCapture)
                DSToggleRow("Warn when copying or sharing an image with unredacted secrets",
                            subtitle: "Scans each capture in the background for API keys, passwords and card numbers.", isOn: $warn)
                DSRow("Custom patterns") {
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(Array(list.enumerated()), id: \.offset) { i, p in
                            HStack {
                                Text(p).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(SensitiveMatcher.customRegex(p) == nil ? DS.destructive : DS.ink)
                                DSClearButton(help: "Remove") { remove(i) }
                            }
                        }
                        HStack(spacing: 8) {
                            TextField("", text: $draft, prompt: Text("Keyword or /regex/")).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit(add)
                            Button("Add", action: add).disabled(SensitiveMatcher.customRegex(draft) == nil)
                        }
                    }
                    .padding(.vertical, list.isEmpty ? 0 : 10)
                }
                SettingsNote("Each line is a keyword (any case) or a /regex/ (add i after the closing slash to ignore case).")
            }
        }
    }

    /// 18×10 preview of a redaction style for the pop-up.
    private static func swatch(_ s: RedactStyle) -> NSImage {
        NSImage(size: CGSize(width: 18, height: 10), flipped: false) { r in
            let shape = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            shape.addClip()
            switch s {
            case .blackout:
                NSColor(hex: "#101A33").setFill()
                r.fill()
            case .secureBlur:
                NSGradient(starting: NSColor(hex: "#8A93A8"), ending: NSColor(hex: "#D5DBE5"))?.draw(in: r, angle: 0)
            case .smoothBlur:
                NSGradient(colors: [NSColor(hex: "#DCE7FF"), NSColor(hex: "#7FB8FF"), NSColor(hex: "#DCE7FF")])?.draw(in: r, angle: 0)
            case .pixelate:
                let tones = ["#55617A", "#B4BCCB", "#8A93A8", "#DDE2EB"].map { NSColor(hex: $0) }
                for col in 0..<6 {
                    for row in 0..<2 {
                        tones[(col + row * 3) % tones.count].setFill()
                        CGRect(x: CGFloat(col) * 3, y: CGFloat(row) * 5, width: 3, height: 5).fill()
                    }
                }
            }
            NSColor(white: 0.5, alpha: 0.35).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            return true
        }
    }

    private func add() {
        guard SensitiveMatcher.customRegex(draft) != nil else { return }
        patterns = (list + [draft.trimmingCharacters(in: .whitespaces)]).joined(separator: "\n")
        draft = ""
    }

    private func remove(_ i: Int) {
        var l = list
        l.remove(at: i)
        patterns = l.joined(separator: "\n")
    }
}

private struct KindToggle: View {
    let kind: SensitiveKind
    @AppStorage private var on: Bool
    init(kind: SensitiveKind) {
        self.kind = kind
        _on = AppStorage(kind.key)
    }
    var body: some View { Toggle(kind.title.loc, isOn: $on) }
}
