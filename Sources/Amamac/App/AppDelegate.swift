import AmamacModels
import AppKit

/// The app lifecycle: builds the environment and the main window at launch, saves the session at
/// quit, and opens files and amamac:// links. Menu commands live in the controllers under
/// `App/Commands`; their items keep a nil target and reach them through the responder chain,
/// which ends here and is forwarded below.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var env: AppEnvironment!
    private var mainWindow: MainWindowController!
    private var desktop: DesktopIntegration?
    private var session: SessionController?
    private var nowPlaying: NowPlayingController?
    /// Written once at launch on the main thread; read there by the Objective-C runtime.
    nonisolated(unsafe) private var commandTargets: [NSObject] = []
    /// Files and links that open Amamac arrive before `applicationDidFinishLaunching`; they wait
    /// here until the environment exists and the saved playlist is back.
    private var pendingURLs: [URL]? = []

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.current
        let dataDir = options.dataDir ?? AppEnvironment.defaultDataDirectory()
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let defaults: UserDefaults
        if options.isAutomation || options.dataDir != nil {
            // Automation and alternate data directories never touch the user's preferences.
            let suite = "local.amamac.automation"
            UserDefaults().removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
        } else {
            defaults = .standard
        }
        #if DEBUG
        let http = options.snapshotDir != nil ? SnapshotRunner.stubNetwork() : .ephemeral
        #else
        let http = URLSessionConfiguration.ephemeral
        #endif
        do {
            env = try AppEnvironment(dataDirectory: dataDir, defaults: defaults, httpConfiguration: http)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Amamac could not open its collection database."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        _ = env.equalizer
        if options.snapshotDir != nil { env.settings.enabledApplets = AppletKind.allCases.map(\.rawValue) }
        NSApp.mainMenu = MainMenu.build()
        #if DEBUG
        if options.snapshotDir != nil { SnapshotRunner.applyAppearance() }
        #endif
        mainWindow = MainWindowController(env: env)
        let tools = ToolsCommands(env: env)
        let setup = CollectionSetup(env: env)
        commandTargets = [PlaybackCommands(env: env), PlaylistCommands(env: env, window: mainWindow),
                          ViewCommands(env: env, window: mainWindow), tools, setup, AppleMusicImport(env: env)]
        let session = SessionController(env: env)
        self.session = session

        #if DEBUG
        if let perfOutput = options.perfOutput {
            PerfRunner(env: env, window: mainWindow, output: perfOutput).run()
            return
        }
        if let snapshotDir = options.snapshotDir {
            SnapshotRunner(env: env, window: mainWindow, output: snapshotDir, layoutDump: options.dumpLayout).run()
            return
        }
        #endif

        mainWindow.showWindow(nil)
        desktop = DesktopIntegration(env: env, mainWindow: mainWindow)
        tools.desktop = desktop
        nowPlaying = NowPlayingController(env: env)
        session.observe()
        session.restore { [weak self] in
            guard let self, let urls = pendingURLs else { return }
            pendingURLs = nil
            if !urls.isEmpty { application(NSApp, open: urls) }
        }
        env.podcasts.startAutoUpdate()
        Task.detached(priority: .background) { [http = env.http] in http.pruneCache() }
        if env.collectionFolders.isEmpty && !env.settings.bool(AppSettings.Key.firstRunDone) {
            DispatchQueue.main.async { setup.runFirstRunSetup() }
        } else {
            env.scanCollection()
            env.startWatching()
        }
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard env != nil, LaunchOptions.current.snapshotDir == nil else { return }
        session?.save()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.showWindow(nil) }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if pendingURLs != nil {
            pendingURLs?.append(contentsOf: urls)
            return
        }
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { env.actions.addURLs(files, mode: .appendAndPlay) }
        for url in urls where url.scheme?.lowercased() == "amamac" { LinkHandler.open(url, env: env) }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if let item = env.player.currentItem, env.player.isActive {
            let title = NSMenuItem(title: [item.streamTitle ?? item.track.displayTitle, item.track.artist]
                .filter { !$0.isEmpty }.joined(separator: " – "), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            menu.addItem(.separator())
        }
        let playing = env.player.state == .playing || env.player.state == .buffering
        menu.addItem(withTitle: playing ? "Pause" : "Play", action: #selector(PlaybackCommands.playPause(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Next Track", action: #selector(PlaybackCommands.nextTrack(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Previous Track", action: #selector(PlaybackCommands.previousTrack(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: Command forwarding

    nonisolated private func commandTarget(for selector: Selector) -> NSObject? {
        guard Thread.isMainThread else { return nil }
        return commandTargets.first { $0.responds(to: selector) }
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || commandTarget(for: aSelector) != nil
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        commandTarget(for: aSelector) ?? super.forwardingTarget(for: aSelector)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard env != nil else { return false }
        guard let action = menuItem.action, let target = commandTarget(for: action) as? NSMenuItemValidation else { return true }
        return target.validateMenuItem(menuItem)
    }
}
