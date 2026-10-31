import AmamacPlayback
import AppKit
import SwiftUI

/// The spectrum analyzer applet, drawn in one of several styles. The output tap is installed only
/// while the applet is shown.
final class AnalyzerAppletController: Applet {
    let kind = AppletKind.analyzer
    let contentView: NSView
    private let env: AppEnvironment
    let tap = SpectrumTap()
    let state: AnalyzerState
    /// Album key and image of the cover Halo shows.
    private var cover: (albumKey: String, image: NSImage?)?

    init(env: AppEnvironment) {
        self.env = env
        let defaults = env.settings.defaults
        let player = env.player
        state = AnalyzerState(defaults: defaults, spectrum: { [tap] bands in
            guard player.state == .playing else { return nil }
            return tap.spectrum(bands: bands, sampleSize: max(512, defaults.integer(forKey: AppSettings.Key.analyzerSampleSize)),
                                minFrequency: Float(defaults.double(forKey: AppSettings.Key.analyzerMinFrequency)),
                                maxFrequency: Float(defaults.double(forKey: AppSettings.Key.analyzerMaxFrequency)))
        })
        contentView = HostedAppletView(rootView: AnalyzerView(state: state))
        state.cover = { [weak self] in self?.currentCover() }
    }

    func setActive(_ active: Bool) {
        tap.reset()
        env.player.local.setSpectrumTap(active ? tap : nil)
    }

    func makeConfigurationView() -> AnyView? {
        AnyView(AnalyzerSettingsView(defaults: env.settings.defaults))
    }

    /// The playing album's cover, loaded once per album; nil for streams and albums without one.
    private func currentCover() -> NSImage? {
        guard let item = env.player.currentItem, !item.isStream else { return nil }
        let key = item.albumKey
        if let cover, cover.albumKey == key { return cover.image }
        cover = (key, env.coverImages.image(albumKey: key, size: 128) { [weak self] image in
            guard let self, self.cover?.albumKey == key else { return }
            self.cover = (key, image)
        })
        return cover?.image
    }
}
