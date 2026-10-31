import AmamacBase
import AmamacDatabase
import AmamacModels
import AmamacQuery
import AppKit
import SwiftUI

final class CurrentTrackAppletController: Applet {
    let kind = AppletKind.currentTrack
    let contentView: NSView
    private let recent: RecentAlbumsModel

    init(env: AppEnvironment) {
        recent = RecentAlbumsModel(env: env)
        contentView = HostedAppletView(rootView: CurrentTrackApplet(player: env.player, covers: env.coverImages, recent: recent))
    }

    func setActive(_ active: Bool) { if active { recent.reload() } }
}

/// Recently added albums, shown while nothing plays.
@MainActor
@Observable
final class RecentAlbumsModel {
    private(set) var albums: [CollectionGroup] = []
    @ObservationIgnored let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
        NotificationCenter.default.addObserver(forName: AppEnvironment.collectionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func reload() {
        let db = env.database
        Task {
            albums = (try? await db.recentlyAddedAlbums(limit: 6)) ?? []
        }
    }

    func play(_ album: CollectionGroup) {
        guard let key = album.albumKey else { return }
        let tracks = (try? env.database.tracks(constraints: [CollectionConstraint(level: .album, key: key)])) ?? []
        Commands.addToPlaylist(tracks, mode: .appendAndPlay)
    }
}

/// Cover, title, artist, album, rating and play statistics of the current track; recently added
/// albums when stopped.
struct CurrentTrackApplet: View {
    let player: PlayerController
    let covers: CoverImageCache
    let recent: RecentAlbumsModel
    @State private var cover: NSImage?

    var body: some View {
        Group {
            if let item = player.currentItem, player.state != .stopped {
                playing(item)
            } else {
                stopped
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: player.currentItem?.albumKey) { await loadCover() }
    }

    private func playing(_ item: PlaylistItem) -> some View {
        HStack(alignment: .top, spacing: 16) {
            CoverImage(image: item.isStream ? nil : cover, symbol: item.isStream ? "antenna.radiowaves.left.and.right" : "opticaldisc")
                .frame(width: 150, height: 150)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.streamTitle ?? item.track.displayTitle)
                    .font(.system(size: 22, weight: .bold)).lineLimit(2).minimumScaleFactor(0.5)
                if item.isStream {
                    if item.streamTitle != nil { Text(item.track.displayTitle).font(.title3).foregroundStyle(.secondary) }
                } else {
                    Text(item.track.displayArtist).font(.system(size: 16)).lineLimit(1).minimumScaleFactor(0.6)
                    HStack(spacing: 6) {
                        Text(item.track.displayAlbum).lineLimit(1)
                        if item.track.year > 0 { Text("(\(String(item.track.year)))") }
                    }
                    .font(.system(size: 15)).foregroundStyle(.secondary).minimumScaleFactor(0.6)
                }
                if let trackId = item.track.id, item.source == .collection {
                    RatingStars(rating: item.statistics?.rating ?? 0, size: 18) { player.setRating($0, trackId: trackId) }
                        .padding(.top, 6)
                    let stats = item.statistics
                    HStack(spacing: 22) {
                        stat("Play Count", "\(stats?.playCount ?? 0)")
                        stat("Score", "\(Int((stats?.score ?? 0).rounded()))")
                        stat("Last Played", stats?.lastPlayed.map { TimeFormatting.relative($0) } ?? "Never")
                    }
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var stopped: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently Added Albums").font(.headline)
            if recent.albums.isEmpty {
                Text("Add folders with Tools › Collection Folders to build your collection.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(recent.albums) { album in
                            RecentAlbumTile(album: album, covers: covers)
                                .onTapGesture(count: 2) { recent.play(album) }
                                .help("Double-click to play")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func loadCover() async {
        guard let item = player.currentItem, !item.isStream else {
            cover = nil
            return
        }
        cover = await covers.image(albumKey: item.albumKey, size: 200)
    }
}

struct RecentAlbumTile: View {
    let album: CollectionGroup
    let covers: CoverImageCache
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverImage(image: image, symbol: "opticaldisc").frame(width: 110, height: 110)
            Text(album.displayName).font(.callout.weight(.medium)).lineLimit(1)
            Text(album.albumArtist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 110)
        .task(id: album.albumKey) {
            if let key = album.albumKey { image = await covers.image(albumKey: key, size: 128) }
        }
    }
}

/// A cover with a placeholder when missing.
struct CoverImage: View {
    let image: NSImage?
    var symbol = "opticaldisc"

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

/// Five clickable stars with half steps (rating 0...10). Clicking the current value clears it.
struct RatingStars: View {
    let rating: Int
    var size: CGFloat = 16
    let onChange: (Int) -> Void
    @State private var hover: Int?

    var body: some View {
        let shown = hover ?? rating
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                let full = shown >= star * 2
                let half = shown == star * 2 - 1
                Image(systemName: full ? "star.fill" : (half ? "star.leadinghalf.filled" : "star"))
                    .font(.system(size: size))
                    .foregroundStyle(shown > 0 && (full || half) ? Color.orange : Color.secondary)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hover = value(at: p.x)
            case .ended: hover = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { e in
            let v = value(at: e.location.x)
            onChange(v == rating ? 0 : v)
        })
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(Double(rating) / 2) stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(10, rating + 1))
            case .decrement: onChange(max(0, rating - 1))
            @unknown default: break
            }
        }
    }

    private func value(at x: CGFloat) -> Int {
        let starWidth = size + 2
        return max(1, min(10, Int((x / starWidth * 2).rounded(.up))))
    }
}
