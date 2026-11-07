import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Annotate editor's remappable shortcuts (the "Annotate" shortcut group). Tool ids are "annotate.<AnnotateTool.rawValue>".
/// Fixed (not listed): Esc, Delete, arrows, Return, Space-pan, ⌘Z/⇧⌘Z, ⌘V, ⌘X, ⌘W, zoom (⌘= ⌘- ⌘0 ⌘1), ⌘[ ⌘].
extension EditorShortcuts {
    static let annotate: [Item] = {
        let k = EditorShortcuts.key
        let tools: [(AnnotateTool, Int)] = [
            (.move, kVK_ANSI_V), (.rectangle, kVK_ANSI_R), (.filledRectangle, kVK_ANSI_F), (.ellipse, kVK_ANSI_E), (.line, kVK_ANSI_L),
            (.arrow, kVK_ANSI_A), (.text, kVK_ANSI_T), (.redact, kVK_ANSI_P), (.spotlight, kVK_ANSI_H), (.counter, kVK_ANSI_C),
            (.pencil, kVK_ANSI_D), (.highlighter, kVK_ANSI_M),
        ]
        return tools.map { Item(id: $0.0.shortcutID, title: $0.0.title + " Tool", defaultShortcut: k($0.1, [])) } + [
            Item(id: "annotate.background", title: "Background Tool", defaultShortcut: k(kVK_ANSI_B, [])),
            Item(id: AnnotateTool.crop.shortcutID, title: "Crop & Resize Tool", defaultShortcut: k(kVK_ANSI_K, [])),
            Item(id: "annotate.increaseSize", title: "Increase Tool Size", defaultShortcut: k(kVK_ANSI_Equal, [])),
            Item(id: "annotate.decreaseSize", title: "Decrease Tool Size", defaultShortcut: k(kVK_ANSI_Minus, [])),
            Item(id: "annotate.autoRedact", title: "Auto Redact", defaultShortcut: k(kVK_ANSI_R, [.command, .shift])),
            Item(id: "annotate.duplicate", title: "Duplicate Object", defaultShortcut: k(kVK_ANSI_D, [.command])),
            Item(id: "annotate.copyObject", title: "Copy Object to Clipboard", defaultShortcut: k(kVK_ANSI_C, [.command])),
            Item(id: "annotate.copyScreenshot", title: "Copy Screenshot to Clipboard", defaultShortcut: k(kVK_ANSI_C, [.command, .shift])),
            Item(id: "annotate.addFromFile", title: "Add Screenshot From File", defaultShortcut: k(kVK_ANSI_I, [.command])),
            Item(id: "annotate.addNewScreenshot", title: "Add New Screenshot", defaultShortcut: k(kVK_ANSI_I, [.command, .shift])),
            Item(id: "annotate.save", title: "Save", defaultShortcut: k(kVK_ANSI_S, [.command])),
            Item(id: "annotate.saveAs", title: "Save As", defaultShortcut: k(kVK_ANSI_S, [.command, .shift])),
            Item(id: "annotate.print", title: "Print", defaultShortcut: k(kVK_ANSI_P, [.command])),
            Item(id: "annotate.pin", title: "Pin to the Screen", defaultShortcut: nil),
            Item(id: "annotate.done", title: "Done (Save and Close)", defaultShortcut: k(kVK_Return, [.command])),
        ]
    }()

    /// " (⇧⌘C)" for tooltips, or "" when unbound.
    static func hint(_ id: String) -> String { shortcut(id).map { " (\($0.display))" } ?? "" }

    /// The binding as a SwiftUI shortcut (menus), nil when unbound or not representable.
    static func swiftUI(_ id: String) -> KeyboardShortcut? {
        guard let s = shortcut(id), let k = s.menuKeyEquivalent?.first else { return nil }
        var m: SwiftUI.EventModifiers = []
        if s.flags.contains(.command) { m.insert(.command) }
        if s.flags.contains(.shift) { m.insert(.shift) }
        if s.flags.contains(.option) { m.insert(.option) }
        if s.flags.contains(.control) { m.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(k), modifiers: m)
    }

    /// Like `matches`, but output actions tolerate an extra ⌥ (it turns them into "… and exit"), and the default "="
    /// size key also fires as "+" (⇧=) and on the keypad.
    static func annotateMatches(_ e: NSEvent, _ id: String) -> Bool {
        if matches(e, id) { return true }
        guard let s = shortcut(id) else { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if ["annotate.done", "annotate.copyScreenshot", "annotate.pin"].contains(id), mods.contains(.option), !s.flags.contains(.option), UInt32(e.keyCode) == s.keyCode,
           mods.subtracting(.option) == s.flags.intersection([.command, .control, .shift]) { return true }
        if id == "annotate.increaseSize", s == key(kVK_ANSI_Equal) {
            return (e.keyCode == kVK_ANSI_Equal && mods == .shift) || (e.keyCode == kVK_ANSI_KeypadPlus && mods.isEmpty)
        }
        if id == "annotate.decreaseSize", s == key(kVK_ANSI_Minus) { return e.keyCode == kVK_ANSI_KeypadMinus && mods.isEmpty }
        return false
    }
}

extension AnnotateTool {
    var shortcutID: String { "annotate." + rawValue }
}
