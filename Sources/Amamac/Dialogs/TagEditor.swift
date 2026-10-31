import AmamacBase
import AmamacDatabase
import AmamacLibrary
import AmamacModels
import AmamacWeb
import AppKit
import SwiftUI

/// "Edit Track Details": Summary, Tags, Lyrics and Labels for one or many tracks. With several
/// tracks, fields edit all of them unless "Per Track" is on.
@MainActor
@Observable
final class TagEditorModel {
    struct Fields: Equatable {
        var title = "", artist = "", albumArtist = "", album = "", composer = "", genre = "", comment = ""
        var year = "", track = "", disc = "", bpm = ""
        var compilation = false

        init(_ t: Track) {
            title = t.title
            artist = t.artist
            albumArtist = t.albumArtist
            album = t.album
            composer = t.composer
            genre = t.genre
            comment = t.comment
            year = t.year > 0 ? String(t.year) : ""
            track = t.trackNumber > 0 ? String(t.trackNumber) : ""
            disc = t.discNumber > 0 ? String(t.discNumber) : ""
            bpm = t.bpm > 0 ? String(t.bpm) : ""
            compilation = t.compilation
        }
    }

    let env: AppEnvironment
    private(set) var tracks: [TrackWithStatistics]
    private var original: [Fields]
    var current: [Fields]
    private var originalLyrics: [String?]
    var lyrics: [String?]
    private var originalLabels: [[String]]
    var labels: [[String]]
    private(set) var allLabels: [String] = []
    var perTrack: Bool
    var index = 0
    var isSaving = false
    var errorMessage: String?
    var onClose: (() -> Void)?

    init(env: AppEnvironment, tracks: [TrackWithStatistics]) {
        self.env = env
        self.tracks = tracks
        let fields = tracks.map { Fields($0.track) }
        original = fields
        current = fields
        let noLyrics = [String?](repeating: nil, count: tracks.count)
        originalLyrics = noLyrics
        lyrics = noLyrics
        let noLabels = [[String]](repeating: [], count: tracks.count)
        originalLabels = noLabels
        labels = noLabels
        perTrack = tracks.count == 1
        load()
    }

    private func load() {
        let ids = tracks.map(\.track.id)
        let db = env.database
        Task {
            let loaded = try? await db.lyricsAndLabels(trackIds: ids)
            guard let loaded else { return }
            originalLyrics = loaded.0
            lyrics = loaded.0
            originalLabels = loaded.1
            labels = loaded.1
            allLabels = loaded.2
        }
    }

    var isMultiple: Bool { tracks.count > 1 }
    var showsOneTrack: Bool { perTrack || !isMultiple }
    var currentTrack: TrackWithStatistics { tracks[index] }
    var hasChanges: Bool { current != original || lyrics != originalLyrics || labels.map(Set.init) != originalLabels.map(Set.init) }

    // MARK: Field access

    /// The value shown for a field: the current track's, or the shared value when editing all.
    func value(_ kp: WritableKeyPath<Fields, String>) -> String {
        showsOneTrack ? current[index][keyPath: kp] : (common(kp) ?? "")
    }

    func isMixed(_ kp: WritableKeyPath<Fields, String>) -> Bool { !showsOneTrack && common(kp) == nil }

    private func common(_ kp: WritableKeyPath<Fields, String>) -> String? {
        let values = Set(current.map { $0[keyPath: kp] })
        return values.count == 1 ? values.first : nil
    }

    func set(_ kp: WritableKeyPath<Fields, String>, _ value: String) {
        if showsOneTrack { current[index][keyPath: kp] = value } else { for i in current.indices { current[i][keyPath: kp] = value } }
    }

    var compilation: Bool {
        get { showsOneTrack ? current[index].compilation : current.allSatisfy(\.compilation) }
        set {
            if showsOneTrack { current[index].compilation = newValue } else { for i in current.indices { current[i].compilation = newValue } }
        }
    }

    // MARK: Labels

    var shownLabels: [String] {
        showsOneTrack ? labels[index].sorted() : Array(Set(labels.flatMap { $0 })).sorted()
    }

    func addLabel(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        for i in (showsOneTrack ? [index] : Array(labels.indices)) where !labels[i].contains(name) { labels[i].append(name) }
    }

    func removeLabel(_ name: String) {
        for i in (showsOneTrack ? [index] : Array(labels.indices)) { labels[i].removeAll { $0 == name } }
    }

    // MARK: Helpers

