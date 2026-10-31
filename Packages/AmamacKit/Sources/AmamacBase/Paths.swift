import Foundation

/// Plain-text checks on absolute file paths, for deciding whether a path stays inside a folder.
public enum Paths {
    /// `path` with "." and ".." resolved and repeated slashes removed, without consulting the disk.
    public static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Whether `path` is `folder` or lies below it. Compares whole components, so "/Music Old" is
    /// not inside "/Music".
    public static func isInside(_ path: String, folder: String) -> Bool {
        let path = normalized(path), folder = normalized(folder)
        return folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }
}
