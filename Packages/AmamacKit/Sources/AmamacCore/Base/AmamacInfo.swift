import Foundation

/// The app's name and version, and the User-Agent its web requests send.
public enum Amamac {
    public static let appName = "Amamac"
    /// The running app's version; "0.1" outside an app bundle (tests).
    public static let version: String = {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "0.1" }
        return version
    }()
    public static let userAgent = "Amamac/\(version) (macOS music player)"
}
