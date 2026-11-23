import Foundation

/// What we remember about our own backup attempts of one device.
public struct DeviceBackupHistory: Codable, Equatable, Sendable {
    /// When a backup made by this app last finished successfully.
    public var lastSuccess: Date?
    /// When the last unsuccessful automatic-retry-relevant attempt ended (failed, busy, passcode timeout,
    /// disconnected, cancelled by the user). Cleared by a success.
    public var lastFailedAttempt: Date?

    public init(lastSuccess: Date? = nil, lastFailedAttempt: Date? = nil) {
        self.lastSuccess = lastSuccess
        self.lastFailedAttempt = lastFailedAttempt
    }

    var isEmpty: Bool { lastSuccess == nil && lastFailedAttempt == nil }
}

/// Persists `DeviceBackupHistory` per UDID as JSON (`state.json` in Application Support), so the
/// scheduler still knows after an app restart that a backup just ran or just failed. Without Full Disk
/// Access `Status.plist` is unreadable, so this is the only source for our own backups there.
@MainActor
public final class BackupHistoryStore {
    private struct File: Codable {
        var version = 1
        var devices: [String: DeviceBackupHistory] = [:]
    }

    public let fileURL: URL?
    private var devices: [String: DeviceBackupHistory]

    nonisolated public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iPhoneBackupHelper/state.json")
    }

    /// `fileURL == nil` keeps everything in memory (tests).
    public init(fileURL: URL? = BackupHistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        self.devices = fileURL.map(Self.load) ?? [:]
    }

    public func history(for udid: String) -> DeviceBackupHistory { devices[udid] ?? DeviceBackupHistory() }

    public func recordSuccess(_ udid: String, at date: Date) {
        var entry = history(for: udid)
        entry.lastSuccess = max(entry.lastSuccess ?? .distantPast, date)
        entry.lastFailedAttempt = nil
        set(udid, entry)
    }

    public func recordFailure(_ udid: String, at date: Date) {
        var entry = history(for: udid)
        entry.lastFailedAttempt = date
        set(udid, entry)
    }

    public func forget(_ udid: String) {
        guard devices.removeValue(forKey: udid) != nil else { return }
        save()
    }

    private func set(_ udid: String, _ entry: DeviceBackupHistory) {
        guard devices[udid] != entry else { return }
        devices[udid] = entry
        save()
    }

    // MARK: - Persistence

    private static func load(_ url: URL) -> [String: DeviceBackupHistory] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(File.self, from: data) { return file.devices }
        // Unreadable: keep it for inspection, start empty (worst case one extra backup).
        let aside = url.deletingLastPathComponent().appendingPathComponent("state.corrupt.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return [:]
    }

    private func save() {
        guard let fileURL else { return }
        var file = File()
        file.devices = devices.filter { !$0.value.isEmpty }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.shared.log(.error, "state", "could not save backup state: \(error)")
        }
    }
}