    func guessFromFilename(pattern: String) -> Int {
        var matched = 0
        for i in (showsOneTrack ? [index] : Array(tracks.indices)) {
            guard let guess = FilenameTagGuesser.guess(path: tracks[i].track.path, pattern: pattern) else { continue }
            matched += 1
            for (field, value) in guess {
                switch field {
                case "title": current[i].title = value
                case "artist": current[i].artist = value
                case "albumartist": current[i].albumArtist = value
                case "album": current[i].album = value
                case "genre": current[i].genre = value
                case "composer": current[i].composer = value
                case "comment": current[i].comment = value
                case "track": current[i].track = value
                case "discnumber": current[i].disc = value
                case "year": current[i].year = value
                default: break
                }
            }
        }
        return matched
    }

    func apply(_ c: MusicBrainzClient.Candidate) {
        current[index].title = c.title
        current[index].artist = c.artist
        current[index].album = c.album
        current[index].albumArtist = c.albumArtist == c.artist ? current[index].albumArtist : c.albumArtist
        if c.year > 0 { current[index].year = String(c.year) }
        if c.trackNumber > 0 { current[index].track = String(c.trackNumber) }
        if c.discNumber > 0 { current[index].disc = String(c.discNumber) }
    }

    // MARK: Saving

    static func changes(from a: Fields, to b: Fields) -> TagChanges {
        var c = TagChanges()
        if a.title != b.title { c.title = b.title }
        if a.artist != b.artist { c.artist = b.artist }
        if a.albumArtist != b.albumArtist { c.albumArtist = b.albumArtist }
        if a.album != b.album { c.album = b.album }
        if a.composer != b.composer { c.composer = b.composer }
        if a.genre != b.genre { c.genre = b.genre }
        if a.comment != b.comment { c.comment = b.comment }
        if a.year != b.year { c.year = Int(b.year) ?? 0 }
        if a.track != b.track { c.trackNumber = Int(b.track) ?? 0 }
        if a.disc != b.disc { c.discNumber = Int(b.disc) ?? 0 }
        if a.bpm != b.bpm { c.bpm = Int(b.bpm) ?? 0 }
        if a.compilation != b.compilation { c.compilation = b.compilation }
        return c
    }

    func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let edits = tracks.indices.map { TrackEditor.Edit(path: tracks[$0].track.path, changes: Self.changes(from: original[$0], to: current[$0])) }
        let lyricEdits = tracks.indices.compactMap { i -> (Int64, String)? in
            guard lyrics[i] != originalLyrics[i], let id = tracks[i].track.id else { return nil }
            return (id, lyrics[i] ?? "")
        }
        let labelEdits = tracks.indices.compactMap { i -> (Int64, [String])? in
            guard Set(labels[i]) != Set(originalLabels[i]), let id = tracks[i].track.id else { return nil }
            return (id, labels[i])
        }
        for edit in edits where !edit.changes.isEmpty { env.ignoreWatcherEvents(for: edit.path) }
        let scanner = env.scanner
        let lyricsService = env.lyrics
        let db = env.database
        let ids = tracks.compactMap(\.track.id)
        Task {
            let failures = await TrackEditor.apply(edits, scanner: scanner)
            for (id, text) in lyricEdits { try? await lyricsService.save(text, trackId: id) }
            if !labelEdits.isEmpty {
                try? await db.setLabels(labelEdits)
            }
            Commands.tracksChanged(ids: ids)
            isSaving = false
            if failures.isEmpty {
                onClose?()
            } else {
                errorMessage = "\(failures.count) file(s) could not be written: " +
                    failures.map { "\(($0.key as NSString).lastPathComponent) (\($0.value))" }.joined(separator: ", ")
            }
        }
    }
}

struct TagEditorView: View {
    @Bindable var model: TagEditorModel
    let covers: CoverImageCache
    @State private var tab = 1
    @State private var newLabel = ""
    @State private var showGuess = false
    @State private var guessPattern = FilenameTagGuesser.presets[0]
    @State private var guessResult: String?
    @State private var showMusicBrainz = false

