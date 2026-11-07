import AppKit
import SwiftUI

/// Capture History window: filter, search by date / app / name, grid grouped by day with hover actions,
/// multi-selection (click, ⌘-click, ⇧-click, ⌘A), Delete / Space / Return / ⌘C on the selection.
struct HistoryView: View {
    @ObservedObject var history: History
    @AppStorage(Prefs.Key.historyCapacity) var capacity: Int
    @State private var filter = Filter.all
    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @State private var anchor: UUID?
    @FocusState private var gridFocused: Bool

    enum Filter: String, CaseIterable, Identifiable {
        case all, screenshots, videos, gifs, projects
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .screenshots: return "Screenshots"
            case .videos: return "Videos"
            case .gifs: return "GIFs"
            case .projects: return "Video Projects"
            }
        }
        func matches(_ k: MediaKind) -> Bool {
            switch self {
            case .all: return true
            case .screenshots: return k == .image
            case .videos: return k == .video
            case .gifs: return k == .gif
            case .projects: return k == .project
            }
        }
    }

    var shown: [History.Entry] {
        history.entries.filter { filter.matches($0.mediaKind) && (query.isEmpty || HistorySearch.matches(query, HistorySearch.text(for: $0))) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Fill the window even when empty, so the header stays pinned to the top on every tab.
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !selection.isEmpty { footer }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onChange(of: filter) { selection.removeAll() }
        .onChange(of: query) { selection.removeAll() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title.loc).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by date, app or name", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 240)
            Menu {
                Picker("Keep History", selection: $capacity) {
                    ForEach(History.capacityOptions, id: \.days) { Text($0.title.loc).tag($0.days) }
                }
                .onChange(of: capacity) { history.prune() }
                Divider()
                Button("Restore Last Capture") { history.restoreLast() }.disabled(history.entries.isEmpty)
                Button("Open History Folder") { NSWorkspace.shared.open(history.folder) }
                Divider()
                Button("Clear History…", role: .destructive) { history.confirmAndDelete(history.entries) }.disabled(history.entries.isEmpty)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("History settings")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        let list = shown
        if list.isEmpty {
            if history.entries.isEmpty {
                ContentUnavailableView(capacity == 0 ? "Capture History is off.".loc : "Nothing to restore".loc,
                                       systemImage: capacity == 0 ? "clock.badge.xmark" : "photo.on.rectangle.angled",
                                       description: Text(capacity == 0 ? "Turn on “Keep history” in the gear menu or in Settings › Advanced.".loc : "Your screenshots and recordings will appear here.".loc))
            } else {
                ContentUnavailableView.search(text: query)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    ForEach(HistorySearch.groupByDay(list), id: \.day) { group in
                        Section {
                            ForEach(group.entries) { e in
                                HistoryCell(entry: e, history: history, selected: selection.contains(e.id),
                                            onSelect: { select(e, in: list) }, actOn: { targets(for: e) })
                            }
                        } header: {
                            Text(HistorySearch.dayTitle(group.day))
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .background(.background)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
            .background(.background)
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onAppear { gridFocused = true }
            .onDeleteCommand { history.confirmAndDelete(selected(in: list)) }
            .onExitCommand { selection.removeAll() }
            .onKeyPress(.space) { quickLook(selected(in: list)); return .handled }
            .onKeyPress(.return) { selected(in: list).forEach(history.open); return .handled }
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                switch press.characters {
                case "a": selection = Set(list.map(\.id)); return .handled
                case "c": HistoryActions.copy(selected(in: list), history); return .handled
                default: return .ignored
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("%d selected".loc(selection.count)).foregroundStyle(.secondary)
            Spacer()
            Button("Deselect") { selection.removeAll() }
            Button("Delete", role: .destructive) { history.confirmAndDelete(selected(in: shown)) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    private func selected(in list: [History.Entry]) -> [History.Entry] { list.filter { selection.contains($0.id) } }

    /// Actions on a cell apply to the whole selection when the cell is part of it, otherwise just to the cell.
    private func targets(for e: History.Entry) -> [History.Entry] {
        selection.contains(e.id) ? selected(in: shown) : [e]
    }

    private func select(_ e: History.Entry, in list: [History.Entry]) {
        gridFocused = true
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(e.id) { selection.remove(e.id) } else { selection.insert(e.id) }
            anchor = e.id
        } else if mods.contains(.shift), let anchor, let a = list.firstIndex(where: { $0.id == anchor }), let b = list.firstIndex(where: { $0.id == e.id }) {
            selection = Set(list[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [e.id]
            anchor = e.id
        }
    }

    private func quickLook(_ list: [History.Entry]) {
        QuickLook.toggle(list.map(history.url), from: History.windowRef)
    }
}

/// Actions shared by the hover buttons and the context menu.
@MainActor
enum HistoryActions {
    static func copy(_ list: [History.Entry], _ history: History) {
        guard !list.isEmpty else { return }
        if list.count == 1, list[0].mediaKind == .image, let s = Exporter.loadShot(history.url(list[0])) {
            Exporter.copy(s, fileURL: history.url(list[0]))
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(list.map { history.url($0) as NSURL })
        }
        Toast.show("Copied")
    }

    static func pin(_ list: [History.Entry], _ history: History) {
        list.filter { $0.mediaKind == .image }.compactMap { Exporter.loadShot(history.url($0)) }.forEach(PinWindow.pin)
    }
}

struct HistoryCell: View {
    let entry: History.Entry
    let history: History
    let selected: Bool
    let onSelect: () -> Void
    let actOn: () -> [History.Entry]
    @State private var thumb: NSImage?
    @State private var badge: String?
    @State private var appIcon: NSImage?
    @State private var hover = false

    var body: some View {
        let url = history.url(entry)
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if entry.mediaKind == .image { Color.primary.opacity(0.05) } else { Color.black.opacity(0.85) }
                if let thumb {
                    Image(nsImage: thumb).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
                if entry.mediaKind.isMotion && !hover {
                    Image(systemName: entry.mediaKind == .project ? "film.stack" : "play.fill")
                        .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 38, height: 38).background(.black.opacity(0.45), in: Circle())
                }
                if let badge, !hover {
                    Text(badge).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.black.opacity(0.6), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(6)
                }
                if hover { hoverControls(url) }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 1))
            HStack(spacing: 5) {
                if let appIcon { Image(nsImage: appIcon).resizable().frame(width: 14, height: 14) }
                Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture(count: 2) { history.open(entry) }
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu { menu(url) }
        .task(id: entry.id) { await load(url) }
    }

    private func load(_ url: URL) async {
        thumb = await MediaInfo.thumbnail(url, maxPixels: 520)
        switch entry.mediaKind {
        case .video: badge = await MediaInfo.videoInfo(url).map { MediaInfo.durationString($0.duration) }
        case .gif: badge = "GIF"
        case .project: badge = "Project".loc
        case .image: badge = nil
        }
        if let id = entry.app { appIcon = HistorySearch.appIcon(id) }
    }

    private func hoverControls(_ url: URL) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            Button("Restore") { history.restore(entry) }
                .buttonStyle(QAPillButtonStyle())
                .help("Restore to Quick Access Overlay")
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    roundButton("doc.on.doc", "Copy") { HistoryActions.copy(actOn(), history) }
                    roundButton(editSymbol, editTitle) { history.open(entry) }
                    if entry.mediaKind == .image { roundButton("pin", "Pin to the Screen") { HistoryActions.pin(actOn(), history) } }
                    roundButton("eye", "Quick Look (Space)") { QuickLook.toggle(actOn().map(history.url), from: History.windowRef) }
                    roundButton("folder", "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(actOn().map(history.url)) }
                    roundButton("trash", "Delete") { history.confirmAndDelete(actOn()) }
                }
                .padding(.bottom, 8)
            }
        }
        .transition(.opacity)
    }

    private var editSymbol: String { entry.mediaKind == .image ? "pencil.tip.crop.circle" : entry.mediaKind == .gif ? "arrow.up.forward.app" : "scissors" }
    private var editTitle: String { entry.mediaKind == .image ? "Annotate" : entry.mediaKind == .gif ? "Open" : "Open Video Editor" }

    private func roundButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .help(help.loc)
    }

    @ViewBuilder private func menu(_ url: URL) -> some View {
        Button("Restore to Quick Access") { history.restore(entry) }
        Button(editTitle.loc) { history.open(entry) }
        Button("Copy") { HistoryActions.copy(actOn(), history) }
        if entry.mediaKind == .image { Button("Pin to the Screen") { HistoryActions.pin(actOn(), history) } }
        Button("Quick Look") { QuickLook.toggle(actOn().map(history.url), from: History.windowRef) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(actOn().map(history.url)) }
        Divider()
        Button("Delete…", role: .destructive) { history.confirmAndDelete(actOn()) }
    }
}

/// Search text and day grouping for history entries (pure — see selfTest).
@MainActor
enum HistorySearch {
    /// Everything a user might type to find an entry: date in several spellings, "today"/"yesterday", app and file name, kind.
    /// The fixed part is cached per entry: the grid re-filters on every keystroke and selection change, and building it
    /// costs 9 date formats plus a Launch Services lookup.
    static func text(for e: History.Entry, now: Date = Date()) -> String {
        var text = stableText[e] ?? {
            var parts = [e.file, e.kind, e.mediaKind == .image ? "screenshot" : e.mediaKind == .project ? "video project" : e.kind]
            parts += formatters.map { $0.string(from: e.date) }
            if let id = e.app {
                parts.append(id)
                if let u = appURL(id) { parts.append(u.deletingPathExtension().lastPathComponent) }
            }
            let t = parts.joined(separator: " ").lowercased()
            stableText[e] = t
            return t
        }()
        let cal = Calendar.current
        if cal.isDate(e.date, inSameDayAs: now) { text += " today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(e.date, inSameDayAs: y) { text += " yesterday" }
        return text
    }

    private static var stableText: [History.Entry: String] = [:]
    private static var appURLs: [String: URL?] = [:]
    private static var appIcons: [String: NSImage?] = [:]

    static func appURL(_ bundleID: String) -> URL? {
        if let hit = appURLs[bundleID] { return hit }
        let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        appURLs[bundleID] = u
        return u
    }

    static func appIcon(_ bundleID: String) -> NSImage? {
        if let hit = appIcons[bundleID] { return hit }
        let icon = appURL(bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        appIcons[bundleID] = icon
        return icon
    }

    private static let formatters: [DateFormatter] = ["EEEE MMMM d yyyy", "MMM d", "d MMM", "yyyy-MM-dd", "M/d/yyyy", "d/M/yyyy", "d.M.yyyy", "HH:mm", "h:mm a"].map {
        let f = DateFormatter()
        f.dateFormat = $0
        return f
    }

    /// Every whitespace-separated word of the query must appear.
    static func matches(_ query: String, _ text: String) -> Bool {
        query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
    }

    static func groupByDay(_ list: [History.Entry]) -> [(day: Date, entries: [History.Entry])] {
        let cal = Calendar.current
        var out: [(day: Date, entries: [History.Entry])] = []
        for e in list {
            let d = cal.startOfDay(for: e.date)
            if out.last?.day == d { out[out.count - 1].entries.append(e) } else { out.append((d, [e])) }
        }
        return out
    }

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today".loc }
        if cal.isDateInYesterday(day) { return "Yesterday".loc }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    static func selfTest() {
        let now = Date()
        let e = History.Entry(file: "Daisyshot 2026-10-08.png", date: now, kind: "image")
        let t = text(for: e, now: now)
        assert(matches("today", t) && matches("SCREENSHOT", t) && matches("", t))
        assert(matches("today png", t) && !matches("yesterday", t) && !matches("gif", t))
        let old = History.Entry(file: "a.mp4", date: now.addingTimeInterval(-86400 * 3), kind: "video")
        let groups = groupByDay([e, e, old])
        assert(groups.count == 2 && groups[0].entries.count == 2)
    }
}
