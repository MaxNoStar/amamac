import AmamacBase
import AmamacDatabase
import AmamacDynamic
import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI

@MainActor
@Observable
final class DynamicPlaylistsModel {
    let env: AppEnvironment
    let store: GeneratorStore
    private(set) var playlists: [DynamicPlaylist] = []
    var selectedId: Int64?
    var editing: DynamicPlaylist?

    init(env: AppEnvironment) {
        self.env = env
        store = env.generators
        playlists = store.dynamicPlaylists()
        selectedId = env.dynamicMode.active?.id ?? playlists.first?.id
    }

    var mode: DynamicModeController { env.dynamicMode }
    var selected: DynamicPlaylist? { playlists.first { $0.id == selectedId } }

    func toggleOn() {
        if mode.active != nil {
            mode.stop()
        } else if let selected {
            mode.start(selected)
        }
    }

    func newPlaylist() {
        editing = DynamicPlaylist(name: "New Dynamic Playlist", bias: .random)
    }

    func duplicate() {
        guard var copy = selected else { return }
        copy.id = nil
        copy.name += " (copy)"
        editing = copy
    }

    func save(_ playlist: DynamicPlaylist) {
        let saved = store.save(playlist)
        playlists = store.dynamicPlaylists()
        selectedId = saved.id
        mode.definitionChanged(saved)
        editing = nil
    }

    func delete() {
        guard let selected, let id = selected.id else { return }
        if mode.active?.id == id { mode.stop() }
        store.deleteDynamicPlaylist(id: id)
        playlists = store.dynamicPlaylists()
        selectedId = playlists.first?.id
    }
}

struct DynamicPlaylistsView: View {
    @Bindable var model: DynamicPlaylistsModel

