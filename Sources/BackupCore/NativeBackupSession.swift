import CLibimobiledevice
import Foundation

/// Converts between libplist nodes and Foundation property lists.
enum PlistBridge {
    /// Deep copy of `node` as Foundation objects (dictionary, array, String, NSNumber, Date, Data).
    static func toFoundation(_ node: plist_t) -> Any? {
        // Wrapped in a dictionary so scalar nodes survive PropertyListSerialization.
        guard let wrapper = plist_new_dict() else { return nil }
        defer { plist_free(wrapper) }
        plist_dict_set_item(wrapper, "v", plist_copy(node))
        var bin: UnsafeMutablePointer<CChar>? = nil
        var length: UInt32 = 0
        plist_to_bin(wrapper, &bin, &length)
        guard let bin else { return nil }
        defer { plist_mem_free(bin) }
        let data = Data(bytes: bin, count: Int(length))
        let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        return dict?["v"]
    }

    /// New libplist node (caller frees with `plist_free`).
    static func fromFoundation(_ value: Any) -> plist_t? {
        let wrapper: [String: Any] = ["v": value]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: wrapper, format: .binary, options: 0) else {
            return nil
        }
        var parsed: plist_t? = nil
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            _ = plist_from_bin(buffer.bindMemory(to: CChar.self).baseAddress, UInt32(buffer.count), &parsed)
        }
        guard let parsed else { return nil }
        defer { plist_free(parsed) }
        guard let item = plist_dict_get_item(parsed, "v") else { return nil }
        return plist_copy(item)
    }
}

public struct NativeBackupSessionFactory: BackupSessionFactory {
    public init() {}

    public func openSession(for target: BackupTarget) throws -> BackupDeviceSession {
        let session = NativeBackupSession(target: target)
        do {
            try session.connect()
        } catch {
            session.close()
            throw error
        }
        return session
    }
}

/// `BackupDeviceSession` on top of libimobiledevice: lockdown, notification_proxy, AFC (sync lock)
/// and mobilebackup2. All C calls for backups live in this file. Blocking; use from one thread.
final class NativeBackupSession: BackupDeviceSession, @unchecked Sendable {
    private static let label = "iPhoneBackupHelper"
    private static let lockPath = "/com.apple.itunes.lock_sync"
    private static let afcWouldBlock: Int32 = 19 // AFC_E_OP_WOULD_BLOCK
    private static let mobilebackup2Timeout: Int32 = -5 // MOBILEBACKUP2_E_RECEIVE_TIMEOUT

    private static let notificationProxyService = "com.apple.mobile.notification_proxy"
    private static let afcService = "com.apple.afc"
    private static let mobilebackup2Service = "com.apple.mobilebackup2"

    private enum Note {
        static let syncWillStart = "com.apple.itunes-mobdev.syncWillStart"
        static let syncLockRequest = "com.apple.itunes-mobdev.syncLockRequest"
        static let syncDidStart = "com.apple.itunes-mobdev.syncDidStart"
        static let syncDidFinish = "com.apple.itunes-mobdev.syncDidFinish"
        static let cancelRequest = "com.apple.itunes-client.syncCancelRequest"
        static let suspendRequest = "com.apple.itunes-client.syncSuspendRequest"
        static let resumeRequest = "com.apple.itunes-client.syncResumeRequest"
        static let backupDomainChanged = "com.apple.mobile.backup.domain_changed"
        static let passcodePresented = "com.apple.LocalAuthentication.ui.presented"
        static let passcodeDismissed = "com.apple.LocalAuthentication.ui.dismissed"
    }

    private let target: BackupTarget
    private var device: idevice_t?
    private var mobilebackup2: mobilebackup2_client_t?
    private var observer: np_client_t?
    private var poster: np_client_t?
    private var afc: afc_client_t?
    private var lockHandle: UInt64 = 0

    private let handlerLock = NSLock()
    private var eventHandler: (@Sendable (SessionEvent) -> Void)?

    private(set) var productVersion: String?
    private(set) var willEncrypt = false
    private(set) var lockdownInfo = LockdownBackupInfo(global: [:])

    init(target: BackupTarget) {
        self.target = target
    }

    deinit { close() }

    // MARK: - Connecting

