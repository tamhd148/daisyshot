import AppKit
import Carbon.HIToolbox

/// Video editor's remappable shortcuts. Esc, Delete and undo/redo stay fixed.
extension EditorShortcuts {
    static let video: [Item] = [
        Item(id: "video.playPause", title: "Play / Pause", defaultShortcut: key(kVK_Space)),
        Item(id: "video.start", title: "Move Playhead to Start", defaultShortcut: key(kVK_LeftArrow, [.command])),
        Item(id: "video.end", title: "Move Playhead to End", defaultShortcut: key(kVK_RightArrow, [.command])),
        Item(id: "video.nextEdge", title: "Jump to Next Clip Edge", defaultShortcut: key(kVK_DownArrow)),
        Item(id: "video.previousEdge", title: "Jump to Previous Clip Edge", defaultShortcut: key(kVK_UpArrow)),
        Item(id: "video.nextFrame", title: "Move Playhead to Next Frame", defaultShortcut: key(kVK_RightArrow)),
        Item(id: "video.previousFrame", title: "Move Playhead to Previous Frame", defaultShortcut: key(kVK_LeftArrow)),
        Item(id: "video.forward10", title: "Move Playhead Forward 10 Frames", defaultShortcut: key(kVK_RightArrow, [.shift])),
        Item(id: "video.back10", title: "Move Playhead Back 10 Frames", defaultShortcut: key(kVK_LeftArrow, [.shift])),
        Item(id: "video.playReverse", title: "Play Backwards", defaultShortcut: key(kVK_ANSI_J)),
        Item(id: "video.pause", title: "Pause", defaultShortcut: key(kVK_ANSI_K)),
        Item(id: "video.playForward", title: "Play Forward / Faster", defaultShortcut: key(kVK_ANSI_L)),
        Item(id: "video.splitClip", title: "Split Clip at Playhead", defaultShortcut: key(kVK_ANSI_B, [.command])),
        Item(id: "video.splitZoom", title: "Split Zoom at Playhead", defaultShortcut: key(kVK_ANSI_B, [.command, .shift])),
        Item(id: "video.zoomIn", title: "Zoom Timeline In", defaultShortcut: key(kVK_ANSI_Equal, [.command])),
        Item(id: "video.zoomOut", title: "Zoom Timeline Out", defaultShortcut: key(kVK_ANSI_Minus, [.command])),
        Item(id: "video.fitTimeline", title: "Fit Timeline to View", defaultShortcut: key(kVK_ANSI_Z, [.shift])),
        Item(id: "video.fullScreen", title: "Toggle Full Screen", defaultShortcut: key(kVK_ANSI_F, [.command, .control])),
        Item(id: "video.exportFrame", title: "Export Current Frame as Image", defaultShortcut: key(kVK_ANSI_E, [.command, .shift])),
        Item(id: "video.export", title: "Export Video", defaultShortcut: key(kVK_ANSI_E, [.command])),
        Item(id: "video.cutTool", title: "Cut Tool", defaultShortcut: key(kVK_ANSI_C)),
        Item(id: "video.selectionTool", title: "Selection Tool", defaultShortcut: key(kVK_ANSI_V)),
        Item(id: "video.loop", title: "Loop Playback", defaultShortcut: key(kVK_ANSI_L, [.command])),
        Item(id: "video.toggleDisabled", title: "Turn Selected Zoom, Mask or Layout Off / On", defaultShortcut: key(kVK_ANSI_D)),
        Item(id: "video.deleteToCut", title: "Delete Back to Previous Cut", defaultShortcut: key(kVK_ANSI_X)),
        Item(id: "video.zoomFollow", title: "Selected Zoom: Follow Cursor", defaultShortcut: key(kVK_ANSI_A)),
        Item(id: "video.zoomManual", title: "Selected Zoom: Manual", defaultShortcut: key(kVK_ANSI_M)),
        Item(id: "video.previewOnly", title: "Preview Only (Hide Sidebar and Timeline)", defaultShortcut: key(kVK_Return, [.command, .shift])),
        Item(id: "video.exportLast", title: "Export with Last Settings", defaultShortcut: key(kVK_ANSI_S, [.command, .option])),
        Item(id: "video.exportLastCopy", title: "Export with Last Settings and Copy", defaultShortcut: key(kVK_ANSI_C, [.command, .option])),
    ]

    /// Tooltip text with the current binding: "Split Clip at Playhead (⌘B)".
    static func help(_ title: String, _ id: String) -> String {
        shortcut(id).map { "\(title.loc) (\($0.display))" } ?? title.loc
    }
}
