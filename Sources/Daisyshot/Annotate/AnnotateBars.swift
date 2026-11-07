import AppKit
import SwiftUI

// MARK: - Shared controls

/// Compact icon button with hover and selected states (toolbar look).
struct IconButton: View {
    let symbol: String
    let help: String
    var selected = false
    var size: CGFloat = 14
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .frame(width: 30, height: 28)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(enabled ? 0.85 : 0.3))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(hover && enabled ? 0.09 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(help)
    }
}

// MARK: - Toolbar look (reference-app style capsules)

/// Active window: white raised capsules on the grey bar, accent-filled selection. Inactive: flat grey, grey selection.
private enum Chrome {
    static let height: CGFloat = 32
    static func fill(_ active: Bool) -> Color { active ? Color(nsColor: .controlColor) : Color.primary.opacity(0.055) }
    static func selected(_ active: Bool) -> Color { active ? Color.accentColor : Color.primary.opacity(0.15) }
    static let hover = Color.primary.opacity(0.07)
}

private extension View {
    /// The capsule background used by every toolbar group.
    func chromeCapsule(_ active: Bool, highlighted: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(highlighted ? Chrome.hover.opacity(active ? 1 : 1.5) : .clear)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Chrome.fill(active)))
            .shadow(color: .black.opacity(active ? 0.14 : 0), radius: 0.6, y: 0.5))
    }
}

