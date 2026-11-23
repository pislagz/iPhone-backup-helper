import BackupCore
import Foundation
import UserNotifications

/// Local notifications (UNUserNotificationCenter): started, needs passcode, finished, failed.
/// Does nothing when the binary is not run from an app bundle (e.g. `swift run`).
final class UserNotificationNotifier: BackupNotifying {
    private let center: UNUserNotificationCenter?

    init() {
        if Bundle.main.bundleURL.pathExtension == "app" {
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            self.center = center
        } else {
            self.center = nil
        }
    }

    func backupStarted(deviceName: String) {
        post(id: "started-\(deviceName)", title: "Backup started", body: "Backing up \(deviceName)…", sound: false)
    }

    func backupNeedsPasscode(deviceName: String) {
        post(
            id: "passcode-\(deviceName)", title: "Unlock your iPhone to back up",
            body: "Enter the passcode on \(deviceName) so the backup can continue.", sound: true)
    }

    func backupFinished(deviceName: String, duration: TimeInterval, bytes: Int64) {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let time = Self.durationText(duration)
        post(id: "done-\(deviceName)", title: "Backup finished", body: "\(deviceName): \(size) in \(time).", sound: false)
    }

    func backupFailed(deviceName: String, reason: String) {
        post(id: "failed-\(deviceName)", title: "Backup failed", body: "\(deviceName): \(reason)", sound: true)
    }

    private func post(id: String, title: String, body: String, sound: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        return minutes < 60 ? "\(minutes) min \(total % 60) s" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
