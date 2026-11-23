import BackupCore
import SwiftUI

struct DeviceRowView: View {
    let device: DeviceState
    let job: BackupJob?
    let result: BackupResult?
    /// 1 = next in line; nil = not queued.
    var queuePosition: Int?
    let canStart: Bool
    /// "Next: today 20:00–23:00" / "Waiting: battery 14% < 20%"; nil when automatic backups are off.
    var scheduleText: String?
    let onBackUp: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: device.isTablet ? "ipad" : "iphone")
                    .font(.title2)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                statusIcons
            }

            // Re-evaluated every 30 s so "2 h ago" stays current.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(statusLine(now: context.date))
                    .font(.caption)
                    .foregroundStyle(statusIsProblem ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if job == nil, queuePosition == nil, let scheduleText {
                Label(scheduleText, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let job {
                backupProgress(job)
            } else if let queuePosition {
                HStack {
                    Label(queuePosition == 1 ? "Queued (next)" : "Queued (\(queuePosition))", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", action: onCancel)
                }
            } else {
                if let result, result.isProblem {
                    Text(result.text)
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Back up now", action: onBackUp)
                        .disabled(!canStart)
                        .help(canStart ? "Back up this device now" : "The device must be connected and trusted.")
                }
            }
        }
        .opacity(device.isReachable ? 1 : 0.6)
    }

    @ViewBuilder
    private func backupProgress(_ job: BackupJob) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = job.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(progressText(job))
                    .font(.caption)
                    .foregroundStyle(job.phase == .waitingForPasscode ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", action: onCancel)
            }
        }
    }

    private func progressText(_ job: BackupJob) -> String {
        if let fraction = job.fraction, job.phase == .transferring {
            return "\(job.message) \(Int((fraction * 100).rounded()))%"
        }
        return job.message
    }

    private var subtitle: String {
        var parts: [String] = []
        if let model = device.modelName { parts.append(model) }
        if let version = device.productVersion {
            parts.append((device.isTablet ? "iPadOS " : "iOS ") + version)
        }
        return parts.joined(separator: " · ")
    }

    private var statusIcons: some View {
        HStack(spacing: 8) {
            if let battery = device.battery {
                HStack(spacing: 2) {
                    if battery.isCharging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                    Image(systemName: Self.batterySymbol(battery.level))
                    Text("\(battery.level)%").font(.caption).monospacedDigit()
                }
                .help(battery.isCharging ? "Battery \(battery.level)%, charging" : "Battery \(battery.level)%")
            }
            switch device.encryption {
            case .encrypted:
                Image(systemName: "lock.fill").help("Backups are encrypted")
            case .unencrypted:
                Image(systemName: "lock.open").help("Backups are not encrypted")
            case .unknown:
                EmptyView()
            }
            if device.connections.contains(.usb) {
                Image(systemName: "cable.connector").help("Connected by USB")
            }
            if device.connections.contains(.wifi) {
                Image(systemName: "wifi").help("Reachable over Wi-Fi")
            }
        }
    }

    private var statusIsProblem: Bool {
        device.isReachable && device.issue != nil
    }

    private func statusLine(now: Date) -> String {
        if !device.isReachable {
            let seen = device.lastSeen.map { "last seen " + RelativeTime.string(for: $0, now: now) } ?? "not seen yet"
            return "Not reachable (\(seen)) · Last backup: \(RelativeTime.string(for: device.lastBackup, now: now))"
        }
        if let issue = device.issue {
            switch issue {
            case .needsTrust: return "Tap “Trust” on the iPhone (and enter its passcode) to allow this Mac."
            case .locked: return "Unlock the iPhone to read its status."
            case .unreachable(let reason):
                let hint = device.connections == [.wifi] ? "Not responding over Wi-Fi (asleep?)" : "Not responding"
                return "\(hint) · \(reason)"
            }
        }
        var text = "Last backup: \(RelativeTime.string(for: device.lastBackup, now: now))"
        if device.connections == [.wifi], device.wifiSyncEnabled == false {
            text += " · Wi-Fi sync is off in Finder"
        }
        return text
    }

    private static func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}
