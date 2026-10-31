import AmamacBase
import AmamacDatabase
import AmamacDynamic
import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI

@MainActor
@Observable
final class GeneratorModel {
    let env: AppEnvironment
    let store: GeneratorStore
    private(set) var presets: [GeneratorPreset] = []
    var selectedId: Int64?
    var draft: GeneratorPreset?
    var quality = 2.0
    private(set) var running = false
    private(set) var result: (ids: [Int64], quality: Double, duration: Int)?

    init(env: AppEnvironment) {
        self.env = env
        store = env.generators
        presets = store.generatorPresets()
        select(presets.first?.id)
    }

    func select(_ id: Int64?) {
        selectedId = id
        draft = presets.first { $0.id == id }
        result = nil
    }

    var isDirty: Bool { draft != presets.first { $0.id == selectedId } }

    func saveDraft() {
        guard let draft else { return }
        let saved = store.save(draft)
        presets = store.generatorPresets()
        select(saved.id)
    }

    func newPreset() {
        let saved = store.save(GeneratorPreset(name: "New Preset", root: .group(matchAll: true, [.trackCount(20, comparison: .about, strength: 1)])))
        presets = store.generatorPresets()
        select(saved.id)
    }

    func deletePreset() {
        guard let id = selectedId else { return }
        store.deleteGeneratorPreset(id: id)
        presets = store.generatorPresets()
        select(presets.first?.id)
    }

    func run() {
        guard let root = draft?.root, !running else { return }
        running = true
        result = nil
        let db = env.database
        let iterations = Int(1000 * pow(2, quality))
        Task {
            let universe = try? await TrackUniverse.load(db, queries: root.searchQueries)
            let output = await Task.detached { () -> PlaylistGenerator.Result? in
                guard let universe else { return nil }
                var rng = SystemRandomNumberGenerator()
                return PlaylistGenerator(root: root, universe: universe).run(iterations: iterations, rng: &rng)
            }.value
            if let output, let universe {
                let ms = output.trackIds.reduce(0) { $0 + (universe.byId[$1]?.durationMs ?? 0) }
                result = (output.trackIds, output.quality, ms)
            }
            running = false
        }
    }

    func use(_ mode: LibraryActions.AddMode) {
        guard let ids = result?.ids else { return }
        let tracks = (try? env.database.tracks(ids: ids)) ?? []
        env.actions.addToPlaylist(tracks, mode: mode)
    }
}

struct GeneratorView: View {
    @Bindable var model: GeneratorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Preset", selection: Binding(get: { model.selectedId }, set: { model.select($0) })) {
                    ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                Button { model.newPreset() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("New preset")
                Button { model.deletePreset() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete preset")
            }
            .padding(8)
            Divider()
            if model.draft != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name", text: Binding(get: { model.draft?.name ?? "" }, set: { model.draft?.name = $0 }))
                        ConstraintEditor(constraint: Binding(get: { model.draft!.root }, set: { model.draft?.root = $0 }), onRemove: nil)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Quality").font(.caption)
                    Slider(value: $model.quality, in: 0...4).help("Higher quality searches longer")
                }
                HStack {
                    Button("Save Preset") { model.saveDraft() }.disabled(!model.isDirty)
                    Spacer()
                    Button("Generate") { model.run() }.keyboardShortcut(.defaultAction).disabled(model.running || model.draft == nil)
                }
                if model.running { ProgressView().progressViewStyle(.linear) }
                if let result = model.result {
                    Text("\(result.ids.count) tracks · \(TimeFormatting.durationMs(result.duration)) · \(Int((result.quality * 100).rounded()))% of the constraints met")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Add to Playlist") { model.use(.append) }
                        Button("Replace Playlist") { model.use(.replace) }
                    }
                }
            }
            .padding(10)
        }
    }
}

/// Recursive editor for generator constraints, laid out to fit the narrow Media Sources pane.
struct ConstraintEditor: View {
    @Binding var constraint: GeneratorConstraint
    let onRemove: (() -> Void)?

    enum Kind: String, CaseIterable, Identifiable {
        case group = "Group", matchTags = "Match Tags", duration = "Duration", trackCount = "Playlist Length",
             totalSize = "Total Size", duplicates = "Prevent Duplicates", spread = "Spread Artists", checkpoint = "Checkpoint"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch constraint {
        case .group: .group
        case .matchTags: .matchTags
        case .duration: .duration
        case .trackCount: .trackCount
        case .totalSize: .totalSize
        case .preventDuplicates: .duplicates
        case .spreadArtists: .spread
        case .checkpoint: .checkpoint
        }
    }

    private static func make(_ kind: Kind) -> GeneratorConstraint {
        switch kind {
        case .group: .group(matchAll: true, [])
        case .matchTags: .matchTags(query: "", invert: false, strength: 1)
        case .duration: .duration(seconds: 3600, comparison: .about, strength: 1)
        case .trackCount: .trackCount(20, comparison: .about, strength: 1)
        case .totalSize: .totalSize(megabytes: 700, comparison: .atMost, strength: 1)
        case .duplicates: .preventDuplicates(.track)
        case .spread: .spreadArtists(strength: 0.7)
        case .checkpoint: .checkpoint(query: "", atSeconds: 0, strength: 1)
        }
    }

