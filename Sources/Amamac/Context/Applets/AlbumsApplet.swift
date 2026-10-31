import AmamacBase
import AmamacDatabase
import AmamacQuery
import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AlbumsAppletController: Applet {
    let kind = AppletKind.albums
    let contentView: NSView
    private let model: AlbumsAppletModel

    init(env: AppEnvironment) {
        model = AlbumsAppletModel(env: env)
        contentView = HostedAppletView(rootView: AlbumsApplet(model: model, covers: env.coverImages))
    }

    func setActive(_ active: Bool) {
        model.isActive = active
        if active { model.reload() }
    }
}

@MainActor
@Observable
final class AlbumsAppletModel {
    struct Album: Identifiable {
        var group: CollectionGroup
        var tracks: [TrackWithStatistics]
        var id: String { group.id }
    }

    private(set) var artist = ""
    private(set) var albums: [Album] = []
    private(set) var currentTrackId: Int64?
    var expanded: Set<String> = []
    @ObservationIgnored var isActive = false
    @ObservationIgnored let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
        env.player.addListener { [weak self] event in
            if event == .trackChanged { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: AppEnvironment.collectionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload(force: true) }
        }
    }

    func reload(force: Bool = false) {
        guard isActive else { return }
        let item = env.player.isActive ? env.player.currentItem : nil
        currentTrackId = item?.track.id
        let name = item.map { $0.track.artist.isEmpty ? $0.track.effectiveAlbumArtist : $0.track.artist } ?? ""
        guard force || name != artist else { return }
        artist = name
        guard !name.isEmpty else {
            albums = []
            return
        }
        let db = env.database
        let current = item?.albumKey
        Task {
            let loaded = ((try? await db.albumsWithTracks(artist: name)) ?? []).map { Album(group: $0.album, tracks: $0.tracks) }
            guard name == artist else { return }
            albums = loaded
            if let current, let album = loaded.first(where: { $0.group.albumKey == current }) { expanded = [album.id] }
        }
    }

    func add(_ tracks: [TrackWithStatistics], play: Bool) {
        Commands.addToPlaylist(tracks, mode: play ? .appendAndPlay : .append)
    }
}

/// Albums by the current artist, newest first; each expands to its tracks. Double-click adds to
/// the playlist; albums and tracks can be dragged into it.
struct AlbumsApplet: View {
    let model: AlbumsAppletModel
    let covers: CoverImageCache

    var body: some View {
        Group {
            if model.albums.isEmpty {
                Text(model.artist.isEmpty ? "Play something to see its artist’s albums." : "No albums by \(model.artist) in the collection.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.albums) { album in albumRow(album) }
                    }
                    .padding(8)
                }
            }
        }
    }

    @ViewBuilder
    private func albumRow(_ album: AlbumsAppletModel.Album) -> some View {
        let isOpen = model.expanded.contains(album.id)
        HStack(spacing: 10) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary).frame(width: 12)
            AlbumCover(albumKey: album.group.albumKey, covers: covers).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.group.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                Text([album.group.year > 0 ? String(album.group.year) : nil, "\(album.group.trackCount) tracks",
                      TimeFormatting.durationMs(album.tracks.reduce(0) { $0 + $1.track.durationMs })]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.add(album.tracks, play: false) }
        .onTapGesture {
            if isOpen { model.expanded.remove(album.id) } else { model.expanded.insert(album.id) }
        }
        .onDrag { Self.provider(album.tracks) }
        .contextMenu {
            Button("Add to Playlist") { model.add(album.tracks, play: false) }
            Button("Play") { model.add(album.tracks, play: true) }
        }
        if isOpen {
            ForEach(album.tracks, id: \.track.id) { t in
                HStack {
                    Text(t.track.trackNumber > 0 ? String(format: "%02d", t.track.trackNumber) : "").monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                    Text(t.track.displayTitle).lineLimit(1)
                        .fontWeight(t.track.id == model.currentTrackId ? .bold : .regular)
                    Spacer()
                    Text(TimeFormatting.durationMs(t.track.durationMs)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.leading, 34).padding(.vertical, 1)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.add([t], play: false) }
                .onDrag { Self.provider([t]) }
            }
        }
    }

    /// Drag payload the playlist and Pop-Up Dropper understand (collection track ids).
    static func provider(_ tracks: [TrackWithStatistics]) -> NSItemProvider {
        let ids = tracks.compactMap(\.track.id)
        let provider = NSItemProvider()
        let data = (try? JSONEncoder().encode(ids)) ?? Data()
        provider.registerDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.amamacTracks.rawValue, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return provider
    }
}

