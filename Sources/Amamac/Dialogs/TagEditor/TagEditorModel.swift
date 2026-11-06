import AmamacBase
import AmamacDatabase
import AmamacLibrary
import AmamacModels
import AppKit
import SwiftUI

/// Edit Track Details: the window's state over `TagEditSession`, which holds the editing logic.
/// This layer loads the files' own values, completes from the collection and saves.
@MainActor
@Observable
final class TagEditorModel {
    enum Tab: Hashable { case summary, tags, labels }

    let env: AppEnvironment
    var session: TagEditSession
    private(set) var statistics: [TrackStatistics?]
    private(set) var allLabels: [String] = []
    /// The embedded front cover of the shown track, as read from its file.
    private(set) var embeddedCover: Data?
    /// Bumped whenever what the cover well shows may have changed.
    private(set) var coverRevision = 0
    private(set) var isReadingFiles = true
    var tab = Tab.tags
    var showsMore = false
    private(set) var isSaving = false
    var errorMessage: String?
    /// Closes the window without asking (after saving).
    var onClose: (() -> Void)?
    /// Closes the window the way its close button does, asking about unsaved changes.
    var onRequestClose: (() -> Void)?

    init(env: AppEnvironment, tracks: [TrackWithStatistics]) {
        self.env = env
        statistics = tracks.map(\.statistics)
        session = TagEditSession(tracks: tracks.map(\.track), playCounts: tracks.map { $0.statistics?.playCount ?? 0 })
        load()
    }

    private func load() {
        let ids = session.tracks.map(\.id)
        let paths = session.tracks.map(\.path)
        let db = env.database
        Task {
            if let loaded = try? await db.labels(trackIds: ids) {
                session.adoptLabels(loaded.labels)
                allLabels = loaded.allLabels
            }
            session.adoptFileValues(await Self.readFiles(paths))
            isReadingFiles = false
        }
    }

    /// The files' own values (sort names are only in files; a file may be newer than the collection).
    @concurrent
    nonisolated static func readFiles(_ paths: [String]) async -> [TagEditSession.Values?] {
        paths.map { path in
            (try? TagReader.read(url: URL(fileURLWithPath: path))).map(TagEditSession.Values.init(read:))
        }
    }

    @concurrent
    nonisolated static func readEmbeddedCover(_ path: String) async -> Data? {
        TagReader.embeddedArt(url: URL(fileURLWithPath: path))
    }

    /// Reads the shown track's embedded cover (the cover well calls this when the track changes).
    func loadEmbeddedCover() async {
        guard let track = shownTrack else { return }
        embeddedCover = await Self.readEmbeddedCover(track.path)
        coverRevision += 1
    }

    // MARK: Shown track

    var tracks: [Track] { session.tracks }
    /// The track the header and cover well show: the current one, or the first of several.
    var shownTrack: Track? { session.tracks.indices.contains(session.index) ? session.tracks[session.index] : nil }
    var shownStatistics: TrackStatistics? { statistics.indices.contains(session.index) ? statistics[session.index] : nil }

    func binding(_ field: TagEditSession.Field) -> Binding<String> {
        Binding(get: { self.session.value(field) }, set: { self.session.set(field, $0) })
    }

    var playCount: Binding<Int> {
        Binding(get: { self.session.playCount(at: self.session.index) },
                set: { self.session.setPlayCount(min($0, StatisticsStore.maxPlayCount), at: self.session.index) })
    }

    var hasChanges: Bool { session.hasChanges }

    // MARK: Cover

    /// Puts `data` in the cover well (checked and converted off the main actor).
    func setCover(data: Data) async {
        do {
            let prepared = try await Self.prepare(data)
            session.setCover(.set(prepared))
            coverRevision += 1
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @concurrent
    nonisolated static func prepare(_ data: Data) async throws(EmbeddedCover.Problem) -> Data {
        try EmbeddedCover.prepared(data)
    }

    func setCover(fileAt url: URL) async {
        guard EmbeddedCover.fileIsSmallEnough(url) else {
            errorMessage = EmbeddedCover.Problem.tooLarge.localizedDescription
            return
        }
        guard let data = await Self.readFile(url) else {
            errorMessage = EmbeddedCover.Problem.notAnImage.localizedDescription
            return
        }
        await setCover(data: data)
    }

    @concurrent
    nonisolated static func readFile(_ url: URL) async -> Data? {
        try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// The image data the cover well shows: a pending change, or what the file has.
    var shownCoverData: Data? {
        switch session.coverEdit {
        case .set(let data): data
        case .remove: nil
        case nil: embeddedCover
        }
    }

    var showsCoverImage: Bool { shownCoverData != nil }

    func removeCover() {
        session.setCover(.remove)
        coverRevision += 1
    }

    /// Drops a pending cover change.
    func revertCover() {
        session.setCover(nil)
        coverRevision += 1
    }

    func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image of at most 20 MB to embed as the front cover."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await setCover(fileAt: url) }
    }

    /// Pastes an image or an image file from the general pasteboard.
    func pasteCover() {
        let pasteboard = NSPasteboard.general
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            Task { await setCover(fileAt: url) }
        } else if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
                    ?? pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            Task { await setCover(data: data) }
        } else {
            errorMessage = "The clipboard holds no image."
        }
    }

    // MARK: Saving

    func save() {
        guard !isSaving else { return }
        guard session.invalidFields.isEmpty else {
            errorMessage = "Some values can’t be saved. Fix the fields outlined in red."
            return
        }
        guard session.hasChanges else {
            onClose?()
            return
        }
        isSaving = true
        errorMessage = nil
        let edits = session.edits
        let labelEdits = session.labelEdits
        let playCounts = session.playCountEdits
        for edit in edits { env.ignoreWatcherEvents(for: edit.path) }
        let scanner = env.scanner
        let db = env.database
        let ids = session.tracks.compactMap(\.id)
        let albumKeys = Set(session.tracks.map(\.albumKey))
        Task {
            let failures = await TrackEditor.apply(edits, scanner: scanner)
            if !labelEdits.isEmpty { try? await db.setLabels(labelEdits) }
            let statistics = StatisticsStore(database: db)
            for edit in playCounts { _ = try? await statistics.setPlayCount(edit.playCount, for: edit.trackId) }
            env.actions.tracksChanged(ids: ids)
            if !edits.isEmpty { refreshCovers(albumKeys.union(((try? await db.tracks(ids: ids)) ?? []).map(\.track.albumKey))) }
            isSaving = false
            if failures.isEmpty {
                onClose?()
            } else {
                errorMessage = "\(failures.count) file(s) could not be written: " +
                    failures.map { "\(($0.key as NSString).lastPathComponent) (\($0.value))" }.joined(separator: ", ")
            }
        }
    }

    /// Embedded art may have changed, and albums may have been renamed: drop their cached covers.
    private func refreshCovers(_ albumKeys: Set<String>) {
        for key in albumKeys { CoverActions.changed(key, env: env) }
    }
}
