import AppKit
import Quartz

/// Shared Quick Look data source. Windows that can show previews subclass `QuickLookWindow` / `QuickLookPanel`
/// so the preview panel finds a controller in the responder chain (the documented way to drive `QLPreviewPanel`).
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private(set) var urls: [URL] = []

    static var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    /// Shows `urls` (or hides the panel if it already shows them) on behalf of `window`, which must be a Quick Look window.
    static func toggle(_ urls: [URL], from window: NSWindow?) {
        guard !urls.isEmpty else { return }
        if isVisible, shared.urls == urls { QLPreviewPanel.shared().orderOut(nil); return }
        shared.urls = urls
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = 0   // the old index may be past the end of the new list
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    static func hide() { if isVisible { QLPreviewPanel.shared().orderOut(nil) } }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            // `toggle` may have swapped in a shorter list while the panel still points past its end.
            guard urls.indices.contains(index) else { return urls.first.map { $0 as NSURL } }
            return urls[index] as NSURL
        }
    }

    fileprivate func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
    }

    fileprivate func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// Floating panel that can host the Quick Look preview (Quick Access cards, pins).
class QuickLookPanel: FloatingPanel {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !QuickLook.shared.urls.isEmpty }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.end(panel) }
}

/// Regular window that can host the Quick Look preview (Capture History).
class QuickLookWindow: NSWindow {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !QuickLook.shared.urls.isEmpty }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLook.shared.end(panel) }
}
