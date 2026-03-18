import Foundation

/// Tries a primary notifier (e.g. Pushover), falls back to a secondary (e.g. macOS).
/// When `pushoverMode` is `.whenLidClosed`, uses Pushover only if the MacBook lid is closed,
/// otherwise falls back to macOS local notifications.
public final class CompositeNotifier: NotifierPort, @unchecked Sendable {
    private var primary: NotifierPort?
    private let fallback: NotifierPort
    private var pushoverMode: PushoverMode

    public init(primary: NotifierPort? = nil, fallback: NotifierPort = MacOSNotificationClient(), pushoverMode: PushoverMode = .enabled) {
        self.primary = primary
        self.fallback = fallback
        self.pushoverMode = pushoverMode
    }

    public func sendNotification(title: String, message: String, imageData: Data?, cardId: String?) async throws {
        if let primary, primary.isConfigured(), shouldUsePushover() {
            do {
                try await primary.sendNotification(title: title, message: message, imageData: imageData, cardId: cardId)
                return
            } catch {
                // Fall through to fallback
            }
        }
        // Fallback doesn't support images, send text only
        try await fallback.sendNotification(title: title, message: message, imageData: nil, cardId: cardId)
    }

    public func isConfigured() -> Bool {
        true // Always configured — fallback is always available
    }

    /// Hot-swap the primary notifier (e.g. when settings change).
    public func updatePrimary(_ notifier: NotifierPort?, pushoverMode: PushoverMode = .enabled) {
        self.primary = notifier
        self.pushoverMode = pushoverMode
    }

    private func shouldUsePushover() -> Bool {
        switch pushoverMode {
        case .disabled: return false
        case .enabled: return true
        case .whenLidClosed: return LidStateDetector.isAway
        }
    }
}
