import CryptoKit
import Foundation

public enum Hashing {
    /// Lowercase hex of the first `bytes` bytes of the SHA-256 digest of `data`.
    public static func sha256Hex(_ data: Data, bytes: Int = SHA256.byteCount) -> String {
        hex(SHA256.hash(data: data), bytes: bytes)
    }

    public static func sha256Hex(_ string: String, bytes: Int = SHA256.byteCount) -> String {
        sha256Hex(Data(string.utf8), bytes: bytes)
    }

    /// Lowercase hex of the first `bytes` bytes of a finished digest.
    public static func hex(_ digest: SHA256.Digest, bytes: Int) -> String {
        digest.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }
}
