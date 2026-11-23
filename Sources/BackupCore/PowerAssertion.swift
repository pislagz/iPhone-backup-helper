import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake while a backup runs.
public protocol SleepBlocking: AnyObject {
    func begin(reason: String)
    func end()
}

/// `IOPMAssertion` (PreventUserIdleSystemSleep). Not reference counted: the caller
/// pairs `begin` / `end` (BackupController does the counting).
public final class IOKitSleepBlocker: SleepBlocking {
    private var assertionID = IOPMAssertionID(0)
    private var active = false

    public init() {}

    public func begin(reason: String) {
        guard !active else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID)
        active = (result == kIOReturnSuccess)
    }

    public func end() {
        guard active else { return }
        IOPMAssertionRelease(assertionID)
        active = false
    }

    deinit { end() }
}
