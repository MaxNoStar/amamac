import Foundation

public enum PlaylistFileFormat: String, CaseIterable, Sendable {
    case m3u, m3u8, pls, xspf, asx

    public static func from(url: URL) -> PlaylistFileFormat? {
        PlaylistFileFormat(rawValue: url.pathExtension.lowercased())
    }

    public var displayName: String {
        switch self {
        case .m3u: "M3U Playlist"
        case .m3u8: "M3U8 Playlist (UTF-8)"
        case .pls: "PLS Playlist"
        case .xspf: "XSPF Playlist"
        case .asx: "ASX Playlist"
        }
    }

    public static let fileExtensions = allCases.map(\.rawValue)
}
