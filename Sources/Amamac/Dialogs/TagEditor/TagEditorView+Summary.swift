import AmamacBase
import AmamacLibrary
import SwiftUI

/// The Summary tab: file facts and statistics; rating and play count are editable (library only).
extension TagEditorView {
    var summary: some View {
        Form {
            if model.session.showsOneTrack, let t = model.shownTrack {
                let s = model.shownStatistics
                LabeledContent("Length", value: TimeFormatting.durationMs(t.durationMs))
                LabeledContent("Format", value: [t.format.uppercased(), t.bitrate > 0 ? "\(t.bitrate) kbps" : nil,
                                                 t.sampleRate > 0 ? "\(t.sampleRate) Hz" : nil,
                                                 t.channels > 0 ? (t.channels == 1 ? "mono" : "\(t.channels) channels") : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: t.fileSize, countStyle: .file))
                if let id = t.id {
                    LabeledContent("Rating") {
                        RatingStars(rating: s?.rating ?? 0) { model.env.player.setRating($0, trackId: id) }
                    }
                    playCountRow
                } else {
                    LabeledContent("Play Count", value: "\(s?.playCount ?? 0)")
                }
                LabeledContent("Score", value: "\(Int((s?.score ?? 0).rounded()))")
                LabeledContent("First Played", value: s?.firstPlayed.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                LabeledContent("Last Played", value: s?.lastPlayed.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                LabeledContent("Added", value: t.dateAdded.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Location") { Text(t.path).textSelection(.enabled).lineLimit(3).font(.caption) }
            } else {
                let tracks = model.tracks
                LabeledContent("Tracks", value: "\(tracks.count)")
                LabeledContent("Total Length", value: TimeFormatting.durationMs(tracks.reduce(0) { $0 + $1.durationMs }))
                LabeledContent("Total Size", value: ByteCountFormatter.string(fromByteCount: tracks.reduce(0) { $0 + $1.fileSize }, countStyle: .file))
                LabeledContent("Formats", value: Set(tracks.map { $0.format.uppercased() }).sorted().joined(separator: ", "))
                Text("Turn on Per Track to see and change one track’s statistics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Play count with a stepper. It changes the library only, never the file.
    private var playCountRow: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("Play count", value: model.playCount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .labelsHidden()
                    .accessibilityLabel("Play count")
                Stepper("Play count", value: model.playCount, in: 0...StatisticsStore.maxPlayCount)
                    .labelsHidden()
                    .accessibilityLabel("Play count")
                    .accessibilityValue("\(model.playCount.wrappedValue)")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Play Count")
                Text("Kept in the library, not written to the file").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
