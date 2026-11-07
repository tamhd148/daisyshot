import AppKit
import SwiftUI

struct ShortcutsPane: View {
    @State private var search = ""
    @State private var version = 0
    @State private var confirmRestore = false
    @State private var systemGuide = false
    @AppStorage(Prefs.Key.ignoreAfterCapture) var ignoreAfterCapture: Bool

    private func matches(_ a: HotKeyAction) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let hay = [a.title, a.keywords, a.group.rawValue.loc, HotKeys.shared.shortcut(for: a)?.display ?? ""].joined(separator: " ")
        return q.split(separator: " ").allSatisfy { hay.localizedCaseInsensitiveContains($0) }
    }

    private func matches(_ item: EditorShortcuts.Item, _ group: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let hay = [item.title.loc, group.loc, EditorShortcuts.shortcut(item.id)?.display ?? ""].joined(separator: " ")
        return q.split(separator: " ").allSatisfy { hay.localizedCaseInsensitiveContains($0) }
    }

    var body: some View {
        let groups = HotKeyAction.Group.allCases.map { ($0, $0.actions.filter(matches)) }.filter { !$0.1.isEmpty }
        // In-editor shortcuts; a group whose editor declares no items (or none match the search) is hidden.
        let editorGroups = [("Annotate", "arrow.up.right", EditorShortcuts.annotate), ("Video Editor", "film", EditorShortcuts.video)]
            .map { g in (title: g.0, symbol: g.1, all: g.2, shown: g.2.filter { matches($0, g.0) }) }.filter { !$0.shown.isEmpty }
        DSSections {
            searchField
            if groups.isEmpty, editorGroups.isEmpty {
                DSCard {
                    Text("No shortcuts match \"%@\"".loc(search)).font(DS.Font.body).foregroundStyle(DS.inkSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                }
            }
            ForEach(groups, id: \.0) { group, actions in
                GroupHeader(title: group.rawValue, symbol: group == .screenshots ? "viewfinder" : group.symbol, recording: group == .recording)
                DSCard {
                    ForEach(actions) { a in
                        DSRow(a.title, minHeight: DS.Metric.shortcutRowMinHeight) { ShortcutRecorder(slot: .global(a), version: version) }
                    }
                }
            }
            ForEach(editorGroups, id: \.title) { g in
                GroupHeader(title: g.title, symbol: g.symbol)
                DSCard {
                    ForEach(g.shown) { item in
                        DSRow(item.title, minHeight: DS.Metric.shortcutRowMinHeight) {
                            ShortcutRecorder(slot: .editor(item, in: g.all), version: version)
                        }
                    }
                }
                Text("Work while the %@ window is active.".loc(g.title.loc)).font(DS.Font.sub).foregroundStyle(DS.inkSecondary)
                    .padding(.leading, 4).padding(.top, -6)
            }
            if search.isEmpty {
                DSCard {
                    Toggle("Ignore \"After Capture\" actions when using \"Capture Area & …\" shortcuts", isOn: $ignoreAfterCapture)
                    HStack {
                        Button("Restore Defaults…") { confirmRestore = true }
                        Spacer()
                        Button("Use System Default Shortcuts…") { systemGuide = true }
                    }
                    .frame(minHeight: DS.Metric.shortcutRowMinHeight)
                    .padding(.vertical, 6)
                }
                .padding(.top, 8)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HotKeys.didChange)) { _ in version += 1 }
        .confirmationDialog("Restore default shortcuts?", isPresented: $confirmRestore) {
            Button("Restore Defaults", role: .destructive) { HotKeys.shared.restoreDefaults() }
        } message: {
            Text("All shortcuts you recorded will be replaced with Daisyshot's defaults.")
        }
        .sheet(isPresented: $systemGuide) {
            SystemShortcutsGuide(onDone: { systemGuide = false })
                .padding(24)
                .frame(width: 480)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.inkSecondary)
            TextField("Search shortcuts", text: $search).textFieldStyle(.plain).font(DS.Font.body).foregroundStyle(DS.ink)
                .onExitCommand { search = "" }
            if !search.isEmpty { DSClearButton(help: "Clear search") { search = "" } }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(DS.cardBg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(DS.separator))
    }
}

