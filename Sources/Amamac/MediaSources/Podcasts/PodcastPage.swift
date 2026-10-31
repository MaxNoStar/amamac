import AmamacBase
import AmamacPodcasts
import AppKit
import SwiftUI

/// Media Sources › Podcasts: subscriptions with their episodes, downloads and an info pane.
final class PodcastBrowserPage: NSViewController, MediaSourcePage {
    let model: PodcastsModel

    init(env: AppEnvironment, owner: MediaSourcesViewController) {
        model = PodcastsModel(env: env, owner: owner)
        super.init(nibName: nil, bundle: nil)
        title = MediaCategory.podcasts.title
    }

    required init?(coder: NSCoder) { fatalError() }

    var crumbTitle: String { MediaCategory.podcasts.title }
    var crumbSymbol: String { MediaCategory.podcasts.symbol }

    override func loadView() {
        let host = NSHostingView(rootView: PodcastsView(model: model))
        host.sizingOptions = []
        view = host
    }
}

enum PodcastItem: Hashable {
    case channel(Int64)
    case episode(Int64)
}

@MainActor
@Observable
final class PodcastsModel {
    let env: AppEnvironment
    @ObservationIgnored weak var owner: MediaSourcesViewController?
    private(set) var expanded: Set<Int64> = []
    private(set) var episodes: [Int64: [PodcastEpisode]] = [:]
    var selection: Set<PodcastItem> = []
    var addingFeed = false
    var feedText = ""
    var editing: PodcastChannel?

    var podcasts: PodcastController { env.podcasts }

