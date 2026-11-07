import AppKit

/// Entry points for the Annotate editor. Each call opens a new editor window.
@MainActor
enum AnnotateWindowController {
    static func open(shot: Shot, fileURL: URL? = nil) {
        AnnotateEditor.present(AutoRedact.editableDoc(for: shot.image) ?? DocState(image: shot.image, scale: shot.scale), fileURL: fileURL, documentURL: nil)
    }

    /// Opens a `.daisyshot` document with its annotations still editable.
    static func open(documentURL: URL) {
        do {
            let d = try AnnotateDocument.load(documentURL)
            guard d.version <= AnnotateDocument.currentVersion, let state = d.state else { throw CocoaError(.fileReadCorruptFile) }
            AnnotateEditor.present(state, fileURL: nil, documentURL: documentURL)
        } catch {
            Toast.show("Couldn't open %@: %@".loc(documentURL.lastPathComponent, error.localizedDescription), isError: true)
        }
    }
}