/// Section title with a small tinted icon tile; Screen Recording gets the yellow-centre record mark.
private struct GroupHeader: View {
    let title: String
    let symbol: String
    var recording = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if recording {
                    ZStack {
                        Circle().strokeBorder(DS.ink, lineWidth: 1.3).frame(width: 11, height: 11)
                        Circle().fill(DS.centerDeep).frame(width: 4.5, height: 4.5)
                    }
                } else {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.accentText)
                }
            }
            .frame(width: 24, height: 24)
            .background(recording ? Self.yellowTint : DS.accentTint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title.loc).font(DS.Font.section).foregroundStyle(DS.ink)
        }
        .padding(.top, 14)
        .padding(.bottom, -4)
    }

    private static let yellowTint = Color(nsColor: .ds("#FFF1C9", "#4A3D1A"))
}

// MARK: Recorder

/// One rebindable row: a global hot key (Carbon, may clash with macOS) or an in-editor shortcut (no registration;
/// conflicts only within its own editor, plain keys allowed).
struct ShortcutSlot {
    let title: String
    let defaultShortcut: Shortcut?
    let isGlobal: Bool
    let failed: Bool
    let current: () -> Shortcut?
    let set: (Shortcut?) -> Void
    let reset: () -> Void
    /// Title of the other slot in the same scope that already uses `s`.
    let owner: (Shortcut) -> String?
    /// Takes `s` away from its current owner and binds it here.
    let assign: (Shortcut) -> Void

    @MainActor static func global(_ a: HotKeyAction) -> ShortcutSlot {
        let hk = HotKeys.shared
        return ShortcutSlot(title: a.title, defaultShortcut: a.defaultShortcut, isGlobal: true, failed: hk.failed.contains(a),
                            current: { hk.shortcut(for: a) }, set: { hk.set($0, for: a) }, reset: { hk.resetToDefault(a) },
                            owner: { hk.action(using: $0, except: a)?.title }, assign: { hk.assign($0, to: a) })
    }

    @MainActor static func editor(_ item: EditorShortcuts.Item, in group: [EditorShortcuts.Item]) -> ShortcutSlot {
        func changed() { NotificationCenter.default.post(name: HotKeys.didChange, object: nil) }   // refreshes the rows
        func other(_ s: Shortcut) -> EditorShortcuts.Item? { group.first { $0.id != item.id && EditorShortcuts.shortcut($0.id) == s } }
        return ShortcutSlot(title: item.title.loc, defaultShortcut: item.defaultShortcut, isGlobal: false, failed: false,
                            current: { EditorShortcuts.shortcut(item.id) },
                            set: { EditorShortcuts.set($0, for: item.id); changed() },
                            reset: {
                                if let d = item.defaultShortcut, let o = other(d) { EditorShortcuts.set(nil, for: o.id) }
                                EditorShortcuts.reset(item.id); changed()
                            },
                            owner: { other($0)?.title.loc },
                            assign: { s in
                                if let o = other(s) { EditorShortcuts.set(nil, for: o.id) }
                                EditorShortcuts.set(s, for: item.id); changed()
                            })
    }
}

/// Click to record; type a shortcut; ⎋ cancels, ⌫ clears. Conflicts with other actions or macOS are explained in a popover.
struct ShortcutRecorder: View {
    let slot: ShortcutSlot
    let version: Int
    @State private var recording = false
    @State private var liveModifiers = ""
    @State private var monitor: Any?
    @State private var problem: Problem?

    enum Problem: Identifiable {
        case taken(Shortcut, by: String)
        case reserved(Shortcut)
        var id: String {
            switch self {
            case let .taken(s, a): return "t\(s.display)\(a)"
            case let .reserved(s): return "r\(s.display)"
            }
        }
    }

