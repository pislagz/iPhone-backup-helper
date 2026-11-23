import XCTest
@testable import BackupCore

final class RuleEngineTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }()

    /// Wall-clock time in Europe/Warsaw ("2026-03-27 21:00").
    private func local(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func absolute(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func device(
        battery: Int? = 80, charging: Bool = false, connections: Set<ConnectionType> = [.usb],
        issue: DeviceIssue? = nil, name: String = "Phone"
    ) -> DeviceState {
        DeviceState(
            udid: "U1", name: name, connections: connections,
            battery: battery.map { BatteryStatus(level: $0, isCharging: charging) },
            encryption: .unencrypted, issue: issue)
    }

    /// Daily, window 20:00-23:00, no interval/retry noise.
    private func settings(_ change: (inout DeviceSettings) -> Void = { _ in }) -> DeviceSettings {
        var s = DeviceSettings(
            enabled: true, frequency: .daily, windowEnabled: true,
            windowStartMinute: 20 * 60, windowEndMinute: 23 * 60,
            minBatteryPercent: 20, ignoreBatteryIfCharging: true, connectionPolicy: .usbOrWiFi,
            requireACPower: false, minFreeDiskGB: 0, minIntervalHours: 0, retryIntervalMinutes: 30)
        change(&s)
        return s
    }

    private func decide(
        _ now: Date, device: DeviceState? = nil, mac: MacState = MacState(onACPower: true, freeDiskBytes: 500_000_000_000),
        settings: DeviceSettings? = nil, last: Date? = nil, failed: Date? = nil, running: Bool = false
    ) -> RuleDecision {
        RuleEngine.evaluate(
            now: now, calendar: calendar, device: device ?? self.device(), mac: mac,
            settings: settings ?? self.settings(), lastBackup: last, lastFailedAttempt: failed, isRunning: running)
    }

    // MARK: Basics

    func testDisabledAndRunning() {
        XCTAssertEqual(decide(local("2026-03-27 21:00"), settings: settings { $0.enabled = false }), .skip("Automatic backups are off"))
        XCTAssertEqual(decide(local("2026-03-27 21:00"), running: true), .skip("Backup in progress"))
    }

    func testRunsInsideTheWindow() {
        XCTAssertEqual(decide(local("2026-03-27 21:00")), .run)
        XCTAssertEqual(decide(local("2026-03-27 20:00")), .run, "start is inclusive")
        XCTAssertEqual(decide(local("2026-03-27 22:59")), .run)
    }

    func testBeforeTheWindowShowsNext() {
        XCTAssertEqual(decide(local("2026-03-27 18:00")), .skip("Next: today 20:00–23:00"))
    }

    func testAfterTheWindowShowsTomorrow() {
        XCTAssertEqual(decide(local("2026-03-27 23:00")), .skip("Next: tomorrow 20:00–23:00"), "end is exclusive")
        XCTAssertEqual(decide(local("2026-03-27 23:30")), .skip("Next: tomorrow 20:00–23:00"))
    }

    func testDailyOnlyOncePerDay() {
        XCTAssertEqual(decide(local("2026-03-27 22:00"), last: local("2026-03-27 08:00")), .skip("Next: tomorrow 20:00–23:00"))
        XCTAssertEqual(decide(local("2026-03-27 22:00"), last: local("2026-03-26 22:00")), .run)
    }

    func testFutureLastBackupIsClampedToNow() {
        XCTAssertEqual(decide(local("2026-03-27 22:00"), last: local("2026-03-28 22:00")), .skip("Next: tomorrow 20:00–23:00"))
    }

    // MARK: Frequency

    func testEveryNHours() {
        let s = settings { $0.frequency = .everyHours; $0.everyHours = 4; $0.windowEnabled = false }
        let now = local("2026-03-27 15:00")
        XCTAssertEqual(decide(now, settings: s, last: local("2026-03-27 10:00")), .run)
        XCTAssertEqual(decide(now, settings: s, last: local("2026-03-27 12:00")), .skip("Next: today 16:00"))
        XCTAssertEqual(decide(now, settings: s, last: nil), .run)
        XCTAssertEqual(decide(now, settings: s, last: local("2026-03-27 14:00")), .skip("Next: today 18:00"))
    }

    func testEveryNHoursWithWindowWaitsForTheNextWindowWhenDueOutsideIt() {
        let s = settings { $0.frequency = .everyHours; $0.everyHours = 4 }
        XCTAssertEqual(decide(local("2026-03-27 15:00"), settings: s, last: local("2026-03-27 10:00")), .skip("Next: today 20:00–23:00"))
        // Due again at 22:30, inside the window: show the effective start.
        XCTAssertEqual(decide(local("2026-03-27 21:00"), settings: s, last: local("2026-03-27 18:30")), .skip("Next: today 22:30–23:00"))
        // Not due before this window closes: next window.
        XCTAssertEqual(decide(local("2026-03-27 21:00"), settings: s, last: local("2026-03-27 20:30")), .skip("Next: tomorrow 20:00–23:00"))
    }

    func testWeeklyOnSelectedDays() {
        let saturday: Set<Int> = [7]
        let s = settings { $0.frequency = .weekly; $0.weeklyDays = saturday }
        XCTAssertEqual(decide(local("2026-03-26 21:00"), settings: s), .skip("Next: Sat 20:00–23:00"), "Thursday")
        XCTAssertEqual(decide(local("2026-03-27 21:00"), settings: s), .skip("Next: tomorrow 20:00–23:00"), "Friday")
        XCTAssertEqual(decide(local("2026-03-28 21:00"), settings: s, last: local("2026-03-21 21:00")), .run)
        XCTAssertEqual(decide(local("2026-03-28 22:00"), settings: s, last: local("2026-03-28 20:30")), .skip("Next: Sat 4 Apr 20:00–23:00"))
    }

    func testWeeklyWithoutDays() {
        let s = settings { $0.frequency = .weekly; $0.weeklyDays = [] }
        XCTAssertEqual(decide(local("2026-03-27 21:00"), settings: s), .skip("No weekday selected"))
    }

    func testMinimumIntervalCountsAnyBackup() {
        let s = settings { $0.windowEnabled = false; $0.minIntervalHours = 12 }
        // Finder backed up yesterday 23:00; today is a new day but only 9 h have passed.
        XCTAssertEqual(decide(local("2026-03-27 08:00"), settings: s, last: local("2026-03-26 23:00")), .skip("Next: today 11:00"))
        XCTAssertEqual(decide(local("2026-03-27 11:00"), settings: s, last: local("2026-03-26 23:00")), .run)
    }

    // MARK: Windows crossing midnight

    func testMidnightCrossingWindow() {
        let s = settings { $0.windowStartMinute = 22 * 60; $0.windowEndMinute = 2 * 60 }
        XCTAssertEqual(decide(local("2026-03-24 21:00"), settings: s), .skip("Next: today 22:00–02:00"))
        XCTAssertEqual(decide(local("2026-03-24 23:30"), settings: s), .run)
        XCTAssertEqual(decide(local("2026-03-25 00:30"), settings: s, last: local("2026-03-23 22:30")), .run, "after midnight, still the window that began yesterday")
        XCTAssertEqual(decide(local("2026-03-25 01:59"), settings: s), .run)
        XCTAssertEqual(decide(local("2026-03-25 02:00"), settings: s), .skip("Next: today 22:00–02:00"))
    }

    func testMidnightCrossingWindowCountsOneBackupPerWindow() {
        let s = settings { $0.windowStartMinute = 22 * 60; $0.windowEndMinute = 2 * 60 }
        // Backed up at 23:00 on the 24th; at 00:30 on the 25th that is the same window.
        XCTAssertEqual(decide(local("2026-03-25 00:30"), settings: s, last: local("2026-03-24 23:00")), .skip("Next: today 22:00–02:00"))
        // Backed up at 00:10 on the 25th: that is the 24th's window, so the 25th's window is still to come.
        XCTAssertEqual(decide(local("2026-03-25 01:00"), settings: s, last: local("2026-03-25 00:10")), .skip("Next: today 22:00–02:00"))
        // ... but a backup at 12:00 on the 25th is the 25th's backup.
        XCTAssertEqual(decide(local("2026-03-25 23:00"), settings: s, last: local("2026-03-25 12:00")), .skip("Next: tomorrow 22:00–02:00"))
    }

    func testWeeklyMidnightWindowBelongsToTheStartDay() {
        // Saturday 22:00-02:00; Sunday 01:00 is still Saturday's window.
        let s = settings { $0.frequency = .weekly; $0.weeklyDays = [7]; $0.windowStartMinute = 22 * 60; $0.windowEndMinute = 2 * 60 }
        XCTAssertEqual(decide(local("2026-03-28 21:00"), settings: s), .skip("Next: today 22:00–02:00"))
        XCTAssertEqual(decide(local("2026-03-29 00:30"), settings: s), .run)
    }

    func testStartEqualsEndMeansAllDay() {
        let s = settings { $0.windowStartMinute = 600; $0.windowEndMinute = 600 }
        XCTAssertEqual(decide(local("2026-03-27 03:00"), settings: s), .run)
    }

    func testNoWindow() {
        let s = settings { $0.windowEnabled = false }
        XCTAssertEqual(decide(local("2026-03-27 03:00"), settings: s), .run)
        XCTAssertEqual(decide(local("2026-03-27 03:00"), settings: s, last: local("2026-03-27 01:00")), .skip("Next: tomorrow"))
    }

    // MARK: DST (Europe/Warsaw)

    func testSpringForwardWindowInsideTheMissingHour() {
        // 2026-03-29: clocks jump 02:00 -> 03:00. A 02:30-03:30 window starts at 03:00 (02:30 does not exist).
        let s = settings { $0.windowStartMinute = 150; $0.windowEndMinute = 210 }
        XCTAssertEqual(decide(absolute("2026-03-29T00:30:00Z"), settings: s), .skip("Next: today 03:00–03:30"), "01:30 local")
        XCTAssertEqual(decide(absolute("2026-03-29T01:10:00Z"), settings: s), .run, "03:10 local")
        XCTAssertEqual(decide(absolute("2026-03-29T01:30:00Z"), settings: s), .skip("Next: tomorrow 02:30–03:30"), "03:30 local")
    }

    func testSpringForwardNightWindow() {
        // Sat 22:00 -> Sun 02:00 never reaches 02:00 on the wall clock (it becomes 03:00).
        let s = settings { $0.windowStartMinute = 22 * 60; $0.windowEndMinute = 2 * 60 }
        XCTAssertEqual(decide(absolute("2026-03-29T00:59:00Z"), settings: s), .run, "01:59 local")
        XCTAssertEqual(decide(absolute("2026-03-29T01:00:00Z"), settings: s, last: local("2026-03-28 23:00")), .skip("Next: today 22:00–02:00"), "03:00 local")
    }

    func testSpringForwardDailyOncePerCalendarDay() {
        let s = settings { $0.windowEnabled = false }
        let now = absolute("2026-03-29T05:00:00Z") // 07:00 CEST on the 23-hour day
        XCTAssertEqual(decide(now, settings: s, last: absolute("2026-03-28T23:30:00Z")), .skip("Next: tomorrow"), "00:30 on the 29th counts")
        XCTAssertEqual(decide(now, settings: s, last: absolute("2026-03-28T22:30:00Z")), .run, "23:30 on the 28th does not")
    }

    func testFallBackWindowSpansTheRepeatedHour() {
        // 2026-10-25: 03:00 CEST -> 02:00 CET. Window 02:30-03:30 runs from 02:30 CEST (first pass) to 03:30 CET.
        let s = settings { $0.windowStartMinute = 150; $0.windowEndMinute = 210 }
        XCTAssertEqual(decide(absolute("2026-10-24T23:45:00Z"), settings: s), .skip("Next: today 02:30–03:30"), "01:45 CEST")
        XCTAssertEqual(decide(absolute("2026-10-25T00:45:00Z"), settings: s), .run, "02:45 CEST")
        XCTAssertEqual(decide(absolute("2026-10-25T01:45:00Z"), settings: s), .run, "02:45 CET, second pass")
        XCTAssertEqual(decide(absolute("2026-10-25T02:15:00Z"), settings: s), .run, "03:15 CET")
        XCTAssertEqual(decide(absolute("2026-10-25T02:30:00Z"), settings: s), .skip("Next: tomorrow 02:30–03:30"), "03:30 CET")
    }

    func testDayWordsAcrossDST() {
        // Saturday evening before the change; "tomorrow" is the 23-hour day.
        XCTAssertEqual(decide(local("2026-03-28 23:30")), .skip("Next: tomorrow 20:00–23:00"))
        XCTAssertEqual(decide(local("2026-03-29 23:30")), .skip("Next: tomorrow 20:00–23:00"))
    }

    // MARK: Conditions

    func testBatteryRule() {
        let now = local("2026-03-27 21:00")
        XCTAssertEqual(decide(now, device: device(battery: 14)), .wait("Waiting: battery 14% < 20%"))
        XCTAssertEqual(decide(now, device: device(battery: 14, charging: true)), .run, "charging is ignored by default")
        XCTAssertEqual(
            decide(now, device: device(battery: 14, charging: true), settings: settings { $0.ignoreBatteryIfCharging = false }),
            .wait("Waiting: battery 14% < 20%"))
        XCTAssertEqual(decide(now, device: device(battery: 20)), .run)
        XCTAssertEqual(decide(now, device: device(battery: nil)), .wait("Waiting: battery level not known yet"))
        XCTAssertEqual(decide(now, device: device(battery: nil), settings: settings { $0.minBatteryPercent = 0 }), .run)
    }

    func testConnectionRules() {
        let now = local("2026-03-27 21:00")
        XCTAssertEqual(decide(now, device: device(connections: [])), .wait("Waiting: iPhone not connected"))
        XCTAssertEqual(
            decide(now, device: DeviceState(udid: "T", name: "Pad", productType: "iPad13,1", connections: [], encryption: .unknown)),
            .wait("Waiting: iPad not connected"))
        XCTAssertEqual(decide(now, device: device(connections: [.wifi])), .run)
        let usbOnly = settings { $0.connectionPolicy = .usbOnly }
        XCTAssertEqual(decide(now, device: device(connections: [.wifi]), settings: usbOnly), .wait("Waiting: connect by USB (Wi-Fi backups are off)"))
        XCTAssertEqual(decide(now, device: device(connections: [.wifi, .usb]), settings: usbOnly), .run)
    }

    func testDeviceIssues() {
        let now = local("2026-03-27 21:00")
        XCTAssertEqual(decide(now, device: device(issue: .needsTrust)), .wait("Waiting: tap Trust on the iPhone"))
        XCTAssertEqual(decide(now, device: device(issue: .locked)), .wait("Waiting: unlock the iPhone"))
        XCTAssertEqual(decide(now, device: device(issue: .unreachable("x"))), .wait("Waiting: iPhone not responding"))
    }

    func testMacRules() {
        let now = local("2026-03-27 21:00")
        let ac = settings { $0.requireACPower = true }
        XCTAssertEqual(decide(now, mac: MacState(onACPower: false, freeDiskBytes: nil), settings: ac), .wait("Waiting: Mac is on battery power"))
        XCTAssertEqual(decide(now, mac: MacState(onACPower: true, freeDiskBytes: nil), settings: ac), .run)
        XCTAssertEqual(decide(now, mac: MacState(onACPower: nil, freeDiskBytes: nil), settings: ac), .run, "unknown is not a reason to block")

        let disk = settings { $0.minFreeDiskGB = 20 }
        XCTAssertEqual(decide(now, mac: MacState(onACPower: true, freeDiskBytes: 8_000_000_000), settings: disk), .wait("Waiting: free disk space 8.0 GB < 20 GB"))
        XCTAssertEqual(decide(now, mac: MacState(onACPower: true, freeDiskBytes: 20_000_000_000), settings: disk), .run)
        XCTAssertEqual(decide(now, mac: MacState(onACPower: true, freeDiskBytes: nil), settings: disk), .run)
    }

    func testConditionsDoNotMatterOutsideTheWindow() {
        XCTAssertEqual(decide(local("2026-03-27 12:00"), device: device(battery: 3)), .skip("Next: today 20:00–23:00"))
    }

    func testRetryInterval() {
        let now = local("2026-03-27 21:30")
        XCTAssertEqual(decide(now, failed: local("2026-03-27 21:10")), .wait("Waiting: retry in 10 min"))
        XCTAssertEqual(decide(now, failed: local("2026-03-27 21:00")), .run)
        XCTAssertEqual(decide(now, failed: local("2026-03-27 21:29")), .wait("Waiting: retry in 29 min"))
        // A failure older than the last successful backup is irrelevant.
        XCTAssertEqual(decide(now, last: local("2026-03-26 21:00"), failed: local("2026-03-25 21:25")), .run)
    }

    func testRetryOnlyAfterFailureNotAfterSuccess() {
        let now = local("2026-03-27 21:30")
        XCTAssertEqual(decide(now, last: local("2026-03-27 21:20"), failed: local("2026-03-27 21:10")), .skip("Next: tomorrow 20:00–23:00"))
    }

    func testIsDeterministicInTheTimeZone() {
        // The same instant is a different wall-clock time elsewhere: the calendar decides.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let instant = absolute("2026-03-27T20:00:00Z") // 21:00 Warsaw, 05:00 next day Tokyo
        XCTAssertEqual(decide(instant), .run)
        let tokyoDecision = RuleEngine.evaluate(
            now: instant, calendar: tokyo, device: device(), mac: MacState(),
            settings: settings(), lastBackup: nil)
        XCTAssertEqual(tokyoDecision, .skip("Next: today 20:00–23:00"))
    }
}
