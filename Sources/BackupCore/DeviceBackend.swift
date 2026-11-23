import Foundation

/// Source of device presence + lockdown details. The real one talks to usbmuxd through
/// libimobiledevice; tests use a fake.
public protocol DeviceBackend: Sendable {
    /// Devices currently known to usbmuxd, USB and Wi-Fi entries separately.
    func listDevices() async throws -> [ConnectedDevice]
    /// Reads name, model, iOS version, battery and encryption status via lockdownd.
    func readDetails(udid: String) async -> DeviceReadResult
}

public enum DeviceBackendError: Error, Equatable, Sendable {
    /// usbmuxd did not answer (daemon not running / no permission).
    case usbmuxUnavailable(Int)
}
