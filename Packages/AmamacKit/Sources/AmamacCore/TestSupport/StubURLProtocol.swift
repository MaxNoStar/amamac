import Foundation
import Synchronization

/// Serves canned responses instead of the network (tests and `--snapshot`). Install it with
/// `StubURLProtocol.configuration { request in ... }`.
public final class StubURLProtocol: URLProtocol {
    public typealias Responder = @Sendable (URLRequest) -> (status: Int, body: Data)?
    static let responder = Mutex<Responder?>(nil)
    static let requests = Mutex<[URL]>([])

    /// A session configuration whose requests are answered by `responder` (nil → 404).
    public static func configuration(_ responder: @escaping Responder) -> URLSessionConfiguration {
        self.responder.withLock { $0 = responder }
        requests.withLock { $0 = [] }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    /// URLs requested since the stub was installed.
    public static var requestedURLs: [URL] { requests.withLock { $0 } }

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let request = self.request
        if let url = request.url { Self.requests.withLock { $0.append(url) } }
        let answer = Self.responder.withLock { $0 }?(request) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override public func stopLoading() {}
}