    func connect() throws {
        var newDevice: idevice_t? = nil
        let lookup = target.connection == .usb ? IDEVICE_LOOKUP_USBMUX.rawValue : IDEVICE_LOOKUP_NETWORK.rawValue
        let found = idevice_new_with_options(&newDevice, target.udid, idevice_options(rawValue: lookup))
        guard found.rawValue == 0, let newDevice else {
            throw BackupError.failed("The iPhone is no longer reachable (error \(found.rawValue)).")
        }
        device = newDevice

        var lockdown: lockdownd_client_t? = nil
        let handshake = lockdownd_client_new_with_handshake(newDevice, &lockdown, Self.label)
        guard handshake.rawValue == 0, let lockdown else { throw Self.lockdownFailure(handshake.rawValue) }
        defer { lockdownd_client_free(lockdown) }

        let global = NativeDeviceBackend.dictionary(client: lockdown, domain: nil) ?? [:]
        productVersion = global["ProductVersion"] as? String
        willEncrypt = Self.boolValue(client: lockdown, domain: "com.apple.mobile.backup", key: "WillEncrypt")
        lockdownInfo = LockdownBackupInfo(
            global: global,
            iTunesSettings: NativeDeviceBackend.dictionary(client: lockdown, domain: "com.apple.iTunes") ?? [:],
            minITunesVersion: Self.stringValue(client: lockdown, domain: "com.apple.mobile.iTunes", key: "MinITunesVersion"))

        // notification_proxy: one connection that listens, one that posts.
        try withService(lockdown, Self.notificationProxyService) { service in
            var client: np_client_t? = nil
            let result = np_client_new(newDevice, service, &client)
            guard result.rawValue == 0, let client else { throw BackupError.failed("Could not start notification_proxy (\(result.rawValue)).") }
            observer = client
        }
        try withService(lockdown, Self.notificationProxyService) { service in
            var client: np_client_t? = nil
            let result = np_client_new(newDevice, service, &client)
            guard result.rawValue == 0, let client else { throw BackupError.failed("Could not start notification_proxy (\(result.rawValue)).") }
            poster = client
        }
        if let observer {
            np_set_notify_callback(observer, Self.notifyCallback, Unmanaged.passUnretained(self).toOpaque())
            for name in [
                Note.cancelRequest, Note.suspendRequest, Note.resumeRequest,
                Note.backupDomainChanged, Note.passcodePresented, Note.passcodeDismissed,
            ] {
                np_observe_notification(observer, name)
            }
        }

        try withService(lockdown, Self.afcService) { service in
            var client: afc_client_t? = nil
            let result = afc_client_new(newDevice, service, &client)
            guard result.rawValue == 0, let client else { throw BackupError.failed("Could not start AFC (\(result.rawValue)).") }
            afc = client
        }

        try withService(lockdown, Self.mobilebackup2Service, escrow: true) { service in
            var client: mobilebackup2_client_t? = nil
            let result = mobilebackup2_client_new(newDevice, service, &client)
            guard result.rawValue == 0, let client else { throw BackupError.failed("Could not start mobilebackup2 (\(result.rawValue)).") }
            mobilebackup2 = client
        }

        var versions: [Double] = [2.0, 2.1]
        var remote = 0.0
        let exchange = mobilebackup2_version_exchange(mobilebackup2, &versions, 2, &remote)
        guard exchange.rawValue == 0 else {
            throw BackupError.failed("Backup protocol version exchange failed (\(exchange.rawValue)).")
        }
    }

    private func withService(
        _ lockdown: lockdownd_client_t, _ identifier: String, escrow: Bool = false,
        _ body: (lockdownd_service_descriptor_t) throws -> Void
    ) throws {
        var descriptor: lockdownd_service_descriptor_t? = nil
        let result = escrow
            ? lockdownd_start_service_with_escrow_bag(lockdown, identifier, &descriptor)
            : lockdownd_start_service(lockdown, identifier, &descriptor)
        defer { if let descriptor { lockdownd_service_descriptor_free(descriptor) } }
        guard result.rawValue == 0 else { throw Self.lockdownFailure(result.rawValue) }
        guard let service = descriptor, service.pointee.port != 0 else {
            throw BackupError.failed("The iPhone did not start \(identifier).")
        }
        try body(service)
    }

    static func lockdownFailure(_ code: Int32) -> BackupError {
        switch NativeDeviceBackend.issue(forLockdownError: code) {
        case .locked:
            return .failed("The iPhone is locked. Unlock it and try again.")
        case .needsTrust:
            return .failed("This Mac is not trusted by the iPhone. Tap “Trust” on the iPhone.")
        case .unreachable(let reason):
            return .failed("Could not talk to the iPhone (\(reason)).")
        }
    }

