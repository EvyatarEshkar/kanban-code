import Foundation
import UserNotifications

/// Sends notifications via macOS UNUserNotificationCenter.
/// Always available as a fallback when Pushover is not configured.
public final class MacOSNotificationClient: NotifierPort, @unchecked Sendable {

    public init() {}

    public func sendNotification(title: String, message: String, imageData: Data?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // Deliver immediately
        )

        try await UNUserNotificationCenter.current().add(request)
    }

    public func isConfigured() -> Bool {
        true // Always available on macOS
    }
}
