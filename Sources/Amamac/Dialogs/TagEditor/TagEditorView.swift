import AmamacLibrary
import SwiftUI

/// Edit Track Details: a header with the cover well, Summary / Tags / Labels tabs and a footer.
/// With several tracks, fields edit all of them unless Per Track is on.
struct TagEditorView: View {
    @Bindable var model: TagEditorModel
    let covers: CoverImageCache
    @State var showGuess = false
    @State var guessPattern = FilenameTagGuesser.presets[0]
    @State var guessResult: String?
    @State var showMusicBrainz = false
    @State var newLabel = ""

    var body: some View {
        VStack(spacing: 0) {
            header.padding(14)
            Picker("Section", selection: $model.tab) {
                Text("Summary").tag(TagEditorModel.Tab.summary)
                Text("Tags").tag(TagEditorModel.Tab.tags)
                Text("Labels").tag(TagEditorModel.Tab.labels)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 6)
            Divider()
            Group {
                switch model.tab {
                case .summary: summary
                case .tags: tags
                case .labels: labelsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isStaticText)
            }
            footer.padding(14)
        }
        .frame(minWidth: 640, minHeight: 600)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverWell(model: model, covers: covers)
            VStack(alignment: .leading, spacing: 3) {
                if model.session.showsOneTrack, let track = model.shownTrack {
                    Text(track.displayTitle).font(.headline).lineLimit(1)
                    Text("\(track.displayArtist) — \(track.displayAlbum)").foregroundStyle(.secondary).lineLimit(1)
                    if model.session.isMultiple {
                        Text("Track \(model.session.index + 1) of \(model.session.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(model.session.count) tracks").font(.headline)
                    Text("Changes apply to every selected track.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Button("Choose…") { model.chooseCover() }
                        .accessibilityLabel("Choose Cover Image…")
                    Button("Remove") { model.removeCover() }
                        .disabled(!model.showsCoverImage)
                        .accessibilityLabel("Remove Cover")
                    Text(model.session.showsOneTrack ? "Embedded cover: drop or paste an image"
                                                     : "Cover of all selected tracks: drop or paste an image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .controlSize(.small)
            }
            .frame(height: CoverWell.size)
            Spacer(minLength: 0)
            if model.session.isMultiple {
                VStack(alignment: .trailing, spacing: 6) {
                    Toggle("Per Track", isOn: $model.session.perTrack).toggleStyle(.checkbox)
                    ControlGroup {
                        Button { model.session.index -= 1 } label: { Image(systemName: "chevron.left") }
                            .disabled(!model.session.perTrack || model.session.index == 0)
                            .accessibilityLabel("Previous Track")
                        Button { model.session.index += 1 } label: { Image(systemName: "chevron.right") }
                            .disabled(!model.session.perTrack || model.session.index >= model.session.count - 1)
                            .accessibilityLabel("Next Track")
                    }
                    .frame(width: 70)
                    .help("Previous / Next track")
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Shout-out to anditron 🤘")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.isSaving || model.isReadingFiles { ProgressView().controlSize(.small) }
            Button("Cancel") { model.onRequestClose?() }
                .keyboardShortcut(.cancelAction)
            Button("Save & Close") { model.save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.amamacAccentFill)
                .disabled(!model.session.canSave || model.isSaving)
            // ⌘S saves too (Return already does through the default button).
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.session.canSave || model.isSaving)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}
