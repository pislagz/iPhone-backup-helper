import AppKit
import BackupCore
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var monitor: DeviceMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("iPhone Backup Helper")
                .font(.headline)

            if !monitor.usbmuxAvailable {
                Banner(
                    symbol: "exclamationmark.triangle.fill",
                    text: "Can't reach the system's device service (usbmuxd).")
            }

            if monitor.diskAccess == .denied {
                FullDiskAccessBanner()
            }

            if monitor.devices.isEmpty {
                Text("No iPhone or iPad found.\nConnect one with a cable, or turn on “Show this iPhone when on Wi-Fi” in Finder.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(monitor.devices) { device in
                    DeviceRowView(device: device)
                    if device.id != monitor.devices.last?.id { Divider() }
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

private struct Banner: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FullDiskAccessBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Banner(
                symbol: "lock.shield.fill",
                text: "Full Disk Access is needed to read and write backups in the MobileSync folder.")
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            Text("After enabling it, quit and reopen this app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