    var body: some View {
        VStack(spacing: 0) {
            header.padding(14)
            TabView(selection: $tab) {
                summary.tabItem { Text("Summary") }.tag(0)
                tags.tabItem { Text("Tags") }.tag(1)
                lyricsTab.tabItem { Text("Lyrics") }.tag(2)
                labelsTab.tabItem { Text("Labels") }.tag(3)
            }
            .padding(.horizontal, 14)
            footer.padding(14)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AlbumCover(albumKey: model.showsOneTrack ? model.currentTrack.track.albumKey : model.tracks.first?.track.albumKey, covers: covers)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                if model.showsOneTrack {
                    Text(model.currentTrack.track.displayTitle).font(.headline).lineLimit(1)
                    Text("\(model.currentTrack.track.displayArtist) — \(model.currentTrack.track.displayAlbum)")
                        .foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("\(model.tracks.count) tracks").font(.headline)
                    Text("Changes apply to every selected track.").foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isMultiple {
                Toggle("Per Track", isOn: $model.perTrack).toggleStyle(.checkbox)
                ControlGroup {
                    Button { model.index -= 1 } label: { Image(systemName: "chevron.left") }.disabled(!model.perTrack || model.index == 0)
                    Button { model.index += 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(!model.perTrack || model.index >= model.tracks.count - 1)
                }
                .frame(width: 70)
                .help("Previous / Next track")
            }
        }
    }

    // MARK: Summary

    private var summary: some View {
        Form {
            if model.showsOneTrack {
                let t = model.currentTrack.track
                let s = model.currentTrack.statistics
                LabeledContent("Length", value: TimeFormatting.durationMs(t.durationMs))
                LabeledContent("Format", value: [t.format.uppercased(), t.bitrate > 0 ? "\(t.bitrate) kbps" : nil,
                                                 t.sampleRate > 0 ? "\(t.sampleRate) Hz" : nil,
                                                 t.channels > 0 ? (t.channels == 1 ? "mono" : "\(t.channels) channels") : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: t.fileSize, countStyle: .file))
                if let id = t.id {
                    LabeledContent("Rating") {
                        RatingStars(rating: s?.rating ?? 0) { model.env.player.setRating($0, trackId: id) }
                    }
                }
                LabeledContent("Play Count", value: "\(s?.playCount ?? 0)")
                LabeledContent("Score", value: "\(Int((s?.score ?? 0).rounded()))")
                LabeledContent("First Played", value: s?.firstPlayed.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                LabeledContent("Last Played", value: s?.lastPlayed.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                LabeledContent("Added", value: t.dateAdded.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Location") { Text(t.path).textSelection(.enabled).lineLimit(3).font(.caption) }
            } else {
                let tracks = model.tracks.map(\.track)
                LabeledContent("Tracks", value: "\(tracks.count)")
                LabeledContent("Total Length", value: TimeFormatting.durationMs(tracks.reduce(0) { $0 + $1.durationMs }))
                LabeledContent("Total Size", value: ByteCountFormatter.string(fromByteCount: tracks.reduce(0) { $0 + $1.fileSize }, countStyle: .file))
                LabeledContent("Formats", value: Set(tracks.map { $0.format.uppercased() }).sorted().joined(separator: ", "))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Tags

    private func field(_ title: String, _ kp: WritableKeyPath<TagEditorModel.Fields, String>) -> some View {
        TextField(title, text: Binding(get: { model.value(kp) }, set: { model.set(kp, $0) }),
                  prompt: Text(model.isMixed(kp) ? "Various" : ""))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
    }

    private func row(_ title: String, _ kp: WritableKeyPath<TagEditorModel.Fields, String>) -> some View {
        GridRow {
            Text(title + ":").fixedSize().gridColumnAlignment(.trailing)
            field(title, kp).gridCellColumns(7)
        }
    }

    private var tags: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                row("Title", \.title)
                row("Artist", \.artist)
                row("Album Artist", \.albumArtist)
                row("Album", \.album)
                row("Composer", \.composer)
                row("Genre", \.genre)
                GridRow {
                    Text("Year:").fixedSize().gridColumnAlignment(.trailing)
                    field("Year", \.year).frame(width: 64)
                    Text("Track:")
                    field("Track", \.track).frame(width: 52)
                    Text("Disc:")
                    field("Disc", \.disc).frame(width: 44)
                    Text("BPM:")
                    field("BPM", \.bpm).frame(width: 52)
                }
                row("Comment", \.comment)
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Part of a compilation", isOn: $model.compilation).toggleStyle(.checkbox).gridCellColumns(7)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    HStack {
                        Button("Guess Tags from Filename…") { showGuess = true }
                            .popover(isPresented: $showGuess) { guessPopover }
                        Button("MusicBrainz…") { showMusicBrainz = true }
                            .disabled(!model.showsOneTrack)
                            .help(model.showsOneTrack ? "Look the track up on MusicBrainz" : "Turn on Per Track to look up a single track")
                            .popover(isPresented: $showMusicBrainz) {
                                MusicBrainzLookupView(model: model, client: MusicBrainzClient(http: model.env.http))
                            }
                    }
                    .gridCellColumns(7)
                }
            }
            .padding(16)
        }
    }

    private var guessPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pattern").font(.headline)
            Picker("Preset", selection: $guessPattern) {
                ForEach(FilenameTagGuesser.presets, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            TextField("Pattern", text: $guessPattern).font(.system(.body, design: .monospaced))
            Text("Tokens: %title% %artist% %albumartist% %album% %track% %discnumber% %year% %genre% %composer%. Use / for folders.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let guessResult { Text(guessResult).font(.caption) }
            HStack {
                Spacer()
                Button("Guess") {
                    let matched = model.guessFromFilename(pattern: guessPattern)
                    guessResult = matched == 0 ? "No file name matched the pattern." : "Filled in \(matched) track(s)."
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Lyrics / Labels

    private var lyricsTab: some View {
        Group {
            if model.showsOneTrack && model.currentTrack.track.id != nil {
                TextEditor(text: Binding(get: { model.lyrics[model.index] ?? "" },
                                         set: { model.lyrics[model.index] = $0.isEmpty ? nil : $0 }))
                    .font(.body)
                    .padding(4)
            } else {
                Text(model.isMultiple ? "Turn on Per Track to edit lyrics." : "Lyrics can be edited for collection tracks.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var labelsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add label", text: $newLabel)
                    .onSubmit { model.addLabel(newLabel); newLabel = "" }
                Button("Add") { model.addLabel(newLabel); newLabel = "" }.disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(model.shownLabels, id: \.self) { label in
                    HStack {
                        Image(systemName: "tag")
                        Text(label)
                        Spacer()
                        Button { model.removeLabel(label) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            let suggestions = model.allLabels.filter { !model.shownLabels.contains($0) }
            if !suggestions.isEmpty {
                Text("Existing labels").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { label in
                            Button(label) { model.addLabel(label) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(8)
    }

    private var footer: some View {
        HStack {
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            Spacer()
            if model.isSaving { ProgressView().controlSize(.small) }
            Button("Cancel") { model.onClose?() }.keyboardShortcut(.cancelAction)
            Button("Save & Close") { model.save() }.keyboardShortcut(.defaultAction).disabled(!model.hasChanges || model.isSaving)
        }
    }
}

/// MusicBrainz candidates for the current track; choosing one fills the fields.
struct MusicBrainzLookupView: View {
    let model: TagEditorModel
    let client: MusicBrainzClient
    @State private var candidates: [MusicBrainzClient.Candidate]?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MusicBrainz").font(.headline)
            if let candidates {
                if candidates.isEmpty {
                    Text("No matching recordings.").foregroundStyle(.secondary)
                } else {
                    List(candidates) { c in
                        Button {
                            model.apply(c)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(c.title) — \(c.artist)").fontWeight(.medium)
                                Text([c.album, c.year > 0 ? String(c.year) : nil, c.trackNumber > 0 ? "track \(c.trackNumber)" : nil,
                                      c.durationMs > 0 ? TimeFormatting.durationMs(c.durationMs) : nil].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 260)
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView("Searching…").controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 420)
        .task {
            let f = model.current[model.index]
            do {
                candidates = try await client.recordings(title: f.title, artist: f.artist, album: f.album,
                                                         durationMs: model.currentTrack.track.durationMs)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Opens tag editor windows.
@MainActor
enum TagEditorWindow {
    private static var open: [NSWindow] = []

    static func show(tracks: [TrackWithStatistics], env: AppEnvironment) {
        guard !tracks.isEmpty else { return }
        let model = TagEditorModel(env: env, tracks: tracks)
        let host = NSHostingController(rootView: TagEditorView(model: model, covers: env.coverImages))
        let window = NSWindow(contentViewController: host)
        window.title = tracks.count == 1 ? "Edit Track Details" : "Edit Track Details (\(tracks.count) tracks)"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 600, height: 600))
        window.center()
        model.onClose = { [weak window] in window?.close() }
        let id = ObjectIdentifier(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { open.removeAll { ObjectIdentifier($0) == id } }
        }
        open.append(window)
        window.makeKeyAndOrderFront(nil)
    }
}
