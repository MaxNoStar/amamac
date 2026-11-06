import Foundation
@preconcurrency import SFBAudioEngine

/// Audio file extensions the collection scanner picks up.
public enum AudioFileTypes {
    public static let extensions: Set<String> = {
        var set = Set(AudioFile.supportedPathExtensions.map { $0.lowercased() })
        set.formUnion(["mp3", "m4a", "m4b", "aac", "alac", "flac", "ogg", "oga", "opus", "wav", "aif", "aiff",
                       "aifc", "caf", "wv", "ape", "mpc", "tta", "dsf", "dff", "mod", "s3m", "xm", "it", "spx"])
        set.subtract(["m3u", "pls", "xspf", "cue", "txt"])
        return set
    }()

    public static func isAudio(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
}
