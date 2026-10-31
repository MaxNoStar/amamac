import AmamacBase
import AppKit

/// First-run folder choice and Tools › Collection Folders.
@MainActor
final class CollectionSetup: NSObject, NSMenuItemValidation {
    private unowned let env: AppEnvironment

    init(env: AppEnvironment) { self.env = env }

    func runFirstRunSetup() {
        env.settings.set(true, AppSettings.Key.firstRunDone)
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        let alert = NSAlert()
        alert.messageText = "Where is your music?"
        alert.informativeText = "Amamac builds its collection from the folders you choose. You can change them later with Tools › Collection Folders."
        alert.addButton(withTitle: "Use \(music.lastPathComponent) Folder")
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            env.setCollectionFolders([music.path])
            env.scanCollection()
        case .alertSecondButtonReturn:
            chooseCollectionFolders(nil)
        default:
            break
        }
    }

    @objc func chooseCollectionFolders(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Use as Collection"
        panel.message = "Choose the folders that make up your collection. Folders already in the collection: " +
            (env.collectionFolders.map(\.path).joined(separator: ", ").nilIfEmpty ?? "none")
        guard panel.runModal() == .OK else { return }
        let paths = env.collectionFolders.map(\.path) + panel.urls.map(\.path)
        env.setCollectionFolders(Array(NSOrderedSet(array: paths)) as? [String] ?? paths)
        env.scanCollection()
    }

    @objc func removeCollectionFolders(_ sender: Any?) {
        let folders = env.collectionFolders
        guard !folders.isEmpty else { return }
        guard Confirm.ask("Remove all collection folders?",
                          info: folders.map(\.path).joined(separator: "\n") +
                              "\n\nTracks stay on disk; their statistics are kept until the next full rescan.",
                          action: "Remove") else { return }
        env.setCollectionFolders([])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(removeCollectionFolders(_:)) { return !env.collectionFolders.isEmpty }
        return true
    }
}
