import AppKit
import UserNotifications

/// Posts a system notification after each capture with the actions the user
/// didn't take by default, so they can "punch out" of the default flow.
final class CaptureNotifications: NSObject, UNUserNotificationCenterDelegate {
    private enum Action: String {
        case edit = "clip.edit"
        case save = "clip.save"
        case copy = "clip.copy"
        case reveal = "clip.reveal"
    }

    private let center = UNUserNotificationCenter.current()
    private nonisolated static let historyKey = "historyID"

    /// Called with the chosen action and the history item it applies to.
    var onEdit: ((UUID) -> Void)?
    var onSave: ((UUID) -> Void)?
    var onCopy: ((UUID) -> Void)?
    var onReveal: ((UUID) -> Void)?

    func start() {
        center.delegate = self
        let edit = UNNotificationAction(identifier: Action.edit.rawValue, title: "Open in Editor",
                                        options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "pencil.tip.crop.circle"))
        let save = UNNotificationAction(identifier: Action.save.rawValue, title: "Save to Disk",
                                        options: [], icon: UNNotificationActionIcon(systemImageName: "square.and.arrow.down"))
        let copy = UNNotificationAction(identifier: Action.copy.rawValue, title: "Copy",
                                        options: [], icon: UNNotificationActionIcon(systemImageName: "doc.on.doc"))
        let reveal = UNNotificationAction(identifier: Action.reveal.rawValue, title: "Show in Finder",
                                          options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "folder"))
        // One category per default action, listing the alternatives first.
        center.setNotificationCategories([
            UNNotificationCategory(identifier: AfterCaptureAction.copyToClipboard.rawValue, actions: [edit, save], intentIdentifiers: []),
            UNNotificationCategory(identifier: AfterCaptureAction.saveToDisk.rawValue, actions: [edit, copy, reveal], intentIdentifiers: []),
            UNNotificationCategory(identifier: AfterCaptureAction.openEditor.rawValue, actions: [copy, save], intentIdentifiers: []),
        ])
    }

    /// Asks for permission if needed. Returns whether notifications can be shown.
    func authorize() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert])) ?? false
        default:
            return false
        }
    }

    func post(for item: HistoryItem, action: AfterCaptureAction, savedURL: URL?, thumbnail: URL) async {
        let content = UNMutableNotificationContent()
        content.title = "\(item.kind.displayName) Captured"
        content.body = switch action {
        case .copyToClipboard: "Copied to clipboard · \(item.pixelWidth) × \(item.pixelHeight)"
        case .saveToDisk: "Saved to \(savedURL?.deletingLastPathComponent().lastPathComponent ?? "disk") · \(item.pixelWidth) × \(item.pixelHeight)"
        case .openEditor: "Opened in the editor · \(item.pixelWidth) × \(item.pixelHeight)"
        }
        content.categoryIdentifier = action.rawValue
        content.threadIdentifier = "captures"
        content.userInfo = [Self.historyKey: item.id.uuidString]

        // Attachments are moved into the notification store, so hand over a copy.
        let copy = FileManager.default.temporaryDirectory.appending(path: "Clip-Notification-\(item.id.uuidString).png")
        try? FileManager.default.removeItem(at: copy)
        if (try? FileManager.default.copyItem(at: thumbnail, to: copy)) != nil,
           let attachment = try? UNNotificationAttachment(identifier: "thumbnail", url: copy) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    func remove(_ id: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while Clip is the active app (it activates during capture).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let actionID = response.actionIdentifier
        guard let idString = response.notification.request.content.userInfo[Self.historyKey] as? String,
              let id = UUID(uuidString: idString) else { return }
        await MainActor.run {
            switch actionID {
            case Action.edit.rawValue, UNNotificationDefaultActionIdentifier: onEdit?(id)
            case Action.save.rawValue: onSave?(id)
            case Action.copy.rawValue: onCopy?(id)
            case Action.reveal.rawValue: onReveal?(id)
            default: break
            }
        }
    }
}
