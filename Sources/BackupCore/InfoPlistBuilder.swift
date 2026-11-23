import Foundation

/// Values read from lockdownd that go into the backup's Info.plist.
public struct LockdownBackupInfo: @unchecked Sendable {
    /// Global domain (DeviceName, ProductVersion, SerialNumber, ...).
    public var global: [String: Any]
    /// `com.apple.iTunes` domain.
    public var iTunesSettings: [String: Any]
    /// `com.apple.mobile.iTunes` / `MinITunesVersion`.
    public var minITunesVersion: String?

    public init(global: [String: Any], iTunesSettings: [String: Any] = [:], minITunesVersion: String? = nil) {
        self.global = global
        self.iTunesSettings = iTunesSettings
        self.minITunesVersion = minITunesVersion
    }
}

/// Builds the `Info.plist` Finder/iTunes keep next to every backup.
public enum InfoPlistBuilder {
    /// Small files in `/iTunes_Control/iTunes/` on the device that iTunes copies into Info.plist.
    public static let iTunesFileNames = [
        "ApertureAlbumPrefs", "IC-Info.sidb", "IC-Info.sidv", "PhotosFolderAlbums", "PhotosFolderName",
        "PhotosFolderPrefs", "VoiceMemos.plist", "iPhotoAlbumPrefs", "iTunesApplicationIDs",
        "iTunesPrefs", "iTunesPrefs.plist",
    ]

    /// - Parameters:
    ///   - existing: the current Info.plist, if any. Unknown keys (e.g. the application list a
    ///     Finder backup stored) and the GUID are preserved.
    ///   - lastBackupDate: value for "Last Backup Date"; nil removes the key. The engine passes the
    ///     *previous* date while a backup is running and the new one only after it succeeded, so a
    ///     failed run never looks like a successful one.
    public static func build(
        udid: String,
        existing: [String: Any]?,
        lockdown: LockdownBackupInfo,
        iTunesFiles: [String: Data] = [:],
        iBooksData: Data? = nil,
        lastBackupDate: Date?,
        newGUID: () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
    ) -> [String: Any] {
        var info = existing ?? [:]
        let global = lockdown.global

        func copy(_ lockdownKey: String, to key: String) {
            if let value = global[lockdownKey] { info[key] = value }
        }
        copy("BuildVersion", to: "Build Version")
        copy("DeviceName", to: "Device Name")
        copy("DeviceName", to: "Display Name")
        copy("IntegratedCircuitCardIdentity", to: "ICCID")
        copy("InternationalMobileEquipmentIdentity", to: "IMEI")
        copy("MobileEquipmentIdentifier", to: "MEID")
        if let phone = global["PhoneNumber"] as? String { info["Phone Number"] = phone }
        copy("ProductType", to: "Product Type")
        copy("ProductVersion", to: "Product Version")
        copy("SerialNumber", to: "Serial Number")

        if (info["GUID"] as? String)?.isEmpty != false { info["GUID"] = newGUID() }
        info["Target Identifier"] = udid
        info["Target Type"] = "Device"
        info["Unique Identifier"] = udid.uppercased()
        if info["Applications"] == nil { info["Applications"] = [String: Any]() }
        if info["Installed Applications"] == nil { info["Installed Applications"] = [Any]() }
        if let iBooksData { info["iBooks Data 2"] = iBooksData }
        info["iTunes Files"] = iTunesFiles
        info["iTunes Settings"] = lockdown.iTunesSettings
        // Without iTunes we advertise the minimum version the device asks for.
        info["iTunes Version"] = lockdown.minITunesVersion ?? "10.0.1"

        if let lastBackupDate { info["Last Backup Date"] = lastBackupDate } else { info.removeValue(forKey: "Last Backup Date") }
        return info
    }

    public static func parse(_ data: Data?) -> [String: Any]? {
        BackupMetadata.dictionary(data)
    }

    public static func serialize(_ info: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    }

    /// Atomic write (temp file + rename), so a crash never leaves a half-written Info.plist.
    public static func write(_ info: [String: Any], to url: URL) throws {
        try serialize(info).write(to: url, options: .atomic)
    }
}
