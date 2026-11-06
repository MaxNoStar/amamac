import AmamacBase
import AmamacModels
import Foundation
@preconcurrency import SFBAudioEngine

/// Sort names exactly as the tags hold them ("" when absent). `Track` keeps folded sort keys instead.
public struct SortNames: Sendable, Hashable {
    public var title = ""
    public var artist = ""
    public var albumArtist = ""
    public var album = ""

    public init(title: String = "", artist: String = "", albumArtist: String = "", album: String = "") {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
    }
}

/// Tag values read from a file, before database bookkeeping fields are filled in.
public struct TagReadResult: Sendable {
    public var track: Track
    /// FMPS / POPM rating normalised to 0...10, when present.
    public var rating: Int?
    public var playCount: Int?
    public var embeddedArt: Data?
    public var sortNames = SortNames()
}

public enum TagReader {
    /// Reads properties and metadata. Never throws for unreadable tags: falls back to file name.
    public static func read(url: URL, includeArt: Bool = false) throws -> TagReadResult {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let props = file.properties
        let meta = file.metadata
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let extra = meta.additionalMetadata ?? [:]
        let helper = TagLibFieldIO.read(url)

        var t = Track(path: url.standardizedFileURL.path)
        t.title = clean(meta.title)
        t.artist = clean(meta.artist)
        t.albumArtist = clean(meta.albumArtist)
        t.album = clean(meta.albumTitle)
        t.composer = clean(meta.composer)
        t.genre = clean(meta.genre)
        t.comment = clean(meta.comment)
        t.releaseDate = date(meta.releaseDate)
        t.originalDate = originalDate(helper: helper, extra: extra)
        t.year = year(from: t.releaseDate)
        t.trackNumber = meta.trackNumber ?? 0
        t.trackTotal = meta.trackTotal ?? 0
        t.discNumber = meta.discNumber ?? 0
        t.discTotal = meta.discTotal ?? 0
        t.bpm = meta.bpm ?? 0
        t.compilation = meta.isCompilation ?? false
        t.grouping = clean(meta.grouping)
        // SFBAudioEngine has no MP4 ISRC.
        t.isrc = clean(meta.isrc ?? helper?.isrc)
        t.mbReleaseId = clean(meta.musicBrainzReleaseID)
        t.mbRecordingId = clean(meta.musicBrainzRecordingID)
        let sortNames = SortNames(title: clean(meta.titleSortOrder), artist: clean(meta.artistSortOrder),
                                  albumArtist: clean(meta.albumArtistSortOrder), album: clean(meta.albumTitleSortOrder))
        t.titleSort = sortValue(sortNames.title)
        t.artistSort = sortValue(sortNames.artist)
        t.albumArtistSort = sortValue(sortNames.albumArtist)
        t.albumSort = sortValue(sortNames.album)
        t.rgTrackGain = meta.replayGainTrackGain
        t.rgTrackPeak = meta.replayGainTrackPeak
        t.rgAlbumGain = meta.replayGainAlbumGain
        t.rgAlbumPeak = meta.replayGainAlbumPeak

        // Properties come from the file, so a crafted one may claim NaN or infinite values.
        t.durationMs = SafeNumbers.milliseconds(seconds: props.duration ?? 0) ?? 0
        t.sampleRate = SafeNumbers.int(props.sampleRate ?? 0) ?? 0
        t.channels = Int(props.channelCount ?? 0)
        t.bitrate = SafeNumbers.int(props.bitrate ?? 0) ?? 0
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

        var rating: Int? = normalizedRating(meta.rating, extra: extra)
        if rating == 0 { rating = nil }
        let playCount = extraInt(extra, keys: ["FMPS_PLAYCOUNT", "FMPS_Playcount", "PLAYCOUNT"])

        t.updateDerivedFields()
        return TagReadResult(track: t, rating: rating, playCount: playCount, embeddedArt: art, sortNames: sortNames)
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

    /// A tag's date as ISO at its own precision, "" when there is no year in it.
    static func date(_ raw: String?) -> String {
        ReleaseDate.lenient(clean(raw))?.isoString ?? ""
    }

    static func year(from date: String?) -> Int {
        ReleaseDate.lenient(date)?.year ?? 0
    }

    /// ORIGINALDATE (or ORIGINALYEAR) from Xiph and APE tags; TDOR or the MP4 freeform item through
    /// the TagLib helper (`helper` is what it read, nil for other formats).
    static func originalDate(helper: TagLibFieldIO.Values?, extra: [AnyHashable: Any]) -> String {
        if let helper { return date(helper.originalDate) }
        return date(extraString(extra, keys: ["ORIGINALDATE", "ORIGINALYEAR"]))
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
        if let fmps = extraDouble(extra, keys: ["FMPS_RATING", "FMPS_Rating"]), fmps.isFinite {
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

    /// The first of `keys` present, compared without case (APE keys keep the case they were written in).
    static func extraString(_ extra: [AnyHashable: Any], keys: [String]) -> String? {
        for key in keys {
            for (k, value) in extra {
                guard let k = k as? String, k.caseInsensitiveCompare(key) == .orderedSame, let s = value as? String else { continue }
                return s
            }
        }
        return nil
    }

    static func extraDouble(_ extra: [AnyHashable: Any], keys: [String]) -> Double? {
        for key in keys {
            if let v = extra[key] as? String, let d = Double(v) { return d }
            if let v = extra[key] as? NSNumber { return v.doubleValue }
        }
        return nil
    }

    static func extraInt(_ extra: [AnyHashable: Any], keys: [String]) -> Int? {
        extraDouble(extra, keys: keys).flatMap { SafeNumbers.int($0) }
    }
}
