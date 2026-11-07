#if DEBUG
import AppKit
import SwiftUI

/// Design QA: `DAISYSHOT_SNAP=<dir> .build/debug/Daisyshot` (or, for translations, `CONFIG=debug ./scripts/build-app.sh` then
/// `DAISYSHOT_SNAP=<dir> build/Daisyshot.app/Contents/MacOS/Daisyshot -AppleLanguages '(vi)'`) writes PNGs of the menu header, menu bar glyphs and every
/// Settings pane in light and dark appearance, then quits.
@MainActor
enum DebugSnap {
    static func run(_ dir: String) {
        // Snapshots flip these; put the user's values back afterwards.
        let tab = Prefs.string(.settingsTab), indicator = Prefs.string(.menuBarRecordingIndicator)
        defer { Prefs.set(tab, .settingsTab); Prefs.set(indicator, .menuBarRecordingIndicator) }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, ap) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
            save(StatusMenuHeader.make(), ap, out.appendingPathComponent("menu-header-\(name).png"))
            save(glyphs(), ap, out.appendingPathComponent("menubar-glyphs-\(name).png"))
            for tab in SettingsTab.allCases {
                SettingsWindow.model.tab = tab
                let v = NSHostingView(rootView: SettingsView(model: SettingsWindow.model, scrolls: false))
                v.frame.size = CGSize(width: DS.Metric.windowWidth, height: 400)
                v.appearance = ap
                v.frame.size.height = max(600, v.fittingSize.height)
                save(v, ap, out.appendingPathComponent("settings-\(tab.rawValue)-\(name).png"), layout: true)
            }
            FileNameEditor.show()
            if let w = NSApp.windows.first(where: { $0.title == "File name format".loc }), let v = w.contentView {
                w.appearance = ap
                save(v, ap, out.appendingPathComponent("file-name-editor-\(name).png"), layout: true)
            }
            FileNameEditor.close()
        }
        print("SNAP done: \(out.path)")
        Prefs.set(tab, .settingsTab); Prefs.set(indicator, .menuBarRecordingIndicator)
        exit(0)
    }

    /// `DAISYSHOT_STUDIO_SNAP=<dir>`: opens a synthetic Studio recording and writes PNGs of the video editor in several
    /// states (sidebar tabs, clip and mask inspectors, export sheet), then quits. The video itself doesn't show (player layer).
    /// `DAISYSHOT_SETUP_SNAP=<dir>`: real screenshots (glass needs the window server) of the Record Screen setup in each
    /// mode, dark and light. Moves the pointer: area modes to the screen centre, Window mode onto the largest window.
    static func recordingSetup(_ dir: String) {
        Task { @MainActor in
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let screen = NSScreen.main ?? NSScreen.screens[0], b = screen.frame
            let area = CaptureRegion(displayID: screen.displayID, rect: CGRect(x: b.width * 0.3, y: b.height * 0.3, width: 560, height: 315))
            let small = CaptureRegion(displayID: screen.displayID, rect: CGRect(x: b.width * 0.4, y: b.height * 0.35, width: 300, height: 200))
            let window = CaptureService.visibleWindows().max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            let cases: [(String, CaptureRegion?, RecordingSetup.Source?, CGPoint)] = [
                ("area-empty", nil, .area, CGPoint(x: b.midX - 200, y: b.height * 0.55)),
                ("area", area, nil, CGPoint(x: area.rect.midX, y: area.rect.midY)),
                ("area-small", small, nil, CGPoint(x: b.width * 0.15, y: b.height * 0.8)),
                ("screen", nil, .display, CGPoint(x: b.midX, y: b.midY)),
                ("device", nil, .device, CGPoint(x: b.midX, y: b.midY)),
                ("window", nil, .window, window.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? CGPoint(x: b.midX, y: b.midY)),
            ]
            for dark in [true, false] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for (name, region, source, pointer) in cases {
                    CGWarpMouseCursorPosition(pointer)    // global, top-left origin
                    Task { _ = await RecordingSetup.run(region: region, source: source) }
                    try? await Task.sleep(for: .milliseconds(1200))
                    let file = out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png").path
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-m", file]
                    try? p.run()
                    p.waitUntilExit()
                    for v in NSApp.windows.compactMap({ $0.contentView as? SetupOverlayView }) {
                        v.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            print("SETUP SNAP done: \(out.path)")
            exit(0)
        }
    }

    /// The view drawn over `backdrop` (aspect-filled), else over a neutral grey; keeps transparency readable.
    private static func composite(_ v: NSView, over backdrop: NSImage?, to url: URL) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        let pad: CGFloat = backdrop == nil ? 24 : 0
        let size = CGSize(width: rep.size.width + pad * 2, height: rep.size.height + pad * 2)
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        guard let outRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        outRep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outRep)
        if let img = backdrop {
            let k = max(size.width / img.size.width, size.height / img.size.height)
            let s = CGSize(width: img.size.width * k, height: img.size.height * k)
            img.draw(in: CGRect(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2, width: s.width, height: s.height))
        } else {
            NSColor(white: 0.55, alpha: 1).setFill()
            CGRect(origin: .zero, size: size).fill()
        }
        rep.draw(in: CGRect(x: pad, y: pad, width: rep.size.width, height: rep.size.height), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? outRep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `DAISYSHOT_QUICK_EXPORT=<dir>` (debug defaults domain only): the Quick Export panel for a sample recording, then an
    /// MP4 exported through it into `<dir>/export`.
    static func quickExport(_ dir: String) {
        Task { @MainActor in
            let out = URL(fileURLWithPath: dir)
            let exports = out.appendingPathComponent("export", isDirectory: true)
            try? FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            Prefs.set(exports.path, .exportFolder)
            guard let pkg = try? await StudioSample.make(in: out, seconds: 4) else { exit(1) }
            StudioQuickExport.show(pkg)
            try? await Task.sleep(for: .milliseconds(1500))
            if let v = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible })?.contentView {
                save(v, NSAppearance(named: .darkAqua)!, out.appendingPathComponent("quick-export.png"))
            }
            StudioQuickExport.debugExportMP4()
            for _ in 0..<120 {
                try? await Task.sleep(for: .milliseconds(500))
                if let f = try? FileManager.default.contentsOfDirectory(atPath: exports.path), f.contains(where: { $0.hasSuffix(".mp4") }) {
                    print("QUICK EXPORT done: \(f)")
                    exit(0)
                }
            }
            print("QUICK EXPORT timed out")
            exit(1)
        }
    }

    static func studio(_ dir: String) {
        Task { @MainActor in
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-sample", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            fputs("studio snap: making sample\n", stderr)
            guard let pkg = try? await StudioSample.make(in: tmp, seconds: 8) else { exit(1) }
            fputs("studio snap: opening \(pkg.path)\n", stderr)
            VideoEditor.open(pkg)
            var found: (StudioEditor, NSWindow)?
            for _ in 0..<100 where found == nil {
                try? await Task.sleep(for: .milliseconds(100))
                for w in NSApp.windows { if let c = w.delegate as? StudioWindowController, c.editor.sources != nil { found = (c.editor, w) } }
            }
            guard let (ed, win) = found else { fputs("studio snap: no editor\n", stderr); exit(1) }
            @MainActor func snap(_ name: String, _ view: NSView?) async {
                try? await Task.sleep(for: .milliseconds(700))
                save(view, to: out.appendingPathComponent("studio-\(name).png"))
            }
            ed.seek(to: 4.5)
            for tab in [StudioEditor.Tab.cursor, .keystrokes, .background, .animations, .masks, .audio] {
                ed.selection = nil
                ed.tab = tab
                await snap("tab-\(tab.rawValue)", win.contentView)
            }
            ed.tab = .audio
            ed.edit { $0.audio.setDenoise(true, 0); $0.audio.setNormalize(true, 0) }
            for _ in 0..<50 where ed.sources?.cleanAudio[0] == nil || ed.sources?.gains["0c"] == nil { try? await Task.sleep(for: .milliseconds(100)) }
            fputs("studio snap: clean audio \(ed.sources?.cleanAudio[0] != nil), gain \(ed.sources?.gains["0c"] ?? 0)\n", stderr)
            await snap("audio-clean", win.contentView)
            if let pop = ed.timeline.debugTypingPopover() {
                try? await Task.sleep(for: .milliseconds(500))
                save(pop, NSAppearance(named: .darkAqua)!, out.appendingPathComponent("studio-typing-popover.png"))
                await snap("typing-lane", ed.timeline)
                ed.speedUpTyping(ed.typingStretches.map(\.range), speed: 4)
                await snap("typing-applied", ed.timeline)
                ed.undo()
            }
            if ed.hasCamera {
                ed.addLayout(3...6.5)
                ed.seek(to: 4.4)
                try? await Task.sleep(for: .milliseconds(800))
                ed.seek(to: 4.5)
                try? await Task.sleep(for: .milliseconds(1500))
                await snap("camera-layout", win.contentView)
                ed.undo()
                ed.seek(to: 4.5)
            }
            if let c = ed.doc.clips.first { ed.selection = .clip(c.id); await snap("clip", win.contentView) }
            ed.addMaskAtPlayhead(.blur)
            await snap("mask", win.contentView)
            ed.selection = nil
            ed.showCrop = true
            try? await Task.sleep(for: .milliseconds(800))
            await snap("crop", win.attachedSheet?.contentView)
            ed.showCrop = false
            try? await Task.sleep(for: .milliseconds(400))
            ed.showExport = true
            try? await Task.sleep(for: .milliseconds(500))
            await snap("export", win.attachedSheet?.contentView)
            print("STUDIO SNAP done: \(out.path)")
            exit(0)
        }
    }

    /// `DAISYSHOT_STUDIO_DRAG=1`: opens a Retina-sized recording in the editor and drags Padding at 60 Hz while paused,
    /// reporting how long each tick holds the main thread (what the user feels as lag).
    static func studioDrag() {
        Task { @MainActor in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-drag", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let pkg = tmp.appendingPathComponent("Sample.daisyshotvideo")
            if !FileManager.default.fileExists(atPath: pkg.appendingPathComponent("video.mp4").path) {
                guard (try? await StudioSample.make(in: tmp, seconds: 20, k: 4.725)) != nil else { exit(1) }
            }
            try? FileManager.default.removeItem(at: pkg.appendingPathComponent("project.json"))
            VideoEditor.open(pkg)
            var found: StudioEditor?
            for _ in 0..<200 where found == nil {
                try? await Task.sleep(for: .milliseconds(100))
                for w in NSApp.windows { if let c = w.delegate as? StudioWindowController, c.editor.sources != nil { found = c.editor } }
            }
            guard let ed = found else { exit(1) }
            ed.tab = .background
            ed.seek(to: 5)
            try? await Task.sleep(for: .seconds(2))
            var ticks: [Double] = []
            var last = CACurrentMediaTime()
            for i in 0..<90 {
                ed.live(\.background.padding)(0.04 + Double(i % 30) * 0.004)     // what a slider drag does
                NSApp.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded(); $0.displayIfNeeded() }
                try? await Task.sleep(for: .milliseconds(16))
                let now = CACurrentMediaTime()
                ticks.append((now - last) * 1000)
                last = now
            }
            ed.commitLive()
            let sorted = ticks.sorted()
            fputs(String(format: "DRAG tick ms: median %.0f  p90 %.0f  max %.0f  (ideal ≈ 17)\n", sorted[45], sorted[81], sorted.last!), stderr)
            exit(0)
        }
    }

    /// `DAISYSHOT_STUDIO_BENCH=1`: times one background-slider tick (new render model + preview frame) on a Retina-sized recording.
    static func studioBench() {
        Task { @MainActor in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Daisyshot-bench", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("video.mp4")
            try? await StudioSample.writeVideo(to: url, size: CGSize(width: 3024, height: 1964), seconds: 2, audio: false) { ctx, t in
                ctx.setFillColor(CGColor(gray: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 3024, height: 1964))
                ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 200 + t * 300, y: 600, width: 800, height: 500))
            }
            guard let pkg = try? StudioPackage.open(url), let src = try? await StudioSources.load(pkg) else { exit(1) }
            let wall = StudioEditor.loadImage(URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic"), maxSide: 3840)
            for kind in [BackgroundKind.gradient, .blurredWallpaper, .image] {
                var doc = StudioDocument(clips: [.init(start: 0, duration: 2)])
                doc.background.kind = kind
                var old: StudioRenderModel?
                var times: [Double] = []
                for i in 0..<12 {
                    doc.background.padding = 0.05 + Double(i) * 0.005
                    let t0 = CACurrentMediaTime()
                    let m = StudioRenderModel(doc: doc, sources: src, events: nil, cursor: nil, wallpaper: wall, customImage: wall)
                    m.reuseBackgrounds(from: old)
                    let comp = try! StudioComposer.composition(src, doc: doc)
                    let vc = StudioComposer.videoComposition(comp, model: m, renderSize: m.renderSize(maxSide: 1920), fps: 60)
                    _ = try? await StudioExportJob.frame(comp, video: vc, at: 1)
                    times.append((CACurrentMediaTime() - t0) * 1000)
                    old = m
                }
                fputs("BENCH \(kind): " + times.map { String(format: "%.0f", $0) }.joined(separator: " ") + " ms\n", stderr)
                // Pieces: decode only (same model, background cached) and render only (no decode).
                let m = old!
                let comp = try! StudioComposer.composition(src, doc: doc)
                let vc = StudioComposer.videoComposition(comp, model: m, renderSize: m.renderSize(maxSide: 1920), fps: 60)
                var t0 = CACurrentMediaTime()
                _ = try? await StudioExportJob.frame(comp, video: vc, at: 1.2)
                let decode = (CACurrentMediaTime() - t0) * 1000
                let screen = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 3024, height: 1964))
                let size = m.renderSize(maxSide: 1920)
                var fresh = 0.0, cached = 0.0, initT = 0.0
                for i in 0..<5 {
                    doc.background.padding = 0.2 + Double(i) * 0.01
                    t0 = CACurrentMediaTime()
                    let mm = StudioRenderModel(doc: doc, sources: src, events: nil, cursor: nil, wallpaper: wall, customImage: wall)
                    initT += CACurrentMediaTime() - t0
                    t0 = CACurrentMediaTime()
                    _ = StudioCompositor.context.createCGImage(mm.render(outputTime: 1, screen: screen, camera: nil, size: size), from: CGRect(origin: .zero, size: size))
                    fresh += CACurrentMediaTime() - t0
                    t0 = CACurrentMediaTime()
                    _ = StudioCompositor.context.createCGImage(mm.render(outputTime: 1, screen: screen, camera: nil, size: size), from: CGRect(origin: .zero, size: size))
                    cached += CACurrentMediaTime() - t0
                }
                fputs(String(format: "   decode+render %.0f  init %.1f  render(new bg) %.0f  render(cached bg) %.0f ms\n", decode, initT * 200, fresh * 200, cached * 200), stderr)
            }
            exit(0)
        }
    }

    private static func save(_ view: NSView?, to url: URL) {
        guard let v = view, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Menu bar strip: standard, mono recording, yellow recording, menu item glyphs.
    private static func glyphs() -> NSView {
        Prefs.set("mono", .menuBarRecordingIndicator)
        let mono = MenuBarIcon.recording
        Prefs.set("yellow", .menuBarRecordingIndicator)
        let row = NSStackView(views: [MenuBarIcon.standard, mono, MenuBarIcon.recording, MenuBarIcon.markGlyph!, MenuBarIcon.recordGlyph].map {
            let v = NSImageView(image: $0)
            v.frame.size = CGSize(width: 24, height: 24)
            return v
        })
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        row.frame.size = row.fittingSize
        return row
    }

    private static func save(_ v: NSView, _ ap: NSAppearance, _ url: URL, layout: Bool = false) {
        let w = v.window ?? NSWindow(contentRect: v.frame, styleMask: .borderless, backing: .buffered, defer: false)
        if v.window == nil { w.contentView = v }
        w.appearance = ap
        ap.performAsCurrentDrawingAppearance {
            v.layoutSubtreeIfNeeded()
            if layout { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            // Composite over a light/dark backdrop so transparent views read correctly.
            guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return }
            out.size = rep.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            NSColor(white: ap.name == .darkAqua ? 0.17 : 0.97, alpha: 1).setFill()
            CGRect(origin: .zero, size: rep.size).fill()
            rep.draw(in: CGRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            try? out.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#endif
