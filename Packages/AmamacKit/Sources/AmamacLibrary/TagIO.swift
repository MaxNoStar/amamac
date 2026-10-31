import AmamacBase
import AmamacModels
import Foundation
@preconcurrency import SFBAudioEngine

/// Audio file extensions the collection scanner picks up.
public enum AudioFileTypes {
    public static let extensions: Set<String> = {
        var set = Set(AudioFile.supportedPathExtensions.map { $0.lowercased() })
        set.formUnion(["mp3", "m4a", "m4b", "aac", "alac", "flac", "ogg", "oga", "opus", "wav", "aif", "aiff",
                       "aifc", "caf", "wv", "ape", "mpc", "tta", "dsf", "dff", "mod", "s3m", "xm", "it", "spx"])
        set.subtract(["m3u", "pls", "xspf", "cue", "txt"])
        return set
    }()

    public static func isAudio(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}

/// Tag values read from a file, before database bookkeeping fields are filled in.
public struct TagReadResult: Sendable {
    public var track: Track
    public var lyrics: String?
    /// FMPS / POPM rating normalised to 0...10, when present.
    public var rating: Int?
    public var playCount: Int?
    public var embeddedArt: Data?
}

public enum TagReader {
    /// Reads properties and metadata. Never throws for unreadable tags: falls back to file name.
    public static func read(url: URL, includeArt: Bool = false) throws -> TagReadResult {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let props = file.properties
        let meta = file.metadata
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)

        var t = Track(path: url.standardizedFileURL.path)
        t.title = clean(meta.title)
        t.artist = clean(meta.artist)
        t.albumArtist = clean(meta.albumArtist)
        t.album = clean(meta.albumTitle)
        t.composer = clean(meta.composer)
        t.genre = clean(meta.genre)
        t.comment = clean(meta.comment)
        t.year = year(from: meta.releaseDate)
        t.trackNumber = meta.trackNumber ?? 0
        t.trackTotal = meta.trackTotal ?? 0
        t.discNumber = meta.discNumber ?? 0
        t.discTotal = meta.discTotal ?? 0
        t.bpm = meta.bpm ?? 0
        t.compilation = meta.isCompilation ?? false
        t.mbReleaseId = clean(meta.musicBrainzReleaseID)
        t.mbRecordingId = clean(meta.musicBrainzRecordingID)
        t.titleSort = sortValue(meta.titleSortOrder)
        t.artistSort = sortValue(meta.artistSortOrder)
        t.albumArtistSort = sortValue(meta.albumArtistSortOrder)
        t.albumSort = sortValue(meta.albumTitleSortOrder)
        t.rgTrackGain = meta.replayGainTrackGain
        t.rgTrackPeak = meta.replayGainTrackPeak
        t.rgAlbumGain = meta.replayGainAlbumGain
        t.rgAlbumPeak = meta.replayGainAlbumPeak

        t.durationMs = Int(((props.duration ?? 0) * 1000).rounded())
        t.sampleRate = Int(props.sampleRate ?? 0)
        t.channels = Int(props.channelCount ?? 0)
        t.bitrate = Int((props.bitrate ?? 0).rounded())
        t.format = formatName(props.formatName, url: url)
        t.fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        t.mtime = (attributes?[.modificationDate] as? Date) ?? Date()

        let pictures = meta.attachedPictures
        t.hasEmbeddedArt = !pictures.isEmpty
        var art: Data?
        if includeArt {
            art = (meta.attachedPictures(ofType: .frontCover).first ?? pictures.first)?.imageData
        }

        // Derive the missing bitrate from size and duration.
        if t.bitrate == 0, t.durationMs > 0, t.fileSize > 0 {
            t.bitrate = Int(Double(t.fileSize) * 8 / Double(t.durationMs))
        }
        if t.bitrate > 10_000 { t.bitrate /= 1000 } // Some decoders report bits per second.

        let extra = meta.additionalMetadata ?? [:]
        var rating: Int? = normalizedRating(meta.rating, extra: extra)
        if rating == 0 { rating = nil }
        let playCount = extraInt(extra, keys: ["FMPS_PLAYCOUNT", "FMPS_Playcount", "PLAYCOUNT"])

        t.updateDerivedFields()
        return TagReadResult(track: t, lyrics: meta.lyrics.flatMap { $0.isEmpty ? nil : $0 },
                             rating: rating, playCount: playCount, embeddedArt: art)
    }

    /// Reads only the embedded front cover (or any picture).
    public static func embeddedArt(url: URL) -> Data? {
        guard let file = try? AudioFile(readingPropertiesAndMetadataFrom: url) else { return nil }
        let meta = file.metadata
        return (meta.attachedPictures(ofType: .frontCover).first ?? meta.attachedPictures.first)?.imageData
    }

    static func clean(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }

    static func sortValue(_ s: String?) -> String {
        let v = clean(s)
        return v.isEmpty ? "" : TextFolding.fold(v)
    }

    static func year(from date: String?) -> Int {
        guard let date = date?.trimmingCharacters(in: .whitespaces), date.count >= 4 else { return 0 }
        let prefix = date.prefix(4)
        if let y = Int(prefix), y > 0 { return y }
        // Formats like "12/03/1998".
        if let match = date.range(of: "\\d{4}", options: .regularExpression), let y = Int(date[match]) { return y }
        return 0
    }

