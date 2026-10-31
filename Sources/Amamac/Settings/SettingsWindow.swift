import AmamacBase
import AmamacModels
import AmamacPlayback
import AppKit
import SwiftUI

/// The Settings window: one toolbar tab per page, each a SwiftUI form.
enum SettingsPane: String, CaseIterable {
    case general, collection, metadata, playback, notifications, internet, shortcuts

    var title: String {
        switch self {
        case .general: "General"
        case .collection: "Local Collection"
        case .metadata: "Metadata"
        case .playback: "Playback"
        case .notifications: "Notifications"
        case .internet: "Internet"
        case .shortcuts: "Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .collection: "music.note.house"
        case .metadata: "tag"
        case .playback: "play.circle"
        case .notifications: "text.bubble"
        case .internet: "globe"
        case .shortcuts: "keyboard"
        }
    }

    @MainActor func makeView(env: AppEnvironment, osd: OSDController?) -> AnyView {
        switch self {
        case .general: AnyView(GeneralSettingsView(env: env))
        case .collection: AnyView(CollectionSettingsView(env: env))
        case .metadata: AnyView(MetadataSettingsView(env: env))
        case .playback: AnyView(PlaybackSettingsView(env: env))
        case .notifications: AnyView(NotificationSettingsView(env: env, osd: osd))
        case .internet: AnyView(InternetSettingsView(env: env))
        case .shortcuts: AnyView(ShortcutSettingsView())
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    private let tabs = SettingsTabViewController()

    /// `osd` drives the on-screen display preview (nil in automation runs).
    static func show(env: AppEnvironment, osd: OSDController? = nil, pane: SettingsPane? = nil) {
        let controller = shared ?? SettingsWindowController(env: env, osd: osd)
        shared = controller
        if let pane, let index = SettingsPane.allCases.firstIndex(of: pane) { controller.tabs.selectedTabViewItemIndex = index }
        controller.window?.title = controller.tabs.tabViewItems[controller.tabs.selectedTabViewItemIndex].label
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(env: AppEnvironment, osd: OSDController?) {
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: pane.makeView(env: env, osd: osd))
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
