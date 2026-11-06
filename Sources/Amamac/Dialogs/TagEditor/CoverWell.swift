import AmamacLibrary
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The embedded front cover in the tag editor's header. Takes a dropped or pasted image or a
/// chosen file (at most 20 MB; JPEG and PNG as they are, other images as PNG) and can remove the
/// cover. Keyboard: Space or Return chooses a file, Delete removes, ⌘V pastes. The Choose… and
/// Remove buttons sit next to it in the header.
struct CoverWell: View {
    let model: TagEditorModel
    let covers: CoverImageCache
    @State private var image: NSImage?
    /// The album's cover from the cover cache, shown faded when nothing is embedded.
    @State private var albumImage: NSImage?
    @State private var isTargeted = false
    @FocusState private var focused: Bool

    private struct Shown: Equatable {
        var index: Int
        var perTrack: Bool
        var revision: Int
    }

    private enum Dropped: Sendable {
        case file(URL)
        case data(Data)
    }

    static let size: CGFloat = 92

    var body: some View {
        well
            .task(id: model.session.index) { await model.loadEmbeddedCover() }
            .task(id: Shown(index: model.session.index, perTrack: model.session.perTrack, revision: model.coverRevision)) {
                image = model.shownCoverData.flatMap(NSImage.init(data:))
                albumImage = nil
                if image == nil, model.session.coverEdit == nil, let key = model.shownTrack?.albumKey {
                    albumImage = await covers.image(albumKey: key, size: 100)
                }
            }
    }

    private var well: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let albumImage {
                    Image(nsImage: albumImage).resizable().aspectRatio(contentMode: .fill).opacity(0.35)
                }
                Image(systemName: "photo.badge.plus").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isTargeted ? Color.amamacAccent : Color(nsColor: .separatorColor), lineWidth: isTargeted ? 3 : 1)
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .onTapGesture(count: 2) { model.chooseCover() }
        .onKeyPress(.space) { model.chooseCover(); return .handled }
        .onKeyPress(.return) { model.chooseCover(); return .handled }
        .onKeyPress(.delete) { model.removeCover(); return .handled }
        .onKeyPress(.deleteForward) { model.removeCover(); return .handled }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg, .image]) { _ in model.pasteCover() }
        .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
            Task {
                switch await Self.load(providers) {
                case .file(let url): await model.setCover(fileAt: url)
                case .data(let data): await model.setCover(data: data)
                case nil: model.errorMessage = EmbeddedCover.Problem.notAnImage.localizedDescription
                }
            }
            return true
        }
        .contextMenu {
            Button("Choose Image…") { model.chooseCover() }
            Button("Paste Image") { model.pasteCover() }
            Button("Remove Cover") { model.removeCover() }.disabled(!hasCover)
            if model.session.coverEdit != nil { Button("Undo Cover Change") { model.revertCover() } }
        }
        .help("Drop, paste or choose an image (at most 20 MB). Delete removes the embedded cover.")
        .accessibilityElement()
        .accessibilityLabel("Embedded cover")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Drop or paste an image, press Space to choose a file, or Delete to remove the cover.")
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: "Choose Image…") { model.chooseCover() }
        .accessibilityAction(named: "Paste Image") { model.pasteCover() }
        .accessibilityAction(named: "Remove Cover") { model.removeCover() }
    }

    private var hasCover: Bool { model.showsCoverImage }

    private var accessibilityValue: String {
        switch model.session.coverEdit {
        case .set: "New image, saved with the tags"
        case .remove: "Removed when you save"
        case nil: model.embeddedCover == nil ? "No embedded cover" : "Embedded cover"
        }
    }

    /// A dropped image file or image data. Item provider callbacks arrive off the main actor.
    private nonisolated static func load(_ providers: [NSItemProvider]) async -> Dropped? {
        guard let provider = providers.first else { return nil }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in continuation.resume(returning: url) }
            }
            return url.map(Dropped.file)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { @Sendable data, _ in
                    continuation.resume(returning: data)
                }
            }
            return data.map(Dropped.data)
        }
        return nil
    }
}
