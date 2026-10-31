import AppKit
import AmamacCore

/// Edits the collection filter text. (The attribute-builder version arrives with M4.)
enum EditFilterDialog {
    @MainActor
    static func show(initial: String, relativeTo window: NSWindow?, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Edit Filter"
        alert.informativeText = "Words match title, artist, album, genre and more. Use field:value, field:>value, " +
            "OR between alternatives and -word to exclude (e.g. artist:beatles year:<1970 -live)."
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}
