import AmamacModels
import AppKit
import UniformTypeIdentifiers

/// A yes/no alert. Returns true when the user picks `action`.
@MainActor
enum Confirm {
    static func ask(_ message: String, info: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// An alert with one text field. Returns the text, or nil when cancelled.
@MainActor
enum TextPrompt {
    static func ask(_ message: String, info: String, text: String = "", placeholder: String? = nil,
                    width: CGFloat, action: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

extension PlaylistFileFormat {
    /// Open and save panel types for the playlist file formats.
    static var contentTypes: [UTType] { allCases.compactMap { UTType(filenameExtension: $0.rawValue) } }
}
