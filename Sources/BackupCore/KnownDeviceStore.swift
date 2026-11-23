import Foundation

/// Persists previously seen devices as JSON in Application Support.
public struct KnownDeviceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = KnownDeviceStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/iPhoneBackupHelper/devices.json")
    }

    public func load() -> [KnownDevice] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([KnownDevice].self, from: data)) ?? []
    }

    public func save(_ devices: [KnownDevice]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(devices.sorted { $0.udid < $1.udid }).write(to: fileURL, options: .atomic)
    }
}
