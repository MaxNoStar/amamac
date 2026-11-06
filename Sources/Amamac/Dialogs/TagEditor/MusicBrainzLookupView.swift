import AmamacBase
import AmamacLibrary
import AmamacWeb
import SwiftUI

/// MusicBrainz candidates for the shown track; choosing one fills its fields, the full release
/// date and "of N" included.
struct MusicBrainzLookupView: View {
    let model: TagEditorModel
    let client: MusicBrainzClient
    @State private var candidates: [MusicBrainzClient.Candidate]?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MusicBrainz").font(.headline)
            if let candidates {
                if candidates.isEmpty {
                    Text("No matching recordings.").foregroundStyle(.secondary)
                } else {
                    List(candidates) { c in
                        Button {
                            apply(c)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(c.title) — \(c.artist)").fontWeight(.medium)
                                Text([c.album, c.releaseDate.isEmpty ? nil : c.releaseDate,
                                      c.trackNumber > 0 ? (c.trackTotal > 0 ? "track \(c.trackNumber) of \(c.trackTotal)" : "track \(c.trackNumber)") : nil,
                                      c.durationMs > 0 ? TimeFormatting.durationMs(c.durationMs) : nil].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 260)
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView("Searching…").controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 440)
        .task {
            let session = model.session
            guard let track = model.shownTrack else { return }
            do {
                candidates = try await client.recordings(title: session.value(.title), artist: session.value(.artist),
                                                         album: session.value(.album), durationMs: track.durationMs)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func apply(_ c: MusicBrainzClient.Candidate) {
        func number(_ n: Int) -> String { n > 0 ? String(n) : "" }
        var values: [TagEditSession.Field: String] = [
            .title: c.title, .artist: c.artist, .album: c.album, .releaseDate: c.releaseDate,
            .trackNumber: number(c.trackNumber), .trackTotal: number(c.trackTotal), .discNumber: number(c.discNumber),
        ]
        if c.albumArtist != c.artist { values[.albumArtist] = c.albumArtist }
        model.session.fill(values, at: model.session.index)
    }
}