    private static func boolValue(client: lockdownd_client_t, domain: String, key: String) -> Bool {
        var node: plist_t? = nil
        guard lockdownd_get_value(client, domain, key, &node).rawValue == 0, let node else { return false }
        defer { plist_free(node) }
        var value: UInt8 = 0
        plist_get_bool_val(node, &value)
        return value != 0
    }

    private static func stringValue(client: lockdownd_client_t, domain: String, key: String) -> String? {
        var node: plist_t? = nil
        guard lockdownd_get_value(client, domain, key, &node).rawValue == 0, let node else { return nil }
        defer { plist_free(node) }
        var raw: UnsafeMutablePointer<CChar>? = nil
        plist_get_string_val(node, &raw)
        guard let raw else { return nil }
        defer { free(raw) }
        return String(cString: raw)
    }

    // MARK: - Notifications from the device

    private static let notifyCallback: np_notify_cb_t = { notification, userData in
        guard let notification, let userData else { return }
        let session = Unmanaged<NativeBackupSession>.fromOpaque(userData).takeUnretainedValue()
        session.handleNotification(String(cString: notification))
    }

    func setEventHandler(_ handler: @escaping @Sendable (SessionEvent) -> Void) {
        handlerLock.lock()
        eventHandler = handler
        handlerLock.unlock()
    }

    private func handleNotification(_ name: String) {
        let event: SessionEvent
        switch name {
        case Note.cancelRequest: event = .cancelRequestedOnDevice
        case Note.passcodePresented: event = .passcodePromptShown
        case Note.passcodeDismissed: event = .passcodePromptDismissed
        default: return
        }
        handlerLock.lock()
        let handler = eventHandler
        handlerLock.unlock()
        handler?(event)
    }

    private func post(_ notification: String) {
        guard let poster else { return }
        np_post_notification(poster, notification)
    }

    // MARK: - Sync lock

    func acquireSyncLock(attempts: Int, retryDelay: TimeInterval) throws {
        guard let afc else { throw BackupError.failed("AFC is not connected.") }

        // 1. Peek without telling the device: if Finder (or another sync) holds the lock we must not
        //    disturb it with our own syncWillStart/syncLockRequest notifications.
        var probe: UInt64 = 0
        let opened = afc_file_open(afc, Self.lockPath, AFC_FOPEN_RW, &probe)
        guard opened.rawValue == 0, probe != 0 else {
            throw BackupError.failed("Cannot open the sync lock file on the iPhone (AFC error \(opened.rawValue)).")
        }
        var lockIsFree = false
        for attempt in 0..<5 {
            let result = afc_file_lock(afc, probe, AFC_LOCK_EX)
            if result.rawValue == 0 { lockIsFree = true; break }
            guard result.rawValue == Self.afcWouldBlock else {
                afc_file_close(afc, probe)
                throw BackupError.failed("Cannot lock the iPhone for syncing (AFC error \(result.rawValue)).")
            }
            if attempt < 4 { Thread.sleep(forTimeInterval: retryDelay) }
        }
        if lockIsFree { afc_file_lock(afc, probe, AFC_LOCK_UN) }
        afc_file_close(afc, probe)
        guard lockIsFree else { throw BackupError.deviceBusy }

        // 2. The regular iTunes/Finder sequence.
        post(Note.syncWillStart)
        var handle: UInt64 = 0
        let reopened = afc_file_open(afc, Self.lockPath, AFC_FOPEN_RW, &handle)
        guard reopened.rawValue == 0, handle != 0 else {
            post(Note.syncDidFinish)
            throw BackupError.failed("Cannot open the sync lock file on the iPhone (AFC error \(reopened.rawValue)).")
        }
        post(Note.syncLockRequest)
        for _ in 0..<max(1, attempts) {
            let result = afc_file_lock(afc, handle, AFC_LOCK_EX)
            if result.rawValue == 0 {
                lockHandle = handle
                post(Note.syncDidStart)
                return
            }
            guard result.rawValue == Self.afcWouldBlock else {
                afc_file_close(afc, handle)
                post(Note.syncDidFinish)
                throw BackupError.failed("Cannot lock the iPhone for syncing (AFC error \(result.rawValue)).")
            }
            Thread.sleep(forTimeInterval: retryDelay)
        }
        // Somebody grabbed it in between: stay out of their way (no syncDidFinish).
        afc_file_close(afc, handle)
        throw BackupError.deviceBusy
    }

