import AppKit
import SwiftUI

extension Prefs.Key {
    /// Menu bar glyph while recording: "yellow" (daisy with a yellow centre) or "mono" (template, solid centre).
    static let menuBarRecordingIndicator = Prefs.Key("menuBarRecordingIndicator", "yellow")
}

/// Menu bar glyphs (18×18 pt). The daisy artwork is bundled (`Assets/MenuBar`); busy/paused states are drawn in code.
@MainActor
enum MenuBarIcon {
    /// Daisy inside viewfinder corners, hollow centre (template).
    static let standard = bundled("menubar-black", template: true)

    /// Recording: the daisy with a filled centre. "Yellow centre" isn't a template, so it picks the black or white
    /// drawing for the menu bar's current appearance at draw time.
    static var recording: NSImage { recordingImage(Prefs.string(.menuBarRecordingIndicator)) }

    static func recordingImage(_ kind: String) -> NSImage { kind == "mono" ? monoRecording : yellowRecording }

    private static let monoRecording = bundled("menubar-rec-black", template: true)
    private static let yellowRecording: NSImage = {
        let onLight = DS.image("MenuBar/menubar-rec-yellow-black.svg"), onDark = DS.image("MenuBar/menubar-rec-yellow-white.svg")
        let img = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { r in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? onDark : onLight)?.draw(in: r)
            return true
        }
        img.cacheMode = .never   // redraw when the menu bar flips between light and dark
        img.accessibilityDescription = "Daisyshot"
        return img
    }()

    /// Brand mark as a 16 pt menu item glyph (All-In-One).
    static let markGlyph: NSImage? = {
        guard let m = DS.image("Logo/mark-ink.svg")?.copy() as? NSImage else { return nil }
        m.size = CGSize(width: 15, height: 15)
        m.isTemplate = true
        return m
    }()

    /// Record Screen menu glyph: ring in the label colour around a yellow centre.
    static let recordGlyph: NSImage = {
        let img = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { r in
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 1.4
            NSColor.labelColor.setStroke()
            ring.stroke()
            NSColor(hex: "#F5A21B").setFill()
            NSBezierPath(ovalIn: CGRect(x: r.midX - 2.8, y: r.midY - 2.8, width: 5.6, height: 5.6)).fill()
            return true
        }
        img.cacheMode = .never
        return img
    }()

    private static func bundled(_ name: String, template: Bool) -> NSImage {
        let img = (DS.image("MenuBar/\(name).svg")?.copy() as? NSImage) ?? Self.template { corners($0).stroke() }
        img.size = CGSize(width: 18, height: 18)
        img.isTemplate = template
        img.accessibilityDescription = "Daisyshot"
        return img
    }

    private static func corners(_ r: CGRect) -> NSBezierPath {
        let inset = r.insetBy(dx: 2, dy: 2)
        let arm: CGFloat = 4.2
        let p = NSBezierPath()
        p.lineWidth = 1.6
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        for (corner, dx, dy) in [(CGPoint(x: inset.minX, y: inset.minY), 1.0, 1.0), (CGPoint(x: inset.maxX, y: inset.minY), -1.0, 1.0),
                                 (CGPoint(x: inset.minX, y: inset.maxY), 1.0, -1.0), (CGPoint(x: inset.maxX, y: inset.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            p.line(to: corner)
            p.line(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return p
    }

    /// Busy (GIF conversion, export…): the viewfinder corners around a spinning arc, cycled by the app delegate.
    static let busyFrames: [NSImage] = (0..<12).map { i in
        template { r in
            corners(r).stroke()
            let arc = NSBezierPath()
            let start = 90 - CGFloat(i) * 30
            arc.appendArc(withCenter: CGPoint(x: r.midX, y: r.midY), radius: 3.6, startAngle: start, endAngle: start - 250, clockwise: true)
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            arc.stroke()
        }
    }

    /// Paused recording: ring with a play triangle (click to resume).
    static let resume = template { r in
        ring(r).stroke()
        let t = NSBezierPath()
        t.move(to: CGPoint(x: r.midX - 2.2, y: r.midY - 3.6))
        t.line(to: CGPoint(x: r.midX + 3.6, y: r.midY))
        t.line(to: CGPoint(x: r.midX - 2.2, y: r.midY + 3.6))
        t.close()
        t.lineJoinStyle = .round
        t.lineWidth = 1
        t.fill()
        t.stroke()
    }

    private static func ring(_ r: CGRect) -> NSBezierPath {
        let p = NSBezierPath(ovalIn: r.insetBy(dx: 1.75, dy: 1.75))
        p.lineWidth = 1.5
        return p
    }

    private static func template(_ draw: @escaping (CGRect) -> Void) -> NSImage {
        let img = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { r in
            NSColor.black.set()
            draw(r)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Daisyshot"
        return img
    }
}

/// First row of the status menu: logotype and the "Offline · Private" chip.
@MainActor
enum StatusMenuHeader {
    static func make() -> NSView {
        let v = NSHostingView(rootView: Content())
        v.frame.size = v.fittingSize
        return v
    }

    private struct Content: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            HStack(spacing: 16) {
                if let logo = DS.image(scheme == .dark ? "Logo/logotype-white.svg" : "Logo/logotype-ink.svg") {
                    Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit).frame(width: 104)
                }
                Spacer(minLength: 0)
                DSChip("Offline · Private").fixedSize()   // one line; longer translations widen the menu
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .frame(minWidth: 300)
        }
    }
}
