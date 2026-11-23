import Combine
import Foundation

/// Starts automatic backups. Every minute, and whenever something changes (device attached, battery
/// changed, wake from sleep ...), it asks the `RuleEngine` about each device and starts a backup through
/// the `BackupController` when the answer is `.run`. It never starts a backup the controller refuses
/// (one per device at a time).
@MainActor
public final class BackupScheduler: ObservableObject {
    /// Latest decision per device (shown in the menu).
    @Published public private(set) var decisions: [String: RuleDecision] = [:]

    private let controller: BackupController
    private let devices: () -> [DeviceState]
    private let settings: (String) -> DeviceSettings
    private let lastBackup: (String) -> Date?
    private let macState: () -> MacState
    private let clock: () -> Date
    private let calendar: () -> Calendar
    private let tickInterval: TimeInterval
    private var loop: Task<Void, Never>?

    private static let log = AppLog.shared.logger(category: "scheduler")

    public init(
        controller: BackupController,
        devices: @escaping () -> [DeviceState],
        settings: @escaping (String) -> DeviceSettings,
        lastBackup: @escaping (String) -> Date?,
        macState: @escaping () -> MacState = { MacState.current() },
        clock: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = { Calendar.current },
        tickInterval: TimeInterval = 60
    ) {
        self.controller = controller
        self.devices = devices
        self.settings = settings
        self.lastBackup = lastBackup
        self.macState = macState
        self.clock = clock
        self.calendar = calendar
        self.tickInterval = tickInterval
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.evaluate()
                try? await Task.sleep(nanoseconds: UInt64(self.tickInterval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Text for the menu: "Next: today 20:00–23:00", "Waiting: battery 14% < 20%". nil when automatic
    /// backups are off or nothing is worth showing.
    public func statusText(for udid: String) -> String? {
        guard settings(udid).enabled else { return nil }
        guard let decision = decisions[udid] else { return nil }
        switch decision {
        case .run: return "Starting backup…"
        case .wait(let reason), .skip(let reason): return reason
        }
    }

    /// One pass over all devices. Safe to call as often as you like.
    public func evaluate() {
        let now = clock()
        let calendar = self.calendar()
        let mac = macState()
        var updated: [String: RuleDecision] = [:]

        for device in devices() {
            let udid = device.udid
            let deviceSettings = settings(udid)

            // Our own result is merged in: Status.plist may not be readable (no Full Disk Access) or
            // not refreshed yet, and we must not start the same backup again right after it succeeded.
            var last = lastBackup(udid)
            var failedAt: Date?
            if let result = controller.results[udid] {
                switch result.kind {
                case .success: last = max(last ?? .distantPast, result.finishedAt)
                case .failed, .deviceBusy, .passcodeTimeout, .cancelled: failedAt = result.finishedAt
                }
            }

            let decision = RuleEngine.evaluate(
                now: now, calendar: calendar, device: device, mac: mac, settings: deviceSettings,
                lastBackup: last, lastFailedAttempt: failedAt, isRunning: controller.isRunning(udid))

            if decision == .run {
                if controller.start(device) {
                    Self.log(.info, "automatic backup started for \(udid.prefix(8))")
                    updated[udid] = .skip("Backup in progress")
                    continue
                }
            }
            updated[udid] = decision
        }
        if updated != decisions { decisions = updated }
    }
}
