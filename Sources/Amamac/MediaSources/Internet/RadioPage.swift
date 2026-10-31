import AmamacBase
import AmamacModels
import AmamacPodcasts
import AmamacWeb
import AppKit
import SwiftUI

/// One list of stations (favourites, top, a search, a genre or a country) and what can be done with it.
@MainActor
@Observable
final class RadioListModel {
    let env: AppEnvironment
    private(set) var stations: [RadioBrowserStation] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var favoriteIDs: Set<String> = []
    var selection: Set<String> = []
    var hideUnplayable: Bool {
        didSet { env.settings.set(hideUnplayable, AppSettings.Key.radioHideUnplayable) }
    }
    @ObservationIgnored private let loader: @MainActor (RadioBrowserClient) async throws -> [RadioBrowserStation]

    /// One directory connection for the whole app.
    @ObservationIgnored private static var client: RadioBrowserClient?

    static func connect(_ env: AppEnvironment) async -> RadioBrowserClient {
        if let client { return client }
        let connected = await RadioBrowserClient.connect(http: env.http)
        client = connected
        return connected
    }

    init(env: AppEnvironment, loader: @escaping @MainActor (RadioBrowserClient) async throws -> [RadioBrowserStation]) {
        self.env = env
        self.loader = loader
        hideUnplayable = env.settings.bool(AppSettings.Key.radioHideUnplayable)
        NotificationCenter.default.addObserver(forName: RadioFavorites.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFavorites() }
        }
        reloadFavorites()
    }

    var visible: [RadioBrowserStation] { hideUnplayable ? stations.filter(\.isPlayable) : stations }
    var hiddenCount: Int { stations.count - visible.count }

    func load() {
        loading = true
        error = nil
        Task {
            do {
                stations = try await loader(await Self.connect(env))
            } catch {
                self.error = "The station directory could not be reached. \(error.localizedDescription)"
            }
            loading = false
        }
    }

    private func reloadFavorites() {
        favoriteIDs = Set(env.radioFavorites.all().map(\.id))
    }

    func stations(for ids: Set<String>) -> [RadioBrowserStation] { visible.filter { ids.contains($0.id) } }

    func add(_ stations: [RadioBrowserStation], mode: LibraryActions.AddMode) {
        let items = stations.compactMap { s in s.streamURL.map { PlaylistItem.stream(url: $0, title: s.name) } }
        env.actions.add(items, mode: mode)
        if mode == .appendAndPlay || mode == .replace, let first = stations.first {
            Task { await Self.connect(env).reportClick(first) }
        }
    }

    func isFavorite(_ station: RadioBrowserStation) -> Bool { favoriteIDs.contains(station.id) }

    func toggleFavorite(_ station: RadioBrowserStation) {
        let favorites = env.radioFavorites
        isFavorite(station) ? favorites.remove(station) : favorites.add(station)
    }
}

@MainActor
@Observable
final class RadioModel {
    enum Section: String, CaseIterable, Identifiable {
        case favorites = "Favorites", top = "Top", genres = "Genres", countries = "Countries", search = "Search"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .favorites: "star"
            case .top: "chart.bar"
            case .genres: "tag"
            case .countries: "globe"
            case .search: "magnifyingglass"
            }
        }
    }

    let env: AppEnvironment
    @ObservationIgnored weak var owner: MediaSourcesViewController?
    var section: Section = .top {
        didSet { sectionChanged() }
    }
    let favorites: RadioListModel
    let top: RadioListModel
    private(set) var searchList: RadioListModel
    private(set) var facets: [RadioFacet] = []
    private(set) var loadingFacets = false
    private(set) var facetError: String?
    var facetFilter = ""
    var searchText = ""

    init(env: AppEnvironment, owner: MediaSourcesViewController?) {
        self.env = env
        self.owner = owner
        favorites = RadioListModel(env: env) { _ in env.radioFavorites.all() }
        top = RadioListModel(env: env) { try await $0.topStations() }
        searchList = RadioListModel(env: env) { _ in [] }
        // Start on Favorites once there are some.
        let hasFavorites = !env.radioFavorites.all().isEmpty
        section = hasFavorites ? .favorites : .top
        sectionChanged()
    }

    private func sectionChanged() {
        facetFilter = ""
        switch section {
        case .favorites: favorites.load()
        case .top: if top.stations.isEmpty { top.load() }
        case .genres, .countries: loadFacets()
        case .search: break
        }
    }

    func search() {
        let term = searchText.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        searchList = RadioListModel(env: env) { try await $0.stations(.name(term)) }
        searchList.load()
    }

    private func loadFacets() {
        let section = self.section
        facets = []
        loadingFacets = true
        facetError = nil
        Task {
            do {
                let client = await RadioListModel.connect(env)
                let list = section == .genres ? try await client.tags() : try await client.countries()
                if self.section == section { facets = list }
            } catch {
                facetError = "The station directory could not be reached. \(error.localizedDescription)"
            }
            loadingFacets = false
        }
    }

    var visibleFacets: [RadioFacet] {
        let f = TextFolding.fold(facetFilter.trimmingCharacters(in: .whitespaces))
        return f.isEmpty ? facets : facets.filter { TextFolding.fold($0.name).contains(f) }
    }

    func open(_ facet: RadioFacet) {
        let isGenre = section == .genres
        let list = RadioListModel(env: env) { client in
            try await client.stations(isGenre ? .tag(facet.name) : .country(code: facet.iso_3166_1 ?? facet.name))
        }
        list.load()
        owner?.push(HostedPage(title: facet.name.capitalized, symbol: isGenre ? "tag" : "globe",
                               root: RadioStationList(model: list)))
    }
}

