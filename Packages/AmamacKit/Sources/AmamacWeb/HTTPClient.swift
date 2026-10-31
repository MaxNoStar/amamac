import AmamacBase
import CoreServices
import Foundation
import Synchronization

public enum HTTPError: Error, LocalizedError, Equatable {
    case status(Int)
    case notFound
    case invalidResponse
    case invalidURL
    case tooLarge
    case insecureRedirect

    public var errorDescription: String? {
        switch self {
        case .status(let code): "The server answered with status \(code)."
        case .notFound: "Not found."
        case .invalidResponse: "The server sent an invalid response."
        case .invalidURL: "The address is not valid."
        case .tooLarge: "The server sent more data than expected."
        case .insecureRedirect: "The server redirected to an insecure (http) address."
        }
    }
}

/// HTTP for the online features: a fixed User-Agent, per-host rate limits (MusicBrainz: one request
/// per second), retries on 429/503 honouring Retry-After, and an on-disk cache with per-host lifetimes.
/// Responses are size-capped, redirects from https to plain http are refused, and downloads are
/// quarantined like a browser's.
public final class HTTPClient: Sendable {
    /// Largest response `data(from:)` accepts.
    public static let maxResponseBytes = 16 * 1024 * 1024
    /// Largest file `download(from:to:)` accepts.
    public static let maxDownloadBytes: Int64 = 4 * 1024 * 1024 * 1024

    struct HostPolicy {
        var minInterval: Double
        var cacheLifetime: TimeInterval
    }

    let session: URLSession
    /// Separate so downloads get hours while ordinary requests must finish within two minutes.
    let downloadSession: URLSession
    let cacheDirectory: URL?
    private let limiter = HostRateLimiter()

