import Foundation
import IOKit.ps

/// Free disk space the way Finder counts it.
public enum DiskSpace {
    /// Space available for the volume that holds `url` (or its nearest existing parent).
    ///
    /// Prefers `volumeAvailableCapacityForImportantUsage`, which includes APFS purgeable space (what
    /// Finder uses before it starts a backup); falls back to `systemFreeSize`.
    public static func availableBytes(
        at url: URL,
        importantUsage: (URL) -> Int64? = DiskSpace.liveImportantUsage,
        systemFree: (URL) -> UInt64? = DiskSpace.liveSystemFree
    ) -> UInt64? {
        let probe = nearestExisting(url)
        if let important = importantUsage(probe), important > 0 { return UInt64(important) }
        return systemFree(probe)
    }

    public static let liveImportantUsage: @Sendable (URL) -> Int64? = { url in
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public static let liveSystemFree: @Sendable (URL) -> UInt64? = { url in
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path) else { return nil }
        return (attributes[.systemFreeSize] as? NSNumber)?.uint64Value
    }

    static func nearestExisting(_ url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        return probe
    }
}

/// What the rules need to know about the Mac. `nil` = could not be determined (the rule is not applied).
public struct MacState: Equatable, Sendable {
    public var onACPower: Bool?
    public var freeDiskBytes: UInt64?

    public init(onACPower: Bool? = nil, freeDiskBytes: UInt64? = nil) {
        self.onACPower = onACPower
        self.freeDiskBytes = freeDiskBytes
    }

    public static func current(backupRoot: URL = BackupFolder.defaultRoot) -> MacState {
        MacState(onACPower: isOnACPower(), freeDiskBytes: DiskSpace.availableBytes(at: backupRoot))
    }

    /// True on AC (or UPS); false on battery. Desktop Macs report AC.
    static func isOnACPower() -> Bool? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return nil }
        return type != "Battery Power"
    }
}
