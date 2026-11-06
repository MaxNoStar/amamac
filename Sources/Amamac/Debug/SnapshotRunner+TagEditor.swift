// Debug builds and tests only: Release builds compile this out.
#if DEBUG
import AmamacDatabase
import AmamacLibrary
import AmamacTestSupport
import AppKit

/// Edit Track Details: one MP3's Tags tab (a new cover, an invalid date outlined), a save that
/// must reach the file, the collection (the play count the collection only) and the album's
/// cover, several tracks with mixed values after Number Tracks, and the Summary tab.
extension SnapshotRunner {
    func captureTagEditor(tracks: [TrackWithStatistics]) async {
        guard let hit = tracks.first(where: { $0.track.title == "Alpha Hit" }), let hitId = hit.track.id else { fail("no Alpha Hit fixture") }
        guard let one = TagEditorWindow.show(tracks: [hit], env: env) else { fail("tag editor did not open") }
        await Snapshotter.waitUntil(timeout: 5) { !one.isReadingFiles }
        one.session.set(.trackTotal, "3")
        one.session.set(.releaseDate, "2020-05-17")
        one.session.set(.originalDate, "2019-13")
        one.session.set(.grouping, "Summer Singles")
        one.session.set(.artistSort, "Alpha")
        one.showsMore = true
        _ = await env.covers.cover(albumKey: hit.track.albumKey, size: 64)
        await one.setCover(data: AudioFixtures.coverPNG(text: "AH", hue: 0.08, size: 300))
        guard one.showsCoverImage else { fail("the cover well did not take the image: \(one.errorMessage ?? "no error")") }
        guard one.session.invalidFields == [.originalDate], !one.session.canSave else { fail("invalid date was accepted") }
        await captureEditor("dialog-tag-editor-track.png")

        one.session.set(.originalDate, "2019-11")
        one.playCount.wrappedValue = 7
        one.save()
        await Snapshotter.waitUntil(timeout: 10) { editorWindow() == nil }
        guard editorWindow() == nil else { fail("tag editor did not close after saving: \(one.errorMessage ?? "no error")") }
        let saved = try? await env.database.tracks(ids: [hitId]).first
        guard let saved, saved.track.releaseDate == "2020-05-17", saved.track.originalDate == "2019-11",
              saved.track.trackTotal == 3, saved.track.grouping == "Summer Singles", saved.statistics?.playCount == 7 else {
            fail("tag edits did not reach the collection: \(String(describing: saved))")
        }
        guard let file = try? TagReader.read(url: saved.track.url), file.track.releaseDate == "2020-05-17",
              file.sortNames.artist == "Alpha", file.track.hasEmbeddedArt, file.playCount == nil else {
            fail("tag edits did not reach the file as expected")
        }
        guard await env.covers.cover(albumKey: saved.track.albumKey, size: 64) != nil else { fail("the album's cover did not refresh") }

        let ids = tracks.filter { $0.track.album == "Dïscs" }.compactMap(\.track.id)
        let album = (try? await env.database.tracks(ids: ids)) ?? []
        guard album.count == 4, let several = TagEditorWindow.show(tracks: album, env: env) else { fail("no Dïscs album to edit") }
        await Snapshotter.waitUntil(timeout: 5) { !several.isReadingFiles }
        several.session.perTrack = true
        several.session.index = 0
        several.session.setCompilation(true)
        several.session.set(.genre, "Art Pop")
        several.session.perTrack = false
        several.session.numberTracks()
        let numbers = several.session.current.map { "\($0.discNumber)/\($0.trackNumber)/\($0.trackTotal)" }.sorted()
        guard numbers == ["1/1/2", "1/2/2", "2/1/2", "2/2/2"] else { fail("Number Tracks gave \(numbers)") }
        guard several.session.compilation == .mixed, several.session.isMixed(.title), several.session.isMixed(.genre) else {
            fail("several tracks did not show mixed values")
        }
        await captureEditor("dialog-tag-editor-several.png")

        several.session.perTrack = true
        several.session.index = 1
        several.tab = .summary
        await captureEditor("dialog-tag-editor-summary.png")
        several.onClose?()
        print("snapshot: tag editor check passed")
    }

    private func editorWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title.hasPrefix("Edit Track Details") }
    }

    /// Captures the open editor with its title bar, leaving it open.
    private func captureEditor(_ name: String) async {
        try? await Task.sleep(for: .milliseconds(700))
        guard let window = editorWindow(), let view = window.contentView?.superview ?? window.contentView else {
            fail("no Edit Track Details window for \(name)")
        }
        await Snapshotter.capture(view, to: output.appendingPathComponent(name))
    }
}
#endif
