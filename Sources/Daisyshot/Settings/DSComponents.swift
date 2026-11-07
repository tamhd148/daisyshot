import AppKit
import SwiftUI

// Settings building blocks in the Daisyshot style (DESIGN_SPEC §4, reference/html/Settings*.dc.html).
// A pane is a `DSSections` of `DSCard`s; inside a card every direct child is a row and gets a 1 pt separator above it.
// Plain `Toggle`s render as rows (label left, switch right) via `DSRowToggleStyle`, which the Settings window applies;
// use `.toggleStyle(.checkbox)` for grid checkboxes. Pop-ups and sliders are the native controls tinted with `DS.accent`.

/// Vertical stack of cards with the page's 16 pt gap.
struct DSSections<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: DS.Metric.sectionGap) { content } }
}

/// Grouped rows: `cardBg`, radius 12, 16 pt side padding, separators between rows.
struct DSCard<Content: View>: View {
    var padding = EdgeInsets(top: 0, leading: DS.Metric.cardPaddingH, bottom: 0, trailing: DS.Metric.cardPaddingH)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { i in
                    if i > 0 { Rectangle().fill(DS.separator).frame(height: 1) }
                    rows[i]
                }
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.cardBg, in: RoundedRectangle(cornerRadius: DS.Metric.cardRadius, style: .continuous))
    }
}

/// Title (+ optional sub-label and leading glyph) on the left, a control on the right; at least 48 pt tall.
struct DSRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var icon: Image?
    var minHeight = DS.Metric.rowMinHeight
    @ViewBuilder var control: Control

    init(_ title: String, subtitle: String? = nil, icon: Image? = nil, minHeight: CGFloat = DS.Metric.rowMinHeight,
         @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.minHeight = minHeight
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon { icon.frame(width: 18, height: 18) }
            DSRowLabel(title: title, subtitle: subtitle)
            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: minHeight)
        .padding(.vertical, subtitle == nil ? 0 : 8)
    }
}

struct DSRowLabel: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.loc).font(DS.Font.body).foregroundStyle(DS.ink)
            if let subtitle {
                Text(subtitle.loc).font(DS.Font.sub).foregroundStyle(DS.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Toggle row with a sub-label (plain `Toggle`s already render as rows).
struct DSToggleRow: View {
    let title: String
    var subtitle: String?
    var icon: Image?
    @Binding var isOn: Bool

    init(_ title: String, subtitle: String? = nil, icon: Image? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        _isOn = isOn
    }

    var body: some View {
        DSRow(title, subtitle: subtitle, icon: icon) { DSSwitch(isOn: $isOn) }
    }
}

/// The native switch, accent-tinted.
struct DSSwitch: View {
    @Binding var isOn: Bool
    var body: some View { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(DS.accent) }
}

/// Makes every plain `Toggle` a settings row. Applied by the Settings window.
struct DSRowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label.font(DS.Font.body).foregroundStyle(DS.ink)
            Spacer(minLength: 12)
            DSSwitch(isOn: configuration.$isOn)
        }
        .frame(minHeight: DS.Metric.rowMinHeight)
        .opacity(configuration.isMixed ? 0.6 : 1)
    }
}

/// Bold section title with an optional caption, shown between cards ("After capture").
struct DSSectionHeader: View {
    let title: String
    var subtitle: String?
    var trailing: AnyView?

    init(_ title: String, subtitle: String? = nil, trailing: AnyView? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.loc).font(DS.Font.section).foregroundStyle(DS.ink)
                if let subtitle { Text(subtitle.loc).font(.system(size: 13)).foregroundStyle(DS.inkSecondary) }
            }
            if let trailing { trailing }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }
}

/// Small grey group label above a card ("Appearance").
struct DSGroupLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.loc).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.inkSecondary).padding(.top, 6)
    }
}

// MARK: Controls

/// Secondary (white + border), primary (`accentStrong` fill) and destructive (red text) buttons. Applied window-wide;
/// icon-only buttons should use `.buttonStyle(.plain)`.
struct DSButtonStyle: ButtonStyle {
    enum Kind { case secondary, primary, destructive }
    var kind = Kind.secondary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .primary ? .semibold : .regular))
            .foregroundStyle(kind == .primary ? AnyShapeStyle(.white) : kind == .destructive ? AnyShapeStyle(DS.destructive) : AnyShapeStyle(DS.ink))
            .padding(.vertical, 5)
            .padding(.horizontal, 14)
            .background {
                let shape = RoundedRectangle(cornerRadius: DS.Metric.buttonRadius, style: .continuous)
                if kind == .primary {
                    shape.fill(DS.accentStrong)
                } else {
                    shape.fill(DS.controlBg).overlay(shape.strokeBorder(DS.controlBorder))
                }
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsDestructive: DSButtonStyle { DSButtonStyle(kind: .destructive) }
}

