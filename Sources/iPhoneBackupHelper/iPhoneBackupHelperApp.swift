import AppKit
import BackupCore
import Combine
import SwiftUI

@main
struct iPhoneBackupHelperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                monitor: model.monitor, backups: model.backups, scheduler: model.scheduler)
        } label: {
            Image(systemName: "iphone.gen3")
        }
        .menuBarExtraStyle(.window)

        Window("iPhone Backup Helper Settings", id: SettingsWindow.id) {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

enum SettingsWindow {
    static let id = "settings"
}

/// Owns the long-lived objects of the app.
@MainActor
final class AppModel: ObservableObject {
    let monitor: DeviceMonitor
    let backups: BackupController
    let settings: SettingsStore
    let scheduler: BackupScheduler
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []

    init() {
        AppLog.shared.log(.info, "app", "iPhone Backup Helper started")
        let settings = SettingsStore()
        let monitor = DeviceMonitor()
        let backups = BackupController(
            notifier: FilteringNotifier(
                base: UserNotificationNotifier(), preferences: settings.notificationPreferences),
            passcodeWaitProvider: { [settings] udid in settings.settings(for: udid).passcodeWaitSeconds })
        backups.onFinished = { [monitor] in monitor.refreshBackupFolderSoon() }
        let folder = BackupFolder()
        let scheduler = BackupScheduler(
            controller: backups,
            devices: { [monitor] in monitor.devices },
            settings: { [settings] in settings.settings(for: $0) },
            lastBackup: { folder.lastBackupDate(udid: $0) },
            macState: { MacState.current(backupRoot: folder.root) })
        self.settings = settings
        self.monitor = monitor
        self.backups = backups
        self.scheduler = scheduler

        monitor.start()
        scheduler.start()
        observeSystemEvents()
        // @Published fires before the value is stored; look at it one turn later.
        monitor.$devices.dropFirst().sink { [weak scheduler] _ in
            Task { @MainActor in scheduler?.evaluate() }
        }.store(in: &cancellables)
        // Changing a device's settings takes effect right away.
        settings.$devices.dropFirst().sink { [weak scheduler] _ in
            Task { @MainActor in scheduler?.evaluate() }
        }.store(in: &cancellables)
    }

    /// Wake from sleep, clock and time-zone changes.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Right after wake the device list is stale; check now and again once usbmuxd has caught up.
            Task { @MainActor [weak self] in
                self?.scheduler.evaluate()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                self?.scheduler.evaluate()
            }
        })
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduler.evaluate() }
            })
        }
    }
}
