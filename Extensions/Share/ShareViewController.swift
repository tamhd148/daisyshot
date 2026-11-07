// One binary for both share extensions (AnnotateShareExtension, PinShareExtension). The bundle identifier picks the
// daisyshot:// command. The extension is sandboxed, so it writes the shared image as a PNG into its own tmp dir and
// hands the path to the (unsandboxed) main app through the URL scheme.
import AppKit
import UniformTypeIdentifiers

@objc(DaisyshotShareViewController)
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, NSTextField(labelWithString: Self.loc("Opening in Daisyshot…"))])
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: 52)
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let provider = (extensionContext?.inputItems.first as? NSExtensionItem)?.attachments?.first
        guard let provider else { return fail("No image to share") }
        Self.loadImageData(provider) { data in
            DispatchQueue.main.async { self.handOff(data) }
        }
    }

    private func handOff(_ data: Data?) {
        guard let data, let png = Self.png(from: data) else { return fail("Could not read the image") }
        // The app only accepts hand-offs from ~/Library/Containers/app.daisyshot.mac.*/Data/tmp (sandboxed home = Data),
        // and deletes the file once read.
        let tmp = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("Daisyshot-\(UUID().uuidString).png")
        let command = Bundle.main.bundleIdentifier?.hasSuffix("PinShareExtension") == true ? "share-extension-pin" : "share-extension-annotate"
        var c = URLComponents()
        c.scheme = "daisyshot"
        c.host = command
        c.queryItems = [URLQueryItem(name: "filepath", value: file.path)]
        do { try png.write(to: file) } catch { return fail(error.localizedDescription) }
        guard let url = c.url, NSWorkspace.shared.open(url) else { return fail("Daisyshot is not installed") }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func fail(_ message: String) {
        extensionContext?.cancelRequest(withError: NSError(domain: "app.daisyshot.share", code: 1,
                                                           userInfo: [NSLocalizedDescriptionKey: Self.loc(message)]))
    }

    /// The app's merged Localizable.strings is copied into each appex (English text is the key).
    static func loc(_ s: String) -> String { Bundle.main.localizedString(forKey: s, value: s, table: nil) }

    /// Image bytes from the attachment: an image representation if there is one, else the file it points at.
    static func loadImageData(_ p: NSItemProvider, _ done: @escaping @Sendable (Data?) -> Void) {
        if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = p.loadDataRepresentation(for: .image) { data, _ in done(data) }
        } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: URL.self) { url, _ in done(url.flatMap { try? Data(contentsOf: $0) }) }
        } else {
            done(nil)
        }
    }

    static func png(from data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, CGImageSourceCopyPropertiesAtIndex(src, 0, nil))
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}