/// Segmented control: `#E6EAF1` track, white selected segment with a soft shadow, `accentText` semibold label.
struct DSSegmented<Value: Hashable>: View {
    struct Option {
        var value: Value
        var title: String
        var image: NSImage?
    }

    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i], on = o.value == selection
                Button { selection = o.value } label: {
                    HStack(spacing: 6) {
                        if let img = o.image { Image(nsImage: img).resizable().frame(width: 16, height: 16) }
                        Text(o.title.loc)
                    }
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? DS.accentText : DS.ink)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.controlBg)
                                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DS.separator, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Keycap: white, 1 pt border plus a 2 pt bottom edge, monospaced `accentText`.
struct DSKeycap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(DS.Font.keycap)
            .foregroundStyle(DS.accentText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                shape.fill(DS.controlBorder).offset(y: 1)
                shape.fill(DS.controlBg).overlay(shape.strokeBorder(DS.controlBorder))
            }
            .padding(.bottom, 1)
    }
}

/// Dashed ghost button shown where a shortcut is unset ("Record shortcut"); turns accent on hover.
struct DSGhostButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title.loc)
                .font(.system(size: 12.5))
                .foregroundStyle(hover ? DS.accentText : DS.inkTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(hover ? DS.accent : DS.controlBorder, style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Small round × (clear a shortcut, remove an item).
struct DSClearButton: View {
    var help = "Clear"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.inkSecondary)
                .frame(width: 18, height: 18)
                .background(DS.separator, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help.loc)
    }
}

/// Pill label. `.leaf` = "Offline · Private"/"On-device" (with a dot), `.accent` = neutral info chip.
struct DSChip: View {
    enum Tone { case leaf, accent }
    let text: String
    var tone = Tone.leaf
    var dot = true

    init(_ text: String, tone: Tone = .leaf, dot: Bool = true) {
        self.text = text
        self.tone = tone
        self.dot = dot
    }

    var body: some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(tone == .leaf ? DS.leaf : DS.accent).frame(width: 6, height: 6) }
            Text(text.loc)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(tone == .leaf ? DS.leafText : DS.accentText)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(tone == .leaf ? DS.leafTint : DS.accentTint, in: Capsule())
    }
}

/// Monospaced "code" pill (file-name examples, URL-scheme examples).
struct DSCode: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(DS.accentText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DS.accentTint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .textSelection(.enabled)
    }
}

/// Selectable tile with a 2 pt `accent` ring when selected (app icons, window backgrounds).
struct DSTile<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    let content: Content

    init(selected: Bool, action: @escaping () -> Void, @ViewBuilder label: () -> Content) {
        self.selected = selected
        self.action = action
        self.content = label()
    }

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity)
                .background(selected ? DS.controlBg : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? DS.accent : .clear, lineWidth: 2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Colour swatches with a "+" custom colour well. Unselected swatches are dimmed when `dimUnselected`.
struct DSSwatches: View {
    @Binding var hex: String
    let swatches: [String]
    var dimUnselected = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(swatches, id: \.self) { s in
                let on = s.caseInsensitiveCompare(hex) == .orderedSame
                Button { hex = s } label: {
                    Circle().fill(Color(nsColor: NSColor(hex: s)))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.16)))
                        .frame(width: 22, height: 22)
                        .padding(3)
                        .overlay(Circle().strokeBorder(on ? DS.accent : .clear, lineWidth: 2))
                        .opacity(dimUnselected && !on ? 0.55 : 1)
                }
                .buttonStyle(.plain)
                .help(s)
                .accessibilityLabel(s)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            let custom = !swatches.contains { $0.caseInsensitiveCompare(hex) == .orderedSame }
            Button { ColorPanelBridge.open(hex) { hex = $0 } } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.inkSecondary)
                    .frame(width: 22, height: 22)
                    .background(custom ? Color(nsColor: NSColor(hex: hex)) : DS.controlBg, in: Circle())
                    .overlay(Circle().strokeBorder(DS.controlBorder))
                    .padding(3)
                    .overlay(Circle().strokeBorder(custom ? DS.accent : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .help("Custom colour")
        }
    }
}

/// Opens the shared colour panel and reports picks as `#RRGGBB` (a native ColorPicker well is too wide for a swatch row).
@MainActor
private final class ColorPanelBridge: NSObject {
    private static let shared = ColorPanelBridge()
    private var onChange: ((String) -> Void)?

    static func open(_ hex: String, onChange: @escaping (String) -> Void) {
        let panel = NSColorPanel.shared
        shared.onChange = nil   // don't echo the initial colour back
        panel.showsAlpha = false
        panel.color = NSColor(hex: hex)
        shared.onChange = onChange
        panel.setTarget(shared)
        panel.setAction(#selector(changed(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) { onChange?(panel.color.hexString) }
}