struct RadioView: View {
    @Bindable var model: RadioModel

    var body: some View {
        VStack(spacing: 0) {
            // Icons keep the five sections readable in the narrow pane; the name shows below.
            Picker("", selection: $model.section) {
                ForEach(RadioModel.Section.allCases) { section in
                    Image(systemName: section.symbol).help(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.top, 8)
            Text(model.section.rawValue)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            switch model.section {
            case .favorites:
                RadioStationList(model: model.favorites, emptyText: "Stations you mark with a star appear here.")
            case .top:
                RadioStationList(model: model.top)
            case .search:
                TextField("Station name", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                RadioStationList(model: model.searchList, emptyText: "Type a station name and press Return.")
            case .genres, .countries:
                TextField("Filter", text: $model.facetFilter)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                if let error = model.facetError {
                    Text(error).font(.callout).foregroundStyle(.secondary).padding().frame(maxHeight: .infinity)
                } else if model.loadingFacets {
                    ProgressView().frame(maxHeight: .infinity)
                } else {
                    List(model.visibleFacets) { facet in
                        Button { model.open(facet) } label: {
                            HStack {
                                Image(systemName: model.section == .genres ? "tag" : "globe").foregroundStyle(.secondary)
                                Text(model.section == .genres ? facet.name.capitalized : facet.name).lineLimit(1)
                                Spacer()
                                Text("\(facet.stationcount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
        }
    }
}

struct RadioStationList: View {
    @Bindable var model: RadioListModel
    var emptyText = "No stations."

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                VStack(spacing: 8) {
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try Again") { model.load() }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.visible) { station in
                        StationRow(station: station, images: model.env.remoteImages, isFavorite: model.isFavorite(station)) { model.toggleFavorite(station) }
                            .tag(station.id)
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: String.self) { ids in
                    let stations = model.stations(for: ids)
                    Button("Play") { model.add(Array(stations.prefix(1)), mode: .appendAndPlay) }
                    Button("Add to Playlist") { model.add(stations, mode: .append) }
                    Button("Replace Playlist") { model.add(stations, mode: .replace) }
                    Divider()
                    if let first = stations.first {
                        Button(model.isFavorite(first) ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(first) }
                        if let homepage = first.homepage.flatMap(URL.init(string:)), homepage.scheme?.hasPrefix("http") == true {
                            Button("Open Homepage") { NSWorkspace.shared.open(homepage) }
                        }
                        Button("Copy Stream Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(first.streamURL?.absoluteString ?? first.url, forType: .string)
                        }
                    }
                } primaryAction: { ids in
                    model.add(Array(model.stations(for: ids).prefix(1)), mode: .appendAndPlay)
                }
                .overlay {
                    if model.loading {
                        ProgressView()
                    } else if model.visible.isEmpty {
                        Text(model.hiddenCount > 0 ? "Only stations Amamac can't play were found." : emptyText)
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Hide stations Amamac can't play", isOn: $model.hideUnplayable)
                    .toggleStyle(.checkbox)
                    .help("Ogg, Opus and FLAC streams can't be played by macOS's streaming engine.")
                Spacer()
                Text(model.hiddenCount > 0 ? "\(model.visible.count) (+\(model.hiddenCount) hidden)" : "\(model.visible.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }
}

struct StationRow: View {
    let station: RadioBrowserStation
    let images: RemoteImageCache
    let isFavorite: Bool
    let onFavorite: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            RemoteImage(url: station.favicon.flatMap(URL.init(string:)), images: images, symbol: "radio", size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(station.name.trimmingCharacters(in: .whitespaces)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(badge)
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(station.isPlayable ? Color.secondary.opacity(0.18) : Color.red.opacity(0.18)))
                .foregroundStyle(station.isPlayable ? Color.secondary : Color.red)
                .help(station.isPlayable ? "Stream format" : "macOS can't play \(station.codecName) streams")
            Button(action: onFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star").foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .opacity(station.isPlayable ? 1 : 0.55)
    }

    private var detail: String {
        [station.tagList.prefix(3).joined(separator: ", "), station.country ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var badge: String {
        (station.bitrate ?? 0) > 0 ? "\(station.codecName) \(station.bitrate!)" : station.codecName
    }
}