    var body: some View {
        let current = slot.current()
        HStack(spacing: 8) {
            if slot.failed, !recording {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("This shortcut couldn't be registered. Another app may already be using it.")
            }
            ZStack {   // one stable anchor for the popover across the three states
                if recording {
                    Button(action: stop) {
                        field(Text(liveModifiers.isEmpty ? "Type shortcut…".loc : liveModifiers).font(.system(size: 13)), recording: true)
                    }
                    .buttonStyle(.plain)
                } else if let current {
                    Button(action: start) { field(Text(current.display).font(DS.Font.keycap).tracking(0.8), recording: false) }
                        .buttonStyle(.plain)
                } else {
                    DSGhostButton(title: "Record shortcut", action: start)
                }
            }
            .frame(width: DS.Metric.keycapWidth)
            .help((recording ? "Press ⎋ to cancel, ⌫ to delete the shortcut" : "Record shortcut").loc)
            .popover(item: $problem, arrowEdge: .bottom) { ProblemView(problem: $0, slot: slot, close: { problem = nil }) }

            Group {
                if current != nil, !recording { DSClearButton(help: "Delete shortcut") { slot.set(nil) } } else { Color.clear }
            }
            .frame(width: 18, height: 18)
            Group {
                if let d = slot.defaultShortcut, current != d, !recording {
                    Button { slot.reset() } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.inkSecondary)
                            .frame(width: 18, height: 18)
                            .background(DS.separator, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default (%@)".loc(d.display))
                } else {
                    Color.clear
                }
            }
            .frame(width: 18, height: 18)
        }
        .onDisappear(perform: stop)
    }

    /// 140 pt keycap (white, 1 pt border, 2 pt bottom edge); accent-tinted while recording.
    private func field(_ label: Text, recording: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return label
            .foregroundStyle(DS.accentText)
            .lineLimit(1)
            .frame(width: DS.Metric.keycapWidth)
            .padding(.vertical, 4)
            .background {
                if recording {
                    shape.fill(DS.accentTint).overlay(shape.strokeBorder(DS.accent))
                } else {
                    shape.fill(DS.controlBorder).offset(y: 1)
                    shape.fill(DS.controlBg).overlay(shape.strokeBorder(DS.controlBorder))
                }
            }
            .padding(.bottom, 1)
            .contentShape(Rectangle())
    }

