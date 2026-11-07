import AppKit

/// Remappable in-editor (non-global) shortcuts for the Annotate and Video editors.
/// Editors declare their items (`EditorShortcuts.annotate` in Annotate/AnnotateShortcuts.swift, `.video` in
/// Recording/StudioShortcuts.swift) and test key events with `EditorShortcuts.matches(event, id)`.
/// The Shortcuts settings pane lists both groups and lets the user rebind them (stored as "editorShortcut.<id>").
enum EditorShortcuts {
    struct Item: Identifiable {
        let id: String          // e.g. "annotate.rectangle"
        let title: String       // e.g. "Rectangle"
        let defaultShortcut: Shortcut?
    }

    static func shortcut(_ id: String) -> Shortcut? {
        if let data = Prefs.d.data(forKey: "editorShortcut." + id) { return try? JSONDecoder().decode(Shortcut?.self, from: data) }
        return (annotate + video).first { $0.id == id }?.defaultShortcut
    }

    static func set(_ s: Shortcut?, for id: String) {
        Prefs.d.set(try? JSONEncoder().encode(s), forKey: "editorShortcut." + id)
    }

    static func reset(_ id: String) { Prefs.d.removeObject(forKey: "editorShortcut." + id) }

    /// True when `event` (keyDown) matches the current binding for `id`. Modifiers compared exactly (⌘⌥⌃⇧).
    static func matches(_ event: NSEvent, _ id: String) -> Bool {
        guard let s = shortcut(id) else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        return UInt32(event.keyCode) == s.keyCode && mods == s.flags.intersection([.command, .option, .control, .shift])
    }

    /// Convenience for building defaults: `key(kVK_ANSI_R)`, `key(kVK_ANSI_S, [.command])`.
    static func key(_ code: Int, _ mods: NSEvent.ModifierFlags = []) -> Shortcut {
        Shortcut(keyCode: UInt32(code), modifiers: mods.rawValue)
    }
}
