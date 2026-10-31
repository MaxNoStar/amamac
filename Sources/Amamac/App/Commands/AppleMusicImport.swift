import AmamacLibrary
import AppKit

/// Tools › Import Statistics from Apple Music (also offered in Settings › Metadata).
@MainActor
final class AppleMusicImport: NSObject {
    private unowned let env: AppEnvironment

    init(env: AppEnvironment) { self.env = env }

    @objc func importAppleMusicStatistics(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml, .propertyList]
        panel.message = "Choose the library file exported from Music (File › Library › Export Library…)."
        panel.prompt = "Import"
        let overwrite = NSButton(checkboxWithTitle: "Replace ratings that are already set", target: nil, action: nil)
        panel.accessoryView = overwrite
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let replace = overwrite.state == .on
        let db = env.database
        let token = env.status.beginTask("Importing statistics")
        Task {
            defer { env.status.endTask(token) }
            do {
                let entries = try await Task.detached { try AppleMusicImporter.parse(url) }.value
                let report = try await AppleMusicImporter.apply(entries, to: db, overwriteRatings: replace)
                let ids = (try? await db.trackIdsWithStatistics()) ?? []
                env.actions.tracksChanged(ids: ids)
                let alert = NSAlert()
                alert.messageText = "Statistics imported"
                alert.informativeText = "\(report.entries) tracks in the export, \(report.matched) found in the collection, " +
                    "\(report.updated) updated, \(report.unmatched) not found."
                alert.runModal()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
