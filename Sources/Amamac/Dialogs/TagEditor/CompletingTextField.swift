import AmamacDatabase
import SwiftUI

/// A tag editor text field: "Various" when the selected tracks differ, a red outline when the
/// value can't be saved, and suggestions from the collection while it has focus.
struct CompletingTextField: View {
    /// The VoiceOver name (the visible label is a separate grid cell).
    let label: String
    @Binding var text: String
    var isMixed = false
    var isValid = true
    var prompt = ""
    var hint: String?
    var completion: CompletionField?
    var database: LibraryDatabase?
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(isMixed ? "Various" : prompt))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .focused($focused)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.red, lineWidth: 1.5)
                    .opacity(isValid ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .textInputSuggestions {
                ForEach(suggestions, id: \.self) { Text($0).textInputCompletion($0) }
            }
            .task(id: focused ? text : nil) { await loadSuggestions() }
            .accessibilityLabel(label)
            .accessibilityValue(isMixed && text.isEmpty ? "Various" : text)
            .accessibilityHint(accessibilityHint)
    }

    private var accessibilityHint: String {
        let parts = [isValid ? nil : "This value can’t be saved.", isMixed ? "The selected tracks have different values." : nil, hint]
        return parts.compactMap { $0 }.joined(separator: " ")
    }

    private func loadSuggestions() async {
        guard focused, let completion, let database else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let values = (try? await database.distinctValues(completion, prefix: text, limit: 12)) ?? []
        guard !Task.isCancelled else { return }
        suggestions = values.filter { $0 != text }
    }
}
