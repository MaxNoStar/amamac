import AmamacBase
import Foundation
import GRDB

/// A station as radio-browser.info describes it (also used to show saved favourites).
public struct RadioBrowserStation: Decodable, Sendable, Hashable, Identifiable {
    public var stationuuid: String
    public var name: String
    public var url: String
    public var url_resolved: String?
    public var homepage: String?
    public var favicon: String?
    public var tags: String?
    public var country: String?
    public var countrycode: String?
    public var codec: String?
    public var bitrate: Int?
    public var hls: Int?
    public var clickcount: Int?
    public var votes: Int?

    public var id: String { stationuuid.isEmpty ? url : stationuuid }

    public init(stationuuid: String, name: String, url: String, homepage: String? = nil, favicon: String? = nil,
                tags: String? = nil, country: String? = nil, codec: String? = nil, bitrate: Int? = nil, hls: Int? = nil) {
        self.stationuuid = stationuuid
        self.name = name
        self.url = url
        self.homepage = homepage
        self.favicon = favicon
        self.tags = tags
        self.country = country
        self.codec = codec
        self.bitrate = bitrate
        self.hls = hls
    }

    /// The station's stream; nil unless it is http(s), since anyone can add stations to the directory.
    public var streamURL: URL? {
        URL(string: (url_resolved?.isEmpty == false ? url_resolved! : url).trimmingCharacters(in: .whitespaces))
            .flatMap { $0.isWebURL ? $0 : nil }
    }

    /// Display name of the codec, "HLS" for HTTP Live Streaming.
    public var codecName: String {
        if hls == 1 { return "HLS" }
        let c = (codec ?? "").uppercased()
        return c.isEmpty || c == "UNKNOWN" ? "?" : c
    }

    /// AVPlayer plays MP3, AAC/HE-AAC and HLS; Ogg, Opus and FLAC Icecast streams it cannot.
    public var isPlayable: Bool { RadioBrowserClient.isPlayable(codec: codec, hls: hls == 1) }

    public var tagList: [String] {
        (tags ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public init(record: RadioStation) {
        self.init(stationuuid: record.stationUUID ?? "", name: record.name, url: record.url, homepage: record.homepage,
                  favicon: record.favicon, tags: record.tags, country: record.country,
                  codec: record.codec == "HLS" ? "AAC" : record.codec, bitrate: record.bitrate, hls: record.codec == "HLS" ? 1 : 0)
    }
}

/// A tag or country with its station count.
public struct RadioFacet: Decodable, Sendable, Hashable, Identifiable {
    public var name: String
    public var stationcount: Int
    /// ISO 3166-1 code for countries.
    public var iso_3166_1: String?
    public var id: String { iso_3166_1 ?? name }
}

/// radio-browser.info: a community directory of internet radio stations (no account needed).
public struct RadioBrowserClient: Sendable {
    let http: HTTPClient
    public let server: String

    static let fallbackServer = "de1.api.radio-browser.info"

    /// Picks one of the directory's mirrors (they are listed by `all.api.radio-browser.info`).
    public static func connect(http: HTTPClient) async -> RadioBrowserClient {
        struct Server: Decodable { var name: String }
        let servers = (try? await http.json([Server].self, from: URL(string: "https://all.api.radio-browser.info/json/servers")!)) ?? []
        // Mirror names go into URLs, so only plain host names under radio-browser.info are used.
        let names = Set(servers.map(\.name).filter { name in
            name.hasSuffix(".radio-browser.info") && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        })
        return RadioBrowserClient(http: http, server: names.sorted().first ?? fallbackServer)
    }

    public init(http: HTTPClient, server: String) {
        self.http = http
        self.server = server
    }

    public static func isPlayable(codec: String?, hls: Bool) -> Bool {
        if hls { return true }
        switch (codec ?? "").uppercased() {
        case "OGG", "OPUS", "FLAC", "VORBIS", "WMA", "FLV": return false
        default: return true
        }
    }

    private func url(_ path: String, _ query: [(String, String)] = []) throws -> URL {
        try HTTPClient.url("https://\(server)/json/\(path)", query)
    }

    public func topStations(limit: Int = 100) async throws -> [RadioBrowserStation] {
        try await http.json([RadioBrowserStation].self, from: try url("stations/topclick", [("limit", String(limit)), ("hidebroken", "true")]))
    }

    public func tags(limit: Int = 150) async throws -> [RadioFacet] {
        try await http.json([RadioFacet].self, from: try url("tags", [("order", "stationcount"), ("reverse", "true"),
                                                                  ("hidebroken", "true"), ("limit", String(limit))]))
            .filter { $0.stationcount > 0 }
    }

    public func countries() async throws -> [RadioFacet] {
        try await http.json([RadioFacet].self, from: try url("countries", [("order", "name"), ("hidebroken", "true")]))
            .filter { $0.stationcount > 0 }
    }

    public enum Filter: Sendable, Hashable {
        case tag(String)
        case country(code: String)
        case name(String)
    }

    public func stations(_ filter: Filter, limit: Int = 200) async throws -> [RadioBrowserStation] {
        var query: [(String, String)] = [("order", "clickcount"), ("reverse", "true"), ("hidebroken", "true"), ("limit", String(limit))]
        switch filter {
        case .tag(let tag): query += [("tag", tag), ("tagExact", "true")]
        case .country(let code): query += [("countrycode", code)]
        case .name(let name): query += [("name", name)]
        }
        return try await http.json([RadioBrowserStation].self, from: try url("stations/search", query))
    }

    /// Tells the directory a station was played (its popularity ranking depends on it).
    public func reportClick(_ station: RadioBrowserStation) async {
        guard !station.stationuuid.isEmpty else { return }
        _ = try? await http.data(from: try url("url/\(station.stationuuid)"), useCache: false)
    }
}