    var body: some View {
        if case .group(let all, let children) = constraint {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    kindPicker
                    Picker("", selection: Binding(get: { all }, set: { constraint = .group(matchAll: $0, children) })) {
                        Text("all of").tag(true)
                        Text("any of").tag(false)
                    }
                    .labelsHidden().fixedSize()
                    Spacer(minLength: 0)
                    removeButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(children.indices, id: \.self) { i in
                        AnyView(ConstraintEditor(constraint: Binding(get: { children.indices.contains(i) ? children[i] : .preventDuplicates(.track) }, set: { new in
                            var c = children
                            c[i] = new
                            constraint = .group(matchAll: all, c)
                        }), onRemove: {
                            var c = children
                            c.remove(at: i)
                            constraint = .group(matchAll: all, c)
                        }))
                    }
                    Button {
                        constraint = .group(matchAll: all, children + [.matchTags(query: "", invert: false, strength: 1)])
                    } label: { Label("Add Constraint", systemImage: "plus.circle") }
                    .buttonStyle(.borderless).font(.caption)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    kindPicker
                    Spacer(minLength: 0)
                    removeButton
                }
                detail
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
    }

    private var kindPicker: some View {
        Picker("", selection: Binding(get: { kind }, set: { constraint = Self.make($0) })) {
            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private var removeButton: some View {
        if let onRemove {
            Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove")
        }
    }

    private func comparisonPicker(_ selection: Binding<GeneratorConstraint.Comparison>) -> some View {
        Picker("", selection: selection) {
            ForEach(GeneratorConstraint.Comparison.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func strengthRow(_ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text("Strength").font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
        }
        .help("How much this constraint matters")
    }

    @ViewBuilder private var detail: some View {
        switch constraint {
        case .group:
            EmptyView()
        case .matchTags(let q, let invert, let s):
            HStack(spacing: 6) {
                Toggle("Not", isOn: Binding(get: { invert }, set: { constraint = .matchTags(query: q, invert: $0, strength: s) }))
                    .toggleStyle(.checkbox)
                TextField("Filter, e.g. genre:rock", text: Binding(get: { q }, set: { constraint = .matchTags(query: $0, invert: invert, strength: s) }))
            }
            strengthRow(Binding(get: { s }, set: { constraint = .matchTags(query: q, invert: invert, strength: $0) }))
        case .duration(let secs, let c, let s):
            HStack(spacing: 6) {
                comparisonPicker(Binding(get: { c }, set: { constraint = .duration(seconds: secs, comparison: $0, strength: s) }))
                TextField("Minutes", value: Binding(get: { secs / 60 }, set: { constraint = .duration(seconds: max(1, $0) * 60, comparison: c, strength: s) }),
                          format: .number).frame(width: 50)
                Text("minutes")
            }
            strengthRow(Binding(get: { s }, set: { constraint = .duration(seconds: secs, comparison: c, strength: $0) }))
        case .trackCount(let n, let c, let s):
            HStack(spacing: 6) {
                comparisonPicker(Binding(get: { c }, set: { constraint = .trackCount(n, comparison: $0, strength: s) }))
                TextField("Tracks", value: Binding(get: { n }, set: { constraint = .trackCount(max(1, $0), comparison: c, strength: s) }),
                          format: .number).frame(width: 50)
                Text("tracks")
            }
            strengthRow(Binding(get: { s }, set: { constraint = .trackCount(n, comparison: c, strength: $0) }))
        case .totalSize(let mb, let c, let s):
            HStack(spacing: 6) {
                comparisonPicker(Binding(get: { c }, set: { constraint = .totalSize(megabytes: mb, comparison: $0, strength: s) }))
                TextField("MB", value: Binding(get: { mb }, set: { constraint = .totalSize(megabytes: max(1, $0), comparison: c, strength: s) }),
                          format: .number).frame(width: 60)
                Text("MB")
            }
            strengthRow(Binding(get: { s }, set: { constraint = .totalSize(megabytes: mb, comparison: c, strength: $0) }))
        case .preventDuplicates(let field):
            Picker("No two tracks with the same", selection: Binding(get: { field }, set: { constraint = .preventDuplicates($0) })) {
                ForEach(GeneratorConstraint.DuplicateField.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .font(.caption)
            .fixedSize()
        case .spreadArtists(let s):
            strengthRow(Binding(get: { s }, set: { constraint = .spreadArtists(strength: $0) }))
        case .checkpoint(let q, let at, let s):
            TextField("Filter, e.g. title:intro", text: Binding(get: { q }, set: { constraint = .checkpoint(query: $0, atSeconds: at, strength: s) }))
            HStack(spacing: 6) {
                Text("starts at")
                TextField("Minute", value: Binding(get: { at / 60 }, set: { constraint = .checkpoint(query: q, atSeconds: max(0, $0) * 60, strength: s) }),
                          format: .number).frame(width: 50)
                Text("minutes")
            }
            strengthRow(Binding(get: { s }, set: { constraint = .checkpoint(query: q, atSeconds: at, strength: $0) }))
        }
    }
}
