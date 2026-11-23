import AppKit
import BackupCore
import Combine
import SwiftUI

@main
struct iPhoneBackupHelperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

/// Makes quitting safe while a backup runs: cancel it, wait for the cleanup (partial files removed,
/// device sync lock released), and only then exit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `AppModel.init`.
    @MainActor static weak var model: AppModel?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.backups.isBusy else { return .terminateNow }
        AppLog.shared.log(.info, "app", "quit requested during a backup: cancelling it first")
        Task { @MainActor in
            let clean = await model.backups.shutdown(timeout: 25)
            if !clean { AppLog.shared.log(.error, "app", "backup did not stop in time; quitting anyway") }
            AppLog.shared.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
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
        OfflineGuard.sanitizeEnvironment() // before any library call
        AppLog.shared.log(.info, "app", "iPhone Backup Helper started")
        let settings = SettingsStore()
        let monitor = DeviceMonitor()
        let backups = BackupController(
            notifier: FilteringNotifier(
                base: UserNotificationNotifier(), preferences: settings.notificationPreferences),
            history: BackupHistoryStore(),
            passcodeWaitProvider: { [settings] udid in settings.settings(for: udid).passcodeWaitSeconds })
        backups.onFinished = { [monitor] in monitor.refreshBackupFolderSoon() }
        backups.deviceLookup = { [monitor] udid in monitor.devices.first { $0.udid == udid } }
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
        AppDelegate.model = self

        monitor.start()
        scheduler.start()
        observeSystemEvents()
        // @Published fires before the value is stored; look at it one turn later.
        monitor.$devices.dropFirst().sink { [weak scheduler, weak backups] _ in
            Task { @MainActor in
                backups?.deviceListChanged()
                scheduler?.evaluate()
            }
        }.store(in: &cancellables)
        // Changing a device's settings takes effect right away.
        settings.$devices.dropFirst().sink { [weak scheduler] _ in
            Task { @MainActor in scheduler?.evaluate() }
        }.store(in: &cancellables)
    }

    /// Sleep, wake, clock and time-zone changes.
    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The connections to the iPhones won't survive the sleep: stop cleanly now, don't wait for
            // timeouts after wake. Whatever is still due is started again after wake.
            // Already on the main queue: issue the abort now, before the system goes to sleep.
            MainActor.assumeIsolated { self?.backups.suspendForSleep() }
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.handleWake() }
        })
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduler.evaluate() }
            })
        }
    }

    /// Right after wake the device list is the one from before the sleep: a device that was unplugged
    /// meanwhile still looks reachable, and a backup started now would fail and then be delayed by the
    /// retry interval. So: hold automatic starts, refresh the list now and again once usbmuxd has caught
    /// up (15 s), and only then let the scheduler start backups.
    private func handleWake() async {
        scheduler.holdStarts(for: 60) // safety limit; released below
        await monitor.refreshNow()
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await monitor.refreshNow()
        try? await Task.sleep(nanoseconds: 2_000_000_000) // let the detail reads finish
        scheduler.releaseStarts()
    }
}
