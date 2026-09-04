import Foundation
import UserNotifications

@MainActor
final class MeetingNotifications: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "meeting-detected"
    private nonisolated static let startAction = "start-recording"
    private nonisolated static let closeAction = "close-notification"
    private let center = UNUserNotificationCenter.current()
    private var isAuthorized = false

    var onStart: ((MeetingApplication) async -> Void)?

    func configure() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.category,
                actions: [
                    UNNotificationAction(identifier: Self.startAction, title: "Start Recording"),
                    UNNotificationAction(identifier: Self.closeAction, title: "Close"),
                ],
                intentIdentifiers: []
            ),
        ])
    }

    func requestAuthorization() async -> Bool {
        isAuthorized = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        return isAuthorized
    }

    func offerRecording(for application: MeetingApplication) {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected in \(application.name)"
        content.body = "Should Scribe start recording?"
        content.categoryIdentifier = Self.category
        content.userInfo = ["bundleID": application.bundleID, "name": application.name]
        center.add(UNNotificationRequest(identifier: identifier(for: application), content: content, trigger: nil))
    }

    func clearOffer(for application: MeetingApplication) {
        center.removeDeliveredNotifications(withIdentifiers: [identifier(for: application)])
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let identifier = response.notification.request.identifier
        let bundleID = response.notification.request.content.userInfo["bundleID"] as? String
        let name = response.notification.request.content.userInfo["name"] as? String
        await handle(action: action, identifier: identifier, bundleID: bundleID, name: name)
    }

    private func handle(action: String, identifier: String, bundleID: String?, name: String?) async {
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        guard action == Self.startAction, let bundleID, let name else { return }
        await onStart?(MeetingApplication(bundleID: bundleID, name: name))
    }

    private func identifier(for application: MeetingApplication) -> String {
        "meeting-\(application.bundleID)"
    }
}
