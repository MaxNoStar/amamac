import AppKit
import SwiftUI
import AmamacCore

/// Builds a collection filter from attribute conditions (Amarok's "Edit Filter" dialog). The
/// result is ordinary filter text, so it can also be typed or refined by hand.
@MainActor
@Observable
final class EditFilterModel {
    struct Condition: Identifiable {
        let id = UUID()
        var field: QueryField?
        var op: QueryOperator = .contains
        var value = ""
        var negated = false

        var term: QueryTerm? {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return QueryTerm(negated: negated, field: field, op: field?.kind == .text || field == nil ? (op == .equals ? .equals : .contains) : op,
                             value: trimmed)
        }
    }

    var conditions: [Condition]
    var matchAll = true
    var text: String

    init(initial: String) {
        text = initial
        let query = CollectionQuery.parse(initial)
        // Show simple filters as conditions; anything with OR stays as text only.
        if query.groups.allSatisfy({ $0.count == 1 }) && !query.groups.isEmpty {
            conditions = query.groups.map { Condition(field: $0[0].field, op: $0[0].op, value: $0[0].value, negated: $0[0].negated) }
        } else if query.groups.count == 1 {
            matchAll = false
            conditions = query.groups[0].map { Condition(field: $0.field, op: $0.op, value: $0.value, negated: $0.negated) }
        } else {
            conditions = [Condition(field: .artist)]
        }
    }

    func rebuildText() {
        let terms = conditions.compactMap(\.term)
        let query = CollectionQuery(groups: matchAll ? terms.map { [$0] } : (terms.isEmpty ? [] : [terms]))
        text = query.text
    }
}

struct EditFilterView: View {
    @Bindable var model: EditFilterModel
    let onDone: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Match", selection: $model.matchAll) {
                Text("All of the following").tag(true)
                Text("Any of the following").tag(false)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .onChange(of: model.matchAll) { model.rebuildText() }
            ForEach($model.conditions) { $condition in
                HStack {
                    Picker("", selection: $condition.field) {
                        Text("Any text").tag(QueryField?.none)
                        Divider()
                        ForEach(QueryField.allCases, id: \.self) { Text($0.displayName).tag(QueryField?.some($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Picker("", selection: $condition.op) {
                        if condition.field == nil || condition.field?.kind == .text {
                            Text("contains").tag(QueryOperator.contains)
                            Text("is").tag(QueryOperator.equals)
                        } else {
                            Text("is").tag(QueryOperator.equals)
                            Text(condition.field?.kind == .date ? "newer than" : "more than").tag(QueryOperator.greater)
                            Text(condition.field?.kind == .date ? "older than" : "less than").tag(QueryOperator.less)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    TextField(placeholder(condition.field), text: $condition.value)
                    Toggle("Not", isOn: $condition.negated).toggleStyle(.checkbox)
                    Button {
                        model.conditions.removeAll { $0.id == condition.id }
                        model.rebuildText()
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(model.conditions.count == 1)
                }
                .onChange(of: condition.field) { _, field in
                    if field?.kind == .number || field?.kind == .date { condition.op = field?.kind == .date ? .greater : .equals }
                    else if condition.op != .equals { condition.op = .contains }
                    model.rebuildText()
                }
                .onChange(of: condition.value) { model.rebuildText() }
                .onChange(of: condition.op) { model.rebuildText() }
                .onChange(of: condition.negated) { model.rebuildText() }
            }
            Button {
                model.conditions.append(.init(field: .title))
            } label: { Label("Add Condition", systemImage: "plus.circle") }
            .buttonStyle(.borderless)
            Divider()
            Text("Filter").font(.caption).foregroundStyle(.secondary)
            TextField("Filter text", text: $model.text).font(.system(.body, design: .monospaced))
            Text("Dates take ages like 2w (two weeks), 3m or 1y; ratings are stars (3.5); length is seconds or m:ss.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button("Apply") { onDone(model.text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 620)
    }

    private func placeholder(_ field: QueryField?) -> String {
        switch field?.kind {
        case .date: "e.g. 2w"
        case .number: field == .rating ? "stars, e.g. 4" : "number"
        default: "text"
        }
    }
}

enum EditFilterDialog {
    @MainActor
    static func show(initial: String, relativeTo window: NSWindow?, completion: @escaping (String) -> Void) {
        let model = EditFilterModel(initial: initial)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let finish: (String?) -> Void = { [weak panel] text in
            guard let panel else { return }
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
            if let text { completion(text) }
        }
        panel.contentViewController = NSHostingController(rootView: EditFilterView(model: model, onDone: finish))
        panel.title = "Edit Filter"
        if let window {
            window.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
