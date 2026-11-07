import AppKit
import SwiftUI

extension Prefs.Key {
    static let annotateCustomColors = Prefs.Key("annotateCustomColors", [String]())
}

/// A colour swatch; transparent colours show a checkerboard.
struct ColorSwatch: View {
    let hex: String
    var size: CGFloat = 18
    var selected = false

    var body: some View {
        ZStack {
            if NSColor(hex: hex).alphaComponent < 1 { Checkerboard().clipShape(Circle()) }
            Circle().fill(Color(nsColor: NSColor(hex: hex)))
            Circle().strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3.5).opacity(selected ? 1 : 0))
    }
}

/// Toolbar colour button: swatch that opens the palette popover.
struct ColorButton: View {
    @Binding var hex: String
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                ColorSwatch(hex: hex, size: 18)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Color")
        .popover(isPresented: $open, arrowEdge: .bottom) { ColorPalettePanel(hex: $hex) }
    }
}

/// 17 named colours, saved custom colours (capped), hex field, eyedropper and the system colour panel.
struct ColorPalettePanel: View {
    @Binding var hex: String
    @State private var custom: [String] = Prefs.codable(.annotateCustomColors, [String].self) ?? []
    @State private var hexText = ""
    @State private var limitAlert = false

    private let columns = Array(repeating: GridItem(.fixed(24), spacing: 6), count: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(Palette.named, id: \.hex) { c in
                    ColorSwatch(hex: c.hex, size: 20, selected: same(c.hex))
                    .contentShape(Rectangle())
                    .onTapGesture { hex = c.hex }
                    .help(c.name.loc)
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text("My Colors").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { addCustom() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Add to My Colors")
            }
            if custom.isEmpty {
                Text("Save colors you use often with +.").font(.caption).foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 9), alignment: .leading, spacing: 6) {
                    ForEach(custom, id: \.self) { c in
                        ColorSwatch(hex: c, size: 20, selected: same(c))
                            .onTapGesture { hex = c }
                            .contextMenu {
                                Button("Update with Current Color") { replace(c) }
                                Button("Remove") { custom.removeAll { $0 == c }; save() }
                            }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Hex", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 100)
                    .onSubmit { applyHex() }
                Button { sample() } label: { Image(systemName: "eyedropper") }
                    .help("Pick a color from the screen")
                ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hex: hex)) }, set: { hex = NSColor($0).hexString }), supportsOpacity: true)
                    .labelsHidden()
                    .help("More colors…")
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { hexText = hex }
        .onChange(of: hex) { _, v in hexText = v }
        .alert("You've reached the limit of saved colors.", isPresented: $limitAlert) {
            Button("OK", role: .cancel) {}
        } message: { Text("To add a new one, please delete an existing color first.") }
    }

    private func same(_ c: String) -> Bool { c.caseInsensitiveCompare(hex) == .orderedSame }

    private func save() { Prefs.setCodable(custom, .annotateCustomColors) }

    private func addCustom() {
        guard !custom.contains(where: same) else { return }
        guard custom.count < Palette.maxCustom else { limitAlert = true; return }
        custom.append(hex.uppercased())
        save()
    }

    private func replace(_ c: String) {
        guard let i = custom.firstIndex(of: c) else { return }
        custom[i] = hex.uppercased()
        save()
    }

    private func applyHex() {
        var s = hexText.trimmingCharacters(in: .whitespaces).uppercased()
        if !s.hasPrefix("#") { s = "#" + s }
        let digits = s.dropFirst()
        guard [6, 8].contains(digits.count), UInt64(digits, radix: 16) != nil else { hexText = hex; NSSound.beep(); return }
        hex = s
    }

    private func sample() {
        NSColorSampler().show { c in
            guard let c else { return }
            DispatchQueue.main.async { hex = c.hexString }
        }
    }
}