    private func start() {
        recording = true
        liveModifiers = ""
        HotKeys.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown]) { e in
            switch e.type {
            case .leftMouseDown:
                stop()
                return nil   // a click anywhere cancels recording (swallowed so it can't restart the recorder)
            case .flagsChanged:
                liveModifiers = Shortcut.symbols(e.modifierFlags)
                return nil
            default:
                handle(e)
                return nil
            }
        }
    }

    private func handle(_ e: NSEvent) {
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if e.keyCode == 53, mods.isEmpty { stop(); return }                                   // ⎋
        if (e.keyCode == 51 || e.keyCode == 117), mods.isEmpty { slot.set(nil); stop(); return } // ⌫ ⌦
        let isFKey = Shortcut.keyName(UInt32(e.keyCode)).hasPrefix("F") && Shortcut.keyName(UInt32(e.keyCode)).count > 1
        // Global hot keys need a modifier; editor shortcuts may be plain keys (tools: R, A, T…).
        guard !slot.isGlobal || !mods.subtracting(.shift).isEmpty || isFKey else { NSSound.beep(); return }
        let s = Shortcut(keyCode: UInt32(e.keyCode), modifiers: mods.rawValue)
        stop()
        if slot.isGlobal, SystemHotKeys.isReserved(s) {
            problem = .reserved(s)
        } else if let other = slot.owner(s) {
            problem = .taken(s, by: other)
        } else {
            slot.set(s)
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        recording = false
        liveModifiers = ""
        HotKeys.shared.suspended = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct ProblemView: View {
    let problem: ShortcutRecorder.Problem
    let slot: ShortcutSlot
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch problem {
            case let .taken(s, other):
                Label("Another action already uses this shortcut", systemImage: "exclamationmark.triangle.fill").font(.headline).symbolRenderingMode(.multicolor)
                Text("%@ is assigned to \"%@\". Reassign it to \"%@\"?".loc(s.display, other, slot.title))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Use old shortcut", action: close)
                    Button("Reassign") { slot.assign(s); close() }.keyboardShortcut(.defaultAction).buttonStyle(.dsPrimary)
                }
            case let .reserved(s):
                Label("Shortcut is reserved for macOS", systemImage: "apple.logo").font(.headline)
                Text("%@ is used by macOS and cannot be assigned.".loc(s.display)).fixedSize(horizontal: false, vertical: true)
                if SystemHotKeys.isScreenshotShortcut(s) {
                    Text("To use it with Daisyshot, turn off the shortcuts in System Settings › Keyboard › Keyboard Shortcuts… › Screenshots, then record it again.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("You can change or turn off system shortcuts in System Settings › Keyboard › Keyboard Shortcuts….")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Open Keyboard Shortcuts…") { SystemHotKeys.openKeyboardShortcutsSettings(); close() }
                    Button("OK", action: close).keyboardShortcut(.defaultAction).buttonStyle(.dsPrimary)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

// MARK: ⇧⌘3/4/5 like macOS

/// Walks the user through turning off macOS's screenshot shortcuts, then binds ⇧⌘3/4/5 to Fullscreen/Area/All-In-One.
/// Used by Settings › Shortcuts and onboarding.
struct SystemShortcutsGuide: View {
    var onDone: () -> Void
    var showsCancel = true
    @State private var systemOn = SystemHotKeys.screenshotShortcutsEnabled
    @State private var notDisabled = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Use the same shortcuts as macOS?").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(HotKeys.systemScreenshotShortcuts.indices, id: \.self) { i in
                    let item = HotKeys.systemScreenshotShortcuts[i]
                    HStack {
                        KeyCaps(item.shortcut)
                        Image(systemName: "arrow.right").foregroundStyle(DS.inkTertiary)
                        Text(item.action.title)
                    }
                }
            }
            Text("macOS uses these shortcuts for its own screenshot tool. Turn them off first:")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                step(1, "Open System Settings › Keyboard.")
                step(2, "Click **Keyboard Shortcuts…**.")
                step(3, "Choose **Screenshots** from the list on the left.")
                step(4, "Turn off all shortcuts.")
            }
            HStack(spacing: 6) {
                Image(systemName: systemOn ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(systemOn ? Color.orange : DS.leaf)
                Text((systemOn ? "macOS screenshot shortcuts are still on." : "macOS screenshot shortcuts are off.").loc)
                    .font(.callout)
                Spacer()
                Button("Open System Settings") { SystemHotKeys.openKeyboardShortcutsSettings() }
            }
            .animation(.snappy, value: systemOn)
            if notDisabled {
                Text("macOS's own screenshot shortcuts are still on.").font(.callout).foregroundStyle(DS.destructive)
            }
            HStack {
                Spacer()
                if showsCancel { Button("Cancel", action: onDone).keyboardShortcut(.cancelAction) }
                Button("Use ⇧⌘3, ⇧⌘4, ⇧⌘5") {
                    if HotKeys.shared.useSystemScreenshotShortcuts() { onDone() } else { withAnimation { notDisabled = true } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.dsPrimary)
            }
        }
        .onReceive(poll) { _ in
            systemOn = SystemHotKeys.screenshotShortcutsEnabled
            if !systemOn { notDisabled = false }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(DS.accent))
            Text(text)
        }
    }
}

/// A shortcut drawn as individual key caps.
struct KeyCaps: View {
    let parts: [String]
    init(_ s: Shortcut) {
        var p: [String] = []
        if s.flags.contains(.control) { p.append("⌃") }
        if s.flags.contains(.option) { p.append("⌥") }
        if s.flags.contains(.shift) { p.append("⇧") }
        if s.flags.contains(.command) { p.append("⌘") }
        parts = p + [Shortcut.keyName(s.keyCode)]
    }

    var body: some View {
        HStack(spacing: 3) { ForEach(Array(parts.enumerated()), id: \.offset) { DSKeycap($0.element) } }
    }
}
