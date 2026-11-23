import Foundation

/// Pure state machine behind `DeviceMonitor`: merges usbmuxd presence, lockdown details,
/// persisted known devices and backup dates into `DeviceState`s and schedules probes.
public struct DeviceRegistry: Sendable {
    public struct Timing: Sendable {
        public var detailInterval: TimeInterval = 120   // battery etc. refresh while present
        public var trustRetryInterval: TimeInterval = 30 // not trusted yet: don't spam the Trust dialog
        public var lockedRetryInterval: TimeInterval = 10
        public var failureRetryInterval: TimeInterval = 15
        public init() {}
    }

    struct Entry: Sendable {
        var known: KnownDevice?
        var connections: Set<ConnectionType> = []
        var details: DeviceDetails?
        var issue: DeviceIssue?
        var lastBackup: Date?
        var lastSeen: Date?
        var nextProbe: Date?
        var probing = false
        /// Bumped on every attach and detach; a probe result is only applied when its tag still matches.
        var generation = 0
    }

    var entries: [String: Entry] = [:]
    public var timing: Timing

    public init(known: [KnownDevice] = [], timing: Timing = Timing()) {
        self.timing = timing
        for device in known {
            entries[device.udid] = Entry(known: device, lastSeen: device.lastSeen)
        }
    }

    /// Replace the set of present connections. Newly appeared devices get an immediate probe.
    /// Returns true when a known device just went away (so `lastSeen` should be persisted).
    @discardableResult
    public mutating func applyConnections(_ list: [ConnectedDevice], now: Date) -> Bool {
        var detached = false
        var byUDID: [String: Set<ConnectionType>] = [:]
        for item in list { byUDID[item.udid, default: []].insert(item.connection) }

        for (udid, conns) in byUDID {
            var entry = entries[udid] ?? Entry()
            if entry.connections.isEmpty { // (re)attached
                entry.nextProbe = now
                entry.generation += 1
                entry.probing = false
            }
            entry.connections = conns
            entry.lastSeen = now
            entries[udid] = entry
        }
        for udid in entries.keys where byUDID[udid] == nil {
            if entries[udid]?.connections.isEmpty == false { detached = true }
            entries[udid]?.connections = []
            entries[udid]?.issue = nil
            entries[udid]?.nextProbe = nil
            entries[udid]?.probing = false
            entries[udid]?.generation += 1
        }
        return detached
    }

    /// Snapshot of devices to persist (details we have learned, with their last-seen time).
    public func knownDevices() -> [KnownDevice] {
        entries.values.compactMap { entry in
            guard var known = entry.known else { return nil }
            if let seen = entry.lastSeen { known.lastSeen = seen }
            return known
        }
    }

    /// UDIDs that are present and due for a lockdown read.
    public func udidsDueForProbe(now: Date) -> [String] {
        entries.compactMap { udid, entry in
            guard !entry.connections.isEmpty, !entry.probing, let next = entry.nextProbe, next <= now else { return nil }
            return udid
        }.sorted()
    }

    /// Makes every present device due for a lockdown read right away (after wake from sleep, when the
    /// battery level and lock state we hold are stale).
    public mutating func requestReprobe(now: Date) {
        for udid in entries.keys where entries[udid]?.connections.isEmpty == false {
            entries[udid]?.nextProbe = now
        }
    }

    /// Marks a probe as in flight and returns the tag to hand back to `applyRead`.
    @discardableResult
    public mutating func markProbing(_ udid: String) -> Int {
        entries[udid]?.probing = true
        return entries[udid]?.generation ?? 0
    }

    /// Apply a lockdown read. Returns the `KnownDevice` to persist when it changed.
    /// A result tagged with an older generation (the device detached and/or re-attached while the
    /// probe was in flight) is dropped and does not touch the state of the newer probe.
    @discardableResult
    public mutating func applyRead(
        udid: String, result: DeviceReadResult, now: Date, generation: Int? = nil
    ) -> KnownDevice? {
        guard var entry = entries[udid] else { return nil }
        if let generation, generation != entry.generation { return nil }
        entry.probing = false
        // A detach while the probe was in flight: ignore stale results.
        guard !entry.connections.isEmpty else { entries[udid] = entry; return nil }

        var toPersist: KnownDevice?
        switch result {
        case .success(let details):
            entry.details = details
            entry.issue = nil
            entry.nextProbe = now.addingTimeInterval(timing.detailInterval)
            let known = KnownDevice(
                udid: udid, name: details.name, productType: details.productType,
                productVersion: details.productVersion, encryption: details.encryption, lastSeen: now)
            if entry.known.map({ Self.differsIgnoringLastSeen($0, known) }) ?? true { toPersist = known }
            entry.known = known
        case .failure(let issue):
            entry.issue = issue
            switch issue {
            case .needsTrust: entry.nextProbe = now.addingTimeInterval(timing.trustRetryInterval)
            case .locked: entry.nextProbe = now.addingTimeInterval(timing.lockedRetryInterval)
            case .unreachable: entry.nextProbe = now.addingTimeInterval(timing.failureRetryInterval)
            }
        }
        entries[udid] = entry
        return toPersist
    }

    /// Removes a device that is not connected. Returns false (and keeps it) while it is present.
    @discardableResult
    public mutating func forget(_ udid: String) -> Bool {
        guard let entry = entries[udid], entry.connections.isEmpty else { return false }
        entries[udid] = nil
        return true
    }

    public mutating func applyLastBackup(udid: String, date: Date?) {
        entries[udid]?.lastBackup = date
    }

    /// UDIDs we should look up backup dates for.
    public var allUDIDs: [String] { entries.keys.sorted() }

    /// Reachable devices first, then by name.
    public func states() -> [DeviceState] {
        entries.map { udid, entry in
            let details = entry.details
            let known = entry.known
            return DeviceState(
                udid: udid,
                name: details?.name ?? known?.name ?? "iPhone (\(udid.prefix(8)))",
                productType: details?.productType ?? known?.productType,
                productVersion: details?.productVersion ?? known?.productVersion,
                connections: entry.connections,
                battery: entry.connections.isEmpty ? nil : details?.battery,
                encryption: details?.encryption ?? known?.encryption ?? .unknown,
                wifiSyncEnabled: details?.wifiSyncEnabled,
                lastBackup: entry.lastBackup,
                issue: entry.issue,
                lastSeen: entry.lastSeen)
        }.sorted {
            if $0.isReachable != $1.isReachable { return $0.isReachable }
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.udid < $1.udid : order == .orderedAscending
        }
    }

    private static func differsIgnoringLastSeen(_ a: KnownDevice, _ b: KnownDevice) -> Bool {
        var a = a, b = b
        a.lastSeen = b.lastSeen
        return a != b
    }
}
