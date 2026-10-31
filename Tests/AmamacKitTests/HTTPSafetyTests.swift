import CoreServices
import Foundation
import Testing
@testable import AmamacBase
@testable import AmamacWeb

/// What hostile or careless servers can send: odd `Retry-After` headers, oversized bodies,
/// downgrading redirects, names that aren't URLs, and downloads onto existing files.
struct HTTPSafetyTests {
    /// Answers every request with 200 and `body`; its own class so it shares no state with other suites.
    final class FixedBodyProtocol: URLProtocol {
        static let body = Data(repeating: 0x41, count: 2_000)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    static func client() -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixedBodyProtocol.self]
        return HTTPClient(cacheDirectory: nil, configuration: config)
    }

    /// `Retry-After: nan` used to trap in `Task.sleep`; any server could send it.
    @Test func retryAfterOnlyAcceptsSaneSeconds() {
        #expect(HTTPClient.retryDelay("5") == 5)
        #expect(HTTPClient.retryDelay("0") == 0)
        #expect(HTTPClient.retryDelay("1e300") == 30)
        for bad in ["nan", "-nan", "inf", "-inf", "-1", "-1e30", "Wed, 21 Oct 2015 07:28:00 GMT", nil] {
            #expect(HTTPClient.retryDelay(bad) == nil, "\(bad ?? "nil")")
        }
    }

    @Test func responsesOverTheLimitAreRefused() async throws {
        let http = Self.client()
        let url = URL(string: "https://example.org/big")!
        await #expect(throws: HTTPError.tooLarge) { try await http.data(from: url, useCache: false, maxBytes: 1_000) }
        #expect(try await http.data(from: url, useCache: false, maxBytes: 2_000).count == 2_000)
    }

    @Test func redirectsMayNotDropFromHttpsToHttp() {
        let https = URL(string: "https://feeds.example.org/a")!, http = URL(string: "http://cdn.example.org/a")!
        #expect(!RedirectPolicy.allows(from: https, to: http))
        #expect(RedirectPolicy.allows(from: https, to: URL(string: "https://cdn.example.org/a")!))
        #expect(RedirectPolicy.allows(from: http, to: http))
        #expect(RedirectPolicy.allows(from: http, to: https))
        #expect(!RedirectPolicy.allows(from: http, to: URL(fileURLWithPath: "/etc/passwd")))
    }

    @Test func urlsBuiltFromServerValuesFailInsteadOfCrashing() {
        for bad in ["https://exa mple.org/x", "https://[x/json/url", "https://a%zz/x"] {
            #expect(throws: HTTPError.invalidURL, "\(bad)") { try HTTPClient.url(bad, []) }
        }
        #expect(throws: Never.self) { try HTTPClient.url("https://example.org/search", [("q", "a b&c")]) }
    }

    @Test func downloadsAreQuarantinedAndNeverReplaceFiles() async throws {
        let http = Self.client()
        let dir = temporaryDirectory()
        let source = URL(string: "https://feeds.example.org/episode.mp3")!

        let fresh = dir.appendingPathComponent("episode.mp3")
        try await http.download(from: source, to: fresh) { _ in }
        #expect(try Data(contentsOf: fresh) == FixedBodyProtocol.body)
        let quarantine = try fresh.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)

        let existing = dir.appendingPathComponent("mine.mp3")
        try Data("keep me".utf8).write(to: existing)
        await #expect(throws: (any Error).self) { try await http.download(from: source, to: existing) { _ in } }
        #expect(try Data(contentsOf: existing) == Data("keep me".utf8))
    }
}
