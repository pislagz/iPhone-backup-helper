import Foundation

/// What the scheduler should do for a device right now.
public enum RuleDecision: Equatable, Sendable {
    /// Start a backup now.
    case run
    /// A backup is due and allowed by the schedule, but a condition blocks it ("Waiting: battery 14% < 20%").
    case wait(String)
    /// Nothing to do now ("Next: today 20:00–23:00", "Automatic backups are off").
    case skip(String)

    /// Human-readable reason; nil for `.run`.
    public var reason: String? {
        switch self {
        case .run: return nil
        case .wait(let reason), .skip(let reason): return reason
        }
    }
}

/// Pure scheduling rules: (now, device, Mac, settings, last backup) -> decision. No clocks, files or
/// devices are touched; the caller passes everything in.
public enum RuleEngine {
    public static func evaluate(
        now: Date,
        calendar: Calendar = .current,
        device: DeviceState,
        mac: MacState,
        settings: DeviceSettings,
        lastBackup: Date?,
        lastFailedAttempt: Date? = nil,
        isRunning: Bool = false
    ) -> RuleDecision {
        guard settings.enabled else { return .skip("Automatic backups are off") }
        if isRunning { return .skip("Backup in progress") }

        // A date in the future (clock skew between phone and Mac) counts as "now".
        let last = lastBackup.map { min($0, now) }
        let planner = Planner(now: now, calendar: calendar, settings: settings, lastBackup: last)

        // Schedule: frequency + window + minimum interval.
        guard let slot = planner.nextSlot() else {
            return .skip(settings.frequency == .weekly ? "No weekday selected" : "No upcoming backup")
        }
        if slot.start > now {
            return .skip("Next: " + planner.describe(slot))
        }

        // Due and inside the window: retry gating, then device/Mac conditions.
        if let failed = lastFailedAttempt, failed > (last ?? .distantPast) {
            let retryAt = failed.addingTimeInterval(TimeInterval(settings.retryIntervalMinutes) * 60)
            if now < retryAt {
                let minutes = max(1, Int((retryAt.timeIntervalSince(now) / 60).rounded(.up)))
                return .wait("Waiting: retry in \(minutes) min")
            }
        }

        let kind = device.isTablet ? "iPad" : "iPhone"
        guard device.isReachable else { return .wait("Waiting: \(kind) not connected") }
        if let issue = device.issue {
            switch issue {
            case .needsTrust: return .wait("Waiting: tap Trust on the \(kind)")
            case .locked: return .wait("Waiting: unlock the \(kind)")
            case .unreachable: return .wait("Waiting: \(kind) not responding")
            }
        }
        if settings.connectionPolicy == .usbOnly, !device.connections.contains(.usb) {
            return .wait("Waiting: connect by USB (Wi-Fi backups are off)")
        }
        if settings.minBatteryPercent > 0 {
            guard let battery = device.battery else { return .wait("Waiting: battery level not known yet") }
            let exempt = battery.isCharging && settings.ignoreBatteryIfCharging
            if battery.level < settings.minBatteryPercent, !exempt {
                return .wait("Waiting: battery \(battery.level)% < \(settings.minBatteryPercent)%")
            }
        }
        if settings.requireACPower, mac.onACPower == false {
            return .wait("Waiting: Mac is on battery power")
        }
        if settings.minFreeDiskGB > 0, let free = mac.freeDiskBytes {
            let needed = UInt64(settings.minFreeDiskGB) * 1_000_000_000
            if free < needed {
                return .wait(String(format: "Waiting: free disk space %.1f GB < %ld GB", Double(free) / 1e9, settings.minFreeDiskGB))
            }
        }
        return .run
    }

    // MARK: - Schedule planning

    /// A period in which a backup may start: `start` is the first allowed moment, `end` the end of the window.
    struct Slot: Equatable {
        var start: Date
        var end: Date
        var windowStart: Date
        var hasWindow: Bool
    }

    struct Planner {
        let now: Date
        let calendar: Calendar
        let settings: DeviceSettings
        let lastBackup: Date?

