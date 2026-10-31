import AmamacDatabase
import AmamacDynamic
import AppKit
import SwiftUI

/// Dynamic mode: the playlist keeps a few played tracks before the current one and tops itself
/// up with tracks chosen by the active dynamic playlist's biases.
@MainActor
@Observable
final class DynamicModeController {
    private(set) var active: DynamicPlaylist?
    private(set) var isWorking = false
    var previousCount: Int {
        didSet { env.settings.set(previousCount, AppSettings.Key.dynamicPrevious) }
    }
    var upcomingCount: Int {
        didSet {
            env.settings.set(upcomingCount, AppSettings.Key.dynamicUpcoming)
            maintain()
        }
    }
    var allowDuplicates: Bool {
        didSet { env.settings.set(allowDuplicates, AppSettings.Key.dynamicAllowDuplicates) }
    }

    @ObservationIgnored private unowned let env: AppEnvironment
    @ObservationIgnored private var universe: TrackUniverse?
    @ObservationIgnored private var maintaining = false

    init(env: AppEnvironment) {
        self.env = env
        previousCount = env.settings.int(AppSettings.Key.dynamicPrevious)
        upcomingCount = env.settings.int(AppSettings.Key.dynamicUpcoming)
        allowDuplicates = env.settings.bool(AppSettings.Key.dynamicAllowDuplicates)
        env.player.addListener { [weak self] event in
            if event == .trackChanged { self?.maintain() }
        }
        NotificationCenter.default.addObserver(forName: AppEnvironment.collectionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.universe = nil }
        }
    }

    /// Turns dynamic mode back on after a relaunch.
    func resumeIfNeeded() {
        let id = env.settings.int(AppSettings.Key.activeDynamicPlaylist)
        guard id > 0, let playlist = GeneratorStore(database: env.database).dynamicPlaylists().first(where: { $0.id == Int64(id) }) else { return }
        start(playlist, repopulate: false)
    }

    func start(_ playlist: DynamicPlaylist, repopulate: Bool = true) {
        active = playlist
        universe = nil
        env.settings.set(Int(playlist.id ?? 0), AppSettings.Key.activeDynamicPlaylist)
        // Dynamic mode always walks the playlist in order.
        env.navigator.progression = .standard
        if repopulate { self.repopulate() } else { maintain() }
    }

    func stop() {
        active = nil
        env.settings.set(0, AppSettings.Key.activeDynamicPlaylist)
        env.navigator.progression = env.settings.trackProgression
        env.player.updateUpcoming()
    }

    /// The active playlist was edited: pick up the new biases for future tracks.
    func definitionChanged(_ playlist: DynamicPlaylist) {
        guard active?.id == playlist.id else { return }
        active = playlist
        universe = nil
    }

    /// The playing item while playback is active, otherwise the playlist's active item (the player
    /// keeps its last item after Stop).
    private var activeIndex: Int? {
        let player = env.player
        let id = (player.isActive ? player.currentItem?.id : nil) ?? env.playlist.activeID
        return id.flatMap { env.playlist.index(of: $0) }
    }

    /// Replaces everything after the current track with new picks.
    func repopulate() {
        guard active != nil else { return }
        let order = env.playlist.order
        let keepUntil = activeIndex.map { $0 + 1 } ?? 0
        let drop = Set(order[keepUntil...])
        if !drop.isEmpty { env.playlist.remove(drop) }
        maintain()
    }

    /// Trims played tracks beyond `previousCount` and adds tracks until `upcomingCount` follow.
    func maintain() {
        guard let active, !maintaining else { return }
        maintaining = true
        Task {
            defer { maintaining = false }
            if universe == nil {
                isWorking = true
                universe = try? await TrackUniverse.load(env.database, queries: active.bias.searchQueries)
                isWorking = false
            }
            guard let universe, self.active == active else { return }
            let model = env.playlist
            if let index = activeIndex, index > previousCount {
                model.remove(Set(model.order.prefix(index - previousCount)))
            }
            let index = activeIndex ?? -1
            let upcoming = model.count - index - 1
            guard upcoming < upcomingCount else { return }
            let items = model.items
            let history = items.prefix(max(0, index + 1)).compactMap(\.track.id)
            let existing = Set(items.compactMap(\.track.id))
            let generator = DynamicGenerator(bias: active.bias, universe: universe)
            var rng = SystemRandomNumberGenerator()
            let ids = generator.generate(count: upcomingCount - upcoming, history: Array(history), existing: existing,
                                         allowDuplicates: allowDuplicates, rng: &rng)
            let tracks = (try? await env.database.tracks(ids: ids)) ?? []
            model.append(tracks.map { $0.playlistItem() })
        }
    }
}

/// "Dynamic Mode: name — Repopulate | Turn Off" strip above the playlist.
struct DynamicModeBanner: View {
    let mode: DynamicModeController

    var body: some View {
        if let active = mode.active {
            HStack(spacing: 6) {
                Image(systemName: "dice.fill").foregroundStyle(.tint)
                Text("Dynamic mode: \(Text(active.name).bold())")
                Spacer(minLength: 4)
                if mode.isWorking { ProgressView().controlSize(.mini) }
                Button("Repopulate") { mode.repopulate() }
                Text("|").foregroundStyle(.tertiary)
                Button("Turn Off") { mode.stop() }
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.amamacAccent.opacity(0.12))
            .accessibilityIdentifier("dynamicModeBanner")
        }
    }
}
