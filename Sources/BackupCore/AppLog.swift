import Foundation
import os

public enum LogLevel: String, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case error = "ERROR"
}

/// Logging sink used by the backup engine (a closure so tests can capture it).
public typealias BackupLogger = @Sendable (LogLevel, String) -> Void

/// Writes to the unified log (os_log) and to a size-rotated file in
/// `~/Library/Logs/iPhoneBackupHelper/`. Never leaves the machine.
public final class AppLog: @unchecked Sendable {
    public static let subsystem = "io.github.pislagz.iphonebackuphelper"
    public static let shared = AppLog()

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/iPhoneBackupHelper", isDirectory: true)
    }

    public let directory: URL
    public let maxBytes: Int
    public let keepFiles: Int
    private let fileName = "iPhoneBackupHelper"
    private let queue = DispatchQueue(label: "io.github.pislagz.iphonebackuphelper.log")
    private let clock: @Sendable () -> Date
    private let mirrorToOSLog: Bool

    public init(
        directory: URL = AppLog.defaultDirectory,
        maxBytes: Int = 1_000_000,
        keepFiles: Int = 3,
        mirrorToOSLog: Bool = true,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.keepFiles = max(1, keepFiles)
        self.mirrorToOSLog = mirrorToOSLog
        self.clock = clock
    }

    public var logFileURL: URL { directory.appendingPathComponent("\(fileName).log") }

    private func rotatedURL(_ index: Int) -> URL {
        directory.appendingPathComponent("\(fileName).\(index).log")
    }

    public func log(_ level: LogLevel, _ category: String, _ message: String) {
        if mirrorToOSLog {
            let logger = Logger(subsystem: Self.subsystem, category: category)
            switch level {
            case .debug: logger.debug("\(message, privacy: .public)")
            case .info: logger.info("\(message, privacy: .public)")
            case .error: logger.error("\(message, privacy: .public)")
            }
        }
        let now = clock()
        queue.async { [self] in
            append(line: Self.format(date: now, level: level, category: category, message: message))
        }
    }

    public func logger(category: String) -> BackupLogger {
        { [self] level, message in log(level, category, message) }
    }

    /// Blocks until queued lines are on disk (tests, app termination).
    public func flush() { queue.sync {} }

    static func format(date: Date, level: LogLevel, category: String, message: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let singleLine = message.replacingOccurrences(of: "\n", with: " ⏎ ")
        return "\(formatter.string(from: date)) \(level.rawValue) [\(category)] \(singleLine)\n"
    }

    private func append(line: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = logFileURL
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size > 0, size + line.utf8.count > maxBytes { rotate() }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Logging must never break the app.
        }
    }

    /// log → log.1 → log.2 … (the oldest is dropped).
    private func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL(keepFiles - 1))
        if keepFiles > 2 {
            for index in stride(from: keepFiles - 2, through: 1, by: -1) {
                try? fm.moveItem(at: rotatedURL(index), to: rotatedURL(index + 1))
            }
        }
        if keepFiles > 1 {
            try? fm.removeItem(at: rotatedURL(1))
            try? fm.moveItem(at: logFileURL, to: rotatedURL(1))
        } else {
            try? fm.removeItem(at: logFileURL)
        }
    }
}
