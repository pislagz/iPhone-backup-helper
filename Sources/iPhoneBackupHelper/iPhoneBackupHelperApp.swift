import BackupCore
import SwiftUI

@main
struct iPhoneBackupHelperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: model.monitor, backups: model.backups)
        } label: {
            Image(systemName: "iphone.gen3")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the long-lived objects of the app.
@MainActor
final class AppModel: ObservableObject {
    let monitor: DeviceMonitor
    let backups: BackupController

    init() {
        AppLog.shared.log(.info, "app", "iPhone Backup Helper started")
        monitor = DeviceMonitor()
        backups = BackupController(notifier: UserNotificationNotifier())
        backups.onFinished = { [monitor] in monitor.refreshBackupFolderSoon() }
        monitor.start()
    }
}