    init(env: AppEnvironment, owner: MediaSourcesViewController?) {
        self.env = env
        self.owner = owner
        NotificationCenter.default.addObserver(forName: PodcastService.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func isExpanded(_ id: Int64) -> Bool { expanded.contains(id) }

    func setExpanded(_ id: Int64, _ open: Bool) {
        if open { expanded.insert(id) } else { expanded.remove(id) }
        refresh()
    }

    func refresh() {
        let service = podcasts.service
        episodes = Dictionary(uniqueKeysWithValues: expanded.map { ($0, service.episodes(channelId: $0)) })
    }

    func episode(_ id: Int64) -> PodcastEpisode? {
        for list in episodes.values { if let e = list.first(where: { $0.id == id }) { return e } }
        return podcasts.service.episode(id: id)
    }

    func selectedEpisodes(_ items: Set<PodcastItem>) -> [PodcastEpisode] {
        items.flatMap { item -> [PodcastEpisode] in
            switch item {
            case .episode(let id): return episode(id).map { [$0] } ?? []
            case .channel: return []
            }
        }
        .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }

    func selectedChannels(_ items: Set<PodcastItem>) -> [PodcastChannel] {
        items.compactMap { if case .channel(let id) = $0 { podcasts.channel(id) } else { nil } }
    }

    func subscribeToFeedText() {
        var text = feedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("feed://") { text = "https://" + text.dropFirst(7) }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil else { return }
        addingFeed = false
        feedText = ""
        Task {
            if let channel = await podcasts.subscribe(url), let id = channel.id { setExpanded(id, true) }
        }
    }

    func showDirectory() {
        guard let owner else { return }
        owner.open(category: .internet)
        (owner.page(for: .internet) as? InternetBrowserPage)?.open(.podcasts)
    }
}

struct PodcastsView: View {
    @Bindable var model: PodcastsModel

    var body: some View {
        let podcasts = model.podcasts
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { model.addingFeed = true } label: { Image(systemName: "plus") }.help("Add Podcast…")
                Button { podcasts.updateAll() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Update All Podcasts").disabled(podcasts.channels.isEmpty || podcasts.updating)
                Menu {
                    Button("Find Podcasts…") { model.showDirectory() }
                    Divider()
                    Button("Import OPML…") { podcasts.importOPML() }
                    Button("Export OPML…") { podcasts.exportOPML() }.disabled(podcasts.channels.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                if podcasts.updating { ProgressView().controlSize(.small) }
                if podcasts.totalNew > 0 {
                    Text("\(podcasts.totalNew) new").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            List(selection: $model.selection) {
                ForEach(podcasts.channels) { channel in
                    if let id = channel.id {
                        DisclosureGroup(isExpanded: Binding(get: { model.isExpanded(id) }, set: { model.setExpanded(id, $0) })) {
                            ForEach(model.episodes[id] ?? []) { episode in
                                EpisodeRow(episode: episode, progress: episode.id.flatMap { podcasts.downloads[$0] })
                                    .tag(PodcastItem.episode(episode.id ?? 0))
                            }
                        } label: {
                            ChannelRow(channel: channel, images: model.env.remoteImages, newCount: podcasts.newCounts[id] ?? 0).tag(PodcastItem.channel(id))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: PodcastItem.self) { items in
                contextMenu(items)
            } primaryAction: { items in
                let episodes = model.selectedEpisodes(items)
                if !episodes.isEmpty {
                    podcasts.play(Array(episodes.prefix(1)), mode: .appendAndPlay)
                } else if let channel = model.selectedChannels(items).first, let id = channel.id {
                    model.setExpanded(id, !model.isExpanded(id))
                }
            }
            .overlay {
                if podcasts.channels.isEmpty {
                    VStack(spacing: 8) {
                        Text("No podcasts yet.").font(.headline)
                        Text("Add a feed address with +, or find podcasts in the directory.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Find Podcasts…") { model.showDirectory() }
                    }
                    .padding()
                }
            }
            Divider()
            PodcastInfoPane(model: model).frame(height: 150)
        }
        .sheet(isPresented: $model.addingFeed) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add Podcast").font(.headline)
                Text("Paste the address of the podcast's RSS feed.").font(.callout).foregroundStyle(.secondary)
                TextField("https://example.org/feed.xml", text: $model.feedText).onSubmit { model.subscribeToFeedText() }
                HStack {
                    Spacer()
                    Button("Cancel") { model.addingFeed = false }.keyboardShortcut(.cancelAction)
                    Button("Subscribe") { model.subscribeToFeedText() }.keyboardShortcut(.defaultAction)
                        .disabled(model.feedText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 380)
        }
        .sheet(item: $model.editing) { channel in
            ChannelSettingsView(channel: channel, onSave: { podcasts.service.save($0); model.editing = nil },
                                onCancel: { model.editing = nil })
        }
    }

    @ViewBuilder private func contextMenu(_ items: Set<PodcastItem>) -> some View {
        let podcasts = model.podcasts
        let episodes = model.selectedEpisodes(items)
        let channels = model.selectedChannels(items)
        if !episodes.isEmpty {
            Button("Play") { podcasts.play(Array(episodes.prefix(1)), mode: .appendAndPlay) }
            Button("Add to Playlist") { podcasts.play(episodes, mode: .append) }
            Button("Queue") { podcasts.play(episodes, mode: .queue) }
            Divider()
            let notDownloaded = episodes.filter { !$0.isDownloaded }
            if !notDownloaded.isEmpty {
                Button(notDownloaded.count == 1 ? "Download Episode" : "Download \(notDownloaded.count) Episodes") {
                    notDownloaded.forEach(podcasts.download)
                }
            }
            let downloaded = episodes.filter(\.isDownloaded)
            if !downloaded.isEmpty {
                Button("Delete Download") { downloaded.forEach(podcasts.service.deleteDownload) }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(downloaded.compactMap { $0.localPath.map(URL.init(fileURLWithPath:)) })
                }
            }
            Divider()
            Button("Mark as Played") { podcasts.service.setPlayed(episodes.compactMap(\.id), played: true) }
            Button("Mark as New") { podcasts.service.setNew(episodes.compactMap(\.id), isNew: true) }
        } else if let channel = channels.first {
            Button("Update") { podcasts.update(channel) }
            Button("Mark All as Played") {
                podcasts.service.setPlayed(podcasts.service.episodes(channelId: channel.id ?? 0).compactMap(\.id), played: true)
            }
            Button("Settings…") { model.editing = channel }
            Divider()
            if let link = channel.link.flatMap(URL.init(string:)), link.isWebURL {
                Button("Open Website") { NSWorkspace.shared.open(link) }
            }
            Button("Copy Feed Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(channel.feedURL, forType: .string)
            }
            Divider()
            Button("Unsubscribe…") { podcasts.unsubscribe(channel) }
        }
    }
}

struct ChannelRow: View {
    let channel: PodcastChannel
    let images: RemoteImageCache
    let newCount: Int

    var body: some View {
        HStack(spacing: 8) {
            RemoteImage(url: channel.imageURL.flatMap(URL.init(string:)), images: images, symbol: "mic", size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.title).lineLimit(1)
                if let author = channel.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if newCount > 0 {
                Text("\(newCount)")
                    .font(.caption2.bold().monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.amamacAccent))
                    .help("\(newCount) new episode\(newCount == 1 ? "" : "s")")
            }
        }
    }
}

struct EpisodeRow: View {
    let episode: PodcastEpisode
    let progress: Double?

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.circular).controlSize(.mini)
                } else if episode.isDownloaded {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint).help("Downloaded")
                } else if episode.isNew {
                    Circle().fill(Color.amamacAccent).frame(width: 7, height: 7).help("New")
                } else if episode.isPlayed {
                    Image(systemName: "checkmark").font(.caption).foregroundStyle(.tertiary).help("Played")
                } else {
                    Color.clear
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(episode.title).lineLimit(1).fontWeight(episode.isNew ? .semibold : .regular)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .opacity(episode.isPlayed && !episode.isNew ? 0.7 : 1)
    }

    private var detail: String {
        let date = episode.pubDate.map { $0.formatted(date: .abbreviated, time: .omitted) }
        let length = episode.durationMs.flatMap { $0 > 0 ? TimeFormatting.durationMs($0) : nil }
        return [date, length].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Details of the selected episode or channel, as in Amarok's podcast info pane.
struct PodcastInfoPane: View {
    let model: PodcastsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let episode = model.selectedEpisodes(model.selection).first {
                    Text(episode.title).font(.headline)
                    if let channel = model.podcasts.channel(episode.channelId) {
                        Text(channel.title).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(PodcastText.plain(episode.summary ?? "")).font(.callout).textSelection(.enabled)
                } else if let channel = model.selectedChannels(model.selection).first {
                    Text(channel.title).font(.headline)
                    if let updated = channel.lastUpdated {
                        Text("Updated \(TimeFormatting.relative(updated))").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(PodcastText.plain(channel.summary ?? channel.subtitle ?? "")).font(.callout).textSelection(.enabled)
                } else {
                    Text("Select an episode to read its description.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }
}

struct ChannelSettingsView: View {
    @State var channel: PodcastChannel
    let onSave: (PodcastChannel) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(channel.title).font(.headline)
            Form {
                Toggle("Include in automatic updates", isOn: $channel.autoScan)
                Picker("Episodes", selection: $channel.downloadPolicy) {
                    ForEach(PodcastChannel.DownloadPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Stepper(value: $channel.keepMax, in: 0...200) {
                    Text(channel.keepMax == 0 ? "Keep all downloaded episodes" : "Keep the newest \(channel.keepMax) downloads")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(channel) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