/// A tool / mode button.
struct ToolButton: View {
    let symbol: String
    let help: String
    var selected = false
    var text: String? = nil      // a glyph instead of a symbol (the Text tool's "A")
    let action: () -> Void
    @State private var hover = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let active = activeState != .inactive
        Button(action: action) {
            Group {
                if let text { Text(text).font(.system(size: 17, weight: .bold)) } else { Image(systemName: symbol).font(.system(size: 15, weight: .semibold)) }
            }
            .foregroundStyle(selected && active ? Color.white : Color.primary.opacity(0.85))
            .frame(width: 34, height: Chrome.height - 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Chrome.selected(active) : hover ? Chrome.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Capsule wrapper.
struct Capsuled<Content: View>: View {
    var padding: CGFloat = 2
    @ViewBuilder var content: Content
    @Environment(\.controlActiveState) private var activeState
    var body: some View {
        content
            .padding(padding)
            .frame(height: Chrome.height)
            .chromeCapsule(activeState != .inactive)
    }
}

// MARK: - Dropdowns: native menus (instant, system fade) and cached popovers

/// Remembers the NSView a SwiftUI control is drawn in, so AppKit menus / popovers can anchor to it.
final class AnchorBox { weak var view: NSView? }

struct AnchorView: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView { let v = NSView(); box.view = v; return v }
    func updateNSView(_ v: NSView, context: Context) { box.view = v }
}

/// Capsule label + chevron shared by both dropdown kinds.
private struct DropdownLabel<Label: View>: View {
    let open: Bool
    @ViewBuilder var label: Label
    @State private var hover = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        HStack(spacing: 6) {
            label
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(height: Chrome.height)
        .chromeCapsule(activeState != .inactive, highlighted: hover || open)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

enum MenuEntry {
    case item(String, image: NSImage? = nil, on: Bool = false, action: () -> Void)
    case rich(NSAttributedString, image: NSImage? = nil, on: Bool = false, action: () -> Void)
    case submenu(String, [MenuEntry])
    case separator

    @MainActor static func menu(_ entries: [MenuEntry]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        for e in entries {
            switch e {
            case let .item(title, image, on, action):
                let i = ClosureMenuItem(title: title, keyEquivalent: "", action: action)
                i.image = image
                i.state = on ? .on : .off
                m.addItem(i)
            case let .rich(title, image, on, action):
                let i = ClosureMenuItem(title: title.string, keyEquivalent: "", action: action)
                i.attributedTitle = title
                i.image = image
                i.state = on ? .on : .off
                m.addItem(i)
            case let .submenu(title, items):
                let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                i.submenu = menu(items)
                m.addItem(i)
            case .separator:
                m.addItem(.separator())
            }
        }
        return m
    }
}

/// Dropdown that pops a native menu under the capsule — no SwiftUI popover to build, so it opens instantly.
struct MenuDropdown<Label: View>: View {
    let help: String
    @ViewBuilder var label: Label
    let entries: () -> [MenuEntry]
    @State private var box = AnchorBox()
    @State private var open = false

    var body: some View {
        Button { show() } label: { DropdownLabel(open: open) { label } }
            .buttonStyle(.plain)
            .background(AnchorView(box: box))
            .help(help)
    }

    private func show() {
        guard let v = box.view else { return }
        let menu = MenuEntry.menu(entries())
        menu.minimumWidth = v.bounds.width
        open = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -5), in: v)
        open = false
    }
}

/// Dropdown with rich SwiftUI content (the colour palette) in a popover that is created once and reused,
/// so only the first opening pays for building it (and that one is pre-warmed when an editor opens).
struct PopoverDropdown<Label: View, Content: View>: View {
    let id: String
    let help: String
    @ViewBuilder var label: Label
    @ViewBuilder var content: () -> Content
    @State private var box = AnchorBox()

    var body: some View {
        Button { if let v = box.view { PopoverCache.toggle(id, AnyView(content()), from: v) } } label: { DropdownLabel(open: false) { label } }
            .buttonStyle(.plain)
            .background(AnchorView(box: box))
            .help(help)
    }
}

@MainActor
enum PopoverCache {
    private static var cache: [String: (popover: NSPopover, host: NSHostingController<AnyView>)] = [:]

    static func toggle(_ id: String, _ content: AnyView, from view: NSView) {
        let e = entry(id)
        if e.popover.isShown { e.popover.performClose(nil); return }
        e.host.rootView = wrap(content)
        e.popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// Builds and lays out the popover's view ahead of time.
    static func prewarm(_ id: String, _ content: AnyView) {
        let e = entry(id)
        guard !e.popover.isShown else { return }
        e.host.rootView = wrap(content)
        e.host.view.layoutSubtreeIfNeeded()
    }

    private static func wrap(_ content: AnyView) -> AnyView { AnyView(content.padding(10).controlSize(.small)) }

    private static func entry(_ id: String) -> (popover: NSPopover, host: NSHostingController<AnyView>) {
        if let e = cache[id] { return e }
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        host.sizingOptions = .preferredContentSize
        let p = NSPopover()
        p.contentViewController = host
        p.behavior = .transient
        p.animates = true
        cache[id] = (p, host)
        return (p, host)
    }
}

/// Menu rows for sizes: a live "Aa" preview at (a capped version of) the size, then "N pt".
@MainActor
enum SizeMenu {
    /// The classic typographic scale (Bringhurst, "The Elements of Typographic Style": 6 7 8 9 10 11 12 14 16 18 21 24 36 48 60 72)
    /// from 10 up, continued past 72 with the same ×4/3 · ×3/2 rhythm.
    static let textSizes: [CGFloat] = [10, 12, 14, 16, 18, 21, 24, 36, 48, 60, 72, 96, 144, 192, 288]
    static let lineWidths: [CGFloat] = [1, 2, 3, 4, 5, 7, 10, 14, 20, 28, 40]

    static func textEntries(_ current: CGFloat, _ set: @escaping (CGFloat) -> Void) -> [MenuEntry] {
        withCurrent(textSizes, current).map { v in .rich(title(preview: "Aa", font: min(34, 10 + 5.2 * log2(v / 10)), value: v, current: abs(v - current) < 0.5)) { set(v) } }
    }

    static func lineEntries(_ current: CGFloat, _ set: @escaping (CGFloat) -> Void) -> [MenuEntry] {
        withCurrent(lineWidths, current).map { v in .rich(title(preview: nil, font: 13, value: v, current: abs(v - current) < 0.5), image: line(v, current: abs(v - current) < 0.5)) { set(v) } }
    }

    /// A size set with +/− (or an older default) that isn't on the scale still shows up, marked as current.
    private static func withCurrent(_ scale: [CGFloat], _ current: CGFloat) -> [CGFloat] {
        let c = current.rounded()
        return scale.contains { abs($0 - c) < 0.5 } ? scale : (scale + [c]).sorted()
    }

    private static func title(preview: String?, font: CGFloat, value: CGFloat, current: Bool) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.tabStops = [NSTextTab(textAlignment: .left, location: preview == nil ? 0 : 62)]
        ps.minimumLineHeight = max(24, font * 1.35)
        let out = NSMutableAttributedString()
        if let preview {
            out.append(NSAttributedString(string: preview + "\t", attributes: [
                .font: NSFont.systemFont(ofSize: font), .paragraphStyle: ps,
                .foregroundColor: current ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ]))
        }
        out.append(NSAttributedString(string: "%d pt".loc(Int(value)), attributes: [
            .font: NSFont.systemFont(ofSize: 14), .paragraphStyle: ps, .foregroundColor: NSColor.labelColor,
        ]))
        return out
    }

    /// A stroke of the given thickness (capped) as the row's preview.
    private static func line(_ w: CGFloat, current: Bool) -> NSImage {
        let img = NSImage(size: CGSize(width: 44, height: 18), flipped: false) { r in
            (current ? NSColor.labelColor : NSColor.tertiaryLabelColor).setStroke()
            let p = NSBezierPath()
            p.lineWidth = min(w, 14)
            p.lineCapStyle = .round
            p.move(to: CGPoint(x: 4 + p.lineWidth / 2, y: r.midY))
            p.line(to: CGPoint(x: r.maxX - 4 - p.lineWidth / 2, y: r.midY))
            p.stroke()
            return true
        }
        return img
    }
}

/// Inline slider in the toolbar row (intensity, dim).
private struct InlineSlider: View {
    let help: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var body: some View {
        Slider(value: $value, in: range)
            .controlSize(.small)
            .frame(width: 180)
            .help(help)
    }
}

// MARK: - Top toolbar (in the title bar): modes · tools · options, one row

struct AnnotateToolbar: View {
    @ObservedObject var editor: AnnotateEditor
    @ObservedObject private var history = History.shared // refreshes the recent-captures menu

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: max(0, editor.titleBarLeading - 8)) // traffic lights
            modes
            tools
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) { AnnotateOptions(editor: editor) }
            }
            .scrollDisabled(true)
            Spacer(minLength: 0)
        }
        .padding(.trailing, 10)
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .ignoresSafeArea()
    }

    private var modes: some View {
        HStack(spacing: 6) {
            Capsuled {
                ToolButton(symbol: "crop", help: "Crop & Resize".loc + EditorShortcuts.hint(AnnotateTool.crop.shortcutID), selected: editor.tool == .crop) {
                    editor.tool = editor.tool == .crop ? .move : .crop
                }
            }
            Capsuled {
                Menu {
                    Button("Add New Screenshot") { editor.addNewScreenshot() }.keyboardShortcut(EditorShortcuts.swiftUI("annotate.addNewScreenshot"))
                    Button("From Clipboard") { editor.addFromClipboard() }
                    Button("From File…") { editor.addFromFile() }.keyboardShortcut(EditorShortcuts.swiftUI("annotate.addFromFile"))
                    let recent = AnnotateEditor.recentCaptures()
                    if !recent.isEmpty {
                        Divider()
                        Section("Recent Captures") {
                            ForEach(recent, id: \.url) { r in Button(r.title) { editor.add(r.url) } }
                        }
                    }
                } label: {
                    Image(systemName: "photo.badge.plus").font(.system(size: 15, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 34, height: Chrome.height - 4)
                .help("Add screenshot — or drop images on the canvas")
            }
            Capsuled {
                ToolButton(symbol: "photo.artframe", help: "Background".loc + EditorShortcuts.hint("annotate.background"), selected: editor.showBackground) {
                    editor.toggleBackground()
                }
            }
        }
    }

    private var tools: some View {
        Capsuled {
            HStack(spacing: 0) {
                ForEach(Array(AnnotateTool.toolbar.enumerated()), id: \.element) { i, t in
                    if i > 0 { Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1, height: 14) }
                    ToolButton(symbol: t.symbol, help: t.title.loc + EditorShortcuts.hint(t.shortcutID), selected: editor.tool == t, text: t == .text ? "A" : nil) { editor.tool = t }
                }
            }
        }
    }
}