    func releaseSyncLock() {
        guard lockHandle != 0, let afc else { return }
        afc_file_lock(afc, lockHandle, AFC_LOCK_UN)
        afc_file_close(afc, lockHandle)
        lockHandle = 0
        post(Note.syncDidFinish)
    }

    func readDeviceFile(_ path: String, maxBytes: Int) -> Data? {
        guard let afc else { return nil }
        var handle: UInt64 = 0
        guard afc_file_open(afc, path, AFC_FOPEN_RDONLY, &handle).rawValue == 0, handle != 0 else { return nil }
        defer { afc_file_close(afc, handle) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while result.count < maxBytes {
            var got: UInt32 = 0
            let status = buffer.withUnsafeMutableBytes { raw in
                afc_file_read(afc, handle, raw.bindMemory(to: CChar.self).baseAddress, UInt32(raw.count), &got)
            }
            if status.rawValue != 0 || got == 0 { break }
            result.append(contentsOf: buffer[0..<Int(got)])
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - mobilebackup2

    func requestBackup(udid: String) throws {
        let result = mobilebackup2_send_request(mobilebackup2, "Backup", udid, udid, nil)
        switch result.rawValue {
        case 0: return
        case -6: throw BackupError.failed("Backup protocol version mismatch.")
        case -7: throw BackupError.failed("The iPhone refused to start the backup.")
        default: throw BackupError.failed("Could not start the backup (error \(result.rawValue)).")
        }
    }

    func receiveMessage() throws -> TransportReceive {
        var message: plist_t? = nil
        var name: UnsafeMutablePointer<CChar>? = nil
        let result = mobilebackup2_receive_message(mobilebackup2, &message, &name)
        defer {
            if let message { plist_free(message) }
            if let name { free(name) }
        }
        if result.rawValue == Self.mobilebackup2Timeout { return .timeout }
        guard result.rawValue == 0 else { throw TransportError.connectionLost("mobilebackup2 receive error \(result.rawValue)") }
        guard let message, let name, let items = PlistBridge.toFoundation(message) as? [Any] else { return .timeout }
        return .message(DLMessage(name: String(cString: name), items: items))
    }

    func sendStatusResponse(code: Int, description: String?, payload: Any?) throws {
        let node = payload.flatMap { PlistBridge.fromFoundation($0) }
        defer { if let node { plist_free(node) } }
        let result = mobilebackup2_send_status_response(mobilebackup2, Int32(code), description, node)
        guard result.rawValue == 0 else { throw TransportError.connectionLost("send status response error \(result.rawValue)") }
    }

    func sendRaw(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            var bytes: UInt32 = 0
            let slice = data.suffix(from: data.startIndex + sent)
            let result = slice.withUnsafeBytes { raw in
                mobilebackup2_send_raw(mobilebackup2, raw.bindMemory(to: CChar.self).baseAddress, UInt32(raw.count), &bytes)
            }
            guard result.rawValue == 0, bytes > 0 else { throw TransportError.connectionLost("send error \(result.rawValue)") }
            sent += Int(bytes)
        }
    }

    func receiveRaw(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var bytes: UInt32 = 0
        let result = buffer.withUnsafeMutableBytes { raw in
            mobilebackup2_receive_raw(mobilebackup2, raw.bindMemory(to: CChar.self).baseAddress, UInt32(raw.count), &bytes)
        }
        if result.rawValue == Self.mobilebackup2Timeout { return Data() }
        guard result.rawValue == 0 else { throw TransportError.connectionLost("receive error \(result.rawValue)") }
        return Data(buffer[0..<Int(bytes)])
    }

    // MARK: - Teardown

    func close() {
        releaseSyncLock()
        if let observer {
            np_set_notify_callback(observer, nil, nil)
            np_client_free(observer)
            self.observer = nil
        }
        if let poster { np_client_free(poster); self.poster = nil }
        if let afc { afc_client_free(afc); self.afc = nil }
        if let mobilebackup2 { mobilebackup2_client_free(mobilebackup2); self.mobilebackup2 = nil }
        if let device { idevice_free(device); self.device = nil }
    }
}
