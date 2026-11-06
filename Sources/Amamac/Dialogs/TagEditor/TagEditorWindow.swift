import AmamacDatabase
import AppKit
import SwiftUI

/// Opens Edit Track Details windows. Closing one with unsaved changes asks first.
@MainActor
enum TagEditorWindow {
    /// Returns the editor's model (snapshot runs drive it).
    @discardableResult
    static func show(tracks: [TrackWithStatistics], env: AppEnvironment) -> TagEditorModel? {
        guard !tracks.isEmpty else { return nil }
        let model = TagEditorModel(env: env, tracks: tracks)
        let host = NSHostingController(rootView: TagEditorView(model: model, covers: env.coverImages))
        let window = NSWindow(contentViewController: host)
        window.title = tracks.count == 1 ? "Edit Track Details" : "Edit Track Details (\(tracks.count) tracks)"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 680, height: 740))
        window.contentMinSize = NSSize(width: 640, height: 600)
        let guardian = CloseGuard(model: model)
        window.delegate = guardian
        window.center()
        model.onClose = { [weak window] in window?.close() }
        model.onRequestClose = { [weak window] in window?.performClose(nil) }
        OpenWindows.retain(window)
        guardians[ObjectIdentifier(window)] = guardian
        let id = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = guardians.removeValue(forKey: id) }
        }
        window.makeKeyAndOrderFront(nil)
        return model
    }

    /// Window delegates (an NSWindow holds its delegate weakly).
    private static var guardians: [ObjectIdentifier: CloseGuard] = [:]

    /// Asks before a window with unsaved changes closes: Save, Cancel or Don't Save.
    final class CloseGuard: NSObject, NSWindowDelegate {
        let model: TagEditorModel

        init(model: TagEditorModel) { self.model = model }

        func windowShouldClose(_ window: NSWindow) -> Bool {
            if model.isSaving { return false }
            guard model.hasChanges else { return true }
            let alert = NSAlert()
            let count = model.tracks.count
            alert.messageText = count == 1 ? "Save changes to “\(model.tracks[0].displayTitle)”?" : "Save changes to \(count) tracks?"
            alert.informativeText = "Your changes are lost if you don’t save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let dontSave = alert.addButton(withTitle: "Don’t Save")
            dontSave.keyEquivalent = "d"
            dontSave.keyEquivalentModifierMask = .command
            dontSave.hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [model] response in
                switch response {
                case .alertFirstButtonReturn: model.save()
                case .alertThirdButtonReturn: model.onClose?()
                default: break
                }
            }
            return false
        }
    }
}