// MARK: - Options of the selected tool / object (same row, dropdowns)

struct AnnotateOptions: View {
    @ObservedObject var editor: AnnotateEditor

    /// Options follow the selection when there is one, otherwise the tool.
    private var context: AnnotateTool? {
        if editor.tool == .crop { return .crop }
        if let k = editor.selected?.kind { return AnnotateTool.forKind(k) }
        return editor.tool
    }

    var body: some View {
        if editor.selected?.kind == .image {
            imageOptions
        } else {
            switch context {
            case .crop: cropOptions
            case .move?, nil: EmptyView()
            case let t?: annotationOptions(t)
            }
        }
    }

    @ViewBuilder private func annotationOptions(_ t: AnnotateTool) -> some View {
        if t != .redact && t != .spotlight { ColorButtonCapsule(hex: editor.option(\.color, \.color)) }
        switch t {
        case .arrow:
            let style = editor.option(\.arrowStyle, \.arrowStyle)
            let items: [(ArrowStyle, String, String)] = [(.standard, "arrow.up.right", "Standard"), (.fancy, "location.north.fill", "Fancy"),
                                                         (.curved, "arrow.turn.up.right", "Curved"), (.double, "arrow.up.left.and.arrow.down.right", "Double")]
            MenuDropdown(help: "Arrow style — ⌥ while drawing inverts direction".loc) {
                Image(systemName: items.first { $0.0 == style.wrappedValue }?.1 ?? "arrow.up.right").font(.system(size: 13, weight: .medium))
            } entries: { Self.choices(style, items) }
        case .text:
            let style = editor.option(\.textStyle, \.textStyle)
            let hex = editor.option(\.color, \.color).wrappedValue
            MenuDropdown(help: "Text style — %@".loc(Self.textStyleTitle(style.wrappedValue))) {
                Image(nsImage: TextStylePreview.image(style.wrappedValue, text: "Aa", color: hex, size: 13))
            } entries: {
                // Each style named in its own look, drawn by the canvas renderer.
                TextStyle.allCases.map { v in
                    .item("", image: TextStylePreview.image(v, text: Self.textStyleTitle(v), color: hex, size: 15, backdrop: true), on: v == style.wrappedValue) { style.wrappedValue = v }
                }
            }
        case .redact:
            let style = editor.option(\.redactStyle, \.redactStyle)
            let items: [(RedactStyle, String, String)] = [(.pixelate, "checkerboard.rectangle", "Pixelate"), (.secureBlur, "lock.rectangle", "Secure Blur"),
                                                          (.smoothBlur, "drop.fill", "Smooth Blur"), (.blackout, "rectangle.fill", "Black Out")]
            MenuDropdown(help: "Redaction style".loc) {
                Image(systemName: items.first { $0.0 == style.wrappedValue }?.1 ?? "checkerboard.rectangle").font(.system(size: 13, weight: .medium))
            } entries: { Self.choices(style, items) }
            if style.wrappedValue != .blackout {
                InlineSlider(help: "Intensity".loc, value: editor.option(\.intensity, \.intensity), range: 0.05 ... 1)
            }
            AutoRedactButton(session: editor.autoRedact)
        case .spotlight:
            let shape = editor.option(\.spotShape, \.spotShape)
            let items: [(SpotShape, String, String)] = [(.rectangle, "rectangle", "Rectangle"), (.roundedRectangle, "app", "Rounded Rectangle"), (.ellipse, "circle", "Ellipse")]
            MenuDropdown(help: "Spotlight shape".loc) {
                Image(systemName: items.first { $0.0 == shape.wrappedValue }?.1 ?? "rectangle").font(.system(size: 13, weight: .medium))
            } entries: { Self.choices(shape, items) }
            InlineSlider(help: "Dim".loc, value: editor.spotlightOpacity, range: 0.1 ... 0.95)
        case .counter:
            let style = editor.option(\.counterStyle, \.counterStyle)
            let items: [(CounterStyle, String, String)] = [(.numeric, "textformat.123", "1, 2, 3"), (.roman, "character.book.closed", "I, II, III"),
                                                           (.alphaUpper, "textformat.abc.dottedunderline", "A, B, C"), (.alphaLower, "textformat.abc", "a, b, c")]
            MenuDropdown(help: "Numbering — starting number %d".loc(editor.counterStart)) {
                Text(Self.counterLabel(style.wrappedValue, editor.counterStart)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            } entries: {
                let start = editor.counterStart
                let numbers = Array(Set(Array(0 ... 20) + [start])).sorted()
                return Self.choices(style, items) + [.separator, .submenu("Starting Number: %d".loc(start), numbers.map { n in
                    .item("\(n)", on: n == start) { editor.setCounterStart(n) }
                })]
            }
        default: EmptyView()
        }
        if [.rectangle, .ellipse, .line, .arrow, .pencil, .highlighter].contains(t) {
            let w = editor.option(\.lineWidth, \.lineWidth)
            MenuDropdown(help: "Thickness (+ / −)".loc) { Text("%d pt".loc(Int(w.wrappedValue.rounded()))).monospacedDigit() } entries: {
                SizeMenu.lineEntries(w.wrappedValue) { w.wrappedValue = $0 }
            }
        }
        if t == .text || t == .counter {
            let f = editor.option(\.fontSize, \.fontSize)
            MenuDropdown(help: "Size (+ / −)".loc) { Text("%d pt".loc(Int(f.wrappedValue.rounded()))).monospacedDigit() } entries: {
                SizeMenu.textEntries(f.wrappedValue) { f.wrappedValue = $0 }
            }
        }
        if t == .text {
            Capsuled { ToolButton(symbol: "face.smiling", help: "Emoji & Symbols".loc) { editor.showEmoji() } }
        }
        if t != .redact && t != .spotlight && t != .highlighter {
            let sh = editor.option(\.shadow, \.shadow)
            Capsuled { ToolButton(symbol: "square.filled.on.square", help: (sh.wrappedValue ? "Shadow on" : "Shadow off").loc, selected: sh.wrappedValue) { sh.wrappedValue.toggle() } }
        }
    }

    /// Menu entries for an enum option: symbol + title, current one checked.
    static func choices<T: Equatable>(_ b: Binding<T>, _ items: [(T, String, String)]) -> [MenuEntry] {
        items.map { v, sym, title in .item(title, image: symbol(sym), on: v == b.wrappedValue) { b.wrappedValue = v } }
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    }

    static func textStyleTitle(_ s: TextStyle) -> String {
        switch s {
        case .standard: return "Standard".loc
        case .rounded: return "Rounded".loc
        case .monospaced: return "Monospaced".loc
        case .outline: return "Outline".loc
        case .boxed: return "Box".loc
        case .monospacedBoxed: return "Monospaced Box".loc
        case .boxedRounded: return "Rounded Box".loc
        }
    }

    static func counterLabel(_ s: CounterStyle, _ n: Int) -> String {
        switch s {
        case .numeric: return "\(n)"
        case .roman: return "I"
        case .alphaUpper: return "A"
        case .alphaLower: return "a"
        }
    }

    @ViewBuilder private var imageOptions: some View {
        let sh = editor.option(\.shadow, \.shadow)
        Capsuled { ToolButton(symbol: "square.filled.on.square", help: (sh.wrappedValue ? "Shadow on" : "Shadow off").loc, selected: sh.wrappedValue) { sh.wrappedValue.toggle() } }
        MenuDropdown(help: "Arrange".loc) { Image(systemName: "square.3.layers.3d").font(.system(size: 13, weight: .medium)) } entries: {
            [.item("Bring to Front", image: Self.symbol("square.3.layers.3d.top.filled")) { editor.bringToFront() },
             .item("Send to Back", image: Self.symbol("square.3.layers.3d.bottom.filled")) { editor.sendToBack() }]
        }
    }

    // MARK: Crop

    @ViewBuilder private var cropOptions: some View {
        MenuDropdown(help: "Aspect ratio".loc) { Text(editor.cropChoice.title.loc) } entries: {
            let current = editor.cropChoice
            let fixed: [MenuEntry] = [CropChoice.freeform, .original, .custom].map { c in .item(c.title, on: c == current) { editor.cropChoice = c } }
            return fixed + [.separator] + CropChoice.presets.indices.map { i in
                let c = CropChoice.preset(i)
                return .item(c.title, on: c == current) { editor.cropChoice = c }
            }
        }
        if editor.cropChoice == .custom {
            Capsuled(padding: 4) {
                HStack(spacing: 4) {
                    ratioField(\.width)
                    Button { editor.swapCustomRatio() } label: { Image(systemName: "arrow.left.arrow.right") }.buttonStyle(.plain).help("Swap")
                    ratioField(\.height)
                }
            }
        }
        MenuDropdown(help: "Rotate, flip, resize".loc) { Image(systemName: "rotate.right").font(.system(size: 13, weight: .medium)) } entries: {
            [.item("Rotate Right", image: Self.symbol("rotate.right")) { editor.orient(.rotateRight) },
             .item("Flip Horizontally", image: Self.symbol("arrow.left.and.right.righttriangle.left.righttriangle.right")) { editor.orient(.flipH) },
             .item("Flip Vertically", image: Self.symbol("arrow.up.and.down.righttriangle.up.righttriangle.down")) { editor.orient(.flipV) },
             .separator,
             .item("Resize…", image: Self.symbol("arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")) { editor.resizeImage() },
             .item("Revert to Original", image: Self.symbol("arrow.uturn.backward")) { editor.revertToOriginal() }]
        }
        .help((Prefs.bool(.annotateSnapCrop) ? "Hold ⌘ while dragging to disable snapping" : "Hold ⌘ while dragging to enable snapping").loc)
        Button("Cancel") { editor.cancelCrop() }.keyboardShortcut(.cancelAction).controlSize(.regular)
        Button("Apply") { editor.applyCrop() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).controlSize(.regular)
    }

    private func ratioField(_ kp: WritableKeyPath<CGSize, CGFloat>) -> some View {
        TextField("", value: Binding(get: { Double(editor.customCropRatio[keyPath: kp]) }, set: { editor.customCropRatio[keyPath: kp] = CGFloat(max(0.01, $0)) }),
                  format: .number.precision(.fractionLength(0 ... 2)))
            .frame(width: 40)
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
    }
}

/// Colour swatch dropdown in the grey capsule style.
private struct ColorButtonCapsule: View {
    let hex: Binding<String>
    var body: some View {
        PopoverDropdown(id: "color", help: "Color".loc) { ColorSwatch(hex: hex.wrappedValue, size: 18) } content: { ColorPalettePanel(hex: hex) }
    }
}

// MARK: - Bottom action bar

struct AnnotateActionBar: View {
    @ObservedObject var editor: AnnotateEditor

