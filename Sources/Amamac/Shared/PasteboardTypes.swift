import AppKit

extension NSPasteboard.PasteboardType {
    /// JSON array of collection track ids.
    static let amamacTracks = NSPasteboard.PasteboardType("local.amamac.track-ids")
    /// A playlist item UUID string (one per dragged row; internal reordering).
    static let amamacPlaylistItems = NSPasteboard.PasteboardType("local.amamac.playlist-item")
}

/// An album passed to cover-related menu actions.
struct AlbumReference {
    var albumKey: String
    var album: String
    var artist: String
    /// MusicBrainz release id from the tags, when known (better cover lookups).
    var releaseId: String? = nil
}
