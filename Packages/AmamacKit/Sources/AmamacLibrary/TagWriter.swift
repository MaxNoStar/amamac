import AmamacModels
import Foundation
@preconcurrency import SFBAudioEngine

public enum TagWriteError: LocalizedError, Equatable {
    case invalidDate(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDate(let text): "“\(text)” is not a date. Use 1998, 1998-03 or 1998-03-12."
        }
    }
}

public enum TagWriter {
    /// Writes tags. The file is copied, modified and swapped in with `replaceItemAt` so a decoder
    /// that has the original open keeps reading valid data. A symbolic link is followed first:
    /// copying the link itself would write through it to the real file, in place.
    ///
    /// SFBAudioEngine drops an ID3v2 date that is not a full timestamp, so for ID3v2 formats the
    /// exact date (the new one, or the one the file had) is written back with the TagLib helper,
    /// which also writes original dates (ID3v2, MP4) and MP4 ISRCs.
    public static func write(_ changes: TagChanges, to url: URL) throws {
        let releaseDate = try normalizedDate(changes.effectiveReleaseDate)
        let originalDate = try normalizedDate(changes.originalDate)
        let url = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        let tempDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        let tempURL = tempDir.appendingPathComponent(url.lastPathComponent)
        defer { try? fm.removeItem(at: tempDir) }
        try fm.copyItem(at: url, to: tempURL)

        let format = TagLibFieldIO.format(of: url)
        let before = format == .id3v2 ? TagLibFieldIO.read(tempURL) : nil

        let file = try AudioFile(readingPropertiesAndMetadataFrom: tempURL)
        let meta = file.metadata
        let releaseDateAsRead = meta.releaseDate
        func text(_ value: String?) -> String?? {
            value.map { $0.isEmpty ? nil : $0 }
        }
        func number(_ value: Int?) -> Int?? {
            value.map { $0 > 0 ? $0 : nil }
        }
        if let v = text(changes.title) { meta.title = v }
        if let v = text(changes.artist) { meta.artist = v }
        if let v = text(changes.albumArtist) { meta.albumArtist = v }
        if let v = text(changes.album) { meta.albumTitle = v }
        if let v = text(changes.composer) { meta.composer = v }
        if let v = text(changes.genre) { meta.genre = v }
        if let v = text(changes.comment) { meta.comment = v }
        if let v = text(releaseDate) { meta.releaseDate = v }
        if let v = number(changes.trackNumber) { meta.trackNumber = v }
        if let v = number(changes.trackTotal) { meta.trackTotal = v }
        if let v = number(changes.discNumber) { meta.discNumber = v }
        if let v = number(changes.discTotal) { meta.discTotal = v }
        if let v = number(changes.bpm) { meta.bpm = v }
        if let v = changes.compilation { meta.isCompilation = v ? true : nil }
        if let v = text(changes.grouping) { meta.grouping = v }
        let isrc = changes.isrc.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let v = text(isrc) { meta.isrc = v }
        if let v = text(changes.titleSort) { meta.titleSortOrder = v }
        if let v = text(changes.artistSort) { meta.artistSortOrder = v }
        if let v = text(changes.albumArtistSort) { meta.albumArtistSortOrder = v }
        if let v = text(changes.albumSort) { meta.albumTitleSortOrder = v }
        let originalInExtra = format == .other ? originalDate : nil
        if changes.rating != nil || changes.playCount != nil || originalInExtra != nil {
            var extra = meta.additionalMetadata ?? [:]
            if let r = changes.rating { extra["FMPS_RATING"] = String(format: "%.1f", Double(r) / 10) }
            if let c = changes.playCount { extra["FMPS_PLAYCOUNT"] = String(c) }
            if let date = originalInExtra {
                // Xiph and APE tags: an empty value removes the field. A stale ORIGINALYEAR goes too.
                extra["ORIGINALDATE"] = date
                for key in extra.keys.compactMap({ $0 as? String }) where key.caseInsensitiveCompare("ORIGINALYEAR") == .orderedSame {
                    extra[key] = ""
                }
            }
            meta.additionalMetadata = extra
        }
        if let cover = changes.frontCover {
            meta.removeAttachedPicturesOfType(.frontCover)
            if !cover.isEmpty { meta.attachPicture(AttachedPicture(imageData: cover, type: .frontCover)) }
        }
        file.metadata = meta
        try file.writeMetadata()

        switch format {
        case .id3v2:
            let exact = releaseDate ?? before?.releaseDate ?? releaseDateAsRead
            try TagLibFieldIO.write(releaseDate: exact, originalDate: originalDate, to: tempURL)
        case .mp4:
            try TagLibFieldIO.write(originalDate: originalDate, isrc: isrc, to: tempURL)
        default:
            break
        }
        _ = try fm.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
    }

    /// nil stays nil, "" clears, anything else must parse and is written as ISO at its precision.
    static func normalizedDate(_ text: String?) throws -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        guard let date = ReleaseDate(trimmed) else { throw TagWriteError.invalidDate(trimmed) }
        return date.isoString
    }
}
