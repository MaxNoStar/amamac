import AmamacDatabase
import AmamacLibrary
import AmamacWeb
import SwiftUI

/// The Tags tab: text fields with completion, track and disc "n of N", dates, the compilation
/// checkbox, a More section and the tools row.
extension TagEditorView {
    typealias Field = TagEditSession.Field

    var tags: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                textRow("Title", .title)
                textRow("Artist", .artist, completion: .artist)
                textRow("Album Artist", .albumArtist, completion: .albumArtist)
                textRow("Album", .album, completion: .album)
                textRow("Composer", .composer, completion: .composer)
                textRow("Genre", .genre, completion: .genre)
                row("Track") { numbersRow }
                row("BPM") { input("Beats per minute", .bpm).frame(width: 64) }
                row("Released", alignment: .firstTextBaseline) { datesRow }
                textRow("Comment", .comment)
                row(nil) { compilationToggle }
                DisclosureGroup("More", isExpanded: $model.showsMore) {
                    VStack(alignment: .leading, spacing: 8) {
                        textRow("Grouping", .grouping)
                        row("ISRC") {
                            input("ISRC", .isrc, prompt: "CC-XXX-YY-NNNNN").frame(width: 170)
                            Text("Recording code, like GB-AYE-06-01690")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        textRow("Sort Title", .titleSort)
                        textRow("Sort Artist", .artistSort)
                        textRow("Sort Album Artist", .albumArtistSort)
                        textRow("Sort Album", .albumSort)
                    }
                    .padding(.top, 8)
                }
                .padding(.top, 4)
                toolsRow.padding(.top, 4)
            }
            .padding(16)
        }
    }

    // MARK: Rows

    /// Width of the label column, so More's rows line up with the rest.
    static let labelWidth: CGFloat = 118

    /// A labelled row; the label is for sighted users, the fields carry their own VoiceOver names.
    func row(_ title: String?, alignment: VerticalAlignment = .center,
             @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: alignment, spacing: 8) {
            Text(title.map { $0 + ":" } ?? "")
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .trailing)
                .accessibilityHidden(true)
            content()
            Spacer(minLength: 0)
        }
    }

    func textRow(_ title: String, _ field: Field, completion: CompletionField? = nil) -> some View {
        row(title) { input(title, field, completion: completion) }
    }

    func input(_ label: String, _ field: Field, prompt: String = "", hint: String? = nil,
               completion: CompletionField? = nil) -> CompletingTextField {
        CompletingTextField(label: label, text: model.binding(field), isMixed: model.session.isMixed(field),
                            isValid: model.session.isValid(field), prompt: prompt, hint: hint,
                            completion: completion, database: model.env.database)
    }


    /// Track n of N and Disc n of N.
    private var numbersRow: some View {
        HStack(spacing: 6) {
            input("Track number", .trackNumber).frame(width: 64)
            inlineLabel("of", secondary: true)
            input("Number of tracks", .trackTotal, hint: "Tracks on this disc").frame(width: 64)
            inlineLabel("Disc:").padding(.leading, 18)
            input("Disc number", .discNumber).frame(width: 64)
            inlineLabel("of", secondary: true)
            input("Number of discs", .discTotal).frame(width: 64)
        }
        .fixedSize()
    }

    /// Release date and original date, with one hint for both.
    private var datesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                dateInput("Release date", .releaseDate)
                inlineLabel("Original:").padding(.leading, 18)
                dateInput("Original release date", .originalDate)
            }
            .fixedSize()
            Text("A year, a month or a day: 1998, 1998-03 or 1998-03-12")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func inlineLabel(_ text: String, secondary: Bool = false) -> some View {
        Text(text)
            .foregroundStyle(secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .fixedSize()
            .accessibilityHidden(true)
    }

    private func dateInput(_ label: String, _ field: Field) -> some View {
        let valid = model.session.isValid(field)
        return VStack(alignment: .leading, spacing: 2) {
            input(label, field, prompt: "YYYY-MM-DD", hint: "A year, a year and month, or a full date, like 1998-03-12")
                .frame(width: 124)
            if !valid {
                Text("Not a date").font(.caption).foregroundStyle(.red).accessibilityHidden(true)
            }
        }
    }

    private var compilationToggle: some View {
        let session = model.session
        // One source per edited track, so the checkbox shows "mixed"; setting any of them sets all.
        let sources = session.targets.map { i in
            Binding(get: { model.session.current[i].compilation }, set: { model.session.setCompilation($0) })
        }
        return Toggle("Part of a compilation", sources: sources, isOn: \.self)
            .toggleStyle(.checkbox)
            .accessibilityValue(session.compilation == .mixed ? "Mixed" : session.compilation == .on ? "On" : "Off")
    }

    // MARK: Tools

    private var toolsRow: some View {
        HStack {
            Button("Guess from Filename…") { showGuess = true }
                .popover(isPresented: $showGuess) { guessPopover }
            Button("Look Up on MusicBrainz…") { showMusicBrainz = true }
                .disabled(!model.session.showsOneTrack)
                .help(model.session.showsOneTrack ? "Look the track up on MusicBrainz" : "Turn on Per Track to look up a single track")
                .popover(isPresented: $showMusicBrainz) {
                    MusicBrainzLookupView(model: model, client: MusicBrainzClient(http: model.env.http))
                }
            if model.session.isMultiple {
                Button("Number Tracks") { model.session.numberTracks() }
                    .help("Number the tracks 1…N on each disc, by disc, track number and file name, and set “of N”")
            }
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
                    let matched = model.session.guessFromFilenames(pattern: guessPattern)
                    guessResult = matched == 0 ? "No file name matched the pattern." : "Filled in \(matched) track(s)."
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