    var body: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)".loc) { editor.undo() }.disabled(!editor.canUndo)
            IconButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)".loc) { editor.redo() }.disabled(!editor.canRedo)
            zoomMenu
            if Prefs.bool(.annotateExpandCanvas) {
                IconButton(symbol: editor.canvasLocked ? "lock.fill" : "lock.open", help: (editor.canvasLocked ? "Canvas locked: annotations don't expand it" : "Lock canvas size").loc) {
                    editor.canvasLocked.toggle()
                }
            }
            Spacer()
            IconButton(symbol: "text.viewfinder", help: "Copy text (OCR)".loc) { editor.recognizeText() }
            IconButton(symbol: "pin", help: editor.optionDown ? "Pin and exit".loc : "Pin to the screen%@ — ⌥ and exit".loc(EditorShortcuts.hint("annotate.pin"))) { editor.pin() }
            AnchoredButton(symbol: "square.and.arrow.up", help: "Share".loc) { editor.share(from: $0) }
                .frame(width: 30, height: 28)
            DragOutButton { editor.writeTempFile() }
                .frame(width: 30, height: 28)
                .help("Drag me into another app")
            IconButton(symbol: "doc.on.doc", help: editor.optionDown ? "Copy and exit".loc : "Copy to clipboard%@ — ⌥ and exit".loc(EditorShortcuts.hint("annotate.copyScreenshot"))) { editor.copyScreenshot() }
            Button((editor.optionDown ? "Save As & Exit…" : "Done").loc) { editor.done() }
                .buttonStyle(.borderedProminent)
                .help(editor.optionDown ? "Pick a folder, save and close".loc
                      : "Save and close%@".loc(EditorShortcuts.hint("annotate.done"))
                        + (EditorShortcuts.shortcut("annotate.save").map { " — %@ save".loc($0.display) } ?? "")
                        + (EditorShortcuts.shortcut("annotate.saveAs").map { ", %@ save as".loc($0.display) } ?? ""))
                .padding(.leading, 6)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .ignoresSafeArea()
    }

    private var zoomMenu: some View { ZoomMenu(editor: editor, state: editor.zoomState) }
}

