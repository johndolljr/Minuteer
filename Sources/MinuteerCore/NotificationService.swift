import Foundation
import UserNotifications

public protocol NotificationService: Sendable {
    func requestAuthorization() async -> Bool
    func postNotification(title: String, subtitle: String?, body: String) async
}

public final class SystemNotificationService: NotificationService, @unchecked Sendable {
    public static let shared = SystemNotificationService()
    var customPoster: (@Sendable (String, String?, String) async -> Void)?
    var customAuthorizer: (@Sendable () async -> Bool)?
    public var authorizationHandler: (@Sendable () async throws -> Bool)?
    public var notificationCenterAddHandler: (@Sendable (UNNotificationRequest) async throws -> Void)?

    public init(
        customPoster: (@Sendable (String, String?, String) async -> Void)? = nil,
        customAuthorizer: (@Sendable () async -> Bool)? = nil
    ) {
        self.customPoster = customPoster
        self.customAuthorizer = customAuthorizer
    }

    public func requestAuthorization() async -> Bool {
        if let authorizer = customAuthorizer {
            return await authorizer()
        }
        if let handler = authorizationHandler {
            do {
                return try await handler()
            } catch {
                return false
            }
        }
        guard Bundle.main.bundleIdentifier != nil else {
            return false
        }
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    public func postNotification(title: String, subtitle: String?, body: String) async {
        if let poster = customPoster {
            await poster(title, subtitle, body)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let sub = subtitle {
            content.subtitle = sub
        }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        if let handler = notificationCenterAddHandler {
            do {
                try await handler(request)
            } catch {
                // Handled in test handler
            }
            return
        }

        guard Bundle.main.bundleIdentifier != nil else {
            return
        }

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Notifications may be restricted in non-app bundle or test runner
        }
    }
}
