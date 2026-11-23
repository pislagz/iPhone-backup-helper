import BackupCore
import SwiftUI

@main
struct iPhoneBackupHelperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: model.monitor)
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

    init() {
        monitor = DeviceMonitor()
        monitor.start()
    }
}
