import AppKit
import SwiftUI
import AmamacCore

/// The Settings window: one toolbar tab per page, each a SwiftUI form.
enum SettingsPane: String, CaseIterable {
    case playback

    var title: String {
        switch self {
        case .playback: "Playback"
        }
    }

    var symbol: String {
        switch self {
        case .playback: "play.circle"
        }
    }

    @MainActor func makeView(env: AppEnvironment) -> AnyView {
        switch self {
        case .playback: AnyView(PlaybackSettingsView(env: env))
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private let tabs = SettingsTabViewController()

    static func show(env: AppEnvironment, pane: SettingsPane? = nil) {
        let controller = shared ?? SettingsWindowController(env: env)
        shared = controller
        if let pane, let index = SettingsPane.allCases.firstIndex(of: pane) { controller.tabs.selectedTabViewItemIndex = index }
        controller.window?.title = controller.tabs.tabViewItems[controller.tabs.selectedTabViewItemIndex].label
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(env: AppEnvironment) {
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: pane.makeView(env: env))
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            item.identifier = pane.rawValue
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { Self.shared = nil }
}

/// Titles the window after the selected page, as macOS settings windows do.
final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? "Settings"
    }
}

/// Output devices, kept current while a settings page shows them.
@MainActor
@Observable
final class OutputDeviceList {
    private(set) var devices: [AudioOutputDevice] = AudioDevices.outputDevices()
    @ObservationIgnored private var observation: AudioDeviceObservation?

    init() {
        observation = AudioDevices.observeChanges { [weak self] in
            Task { @MainActor in self?.devices = AudioDevices.outputDevices() }
        }
    }
}

struct PlaybackSettingsView: View {
    let env: AppEnvironment
    @AppStorage private var fadeOnStop: Bool
    @AppStorage private var fadeOnPause: Bool
    @AppStorage private var fadeDuration: Int
    @AppStorage private var replayGainMode: ReplayGainMode
    @AppStorage private var replayGainPreamp: Double
    @AppStorage private var replayGainFallback: Double
    @AppStorage private var seekShort: Int
    @AppStorage private var seekMedium: Int
    @AppStorage private var seekLong: Int
    @AppStorage private var outputDevice: String
    @AppStorage private var resumePlayback: Bool
    @State private var devices = OutputDeviceList()

    init(env: AppEnvironment) {
        self.env = env
        let d = env.settings.defaults
        typealias K = AppSettings.Key
        _fadeOnStop = AppStorage(wrappedValue: false, K.fadeOutOnStop, store: d)
        _fadeOnPause = AppStorage(wrappedValue: false, K.fadeOutOnPause, store: d)
        _fadeDuration = AppStorage(wrappedValue: 2000, K.fadeOutDuration, store: d)
        _replayGainMode = AppStorage(wrappedValue: .track, K.replayGainMode, store: d)
        _replayGainPreamp = AppStorage(wrappedValue: 0, K.replayGainPreamp, store: d)
        _replayGainFallback = AppStorage(wrappedValue: 0, K.replayGainFallback, store: d)
        _seekShort = AppStorage(wrappedValue: 2, K.seekShort, store: d)
        _seekMedium = AppStorage(wrappedValue: 10, K.seekMedium, store: d)
        _seekLong = AppStorage(wrappedValue: 60, K.seekLong, store: d)
        _outputDevice = AppStorage(wrappedValue: "", K.outputDevice, store: d)
        _resumePlayback = AppStorage(wrappedValue: true, K.resumePlayback, store: d)
    }

    var body: some View {
        Form {
            Section("Output") {
                Picker("Output device", selection: $outputDevice) {
                    Text("System Default").tag("")
                    if !outputDevice.isEmpty && !devices.devices.contains(where: { $0.uid == outputDevice }) {
                        Text("Unavailable Device").tag(outputDevice)
                    }
                    Divider()
                    ForEach(devices.devices) { Text($0.name).tag($0.uid) }
                }
                Toggle("Resume playback when Amamac starts", isOn: $resumePlayback)
                LabeledContent("Equalizer") {
                    Button("Open Equalizer…") { EqualizerWindow.show(env: env) }
                }
            }
            Section("Fading") {
                Toggle("Fade out when stopping", isOn: $fadeOnStop)
                Toggle("Fade out when pausing", isOn: $fadeOnPause)
                LabeledContent("Fade-out duration") {
                    HStack {
                        Slider(value: Binding(get: { Double(fadeDuration) }, set: { fadeDuration = Int(($0 / 100).rounded()) * 100 }),
                               in: 200...8000)
                            .frame(width: 180)
                        Text(String(format: "%.1f s", Double(fadeDuration) / 1000)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!fadeOnStop && !fadeOnPause)
            }
            Section {
                Picker("Mode", selection: $replayGainMode) {
                    ForEach(ReplayGainMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                gainSlider("Pre-amp", $replayGainPreamp, range: -12...12)
                gainSlider("Tracks without Replay Gain", $replayGainFallback, range: -12...6)
            } header: {
                Text("Replay Gain")
            } footer: {
                Text("Track mode evens out loudness between songs; Album mode keeps each album's own dynamics. Peaks are never pushed past full scale.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Seeking") {
                seekStepper("Arrow keys", $seekMedium)
                seekStepper("With ⌘ (short)", $seekShort)
                seekStepper("With ⇧ (long)", $seekLong)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func gainSlider(_ title: String, _ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 * 2).rounded() / 2 }), in: range)
                    .frame(width: 180)
                Text(String(format: "%+.1f dB", value.wrappedValue)).monospacedDigit().frame(width: 60, alignment: .trailing)
            }
        }
        .disabled(replayGainMode == .off)
    }

    private func seekStepper(_ title: String, _ value: Binding<Int>) -> some View {
        Stepper(value: value, in: 1...600) {
            LabeledContent(title) { Text("\(value.wrappedValue) s").monospacedDigit() }
        }
    }
}