    /// `configuration` lets tests and snapshots install `StubURLProtocol`.
    public init(cacheDirectory: URL?, configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpAdditionalHeaders = ["User-Agent": Amamac.userAgent]
        configuration.timeoutIntervalForRequest = 20
        let downloads = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForResource = 120
        downloads.timeoutIntervalForResource = 2 * 3_600
        session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        downloadSession = URLSession(configuration: downloads, delegate: RedirectPolicy(), delegateQueue: nil)
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
        case let h where h == "radio-browser.info" || h.hasSuffix(".radio-browser.info"): HostPolicy(minInterval: 0.1, cacheLifetime: 3_600)
        default: HostPolicy(minInterval: 0, cacheLifetime: 3_600)
        }
    }

    /// Fetches `url`, using the cache unless `useCache` is false. 404 throws `HTTPError.notFound`;
    /// a body over `maxBytes` throws `HTTPError.tooLarge`.
    public func data(from url: URL, useCache: Bool = true, maxBytes: Int = maxResponseBytes) async throws -> Data {
        let host = url.host() ?? ""
        let policy = Self.policy(for: host)
        let cacheFile = cacheURL(for: url)
        if useCache, let cacheFile, let data = Self.cached(cacheFile, lifetime: policy.cacheLifetime) { return data }

        var attempt = 0
        while true {
            await limiter.wait(host: host, interval: policy.minInterval)
            var request = URLRequest(url: url)
            request.setValue(Amamac.userAgent, forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
            switch http.statusCode {
            case 200..<300:
                let data = try await Self.collect(bytes, expected: response.expectedContentLength, limit: maxBytes)
                if let cacheFile { try? data.write(to: cacheFile, options: .atomic) }
                return data
            case 300..<400:
                // URLSession follows every redirect except the ones `RedirectPolicy` refuses.
                throw HTTPError.insecureRedirect
            case 404:
                throw HTTPError.notFound
            case 429, 503:
                guard attempt < 3 else { throw HTTPError.status(http.statusCode) }
                attempt += 1
                let delay = Self.retryDelay(http.value(forHTTPHeaderField: "Retry-After")) ?? pow(2, Double(attempt))
                try await Task.sleep(for: .seconds(delay))
            default:
                throw HTTPError.status(http.statusCode)
            }
        }
    }

    /// Downloads `url` to `destination`, reporting progress 0...1. Not cached. Never replaces an
    /// existing item: the move fails instead. The file is quarantined like a browser download, so
    /// macOS warns before opening anything unexpected from it.
    public func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.setValue(Amamac.userAgent, forHTTPHeaderField: "User-Agent")
        let delegate = DownloadProgressDelegate(progress, limit: Self.maxDownloadBytes)
        let temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await downloadSession.download(for: request, delegate: delegate)
        } catch where delegate.exceededLimit {
            throw HTTPError.tooLarge
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw HTTPError.insecureRedirect }
        guard (200..<300).contains(http.statusCode) else { throw http.statusCode == 404 ? HTTPError.notFound : HTTPError.status(http.statusCode) }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: temporary, to: destination)
        Self.quarantine(destination, origin: url)
        progress(1)
    }

    /// Marks a downloaded file the way browsers do (`com.apple.quarantine`).
    static func quarantine(_ file: URL, origin: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: Amamac.appName,
            kLSQuarantineDataURLKey as String: origin,
        ]
        var file = file
        try? file.setResourceValues(values)
    }

    /// The wait a `Retry-After` header asks for, in seconds, if it is a sane number of them (0–30).
    static func retryDelay(_ header: String?) -> Double? {
        guard let seconds = header.flatMap(Double.init), seconds.isFinite, seconds >= 0 else { return nil }
        return min(seconds, 30)
    }

    /// Reads a response body, giving up as soon as it is larger than `limit`.
    static func collect(_ bytes: URLSession.AsyncBytes, expected: Int64, limit: Int) async throws -> Data {
        guard expected <= Int64(limit) else { throw HTTPError.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(max(0, expected)))
        for try await byte in bytes {
            guard data.count < limit else { throw HTTPError.tooLarge }
            data.append(byte)
        }
        return data
    }

    /// Deletes cache files older than the longest cache lifetime. Run once at launch, off the main thread.
    public func pruneCache(olderThan age: TimeInterval = 30 * 86_400) {
        guard let cacheDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files where file.pathExtension == "cache" {
            if let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
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

    /// Builds a URL from a base and query items (values are percent-encoded). Throws `invalidURL`
    /// when the base, which can carry values from servers, isn't a valid URL.
    public static func url(_ base: String, _ query: [(String, String)]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw HTTPError.invalidURL }
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        components.escapePlusInQuery()
        guard let url = components.url else { throw HTTPError.invalidURL }
        return url
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

/// Follows redirects, except from https to plain http, which would let anyone on the network
/// replace what a secure address serves. A refused redirect leaves the 3xx response as the result.
class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.allows(from: response.url ?? task.currentRequest?.url, to: request.url) ? request : nil)
    }

    static func allows(from: URL?, to: URL?) -> Bool {
        guard let to, to.isWebURL else { return false }
        return from?.scheme?.lowercased() != "https" || to.scheme?.lowercased() == "https"
    }
}

/// Forwards a download task's progress and cancels it once it grows past `limit` bytes.
final class DownloadProgressDelegate: RedirectPolicy, @unchecked Sendable {
    private let handler: @Sendable (Double) -> Void
    private let limit: Int64
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var exceeded = false

    init(_ handler: @escaping @Sendable (Double) -> Void, limit: Int64) {
        self.handler = handler
        self.limit = limit
    }

    var exceededLimit: Bool { lock.withLock { exceeded } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let o = task.progress.observe(\.fractionCompleted) { [weak self, weak task] progress, _ in
            guard let self else { return }
            if progress.completedUnitCount > limit || progress.totalUnitCount > limit {
                lock.withLock { exceeded = true }
                task?.cancel()
            } else {
                handler(progress.fractionCompleted)
            }
        }
        lock.withLock { observation = o }
    }
}