final class ZoomState: ObservableObject {
    @Published var value: CGFloat = 1
}

private struct ZoomMenu: View {
    let editor: AnnotateEditor
    @ObservedObject var state: ZoomState

    var body: some View {
        Menu {
            Button("Zoom In") { editor.setZoom(editor.zoom * 1.25) }.keyboardShortcut("+")
            Button("Zoom Out") { editor.setZoom(editor.zoom / 1.25) }.keyboardShortcut("-")
            Divider()
            Button("Fit Canvas") { editor.zoomToFit(animated: true) }.keyboardShortcut("0")
            Button("Actual Size") { editor.setZoom(1) }.keyboardShortcut("1")
            Divider()
            ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { z in Button("%d%%".loc(Int(z * 100))) { editor.setZoom(z) } }
        } label: {
            Text("%d%%".loc(Int((state.value * 100).rounded()))).monospacedDigit().frame(minWidth: 40)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Zoom (⌘-scroll or pinch)")
    }
}

/// 3×3 placement grid for the background tool.
struct AlignmentGrid: View {
    @Binding var selection: Int

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0 ..< 3, id: \.self) { row in
                GridRow {
                    ForEach(0 ..< 3, id: \.self) { col in
                        let i = row * 3 + col
                        RoundedRectangle(cornerRadius: 3)
                            .fill(selection == i ? Color.accentColor : Color.primary.opacity(0.15))
                            .frame(width: 14, height: 11)
                            .contentShape(Rectangle())
                            .onTapGesture { selection = i }
                    }
                }
            }
        }
        .help("Alignment")
    }
}

