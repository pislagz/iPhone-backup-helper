import Combine
import Foundation
import os

/// Watches usbmuxd (USB + Wi-Fi), reads device details/battery periodically and
/// publishes `DeviceState`s for the UI.
@MainActor
public final class DeviceMonitor: ObservableObject {
    @Published public private(set) var devices: [DeviceState] = []
    /// false while usbmuxd cannot be reached.
    @Published public private(set) var usbmuxAvailable = true
    @Published public private(set) var diskAccess: FullDiskAccess.Status = .unknown

    private static let log = Logger(subsystem: "io.github.pislagz.iphonebackuphelper", category: "monitor")

    private let backend: DeviceBackend
    private let store: KnownDeviceStore?
    private let backupFolder: BackupFolder
    private let clock: @Sendable () -> Date
    private let pollInterval: TimeInterval
    private let folderInterval: TimeInterval

    private var registry: DeviceRegistry
    private var loop: Task<Void, Never>?
    private var nextFolderCheck = Date.distantPast

    public init(
        backend: DeviceBackend = NativeDeviceBackend(),
        store: KnownDeviceStore? = KnownDeviceStore(),
        backupFolder: BackupFolder = BackupFolder(),
        pollInterval: TimeInterval = 2,
        folderInterval: TimeInterval = 30,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.store = store
        self.backupFolder = backupFolder
        self.pollInterval = pollInterval
        self.folderInterval = folderInterval
        self.clock = clock
        self.registry = DeviceRegistry(known: store?.load() ?? [])
        self.devices = registry.states()
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                let nanos = UInt64(self.pollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Removes a device that is not connected from the known list (its backups are not touched).
    @discardableResult
    public func forget(udid: String) -> Bool {
        guard registry.forget(udid) else { return false }
        save()
        publish()
        return true
    }

    /// Re-read backup dates and Full Disk Access status on the next tick.
    public func refreshBackupFolderSoon() {
        nextFolderCheck = .distantPast
    }

    // MARK: - One polling step

    func tick() async {
        let now = clock()
        var persist = false

        do {
            let present = try await backend.listDevices()
            usbmuxAvailable = true
            persist = registry.applyConnections(present, now: now)
        } catch {
            if usbmuxAvailable { Self.log.error("usbmuxd unavailable: \(String(describing: error))") }
            usbmuxAvailable = false
            persist = registry.applyConnections([], now: now)
        }

        for udid in registry.udidsDueForProbe(now: now) {
            let generation = registry.markProbing(udid)
            let backend = self.backend
            Task { [weak self] in
                let result = await backend.readDetails(udid: udid)
                self?.finishProbe(udid: udid, result: result, generation: generation)
            }
        }

        if now >= nextFolderCheck {
            nextFolderCheck = now.addingTimeInterval(folderInterval)
            await refreshBackupFolder()
        }

        if persist { save() }
        publish()
    }

    private func finishProbe(udid: String, result: DeviceReadResult, generation: Int) {
        let changed = registry.applyRead(udid: udid, result: result, now: clock(), generation: generation)
        if changed != nil { save() }
        publish()
    }

    private func refreshBackupFolder() async {
        let udids = registry.allUDIDs
        let folder = backupFolder
        let (access, dates) = await withCheckedContinuation { (continuation: CheckedContinuation<(FullDiskAccess.Status, [String: Date]), Never>) in
            DispatchQueue.global(qos: .utility).async {
                var dates: [String: Date] = [:]
                for udid in udids {
                    if let date = folder.lastBackupDate(udid: udid) { dates[udid] = date }
                }
                continuation.resume(returning: (folder.accessStatus(), dates))
            }
        }
        diskAccess = access
        for udid in udids { registry.applyLastBackup(udid: udid, date: dates[udid]) }
    }

    private func save() {
        guard let store else { return }
        do { try store.save(registry.knownDevices()) } catch {
            Self.log.error("could not save known devices: \(String(describing: error))")
        }
    }

    private func publish() {
        let states = registry.states()
        if states != devices { devices = states }
    }
}
