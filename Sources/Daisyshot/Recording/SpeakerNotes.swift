import AppKit
import SwiftUI

/// Speaker notes / teleprompter: a floating window of your script that's never in the video (all our windows are left
/// out of recordings; `sharingType = .none` keeps it out of screenshots too). It scrolls by itself while recording.
@MainActor
final class SpeakerNotes: NSObject, NSTextViewDelegate, NSWindowDelegate {
    static let shared = SpeakerNotes()

    private var panel: NSPanel?
    private var text: NSTextView!
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var wasRecording = false
    let state = State()

    final class State: ObservableObject {
        @Published var scrolling = false
    }

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? hide() : show() }

    func show() {
        if panel == nil { build() }
        apply()
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    func hide() {
        stop()
        panel?.orderOut(nil)
    }

    /// Start / stop scrolling (opens the notes when they're hidden).
    func toggleScrolling() {
        if !isShown { show() }
        state.scrolling ? stop() : start()
    }

    func start() {
        guard panel != nil, timer == nil else { return }
        state.scrolling = true
        var last = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let now = Date()
                self?.step(now.timeIntervalSince(last))
                last = now
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        state.scrolling = false
    }

    func rewind() {
        text?.enclosingScrollView?.contentView.scroll(to: .zero)
        text?.enclosingScrollView.map { $0.reflectScrolledClipView($0.contentView) }
    }

    /// Speed 1 ≈ 30 pt a second at 28 pt text — scaled with the text so lines pass at the same pace.
    private func step(_ dt: Double) {
        guard let scroll = text.enclosingScrollView else { return }
        let clip = scroll.contentView
        let speed = 30 * Prefs.double(.recNotesSpeed) * Prefs.double(.recNotesFontSize) / 28
        let maxY = max(0, text.frame.height - clip.bounds.height)
        var o = clip.bounds.origin
        o.y = min(maxY, o.y + speed * dt)
        clip.scroll(to: o)
        scroll.reflectScrolledClipView(clip)
        if o.y >= maxY { stop() }
    }

    /// Font size and opacity from the settings strip.
    func apply() {
        guard let panel else { return }
        text.font = .systemFont(ofSize: Prefs.double(.recNotesFontSize), weight: .medium)
        panel.alphaValue = Prefs.double(.recNotesOpacity)
    }

    private func build() {
        let vf = NSScreen.underMouse.visibleFrame
        let p = NSPanel(contentRect: CGRect(x: vf.midX - 320, y: vf.maxY - 300, width: 640, height: 280),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "Speaker Notes".loc
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)   // above the recording setup
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.sharingType = .none
        p.setFrameAutosaveName("DaisyshotSpeakerNotes")
        p.delegate = self

        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.string = Prefs.string(.recNotes)
        tv.delegate = self
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = CGSize(width: 16, height: 14)
        tv.textColor = .white
        tv.insertionPointColor = .white
        tv.backgroundColor = NSColor(white: 0.08, alpha: 1)
        scroll.backgroundColor = tv.backgroundColor
        scroll.drawsBackground = true
        text = tv

        let bar = NSHostingView(rootView: SpeakerNotesBar(state: state))
        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        bar.setContentHuggingPriority(.required, for: .vertical)
        p.contentView = stack
        p.appearance = NSAppearance(named: .darkAqua)
        panel = p

        observer = NotificationCenter.default.addObserver(forName: Recorder.stateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recorderChanged() }
        }
    }

    /// Recording starts → scroll from the top (when switched on); pause → pause; stop → stop.
    private func recorderChanged() {
        let rec = Recorder.shared
        defer { wasRecording = rec.isRecording }
        guard isShown, Prefs.bool(.recNotesScrollWhileRecording) else { return }
        if rec.isRecording, !wasRecording { rewind(); start() }
        else if !rec.isRecording, wasRecording { stop() }
        else if rec.isRecording { rec.isPaused ? stop() : start() }
    }

    func textDidChange(_ notification: Notification) { Prefs.set(text.string, .recNotes) }
    func windowWillClose(_ notification: Notification) { stop() }
}

/// The strip under the notes: play/pause, back to the top, size, speed, opacity.
private struct SpeakerNotesBar: View {
    @ObservedObject var state: SpeakerNotes.State
    @AppStorage(Prefs.Key.recNotesFontSize) var size: Double
    @AppStorage(Prefs.Key.recNotesSpeed) var speed: Double
    @AppStorage(Prefs.Key.recNotesOpacity) var opacity: Double
    @AppStorage(Prefs.Key.recNotesScrollWhileRecording) var auto: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button { SpeakerNotes.shared.toggleScrolling() } label: {
                Image(systemName: state.scrolling ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .help(state.scrolling ? "Pause scrolling".loc : "Scroll the notes".loc)
            Button { SpeakerNotes.shared.rewind() } label: { Image(systemName: "backward.end.fill") }
                .help("Back to the top".loc)
            control("textformat.size", value: $size, in: 14...72, help: "Text size")
            control("gauge.with.dots.needle.33percent", value: $speed, in: 0.2...3, help: "Scroll speed")
            control("circle.lefthalf.filled", value: $opacity, in: 0.3...1, help: "Opacity")
            Spacer(minLength: 0)
            Toggle("Scroll while recording", isOn: $auto).toggleStyle(.checkbox).fixedSize()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .onChange(of: size) { SpeakerNotes.shared.apply() }
        .onChange(of: opacity) { SpeakerNotes.shared.apply() }
    }

    private func control(_ symbol: String, value: Binding<Double>, in range: ClosedRange<Double>, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Slider(value: value, in: range).frame(width: 70)
        }
        .help(help.loc)
    }
}

extension SpeakerNotes {
    /// Long notes scroll down with time and stop at the end; the text survives in the pref.
    static func selfTest() {
        let n = SpeakerNotes.shared, saved = Prefs.string(.recNotes)
        defer { Prefs.set(saved, .recNotes); n.hide() }
        Prefs.set((1...200).map { "Line \($0)" }.joined(separator: "\n"), .recNotes)
        n.show()
        n.rewind()
        n.start()
        n.step(1)
        let y = n.text.enclosingScrollView!.contentView.bounds.minY
        assert(y > 10 && n.state.scrolling, "notes scroll")
        n.step(10_000)
        assert(!n.state.scrolling, "stops at the end")
        assert(n.panel?.sharingType == NSWindow.SharingType.none, "never in screenshots")
    }
}
