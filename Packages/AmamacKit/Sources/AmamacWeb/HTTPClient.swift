import AmamacBase
import Foundation
import Synchronization

public enum HTTPError: Error, LocalizedError, Equatable {
    case status(Int)
    case notFound
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .status(let code): "The server answered with status \(code)."
        case .notFound: "Not found."
        case .invalidResponse: "The server sent an invalid response."
        }
    }
}

/// HTTP for the online features: a fixed User-Agent, per-host rate limits (MusicBrainz: one request
/// per second), retries on 429/503 honouring Retry-After, and an on-disk cache with per-host lifetimes.
public final class HTTPClient: Sendable {

    struct HostPolicy {
        var minInterval: Double
        var cacheLifetime: TimeInterval
    }

    let session: URLSession
    let cacheDirectory: URL?
    private let limiter = HostRateLimiter()

    /// `configuration` lets tests and snapshots install `StubURLProtocol`.
    public init(cacheDirectory: URL?, configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpAdditionalHeaders = ["User-Agent": Amamac.userAgent]
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
        self.cacheDirectory = cacheDirectory
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    static func policy(for host: String) -> HostPolicy {
        switch host {
        case "musicbrainz.org": HostPolicy(minInterval: 1.0, cacheLifetime: 7 * 86_400)
        case "coverartarchive.org": HostPolicy(minInterval: 0.2, cacheLifetime: 30 * 86_400)
        case "www.wikidata.org": HostPolicy(minInterval: 0.1, cacheLifetime: 7 * 86_400)
        case "itunes.apple.com": HostPolicy(minInterval: 0.5, cacheLifetime: 7 * 86_400)
        case let h where h.hasSuffix(".wikipedia.org"): HostPolicy(minInterval: 0.1, cacheLifetime: 86_400)
        case let h where h.hasSuffix("radio-browser.info"): HostPolicy(minInterval: 0.1, cacheLifetime: 3_600)
        default: HostPolicy(minInterval: 0, cacheLifetime: 3_600)
        }
    }

    /// Fetches `url`, using the cache unless `useCache` is false. 404 throws `HTTPError.notFound`.
    public func data(from url: URL, useCache: Bool = true) async throws -> Data {
        let host = url.host() ?? ""
        let policy = Self.policy(for: host)
        let cacheFile = cacheURL(for: url)
        if useCache, let cacheFile, let data = Self.cached(cacheFile, lifetime: policy.cacheLifetime) { return data }

        var attempt = 0
        while true {
            await limiter.wait(host: host, interval: policy.minInterval)
            var request = URLRequest(url: url)
            request.setValue(Amamac.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                if let cacheFile { try? data.write(to: cacheFile, options: .atomic) }
                return data
            case 404:
                throw HTTPError.notFound
            case 429, 503:
                guard attempt < 3 else { throw HTTPError.status(http.statusCode) }
                attempt += 1
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? pow(2, Double(attempt))
                try await Task.sleep(for: .seconds(min(retryAfter, 30)))
            default:
                throw HTTPError.status(http.statusCode)
            }
        }
    }

    /// Downloads `url` to `destination` (replacing it), reporting progress 0...1. Not cached.
    public func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue(Amamac.userAgent, forHTTPHeaderField: "User-Agent")
        let delegate = DownloadProgressDelegate(progress)
        let (temporary, response) = try await session.download(for: request, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw http.statusCode == 404 ? HTTPError.notFound : HTTPError.status(http.statusCode) }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
        progress(1)
    }

    public func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await data(from: url))
    }

    /// Untyped JSON (for sparse responses such as Wikidata entities).
    public func jsonObject(from url: URL) async throws -> Any {
        try JSONSerialization.jsonObject(with: try await data(from: url))
    }

    public func removeCachedResponse(for url: URL) {
        if let file = cacheURL(for: url) { try? FileManager.default.removeItem(at: file) }
    }

    private func cacheURL(for url: URL) -> URL? {
        guard let cacheDirectory else { return nil }
        let digest = Hashing.sha256Hex(url.absoluteString, bytes: 16)
        return cacheDirectory.appendingPathComponent(digest + ".cache")
    }

    private static func cached(_ file: URL, lifetime: TimeInterval) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < lifetime else { return nil }
        return try? Data(contentsOf: file)
    }

    /// Builds a URL from a base and query items (values are percent-encoded).
    public static func url(_ base: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        components.escapePlusInQuery()
        return components.url!
    }
}

/// Spaces requests to the same host at least `interval` seconds apart.
actor HostRateLimiter {
    private var nextSlot: [String: ContinuousClock.Instant] = [:]

    func wait(host: String, interval: Double) async {
        guard interval > 0 else { return }
        let now = ContinuousClock.now
        let slot = max(now, nextSlot[host] ?? now)
        nextSlot[host] = slot + .seconds(interval)
        if slot > now { try? await Task.sleep(until: slot) }
    }
}

/// Forwards a download task's progress.
final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let handler: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let handler = self.handler
        let o = task.progress.observe(\.fractionCompleted) { progress, _ in handler(progress.fractionCompleted) }
        lock.withLock { observation = o }
    }
}
