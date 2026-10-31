import AmamacBase
import AmamacModels
import AppKit
import UserNotifications

/// Optional Notification Center banners on track changes while Amamac is in the background.
@MainActor
final class TrackNotifier {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    func trackChanged(_ item: PlaylistItem, env: AppEnvironment) {
        guard env.settings.bool(AppSettings.Key.systemNotifications), !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = item.streamTitle ?? item.track.displayTitle
        content.body = [item.track.artist, item.track.album].filter { !$0.isEmpty }.joined(separator: " — ")
        let key = item.track.albumKey
        Task {
            if item.source == .collection, let cover = await env.covers.cover(albumKey: key, size: 128) {
                // The attachment is moved into the notification store, so hand over a copy.
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + cover.pathExtension)
                if (try? FileManager.default.copyItem(at: cover, to: copy)) != nil,
                   let attachment = try? UNNotificationAttachment(identifier: "cover", url: copy) {
                    content.attachments = [attachment]
                }
            }
            let request = UNNotificationRequest(identifier: "nowPlaying", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
