#if DEBUG
import AppKit
import AVFoundation

/// README media: `CONFIG=debug ./scripts/build-app.sh`, then
/// `open --env DAISYSHOT_DEMO=<dir> build/Daisyshot.app` (the bundle has Screen Recording access for the window shots).
/// Writes `demo.gif` (a Studio export of a synthetic recording), `studio-editor.png`, `annotate.png` and
/// `auto-redact.png` (Auto Redact run on a drawn chat with made-up details), then quits. Everything shown is drawn
/// here — no real screen content. Videos use the iMac Purple desktop picture, screenshots the Candy background.
@MainActor
enum DebugDemo {
    static let points = CGSize(width: 800, height: 500), scale: CGFloat = 2

    static func run(_ dir: String) {
        Task {
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            // Opening the editor records recent projects; put the user's back afterwards.
            let keep = [Prefs.Key.studioLastProject, .studioRecentProjects].map { ($0, Prefs.string($0)) }
            defer { keep.forEach { Prefs.set($0.1, $0.0) } }
            do {
                let pkg = try await makeProject(in: out.appendingPathComponent("work", isDirectory: true))
                try await exportGIF(pkg, to: out.appendingPathComponent("demo.gif"))
                print("DEMO gif")
                try await editorShot(pkg, to: out.appendingPathComponent("studio-editor.png"))
                print("DEMO editor")
                try await annotateShot(to: out.appendingPathComponent("annotate.png"))
                print("DEMO annotate")
                try await redactShot(to: out.appendingPathComponent("auto-redact.png"))
                print("DEMO auto redact")
                try? FileManager.default.removeItem(at: out.appendingPathComponent("work"))
                keep.forEach { Prefs.set($0.1, $0.0) }
                print("DEMO done: \(out.path)")
                exit(0)
            } catch {
                print("DEMO failed: \(error)")
                exit(1)
            }
        }
    }

    // MARK: The recording

    /// Times (seconds) of what happens in the scene.
    private static let checkAt = 1.6, fieldAt = 2.8, typeFrom = 3.1, typeTo = 5.0, addAt = 5.7, saveAt = 6.7, length = 8.0
    private static let typed = "Share the GitHub release"
    private static let tasks = ["Write the release notes", "Record the demo video", "Email the beta testers", "Update the website"]

    private static func makeProject(in folder: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pkg = folder.appendingPathComponent("Daisyshot Demo").appendingPathExtension(StudioPackage.fileExtension)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let px = CGSize(width: points.width * scale, height: points.height * scale)
        try await StudioSample.writeVideo(to: pkg.appendingPathComponent("video.mp4"), size: px, seconds: length, audio: false) { ctx, t in
            drawScene(ctx, size: px, t: t)
        }
        var ev = StudioEvents(version: 1, region: .init(x: 0, y: 0, width: points.width, height: points.height), scale: Double(scale), duration: length)
        // The pointer: checkbox, the new-task field, the Add button, then away.
        let path: [(Double, CGPoint)] = [(0, CGPoint(x: 620, y: 420)), (1.4, CGPoint(x: 236, y: 147)), (2.0, CGPoint(x: 240, y: 150)),
                                         (2.6, CGPoint(x: 420, y: 296)), (5.2, CGPoint(x: 430, y: 300)), (5.55, CGPoint(x: 724, y: 296)),
                                         (6.3, CGPoint(x: 700, y: 330)), (length, CGPoint(x: 690, y: 360))]
        var t = 0.0
        while t <= length {
            let i = max(0, (path.firstIndex { $0.0 > t } ?? path.count) - 1), j = min(path.count - 1, i + 1)
            let (t0, a) = path[i], (t1, b) = path[j]
            let u = t1 > t0 ? StudioTracks.easeInOut((t - t0) / (t1 - t0)) : 1
            ev.events.append(.init(t: t, type: "move", x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u))
            t += 1.0 / 60
        }
        for (c, p) in [(checkAt, CGPoint(x: 236, y: 147)), (fieldAt, CGPoint(x: 420, y: 296)), (addAt, CGPoint(x: 724, y: 296))] {
            ev.events.append(.init(t: c, type: "down", x: p.x, y: p.y))
            ev.events.append(.init(t: c + 0.08, type: "up", x: p.x, y: p.y))
        }
        for i in 0..<typed.count { ev.events.append(.init(t: typeFrom + Double(i) * (typeTo - typeFrom) / Double(typed.count), type: "typing")) }
        ev.events.append(.init(t: saveAt, type: "key", key: "⌘S"))
        ev.events.sort { $0.t < $1.t }
        try StudioJSON.encode(ev)?.write(to: pkg.appendingPathComponent(StudioCaptureLayout.events))

        var doc = StudioDocument(clips: [.init(start: 0, duration: length)])
        let purple = MacWallpapers.systemFolder.appendingPathComponent("iMac Purple.heic")
        if FileManager.default.fileExists(atPath: purple.path) {
            doc.background.kind = .image
            doc.background.imagePath = purple.path
        } else {
            doc.background.kind = .gradient
            doc.background.gradient = 0
        }
        doc.background.padding = 0.07
        doc.background.cornerRadius = 14
        doc.background.shadow = 0.6
        doc.cursor.size = 1.6
        doc.cursor.rippleColor = .blue
        // Two gentle zooms that follow the pointer; the view is back to the whole window for ⌘S.
        doc.zooms = [.init(start: 1.0, end: 2.3, scale: 1.6), .init(start: 2.6, end: 6.1, scale: 1.55)]
        try StudioJSON.encode(doc)?.write(to: pkg.appendingPathComponent("project.json"))
        return pkg
    }

