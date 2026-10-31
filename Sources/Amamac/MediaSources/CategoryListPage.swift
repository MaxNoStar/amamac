import AmamacModels
import AmamacPlaylist
import AppKit
import SwiftUI

/// The root list of categories (big rows with icon and description).
final class CategoryListPage: NSViewController, MediaSourcePage {
    var crumbTitle: String { "Home" }
    var crumbSymbol: String { "house" }
    private let onOpen: (MediaCategory) -> Void

    init(onOpen: @escaping (MediaCategory) -> Void) {
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let hosting = NSHostingView(rootView: CategoryListView(onOpen: onOpen))
        hosting.sizingOptions = []
        view = hosting
    }
}

private struct CategoryListView: View {
    let onOpen: (MediaCategory) -> Void
    @State private var hovered: MediaCategory?

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(MediaCategory.allCases, id: \.self) { category in
                    Button { onOpen(category) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.symbol)
                                .font(.system(size: 24))
                                .frame(width: 36)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title).font(.headline)
                                Text(category.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 8).fill(hovered == category ? Color.amamacAccent.opacity(0.12) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? category : (hovered == category ? nil : hovered) }
                    .accessibilityLabel(category.title)
                }
            }
            .padding(8)
        }
    }
}
