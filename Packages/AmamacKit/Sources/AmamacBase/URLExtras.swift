import Foundation

extension URLComponents {
    /// URLComponents leaves "+" unescaped in queries, which servers and links read as a space.
    public mutating func escapePlusInQuery() {
        percentEncodedQuery = percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
}

extension URL {
    /// Whether the scheme is exactly http or https: the only URLs Amamac streams from or hands to
    /// the browser.
    public var isWebURL: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