    static func formatName(_ name: String?, url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "m4a", "m4b", "mp4": return name?.localizedCaseInsensitiveContains("lossless") == true ? "alac" : "m4a"
        case "oga": return "ogg"
        default: return ext.isEmpty ? (name ?? "").lowercased() : ext
        }
    }

    /// Converts tag ratings into Amarok's 0...10 scale. FMPS_Rating is 0...1; POPM is 0...255;
    /// plain "rating" fields are commonly 0...100 or 0...5.
    static func normalizedRating(_ raw: Int?, extra: [AnyHashable: Any]) -> Int {
        if let fmps = extraDouble(extra, keys: ["FMPS_RATING", "FMPS_Rating"]) {
            return Int((min(max(fmps, 0), 1) * 10).rounded())
        }
        guard let raw, raw > 0 else { return 0 }
        switch raw {
        case ...5: return raw * 2
        case ...10: return raw
        case ...100: return Int((Double(raw) / 10).rounded())
        default: return Int((Double(min(raw, 255)) / 255 * 10).rounded())
        }
    }

    static func extraDouble(_ extra: [AnyHashable: Any], keys: [String]) -> Double? {
        for key in keys {
            if let v = extra[key] as? String, let d = Double(v) { return d }
            if let v = extra[key] as? NSNumber { return v.doubleValue }
        }
        return nil
    }

    static func extraInt(_ extra: [AnyHashable: Any], keys: [String]) -> Int? {
        extraDouble(extra, keys: keys).map { Int($0) }
    }
}

/// Values the tag editor can change. `nil` leaves a field untouched.
public struct TagChanges: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var composer: String?
    public var genre: String?
    public var comment: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var bpm: Int?
    public var compilation: Bool?
    public var lyrics: String?
    /// 0...10; written as FMPS_Rating when "write statistics to file" is enabled.
    public var rating: Int?
    public var playCount: Int?
    /// Front cover image data; empty `Data` removes embedded art.
    public var frontCover: Data?

    public init() {}

    public var isEmpty: Bool { self == TagChanges() }
}

public enum TagWriter {
    /// Formats whose tags SFBAudioEngine writes as ID3v2.
    static let id3Extensions: Set<String> = ["mp3", "wav", "aif", "aiff", "aifc", "dsf", "dff", "tta"]

    /// SFBAudioEngine only writes the ID3v2 TDRC frame when the date parses as a full ISO-8601
    /// timestamp, so year-only dates are expanded for ID3 formats (mid-year, so converting the date to a
    /// year in any time zone gives the same year).
    static func releaseDate(year: Int, url: URL) -> String {
        id3Extensions.contains(url.pathExtension.lowercased()) ? String(format: "%04d-07-01T12:00:00Z", year) : String(year)
    }

    /// Writes tags. The file is copied, modified and swapped in with `replaceItemAt` so a decoder
    /// that has the original open keeps reading valid data.
    public static func write(_ changes: TagChanges, to url: URL) throws {
        let fm = FileManager.default
        let tempDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        let tempURL = tempDir.appendingPathComponent(url.lastPathComponent)
        defer { try? fm.removeItem(at: tempDir) }
        try fm.copyItem(at: url, to: tempURL)

        let file = try AudioFile(readingPropertiesAndMetadataFrom: tempURL)
        let meta = file.metadata
        if let v = changes.title { meta.title = v.isEmpty ? nil : v }
        if let v = changes.artist { meta.artist = v.isEmpty ? nil : v }
        if let v = changes.albumArtist { meta.albumArtist = v.isEmpty ? nil : v }
        if let v = changes.album { meta.albumTitle = v.isEmpty ? nil : v }
        if let v = changes.composer { meta.composer = v.isEmpty ? nil : v }
        if let v = changes.genre { meta.genre = v.isEmpty ? nil : v }
        if let v = changes.comment { meta.comment = v.isEmpty ? nil : v }
        if let v = changes.year { meta.releaseDate = v > 0 ? releaseDate(year: v, url: url) : nil }
        if let v = changes.trackNumber { meta.trackNumber = v > 0 ? v : nil }
        if let v = changes.discNumber { meta.discNumber = v > 0 ? v : nil }
        if let v = changes.bpm { meta.bpm = v > 0 ? v : nil }
        if let v = changes.compilation { meta.isCompilation = v ? true : nil }
        if let v = changes.lyrics { meta.lyrics = v.isEmpty ? nil : v }
        if changes.rating != nil || changes.playCount != nil {
            var extra = meta.additionalMetadata ?? [:]
            if let r = changes.rating { extra["FMPS_RATING"] = String(format: "%.1f", Double(r) / 10) }
            if let c = changes.playCount { extra["FMPS_PLAYCOUNT"] = String(c) }
            meta.additionalMetadata = extra
        }
        if let cover = changes.frontCover {
            meta.removeAttachedPicturesOfType(.frontCover)
            if !cover.isEmpty { meta.attachPicture(AttachedPicture(imageData: cover, type: .frontCover)) }
        }
        file.metadata = meta
        try file.writeMetadata()
        _ = try fm.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [])
    }
}