    /// A small task app, top-left origin in points, scaled to the pixel size.
    private static func drawScene(_ ctx: CGContext, size: CGSize, t: Double) {
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: scale, y: -scale)
        func fill(_ r: CGRect, _ hex: String, radius: CGFloat = 0) {
            NSColor(hex: hex).setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }
        func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: String = "#1D1D1F", strike: Bool = false) {
            var a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(hex: color)]
            if strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            NSAttributedString(string: s, attributes: a).draw(at: p)
        }
        let W = points.width, H = points.height
        fill(CGRect(x: 0, y: 0, width: W, height: H), "#FFFFFF")
        // Title bar and sidebar.
        fill(CGRect(x: 0, y: 0, width: W, height: 38), "#F3F3F5")
        for (i, c) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() { fill(CGRect(x: 16 + CGFloat(i) * 20, y: 13, width: 12, height: 12), c, radius: 6) }
        text("Launch Plan", CGPoint(x: W / 2 - 38, y: 10), size: 13, weight: .semibold, color: "#3C3C43")
        fill(CGRect(x: 0, y: 38, width: 190, height: H - 38), "#F5F5F7")
        fill(CGRect(x: 190, y: 38, width: 1, height: H - 38), "#E5E5EA")
        for (i, item) in ["Inbox", "Today", "Launch", "Design", "Marketing"].enumerated() {
            let y = 62 + CGFloat(i) * 34
            if i == 1 { fill(CGRect(x: 12, y: y - 6, width: 166, height: 30), "#E3ECFF", radius: 8) }
            fill(CGRect(x: 26, y: y + 3, width: 12, height: 12), i == 1 ? "#3E7BFA" : "#C7C7CC", radius: 3)
            text(item, CGPoint(x: 48, y: y), size: 14, weight: i == 1 ? .semibold : .regular, color: i == 1 ? "#2B5FE0" : "#3C3C43")
        }
        // Today's tasks; the second gets ticked, a fifth is added.
        text("Today", CGPoint(x: 220, y: 58), size: 26, weight: .bold)
        var rows = tasks
        if t >= addAt { rows.append(typed) }
        for (i, task) in rows.enumerated() {
            let y = 116 + CGFloat(i) * 34
            let done = i == 1 && t >= checkAt + 0.08
            let ring = NSBezierPath(ovalIn: CGRect(x: 228, y: y + 1, width: 16, height: 16))
            if done { NSColor(hex: "#3E7BFA").setFill(); ring.fill() } else { NSColor(hex: "#C7C7CC").setStroke(); ring.lineWidth = 1.5; ring.stroke() }
            if done { text("✓", CGPoint(x: 231.5, y: y), size: 12, weight: .bold, color: "#FFFFFF") }
            text(task, CGPoint(x: 256, y: y), size: 15, color: done ? "#8E8E93" : "#1D1D1F", strike: done)
        }
        // New-task field and Add button.
        let fy: CGFloat = 282
        fill(CGRect(x: 220, y: fy, width: 460, height: 32), t >= fieldAt && t < addAt ? "#3E7BFA" : "#D1D1D6", radius: 8)
        fill(CGRect(x: 221.5, y: fy + 1.5, width: 457, height: 29), "#FFFFFF", radius: 7)
        let n = t < typeFrom ? 0 : min(typed.count, Int(Double(typed.count) * (t - typeFrom) / (typeTo - typeFrom)) + 1)
        let shown = t >= addAt ? "" : String(typed.prefix(n))
        if shown.isEmpty { text("New task…", CGPoint(x: 232, y: fy + 7), size: 14, color: "#AEAEB2") } else { text(shown, CGPoint(x: 232, y: fy + 7), size: 14) }
        fill(CGRect(x: 692, y: fy, width: 72, height: 32), t >= addAt && t < addAt + 0.25 ? "#2B5FE0" : "#3E7BFA", radius: 8)
        text("Add", CGPoint(x: 714, y: fy + 7), size: 14, weight: .semibold, color: "#FFFFFF")
        // ⌘S: a "Saved" note.
        if t >= saveAt + 0.1, t < saveAt + 1.2 {
            fill(CGRect(x: W - 132, y: 54, width: 112, height: 30), "#1D1D1F", radius: 15)
            text("✓ Saved", CGPoint(x: W - 106, y: 60), size: 13, weight: .semibold, color: "#FFFFFF")
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Outputs

    /// Through the Studio renderer and GIF encoder, like an export, without Quick Access or History.
    private static func exportGIF(_ project: URL, to dst: URL) async throws {
        let pkg = try StudioPackage.open(project)
        let src = try await StudioSources.load(pkg)
        let ed = StudioEditor(package: pkg)
        ed.load(src)
        defer { ed.close() }
        guard let model = ed.makeModel() else { throw StudioError("No model.") }
        let comp = try StudioComposer.composition(src, doc: ed.doc, audio: false)
        let size = StudioResolution.r720.size(for: model.canvasSize)
        let fps = 25
        let vc = StudioComposer.videoComposition(comp, model: model, renderSize: size, fps: Double(fps))
        try? FileManager.default.removeItem(at: dst)
        try await GIFEncoder.convert(comp, videoComposition: vc, to: dst, fps: fps, maxWidth: Int(size.width), quality: 85, optimize: true, loop: true)
    }

    private static func editorShot(_ project: URL, to dst: URL) async throws {
        VideoEditor.open(project)
        var found: (StudioEditor, NSWindow)?
        for _ in 0..<100 where found == nil {
            try await Task.sleep(for: .milliseconds(100))
            for w in NSApp.windows { if let c = w.delegate as? StudioWindowController, c.editor.sources != nil { found = (c.editor, w) } }
        }
        guard let (ed, win) = found else { throw StudioError("No editor.") }
        win.setFrame(CGRect(x: 60, y: 60, width: 1440, height: 900), display: true)
        ed.tab = .cursor
        ed.seek(to: 4.2)
        try await Task.sleep(for: .milliseconds(2500))
        try capture(win, to: dst)
        win.close()
    }

    private static func annotateShot(to dst: URL) async throws {
        let px = CGSize(width: points.width * scale, height: points.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        drawScene(ctx, size: px, t: length - 0.5)
        guard let img = ctx.makeImage() else { return }
        var state = DocState(image: img, scale: scale)
        state.background.fill = candy
        state.background.padding = 48
        func a(_ k: Annotation.Kind, _ p: [CGPoint], _ color: String, width: CGFloat = 5, font: CGFloat = 28) -> Annotation {
            Annotation(kind: k, points: p, color: color, lineWidth: width, shadow: true, fontSize: font)
        }
        var arrow = a(.arrow, [CGPoint(x: 600, y: 420), CGPoint(x: 712, y: 322)], "#FF375F", width: 6)
        arrow.arrowStyle = .standard
        var note = a(.text, [CGPoint(x: 470, y: 420)], "#FF375F", font: 26)
        note.text = "Add it here"
        var one = a(.counter, [CGPoint(x: 206, y: 125)], "#3E7BFA", font: 20), two = a(.counter, [CGPoint(x: 206, y: 159)], "#3E7BFA", font: 20)
        one.number = 1; two.number = 2
        var blur = a(.redact, [CGPoint(x: 252, y: 182), CGPoint(x: 420, y: 202)], "#000000")
        blur.redactStyle = .smoothBlur
        blur.intensity = 0.7
        state.annotations = [a(.highlighter, [CGPoint(x: 252, y: 227), CGPoint(x: 400, y: 227)], "#FFD60A", width: 9), blur, one, two, arrow, note]
        AnnotateEditor.present(state, fileURL: nil, documentURL: nil)
        try await Task.sleep(for: .milliseconds(1500))
        AnnotateEditor.editors.last?.selection = nil      // no selection outline in the shot
        guard let win = NSApp.windows.last(where: { $0.isVisible && $0.className.contains("Annotate") || $0.title.contains("Annotate") })
                ?? NSApp.orderedWindows.first else { throw StudioError("No Annotate window.") }
        win.setFrame(CGRect(x: 60, y: 60, width: 1280, height: 860), display: true)
        try await Task.sleep(for: .milliseconds(800))
        try capture(win, to: dst)
        win.close()
    }

    /// Daisyshot's built-in Candy background for screenshots.
    private static var candy: BackgroundSettings.Fill { .builtin(Backgrounds.wallpapers.firstIndex { $0.name == "Candy" } ?? 0) }

    /// A chat with made-up contract details, then what Auto Redact finds in it — the real scanner, not drawn boxes.
    private static func redactShot(to dst: URL) async throws {
        let size = CGSize(width: 720, height: 470), px = CGSize(width: size.width * scale, height: size.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        drawChat(ctx, size: size)
        guard let img = ctx.makeImage() else { return }
        let found = await SensitiveScanner.scan(img, size: size).filter { $0.kind != .face }
        print("DEMO auto redact found: \(found.map(\.kind.rawValue))")
        var state = DocState(image: img, scale: scale)
        state.background.fill = candy
        state.background.padding = 48
        state.annotations = AutoRedact.annotations(found, style: .blackout)
        AnnotateEditor.present(state, fileURL: nil, documentURL: nil)
        try await Task.sleep(for: .milliseconds(1500))
        AnnotateEditor.editors.last?.selection = nil      // no selection outline in the shot
        guard let win = NSApp.orderedWindows.first(where: { $0.isVisible && $0.className.contains("Annotate") }) ?? NSApp.orderedWindows.first
        else { throw StudioError("No Annotate window.") }
        win.setFrame(CGRect(x: 60, y: 60, width: 1180, height: 860), display: true)
        try await Task.sleep(for: .milliseconds(800))
        try capture(win, to: dst)
        win.close()
    }

    /// A messaging window: a colleague sends the details for a contract (all invented).
    private static func drawChat(_ ctx: CGContext, size: CGSize) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        func fill(_ r: CGRect, _ hex: String, radius: CGFloat = 0) {
            NSColor(hex: hex).setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }
        func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: String = "#1D1D1F") {
            NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(hex: color)]).draw(at: p)
        }
        fill(CGRect(origin: .zero, size: size), "#FFFFFF")
        fill(CGRect(x: 0, y: 0, width: size.width, height: 52), "#F6F6F8")
        fill(CGRect(x: 0, y: 52, width: size.width, height: 1), "#E5E5EA")
        for (i, c) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() { fill(CGRect(x: 16 + CGFloat(i) * 20, y: 20, width: 12, height: 12), c, radius: 6) }
        fill(CGRect(x: 92, y: 10, width: 32, height: 32), "#7C9CFF", radius: 16)
        text("L", CGPoint(x: 103, y: 15), size: 16, weight: .bold, color: "#FFFFFF")
        text("Chị Lan · Kế toán", CGPoint(x: 134, y: 10), size: 14, weight: .semibold)
        text("Đang hoạt động", CGPoint(x: 134, y: 28), size: 11, color: "#34C759")
        // Their messages on the left, mine on the right.
        fill(CGRect(x: 24, y: 72, width: 330, height: 36), "#F0F0F3", radius: 16)
        text("Em gửi chị thông tin làm hợp đồng nhé!", CGPoint(x: 38, y: 81), size: 14)
        fill(CGRect(x: 280, y: 124, width: 416, height: 208), "#E3ECFF", radius: 18)
        let lines = [("Họ tên:", "Nguyễn Văn An"), ("Số CCCD:", "001203004567"), ("STK:", "1903 6655 8899 012"),
                     ("Ngân hàng:", "Techcombank"), ("SĐT:", "0912 345 678"), ("Email:", "an.nguyen@congty.vn")]
        for (i, (label, value)) in lines.enumerated() {
            let y = 140 + CGFloat(i) * 30
            text(label, CGPoint(x: 300, y: y), size: 15, weight: .semibold, color: "#2B5FE0")
            text(value, CGPoint(x: 410, y: y), size: 15)
        }
        fill(CGRect(x: 24, y: 350, width: 250, height: 36), "#F0F0F3", radius: 16)
        text("Ok em, chị nhận được rồi 👍", CGPoint(x: 38, y: 359), size: 14)
        fill(CGRect(x: 20, y: size.height - 56, width: size.width - 40, height: 38), "#F6F6F8", radius: 19)
        text("Nhập tin nhắn…", CGPoint(x: 38, y: size.height - 46), size: 14, color: "#AEAEB2")
        NSGraphicsContext.restoreGraphicsState()
    }

    /// `screencapture -l` of one window, without its shadow.
    private static func capture(_ w: NSWindow, to dst: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", dst.path]
        try p.run()
        p.waitUntilExit()
        guard FileManager.default.fileExists(atPath: dst.path) else { throw StudioError("Couldn't capture the window (Screen Recording access?).") }
    }
}
#endif
