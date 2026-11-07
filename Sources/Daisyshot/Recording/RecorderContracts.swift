import Foundation

extension Recorder {
    /// Where the source video of a GIF recording is kept so the video editor can re-edit/re-export the GIF.
    static func gifSourceURL(for gifURL: URL) -> URL {
        recordingsFolder.appendingPathComponent("GIFSources", isDirectory: true)
            .appendingPathComponent(gifURL.deletingPathExtension().lastPathComponent).appendingPathExtension("mp4")
    }
}

extension Notification.Name {
    /// Posted with `object: Bool` (true = busy) while a long task runs (GIF conversion, export). The menu bar icon shows a busy state.
    static let daisyshotBusyDidChange = Notification.Name("DaisyshotBusyDidChange")
}
