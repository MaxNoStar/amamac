import AmamacPlayback

extension AppSettings {
    /// Settings › Playback › Fading, as the engine's crossfade policy.
    var crossfadePolicy: CrossfadePolicy {
        CrossfadePolicy(enabled: bool(Key.crossfade), seconds: Double(int(Key.crossfadeDuration)) / 1000,
                        keepAlbumsGapless: bool(Key.crossfadeKeepsAlbumsGapless))
    }
}
