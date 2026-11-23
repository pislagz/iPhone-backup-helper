import Combine
import Foundation

/// Starts automatic backups. Every minute, and whenever something changes (device attached, battery
/// changed, wake from sleep ...), it asks the `RuleEngine` about each device and starts a backup through
/// the `BackupController` when the answer is `.run`. The controller runs one backup at a time and queues
/// the rest; whatever it refuses (or holds back) is shown in the menu as a waiting reason.
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
    private var holdUntil: Date?

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
        case .run: return "Starting…"
        case .wait(let reason), .skip(let reason): return reason
        }
    }

    /// Doesn't start any backup for `seconds` (a safety limit; `releaseStarts()` ends it earlier). Used
    /// after wake from sleep, until the device list has been refreshed: right after wake it still shows
    /// pre-sleep devices as reachable. Decisions and the menu text keep updating meanwhile.
    public func holdStarts(for seconds: TimeInterval) {
        holdUntil = clock().addingTimeInterval(seconds)
        evaluate()
    }

    public func releaseStarts() {
        holdUntil = nil
        evaluate()
    }

    public var startsAreHeld: Bool {
        guard let holdUntil else { return false }
        return clock() < holdUntil
    }

    /// One pass over all devices. Safe to call as often as you like.
    public func evaluate() {
        let now = clock()
        let calendar = self.calendar()
        let mac = macState()
        let held = startsAreHeld
        var updated: [String: RuleDecision] = [:]

        for device in devices() {
            let udid = device.udid
            let deviceSettings = settings(udid)

            if controller.isQueued(udid) {
                updated[udid] = .skip(Self.queuedText(controller.queuePosition(udid)))
                continue
            }

            // Our own persisted result is merged in: Status.plist may not be readable (no Full Disk
            // Access) or not refreshed yet, and we must not start the same backup again right after it
            // succeeded (also not after an app restart), nor retry a failed attempt too early.
            var last = lastBackup(udid)
            if let ours = controller.lastSuccess(for: udid) { last = max(last ?? .distantPast, ours) }

            let decision = RuleEngine.evaluate(
                now: now, calendar: calendar, device: device, mac: mac, settings: deviceSettings,
                lastBackup: last, lastFailedAttempt: controller.lastFailedAttempt(for: udid),
                isRunning: controller.isRunning(udid))

            guard decision == .run else {
                updated[udid] = decision
                continue
            }
            if held {
                updated[udid] = .wait("Waiting: checking devices after wake-up")
            } else if let refusal = controller.refusal(for: device) {
                updated[udid] = .wait(refusal)
            } else if controller.start(device) {
                Self.log(.info, "automatic backup \(controller.isRunning(udid) ? "started" : "queued") for \(udid.prefix(8))")
                updated[udid] = .skip(controller.isRunning(udid)
                    ? "Backup in progress" : Self.queuedText(controller.queuePosition(udid)))
            } else {
                updated[udid] = .wait("Waiting: iPhone not ready")
            }
        }
        if updated != decisions { decisions = updated }
    }

    static func queuedText(_ position: Int?) -> String {
        guard let position, position > 1 else { return "Queued: waiting for the running backup to finish" }
        return "Queued: number \(position) in line"
    }
}
