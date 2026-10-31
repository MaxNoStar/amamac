import Foundation

extension URLComponents {
    /// URLComponents leaves "+" unescaped in queries, which servers and links read as a space.
    public mutating func escapePlusInQuery() {
        percentEncodedQuery = percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
}
