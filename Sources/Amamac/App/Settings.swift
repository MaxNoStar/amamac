import AmamacDatabase
import AmamacPlayback
import AmamacPlaylist
import AppKit

/// Typed access to user defaults. Every key is registered here with its default.
@MainActor
final class AppSettings {
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: Self.registeredDefaults)
    }

    static let registeredDefaults: [String: Any] = [
        Key.volume: 80,
        Key.muted: false,
        Key.trackProgression: TrackProgression.standard.rawValue,
        Key.favor: FavorMode.none.rawValue,
        Key.collectionGrouping: ["albumArtist", "album"],
        Key.showYears: true,
        Key.showTrackNumbers: true,
        Key.showArtistForVarious: true,
        Key.showCoverArt: true,
        Key.playlistLayout: "Default",
        Key.playlistGrouping: PlaylistGrouping.album.rawValue,
        Key.playlistSearchFields: PlaylistSearchFields.default.rawValue,
        Key.resumePlayback: true,
        Key.startPlayingOnAdd: false,
        Key.fadeOutOnStop: false,
        Key.fadeOutOnPause: false,
        Key.fadeOutDuration: 2000,
        Key.replayGainMode: ReplayGainMode.track.rawValue,
        Key.replayGainPreamp: 0.0,
        Key.replayGainFallback: 0.0,
        Key.equalizerEnabled: false,
        Key.equalizerPreset: "Zero",
        Key.equalizerBands: [Double](repeating: 0, count: 10),
        Key.equalizerPreamp: 0.0,
        Key.seekShort: 2,
        Key.seekMedium: 10,
        Key.seekLong: 60,
        Key.lockLayout: true,
        Key.slimToolbar: false,
        Key.showTrayIcon: true,
        Key.autoFetchCovers: false,
        Key.autoScrollPlaylist: true,
        Key.writeStatisticsToFile: false,
        Key.osdEnabled: true,
        Key.osdDuration: 5000,
        Key.osdTranslucent: true,
        Key.osdFontScale: 115,
        Key.osdHideWhenFullscreen: true,
        Key.osdScreen: 0,
        Key.osdTextColor: "#FFFFFF",
        Key.osdPosition: [0.5, 0.9],
        Key.systemNotifications: false,
        Key.inhibitSleep: true,
        Key.pauseOnSleep: true,
        Key.wikipediaLanguage: "en",
        Key.lyricsFontSize: 13.0,
        Key.enabledApplets: ["currentTrack", "lyrics", "wikipedia"],
        Key.analyzerBarWidth: 8.0,
        Key.analyzerFallSpeed: 3,
        Key.analyzerShowFadebars: true,
        Key.analyzerSampleSize: 4096,
        Key.analyzerMinFrequency: 40.0,
        Key.analyzerMaxFrequency: 16_000.0,
        Key.timeDisplayRemaining: false,
        Key.dynamicPrevious: 5,
        Key.dynamicUpcoming: 10,
        Key.dynamicAllowDuplicates: false,
        Key.podcastUpdateMinutes: 60,
        Key.radioHideUnplayable: true,
        Key.firstRunDone: false,
    ]

    enum Key {
        static let volume = "volume"
        static let muted = "muted"
        static let trackProgression = "trackProgression"
        static let favor = "favor"
        static let collectionGrouping = "collectionGrouping"
        static let showYears = "collectionShowYears"
        static let showTrackNumbers = "collectionShowTrackNumbers"
        static let showArtistForVarious = "collectionShowArtistForVarious"
        static let showCoverArt = "collectionShowCoverArt"
        static let playlistLayout = "playlistLayout"
        static let playlistGrouping = "playlistGrouping"
        static let playlistSearchFields = "playlistSearchFields"
        static let resumePlayback = "resumePlayback"
        static let startPlayingOnAdd = "startPlayingOnAdd"
        static let fadeOutOnStop = "fadeOutOnStop"
        static let fadeOutOnPause = "fadeOutOnPause"
        static let fadeOutDuration = "fadeOutDuration"
        static let replayGainMode = "replayGainMode"
        static let replayGainPreamp = "replayGainPreamp"
        static let replayGainFallback = "replayGainFallback"
        static let equalizerManual = "equalizerManual"
        static let equalizerUserPresets = "equalizerUserPresets"
        static let equalizerEnabled = "equalizerEnabled"
        static let equalizerPreset = "equalizerPreset"
        static let equalizerBands = "equalizerBands"
        static let equalizerPreamp = "equalizerPreamp"
        static let seekShort = "seekShort"
        static let seekMedium = "seekMedium"
        static let seekLong = "seekLong"
        static let lockLayout = "lockLayout"
        static let slimToolbar = "slimToolbar"
        static let showTrayIcon = "showTrayIcon"
        static let autoFetchCovers = "autoFetchCovers"
        static let autoScrollPlaylist = "autoScrollPlaylist"
        static let writeStatisticsToFile = "writeStatisticsToFile"
        static let osdEnabled = "osdEnabled"
        static let osdDuration = "osdDuration"
        static let osdTranslucent = "osdTranslucent"
        static let osdFontScale = "osdFontScale"
        static let osdHideWhenFullscreen = "osdHideWhenFullscreen"
        static let osdPosition = "osdPosition"
        static let osdScreen = "osdScreen"
        static let osdTextColor = "osdTextColor"
        static let systemNotifications = "systemNotifications"
        static let inhibitSleep = "inhibitSleep"
        static let pauseOnSleep = "pauseOnSleep"
        static let wikipediaLanguage = "wikipediaLanguage"
        static let lyricsFontSize = "lyricsFontSize"
        static let enabledApplets = "enabledApplets"
        static let collapsedApplets = "collapsedApplets"
        static let appletHeights = "appletHeights"
        static let timeDisplayRemaining = "timeDisplayRemaining"
        static let dynamicPrevious = "dynamicPrevious"
        static let dynamicUpcoming = "dynamicUpcoming"
        static let dynamicAllowDuplicates = "dynamicAllowDuplicates"
        static let activeDynamicPlaylist = "activeDynamicPlaylist"
        static let fileBrowserFolder = "fileBrowserFolder"
        static let podcastUpdateMinutes = "podcastUpdateMinutes"
        static let podcastFolder = "podcastFolder"
        static let radioHideUnplayable = "radioHideUnplayable"
        static let paneWidths = "paneWidths"
        static let hiddenPanes = "hiddenPanes"
        static let firstRunDone = "firstRunDone"
        static let outputDevice = "outputDevice"
        static let analyzerBarWidth = "analyzerBarWidth"
        static let analyzerFallSpeed = "analyzerFallSpeed"
        static let analyzerShowFadebars = "analyzerShowFadebars"
        static let analyzerSampleSize = "analyzerSampleSize"
        static let analyzerMinFrequency = "analyzerMinFrequency"
        static let analyzerMaxFrequency = "analyzerMaxFrequency"
    }

    func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    func int(_ key: String) -> Int { defaults.integer(forKey: key) }
    func double(_ key: String) -> Double { defaults.double(forKey: key) }
    func string(_ key: String) -> String? { defaults.string(forKey: key) }
    func set(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .amamacSettingChanged, object: key)
    }

    var volume: Int {
        get { int(Key.volume) }
        set { set(max(0, min(100, newValue)), Key.volume) }
    }

    var trackProgression: TrackProgression {
        get { TrackProgression(rawValue: string(Key.trackProgression) ?? "") ?? .standard }
        set { set(newValue.rawValue, Key.trackProgression) }
    }

    var favor: FavorMode {
        get { FavorMode(rawValue: string(Key.favor) ?? "") ?? .none }
        set { set(newValue.rawValue, Key.favor) }
    }

    var collectionGrouping: CollectionGrouping {
        get {
            let raw = defaults.stringArray(forKey: Key.collectionGrouping) ?? []
            let levels = raw.compactMap(CollectionLevel.init(rawValue:))
            return levels.isEmpty ? .albumArtistAlbum : CollectionGrouping(levels)
        }
        set { set(newValue.levels.map(\.rawValue), Key.collectionGrouping) }
    }

    var replayGainMode: ReplayGainMode {
        get { ReplayGainMode(rawValue: string(Key.replayGainMode) ?? "") ?? .track }
        set { set(newValue.rawValue, Key.replayGainMode) }
    }

    var enabledApplets: [String] {
        get { defaults.stringArray(forKey: Key.enabledApplets) ?? [] }
        set { set(newValue, Key.enabledApplets) }
    }
}

extension Notification.Name {
    static let amamacSettingChanged = Notification.Name("amamacSettingChanged")
}