// MARK: - AppKit bits used by the bars

/// Empty area that drags the window (the toolbar lives in the transparent title bar).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A toolbar button that hands its NSView to the action (for popovers like the share picker).
struct AnchoredButton: NSViewRepresentable {
    let symbol: String
    let help: String
    let action: (NSView) -> Void

    final class Button: NSButton {
        var handler: ((NSView) -> Void)?
        @objc func fire() { handler?(self) }
    }

    func makeNSView(context: Context) -> Button {
        let b = Button()
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        b.contentTintColor = .labelColor
        b.toolTip = help
        b.target = b
        b.action = #selector(Button.fire)
        return b
    }

    func updateNSView(_ b: Button, context: Context) { b.handler = action }
}

/// Drag handle: drag the flattened image file into other apps.
struct DragOutButton: NSViewRepresentable {
    let makeFile: () -> URL?

    final class DragView: NSView, NSDraggingSource {
        var makeFile: () -> URL? = { nil }
        private var started = false

        override var mouseDownCanMoveWindow: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            guard let img = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Drag")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)
                    .applying(.init(paletteColors: [.labelColor]))) else { return }
            let s = img.size
            img.draw(in: CGRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { started = false }

        override func mouseDragged(with event: NSEvent) {
            guard !started, let url = makeFile() else { return }
            started = true
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let img = NSImage(contentsOf: url) ?? NSImage()
            let k = min(1, 160 / max(img.size.width, img.size.height, 1))
            let size = CGSize(width: img.size.width * k, height: img.size.height * k)
            let p = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), contents: img)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ v: DragView, context: Context) { v.makeFile = makeFile }
}
