import AppKit
import SwiftUI
import AmamacCore

/// The middle "Context" pane: a column of applets. M2 shows the Current Track applet only; the
/// applet framework (tabs, configuration, other applets) arrives with M3.
final class ContextPaneController: NSViewController {
    let env: AppEnvironment
    private let dropper = PopUpDropper()

    init(env: AppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        let host = NSHostingView(rootView: CurrentTrackApplet(player: env.player, covers: env.coverImages))
        host.sizingOptions = []
        host.safeAreaRegions = []
        for v in [host, dropper] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: root.topAnchor),
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        root.identifier = NSUserInterfaceItemIdentifier("contextPane")
        view = root
        PopUpDropper.shared = dropper
    }
}

/// Cover, title, artist, album, rating and play statistics of the current track.
struct CurrentTrackApplet: View {
    let player: PlayerController
    let covers: CoverImageCache
    @State private var cover: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                Text("Current Track").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))
            content.padding(12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: player.currentItem?.albumKey) { await loadCover() }
    }

    @ViewBuilder private var content: some View {
        if let item = player.currentItem, player.state != .stopped {
            HStack(alignment: .top, spacing: 14) {
                coverView
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.streamTitle ?? item.track.displayTitle)
                        .font(.title2.bold()).lineLimit(2).minimumScaleFactor(0.6)
                    if !item.track.artist.isEmpty { Text(item.track.displayArtist).font(.title3).lineLimit(1) }
                    if !item.track.album.isEmpty {
                        Text(item.track.displayAlbum).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let trackId = item.track.id, item.source == .collection {
                        RatingStars(rating: item.statistics?.rating ?? 0) { player.setRating($0, trackId: trackId) }
                            .padding(.top, 4)
                        let stats = item.statistics
                        HStack(spacing: 16) {
                            stat("Play Count", "\(stats?.playCount ?? 0)")
                            stat("Score", "\(Int((stats?.score ?? 0).rounded()))")
                            stat("Last Played", stats?.lastPlayed.map { TimeFormatting.relative($0) } ?? "Never")
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "music.note.list").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text("Nothing is playing").font(.title3).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var coverView: some View {
        Group {
            if let cover {
                Image(nsImage: cover).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .overlay(Image(systemName: "opticaldisc").font(.system(size: 40)).foregroundStyle(.tertiary))
            }
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 2, y: 1)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func loadCover() async {
        guard let key = player.currentItem?.albumKey, player.currentItem?.isStream == false else {
            cover = nil
            return
        }
        cover = await covers.image(albumKey: key, size: 128)
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
        let v = Int((x / starWidth * 2).rounded(.up))
        return max(1, min(10, v))
    }
}
