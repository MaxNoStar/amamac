import SwiftUI

/// The Labels tab: the shown track's labels (or every selected track's), with existing labels to add.
extension TagEditorView {
    var labelsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add label", text: $newLabel)
                    .onSubmit { addLabel() }
                Button("Add") { addLabel() }.disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(model.session.shownLabels, id: \.self) { label in
                    HStack {
                        Image(systemName: "tag").accessibilityHidden(true)
                        Text(label)
                        Spacer()
                        Button { model.session.removeLabel(label) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove label \(label)")
                    }
                }
            }
            let shown = Set(model.session.shownLabels)
            let suggestions = model.allLabels.filter { !shown.contains($0) }
            if !suggestions.isEmpty {
                Text("Existing labels").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.self) { label in
                            Button(label) { model.session.addLabel(label) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(8)
    }

    private func addLabel() {
        model.session.addLabel(newLabel)
        newLabel = ""
    }
}