    var body: some View {
        let mode = model.mode
        VStack(spacing: 0) {
            List(selection: $model.selectedId) {
                ForEach(model.playlists) { p in
                    HStack {
                        Image(systemName: mode.active?.id == p.id ? "dice.fill" : "dice")
                            .foregroundStyle(mode.active?.id == p.id ? Color.amamacAccent : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            Text(p.bias.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(p.id)
                    .onTapGesture(count: 2) {
                        model.selectedId = p.id
                        mode.start(p)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Dynamic Mode", isOn: Binding(get: { mode.active != nil }, set: { _ in model.toggleOn() }))
                        .toggleStyle(.switch)
                        .disabled(model.selected == nil && mode.active == nil)
                    Spacer()
                    if mode.isWorking { ProgressView().controlSize(.small) }
                    Button("Repopulate") { mode.repopulate() }.disabled(mode.active == nil)
                }
                Stepper("Previous tracks: \(mode.previousCount)", value: Binding(get: { mode.previousCount }, set: { mode.previousCount = $0 }), in: 0...50)
                Stepper("Upcoming tracks: \(mode.upcomingCount)", value: Binding(get: { mode.upcomingCount }, set: { mode.upcomingCount = $0 }), in: 1...100)
                Toggle("Allow duplicates", isOn: Binding(get: { mode.allowDuplicates }, set: { mode.allowDuplicates = $0 }))
                HStack {
                    Button { model.newPlaylist() } label: { Image(systemName: "plus") }.help("New dynamic playlist")
                    Button { model.duplicate() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate").disabled(model.selected == nil)
                    Button("Edit…") { model.editing = model.selected }.disabled(model.selected == nil)
                    Spacer()
                    Button { model.delete() } label: { Image(systemName: "trash") }.help("Delete").disabled(model.selected == nil)
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
        }
        .sheet(item: $model.editing) { playlist in
            DynamicPlaylistEditor(playlist: playlist, onSave: { model.save($0) }, onCancel: { model.editing = nil })
        }
    }
}

struct DynamicPlaylistEditor: View {
    @State var playlist: DynamicPlaylist
    let onSave: (DynamicPlaylist) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $playlist.name).font(.headline)
            ScrollView {
                BiasEditor(bias: $playlist.bias, onRemove: nil).padding(4)
            }
            .frame(minHeight: 260)
            Text("Searches use the collection filter syntax, e.g. genre:jazz year:<1970 rating:>3.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(playlist) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
    }
}

/// Recursive editor for a bias tree.
struct BiasEditor: View {
    @Binding var bias: Bias
    let onRemove: (() -> Void)?

    enum Kind: String, CaseIterable, Identifiable {
        case random = "Random", and = "Match All", or = "Match Any", not = "Not", partition = "Partition", ifElse = "If / Else"
        case search = "Search", albumPlay = "Album Play", quizPlay = "Quiz Play"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch bias {
        case .random: .random
        case .and: .and
        case .or: .or
        case .not: .not
        case .partition: .partition
        case .ifElse: .ifElse
        case .search: .search
        case .albumPlay: .albumPlay
        case .quizPlay: .quizPlay
        }
    }

    private func make(_ kind: Kind) -> Bias {
        let children = bias.children.isEmpty ? [Bias.search("")] : bias.children
        switch kind {
        case .random: return .random
        case .and: return .and(children)
        case .or: return .or(children)
        case .not: return .not(children[0])
        case .partition: return .partition(children.map { .init(weight: 1, bias: $0) })
        case .ifElse: return .ifElse(children)
        case .search: return .search("")
        case .albumPlay: return .albumPlay(.directlyFollows)
        case .quizPlay: return .quizPlay(.artist)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: Binding(get: { kind }, set: { bias = make($0) })) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                detail
                Spacer(minLength: 0)
                if let onRemove {
                    Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            if !bias.children.isEmpty || [.and, .or, .partition, .ifElse].contains(kind) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bias.children.indices, id: \.self) { i in
                        HStack(alignment: .top) {
                            if case .partition(let parts) = bias {
                                TextField("Weight", value: Binding(get: { parts[i].weight }, set: { w in
                                    var p = parts
                                    p[i].weight = max(0, w)
                                    bias = .partition(p)
                                }), format: .number).frame(width: 44)
                            }
                            AnyView(BiasEditor(bias: child(i), onRemove: canRemoveChildren ? { removeChild(i) } : nil))
                        }
                    }
                    if kind != .not {
                        Button { addChild() } label: { Label("Add", systemImage: "plus.circle") }.buttonStyle(.borderless).font(.caption)
                    }
                }
                .padding(.leading, 18)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch bias {
        case .search(let q):
            TextField("Filter, e.g. genre:rock", text: Binding(get: { q }, set: { bias = .search($0) }))
        case .albumPlay(let mode):
            Picker("", selection: Binding(get: { mode }, set: { bias = .albumPlay($0) })) {
                ForEach(Bias.AlbumPlayMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
        case .quizPlay(let field):
            Picker("Letter chain on", selection: Binding(get: { field }, set: { bias = .quizPlay($0) })) {
                ForEach(Bias.QuizField.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .fixedSize()
        default:
            EmptyView()
        }
    }

    private var canRemoveChildren: Bool { kind != .not && bias.children.count > 1 }

    private func child(_ i: Int) -> Binding<Bias> {
        Binding(get: { bias.children.indices.contains(i) ? bias.children[i] : .random }, set: { new in
            switch bias {
            case .and(var c): c[i] = new; bias = .and(c)
            case .or(var c): c[i] = new; bias = .or(c)
            case .ifElse(var c): c[i] = new; bias = .ifElse(c)
            case .not: bias = .not(new)
            case .partition(var p): p[i].bias = new; bias = .partition(p)
            default: break
            }
        })
    }

    private func addChild() {
        switch bias {
        case .and(let c): bias = .and(c + [.search("")])
        case .or(let c): bias = .or(c + [.search("")])
        case .ifElse(let c): bias = .ifElse(c + [.random])
        case .partition(let p): bias = .partition(p + [.init(weight: 1, bias: .random)])
        default: break
        }
    }

    private func removeChild(_ i: Int) {
        switch bias {
        case .and(var c): c.remove(at: i); bias = .and(c)
        case .or(var c): c.remove(at: i); bias = .or(c)
        case .ifElse(var c): c.remove(at: i); bias = .ifElse(c)
        case .partition(var p): p.remove(at: i); bias = .partition(p)
        default: break
        }
    }
}
