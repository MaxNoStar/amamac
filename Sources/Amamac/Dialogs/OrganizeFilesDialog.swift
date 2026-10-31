import AmamacLibrary
import AmamacModels
import AppKit
import SwiftUI

/// Organize Files: pick a collection folder and naming pattern, preview, then move.
@MainActor
@Observable
final class OrganizeModel {
    let env: AppEnvironment
    let tracks: [Track]
    let roots: [String]
    var root: String
    var pattern: String
    var options: OrganizeOptions
    private(set) var running = false
    private(set) var resultMessage: String?
    var onClose: (() -> Void)?

    static let patternKey = "organizePattern"
    static let optionsKey = "organizeOptions"

    init(env: AppEnvironment, tracks: [Track]) {
        self.env = env
        self.tracks = tracks
        roots = env.collectionFolders.map(\.path)
        root = roots.first { r in tracks.first.map { $0.path.hasPrefix(r) } ?? false } ?? roots.first ?? ""
        pattern = env.settings.string(Self.patternKey) ?? FileNamingPattern.defaultScheme
        options = env.settings.defaults.data(forKey: Self.optionsKey).flatMap { try? JSONDecoder().decode(OrganizeOptions.self, from: $0) }
            ?? OrganizeOptions()
    }

    var plan: [Organizer.Move] {
        guard !root.isEmpty else { return [] }
        return Organizer.plan(tracks, root: root, pattern: FileNamingPattern(pattern), options: options)
    }

    func run() {
        let moves = plan
        guard !moves.isEmpty, !running else { return }
        running = true
        env.settings.set(pattern, Self.patternKey)
        env.settings.set(try? JSONEncoder().encode(options), Self.optionsKey)
        for move in moves {
            env.ignoreWatcherEvents(for: move.source)
            env.ignoreWatcherEvents(for: move.destination)
        }
        let scanner = env.scanner
        let overwrite = options.overwrite
        Task {
            let result = await Organizer.execute(moves, overwrite: overwrite, scanner: scanner)
            for move in result.moved {
                guard let id = move.trackId else { continue }
                env.playlist.updateTrack(id: id) { item in
                    item.track.path = move.destination
                    item.url = URL(fileURLWithPath: move.destination)
                }
            }
            env.actions.tracksChanged(ids: result.moved.compactMap(\.trackId))
            running = false
            if result.failures.isEmpty {
                env.status.showMessage("Moved \(result.moved.count) files.")
                onClose?()
            } else {
                resultMessage = "Moved \(result.moved.count) files; \(result.failures.count) failed: " +
                    result.failures.prefix(3).map { "\(($0.key as NSString).lastPathComponent): \($0.value)" }.joined(separator: "; ")
            }
        }
    }
}

struct OrganizeFilesView: View {
    @Bindable var model: OrganizeModel

    var body: some View {
        let plan = model.plan
        VStack(alignment: .leading, spacing: 10) {
            Form {
                Picker("Collection folder", selection: $model.root) {
                    ForEach(model.roots, id: \.self) { Text($0).tag($0) }
                }
                Picker("Preset", selection: $model.pattern) {
                    ForEach(FileNamingPattern.presets, id: \.pattern) { Text($0.name).tag($0.pattern) }
                    if !FileNamingPattern.presets.contains(where: { $0.pattern == model.pattern }) {
                        Text("Custom").tag(model.pattern)
                    }
                }
                TextField("Pattern", text: $model.pattern).font(.system(.body, design: .monospaced))
                Text("Tokens: " + FileNamingPattern.tokens.joined(separator: " ") + ". Text in { } is left out when its tokens are empty.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Options") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 16) {
                            Toggle("Replace spaces with _", isOn: $model.options.replaceSpaces)
                            Toggle("Ignore “The” (%theartist%)", isOn: $model.options.ignoreThe)
                        }
                        HStack(spacing: 16) {
                            Toggle("VFAT-safe names", isOn: $model.options.vfatSafe)
                            Toggle("ASCII only", isOn: $model.options.asciiOnly)
                            Toggle("Overwrite existing files", isOn: $model.options.overwrite)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                HStack {
                    TextField("Replace (regex)", text: $model.options.regexFind)
                    TextField("with", text: $model.options.regexReplace)
                }
            }
            .formStyle(.grouped)
            Text("Preview").font(.headline)
            Table(plan) {
                TableColumn("Current") { move in Text((move.source as NSString).lastPathComponent).lineLimit(1).help(move.source) }
                TableColumn("New location") { move in
                    Text(move.destination.hasPrefix(model.root) ? String(move.destination.dropFirst(model.root.count + 1)) : move.destination)
                        .foregroundStyle(move.conflict || move.refused != nil ? Color.red : (move.unchanged ? Color.secondary : Color.primary))
                        .lineLimit(1)
                        .help(move.refused ?? (move.conflict ? "A file already exists here" : move.destination))
                }
            }
            .frame(minHeight: 180)
            HStack {
                let changing = plan.filter { !$0.unchanged && $0.refused == nil }.count
                let conflicts = plan.filter(\.conflict).count
                let refused = plan.filter { $0.refused != nil }.count
                Text("\(changing) of \(plan.count) files will move" + (conflicts > 0 ? ", \(conflicts) conflict(s)" : "")
                     + (refused > 0 ? ", \(refused) would leave the collection folder" : ""))
                    .font(.caption).foregroundStyle((conflicts > 0 && !model.options.overwrite) || refused > 0 ? .red : .secondary)
                if let message = model.resultMessage { Text(message).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("Cancel") { model.onClose?() }.keyboardShortcut(.cancelAction)
                Button("Move Files") { model.run() }.keyboardShortcut(.defaultAction)
                    .disabled(model.running || plan.allSatisfy(\.unchanged) || model.root.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 600)
    }
}

@MainActor
enum OrganizeFilesWindow {
    static func show(tracks: [Track], env: AppEnvironment) {
        let files = tracks.filter { $0.id != nil }
        guard !files.isEmpty else { return }
        guard !env.collectionFolders.isEmpty else {
            env.status.showMessage("Add a collection folder first (Tools › Collection Folders).")
            return
        }
        let model = OrganizeModel(env: env, tracks: files)
        let window = NSWindow(contentViewController: NSHostingController(rootView: OrganizeFilesView(model: model)))
        window.title = "Organize Files (\(files.count) tracks)"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 660))
        window.center()
        model.onClose = { [weak window] in window?.close() }
        OpenWindows.retain(window)
        window.makeKeyAndOrderFront(nil)
    }
}
