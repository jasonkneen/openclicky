//
//  OpenClickyDesktopNotificationCenter.swift
//  leanring-buddy
//
//  Small wrapper around macOS UserNotifications so OpenClicky can send
//  user-visible desktop messages from the app, Agent Mode, and the local
//  external-control bridge without stealing focus.
//

import Foundation
import UserNotifications

final class OpenClickyDesktopNotificationCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OpenClickyDesktopNotificationCenter()

    private let center = UNUserNotificationCenter.current()
    private let logQueue = DispatchQueue(label: "com.jkneen.openclicky.desktop-notifications")

    private override init() {
        super.init()
    }

    func configure() {
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            self.logAuthorizationStatus(settings.authorizationStatus, reason: "startup")
        }
    }

    func requestAuthorizationForUserAction() {
        requestAuthorization(reason: "settings")
    }

    func postTestNotification() {
        requestAuthorization(reason: "settings_test") { [weak self] granted in
            guard granted else { return }
            _ = self?.post(
                title: "OpenClicky notifications are on",
                body: "Task-complete alerts will appear here without stealing focus.",
                threadID: "openclicky.settings",
                userInfo: ["source": "settings_test"]
            )
        }
    }

    @discardableResult
    func post(
        title: String,
        body: String,
        subtitle: String? = nil,
        threadID: String? = nil,
        identifier: String = UUID().uuidString,
        playSound: Bool = true,
        userInfo: [String: String] = [:]
    ) -> String {
        let trimmedTitle = Self.cleaned(title, fallback: "OpenClicky")
        let trimmedBody = Self.cleaned(body, fallback: "OpenClicky has an update.")
        guard Self.notificationsEnabled else {
            logDeliveryResult(
                event: "openclicky.desktop_notification.disabled",
                fields: [
                    "identifier": identifier,
                    "title": trimmedTitle,
                    "bodyLength": trimmedBody.count
                ]
            )
            return identifier
        }

        let content = UNMutableNotificationContent()
        content.title = trimmedTitle
        content.body = trimmedBody
        if let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        if let threadID = threadID?.trimmingCharacters(in: .whitespacesAndNewlines), !threadID.isEmpty {
            content.threadIdentifier = threadID
        }
        if playSound {
            content.sound = .default
        }
        if !userInfo.isEmpty {
            content.userInfo = userInfo
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        deliver(request, title: trimmedTitle, bodyLength: trimmedBody.count)
        return identifier
    }

    private func deliver(_ request: UNNotificationRequest, title: String, bodyLength: Int) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.add(request, title: title, bodyLength: bodyLength)
            case .notDetermined:
                self.requestAuthorization(reason: "first_send") { granted in
                    guard granted else { return }
                    self.add(request, title: title, bodyLength: bodyLength)
                }
            case .denied:
                self.logDeliveryResult(
                    event: "openclicky.desktop_notification.denied",
                    fields: [
                        "identifier": request.identifier,
                        "title": title,
                        "bodyLength": bodyLength
                    ]
                )
            @unknown default:
                self.logDeliveryResult(
                    event: "openclicky.desktop_notification.unknown_authorization",
                    fields: [
                        "identifier": request.identifier,
                        "title": title,
                        "bodyLength": bodyLength,
                        "authorizationStatus": "unknown"
                    ]
                )
            }
        }
    }

    private func add(_ request: UNNotificationRequest, title: String, bodyLength: Int) {
        center.add(request) { [weak self] error in
            guard let self else { return }
            var fields: [String: Any] = [
                "identifier": request.identifier,
                "title": title,
                "bodyLength": bodyLength,
                "threadID": request.content.threadIdentifier
            ]
            if let error {
                fields["error"] = error.localizedDescription
                self.logDeliveryResult(event: "openclicky.desktop_notification.failed", fields: fields)
            } else {
                self.logDeliveryResult(event: "openclicky.desktop_notification.sent", fields: fields)
            }
        }
    }

    private func requestAuthorization(reason: String, completion: ((Bool) -> Void)? = nil) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            guard let self else { return }
            var fields: [String: Any] = [
                "reason": reason,
                "granted": granted
            ]
            if let error {
                fields["error"] = error.localizedDescription
            }
            self.logDeliveryResult(event: "openclicky.desktop_notification.authorization", fields: fields)
            completion?(granted)
        }
    }

    private func logAuthorizationStatus(_ status: UNAuthorizationStatus, reason: String) {
        logDeliveryResult(
            event: "openclicky.desktop_notification.authorization_status",
            fields: [
                "reason": reason,
                "status": Self.authorizationStatusName(status)
            ]
        )
    }

    private func logDeliveryResult(event: String, fields: [String: Any]) {
        logQueue.async {
            OpenClickyMessageLogStore.shared.append(
                lane: "notifications",
                direction: "internal",
                event: event,
                fields: fields
            )
        }
    }

    private static func cleaned(_ text: String, fallback: String) -> String {
        let cleaned = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func authorizationStatusName(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static var notificationsEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppBundleConfiguration.userDesktopNotificationsEnabledDefaultsKey) == nil {
            return true
        }
        return defaults.bool(forKey: AppBundleConfiguration.userDesktopNotificationsEnabledDefaultsKey)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}