        var hasWindow: Bool {
            settings.windowEnabled && settings.windowStartMinute != settings.windowEndMinute
        }

        /// Wall-clock time `minute` on the calendar day of `day`; times skipped by a DST jump move forward.
        func moment(_ minute: Int, on day: Date) -> Date {
            let start = calendar.startOfDay(for: day)
            let hour = minute / 60
            let minutes = minute % 60
            return calendar.date(
                bySettingHour: hour, minute: minutes, second: 0, of: start,
                matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) ?? start
        }

        /// The window that begins on `day` (whole day when no window is set).
        func window(on day: Date) -> (start: Date, end: Date) {
            let dayStart = calendar.startOfDay(for: day)
            guard hasWindow else {
                return (dayStart, calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400))
            }
            let start = moment(settings.windowStartMinute, on: dayStart)
            let endDay = settings.windowEndMinute > settings.windowStartMinute
                ? dayStart : (calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400))
            return (start, moment(settings.windowEndMinute, on: endDay))
        }

        /// Earliest moment the minimum interval since the last backup allows.
        var intervalAllowed: Date {
            guard let last = lastBackup, settings.minIntervalHours > 0 else { return .distantPast }
            return last.addingTimeInterval(TimeInterval(settings.minIntervalHours) * 3_600)
        }

        /// First moment (>= window start) at which the frequency rule makes a backup due for the window of `day`.
        func dueMoment(for day: Date) -> Date? {
            switch settings.frequency {
            case .daily, .weekly:
                if settings.frequency == .weekly, !settings.weeklyDays.contains(calendar.component(.weekday, from: day)) {
                    return nil
                }
                // Once per calendar day: a backup made on or after this day's start counts. With a window
                // that runs past midnight, a backup in its after-midnight part belongs to the previous day.
                var lower = calendar.startOfDay(for: day)
                if hasWindow, let previous = calendar.date(byAdding: .day, value: -1, to: lower) {
                    lower = max(lower, window(on: previous).end)
                }
                if let last = lastBackup, last >= lower { return nil }
                return .distantPast
            case .everyHours:
                guard let last = lastBackup else { return .distantPast }
                return last.addingTimeInterval(TimeInterval(settings.everyHours) * 3_600)
            }
        }

        /// The current or next moment/period in which a backup should start.
        func nextSlot() -> Slot? {
            let today = calendar.startOfDay(for: now)
            for offset in -1...14 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                let (windowStart, windowEnd) = window(on: day)
                if windowEnd <= now { continue }
                guard let due = dueMoment(for: day) else { continue }
                let start = max(windowStart, due, intervalAllowed)
                if start >= windowEnd { continue }
                return Slot(start: start, end: windowEnd, windowStart: windowStart, hasWindow: hasWindow)
            }
            return nil
        }

        // MARK: Text (English, locale independent)

        static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

        func clock(_ date: Date) -> String {
            let c = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02ld:%02ld", c.hour ?? 0, c.minute ?? 0)
        }

        func dayWord(_ date: Date) -> String {
            let today = calendar.startOfDay(for: now)
            let target = calendar.startOfDay(for: date)
            let days = calendar.dateComponents([.day], from: today, to: target).day ?? 0
            switch days {
            case ...0: return "today"
            case 1: return "tomorrow"
            case 2...6: return Self.weekdayNames[calendar.component(.weekday, from: date) - 1]
            default:
                let c = calendar.dateComponents([.weekday, .day, .month], from: date)
                return "\(Self.weekdayNames[(c.weekday ?? 1) - 1]) \(c.day ?? 1) \(Self.monthNames[(c.month ?? 1) - 1])"
            }
        }

        func describe(_ slot: Slot) -> String {
            let day = dayWord(slot.start)
            if slot.hasWindow {
                return "\(day) \(clock(slot.start))–\(clock(slot.end))"
            }
            // No window: only mention a time when something (interval, every-N-hours) pushes it past midnight.
            return slot.start > slot.windowStart ? "\(day) \(clock(slot.start))" : day
        }
    }
}
