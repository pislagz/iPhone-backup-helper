import Foundation

/// One DeviceLink message: `["DLMessageXxx", args...]`. `items[0]` is the name.
public struct DLMessage: @unchecked Sendable {
    public var name: String
    public var items: [Any]

    public init(name: String, items: [Any]) {
        self.name = name
        self.items = items
    }

    /// Convenience for tests and handlers: `DLMessage(["DLMessageX", arg1, arg2])`.
    public init?(_ items: [Any]) {
        guard let name = items.first as? String else { return nil }
        self.name = name
        self.items = items
    }
}

public enum TransportReceive {
    case message(DLMessage)
    /// Nothing arrived within the transport's timeout (e.g. the device waits for the passcode).
    case timeout
}

public enum TransportError: Error, Equatable {
    case connectionLost(String)
}

/// The wire to the device's mobilebackup2 service. The real one wraps libimobiledevice
/// (`NativeBackupSession`); the unit tests use a fake.
public protocol MobileBackup2Transport: AnyObject {
    /// Next DeviceLink message, or `.timeout`.
    func receiveMessage() throws -> TransportReceive
    /// `DLMessageStatusResponse`: `[ "DLMessageStatusResponse", code, description ?? "___EmptyParameterString___", payload ]`.
    func sendStatusResponse(code: Int, description: String?, payload: Any?) throws
    func sendRaw(_ data: Data) throws
    /// Up to `count` bytes; empty on timeout.
    func receiveRaw(_ count: Int) throws -> Data
}

/// Frame codes of the file stream used by DLMessageDownloadFiles / UploadFiles.
enum FileFrameCode {
    static let success: UInt8 = 0x00
    static let errorLocal: UInt8 = 0x06
    static let errorRemote: UInt8 = 0x0b
    static let fileData: UInt8 = 0x0c
}

/// Error numbers the device understands in status replies (see the DeviceLink protocol).
enum DeviceErrorCode {
    static let generic = -1
    static let noSuchFile = -6
    static let fileExists = -7
    static let notDirectory = -8
    static let isDirectory = -9
    static let loop = -10
    static let io = -11
    static let multiStatus = -13
    static let noSpace = -15

    static func from(errno value: Int32) -> Int {
        switch value {
        case ENOENT: return noSuchFile
        case EEXIST: return fileExists
        case ENOTDIR: return notDirectory
        case EISDIR: return isDirectory
        case ELOOP: return loop
        case EIO: return io
        case ENOSPC: return noSpace
        default: return generic
        }
    }
}

/// Extracts the errno from a Foundation error (POSIX, underlying POSIX or a few Cocoa codes).
func errnoValue(of error: Error) -> Int32 {
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
        return Int32(underlying.code)
    }
    if ns.domain == NSCocoaErrorDomain {
        switch ns.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return ENOENT
        case NSFileWriteFileExistsError: return EEXIST
        case NSFileWriteOutOfSpaceError: return ENOSPC
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return EACCES
        default: break
        }
    }
    return EIO
}

func describe(errno value: Int32) -> String {
    String(cString: strerror(value))
}
