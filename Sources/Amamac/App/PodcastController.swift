import AmamacPodcasts
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// App-side podcast state: subscriptions, new-episode counts, running downloads and the
/// automatic update timer.
@MainActor
@Observable
final class PodcastController {
    /// Rebuilt on use so a changed download folder applies at once.
    var service: PodcastService {
        PodcastService(database: env.database, http: env.http, downloadFolder: Self.downloadFolder(env))
    }
    private(set) var channels: [PodcastChannel] = []
    private(set) var newCounts: [Int64: Int] = [:]
    /// Running downloads: episode id → fraction done.
    private(set) var downloads: [Int64: Double] = [:]
    private(set) var updating = false
    /// Bumped whenever subscriptions or episodes change.
    private(set) var revision = 0

    @ObservationIgnored private unowned let env: AppEnvironment
    @ObservationIgnored private var timer: Timer?

    init(env: AppEnvironment) {
        self.env = env
        NotificationCenter.default.addObserver(forName: PodcastService.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    /// The Podcasts folder in Music, or one inside the data directory for test and snapshot runs.
    static func downloadFolder(_ env: AppEnvironment) -> URL {
        if let custom = env.settings.string(AppSettings.Key.podcastFolder), !custom.isEmpty { return URL(fileURLWithPath: custom) }
        if LaunchOptions.current.dataDir != nil { return env.dataDirectory.appendingPathComponent("Podcasts") }
        return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Podcasts")
    }

    var totalNew: Int { newCounts.values.reduce(0, +) }

    func reload() {
        channels = service.channels()
        newCounts = service.newCounts()
        revision += 1
    }

    func channel(_ id: Int64) -> PodcastChannel? { channels.first { $0.id == id } }

    // MARK: Updating

    /// Checks feeds every `podcastUpdateMinutes` (channels with automatic updates only).
    func startAutoUpdate() {
        timer?.invalidate()
        let minutes = max(5, env.settings.int(AppSettings.Key.podcastUpdateMinutes))
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAll(automatic: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // A first check shortly after launch.
        Task {
            try? await Task.sleep(for: .seconds(20))
            updateAll(automatic: true)
        }
    }

    func updateAll(automatic: Bool = false) {
        guard !updating, !channels.isEmpty else { return }
        updating = true
        let token = env.status.beginTask("Updating podcasts")
        Task {
            let result = await service.updateAll(includeManual: !automatic)
            env.status.endTask(token)
            updating = false
            handleNewEpisodes(result.added)
            if !result.failures.isEmpty {
                env.status.showMessage("Could not update: \(result.failures.joined(separator: ", "))")
            } else if !automatic || !result.added.isEmpty {
                env.status.showMessage(result.added.isEmpty ? "No new podcast episodes." : "\(result.added.count) new podcast episode\(result.added.count == 1 ? "" : "s").")
            }
        }
    }

    func update(_ channel: PodcastChannel) {
        guard let id = channel.id else { return }
        let token = env.status.beginTask("Updating \(channel.title)")
        Task {
            do {
                let added = try await service.update(channelId: id)
                handleNewEpisodes(added)
                env.status.showMessage(added.isEmpty ? "No new episodes of \(channel.title)." : "\(added.count) new episode\(added.count == 1 ? "" : "s") of \(channel.title).")
            } catch {
                env.status.showMessage("Could not update \(channel.title): \(error.localizedDescription)")
            }
            env.status.endTask(token)
        }
    }

    /// New episodes of channels set to download automatically are fetched right away.
    private func handleNewEpisodes(_ added: [PodcastEpisode]) {
        for episode in added where channel(episode.channelId)?.downloadPolicy == .automatic { download(episode) }
    }

    // MARK: Subscriptions

    @discardableResult
    func subscribe(_ url: URL) async -> PodcastChannel? {
        let token = env.status.beginTask("Subscribing")
        defer { env.status.endTask(token) }
        do {
            let channel = try await service.subscribe(feedURL: url)
            env.status.showMessage("Subscribed to \(channel.title).")
            return channel
        } catch {
            env.status.showMessage("Could not subscribe: \(error.localizedDescription)")
            return nil
        }
    }

    func isSubscribed(feedURL: String) -> Bool { channels.contains { $0.feedURL == feedURL } }

    func unsubscribe(_ channel: PodcastChannel) {
        guard let id = channel.id else { return }
        let alert = NSAlert()
        alert.messageText = "Unsubscribe from “\(channel.title)”?"
        alert.informativeText = "Its episodes disappear from the Podcasts list."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Also delete downloaded episodes"
        alert.addButton(withTitle: "Unsubscribe")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        service.unsubscribe(channelId: id, deleteDownloads: alert.suppressionButton?.state == .on)
    }

    func importOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let token = env.status.beginTask("Importing podcasts")
        Task {
            do {
                let result = try await service.importOPML(url)
                env.status.showMessage("Subscribed to \(result.added) podcast\(result.added == 1 ? "" : "s")"
                                       + (result.failed.isEmpty ? "." : "; \(result.failed.count) could not be read."))
            } catch {
                env.status.showMessage("Could not read the OPML file: \(error.localizedDescription)")
            }
            env.status.endTask(token)
        }
    }

    func exportOPML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Podcasts.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try service.exportOPML(to: url)
        } catch {
            env.status.showMessage("Could not export: \(error.localizedDescription)")
        }
    }

    // MARK: Episodes

    func download(_ episode: PodcastEpisode) {
        guard let id = episode.id, downloads[id] == nil, !episode.isDownloaded else { return }
        downloads[id] = 0
        let token = env.status.beginTask("Downloading \(episode.title)")
        let status = env.status
        Task {
            do {
                try await service.download(episode) { fraction in
                    Task { @MainActor in
                        guard self.downloads[id] != nil else { return }
                        self.downloads[id] = fraction
                        status.update(token, phase: "", fraction: fraction)
                    }
                }
            } catch {
                env.status.showMessage("Could not download \(episode.title): \(error.localizedDescription)")
            }
            downloads[id] = nil
            env.status.endTask(token)
        }
    }

    func play(_ episodes: [PodcastEpisode], mode: LibraryActions.AddMode) {
        let items = episodes.compactMap { $0.playlistItem(channel: channel($0.channelId)) }
        guard !items.isEmpty else { return }
        env.actions.add(items, mode: mode)
        if mode == .appendAndPlay || mode == .replace { service.setPlayed(episodes.compactMap(\.id), played: true) }
    }
}
