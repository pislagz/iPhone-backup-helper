import BackupCore
import ServiceManagement
import SwiftUI

private enum SidebarItem: Hashable {
    case general
    case device(String)
}

struct SettingsView: View {
    let model: AppModel
    @ObservedObject private var monitor: DeviceMonitor
    @ObservedObject private var store: SettingsStore
    @State private var selection: SidebarItem? = .general

    init(model: AppModel) {
        self.model = model
        _monitor = ObservedObject(wrappedValue: model.monitor)
        _store = ObservedObject(wrappedValue: model.settings)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag(SidebarItem.general)
                Section("Devices") {
                    ForEach(monitor.devices) { device in
                        Label(device.name, systemImage: device.isTablet ? "ipad" : "iphone")
                            .opacity(device.isReachable ? 1 : 0.6)
                            .tag(SidebarItem.device(device.udid))
                    }
                    if monitor.devices.isEmpty {
                        Text("No devices yet").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            switch selection ?? .general {
            case .general:
                GeneralSettingsView(store: store)
            case .device(let udid):
                if let device = monitor.devices.first(where: { $0.udid == udid }) {
                    DeviceSettingsView(
                        device: device,
                        settings: Binding(
                            get: { store.settings(for: udid) },
                            set: { store.update(udid, $0) }),
                        onForget: {
                            if monitor.forget(udid: udid) {
                                store.forget(udid)
                                model.backups.forgetHistory(udid: udid)
                                selection = .general
                            }
                        })
                } else {
                    Text("Device not found").foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    Text("Approve “iPhone Backup Helper” in System Settings › General › Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Notifications") {
                Toggle("Backup started", isOn: $store.general.notifyStarted)
                Toggle("iPhone needs to be unlocked (passcode)", isOn: $store.general.notifyNeedsPasscode)
                Toggle("Backup finished", isOn: $store.general.notifyFinished)
                Toggle("Backup failed", isOn: $store.general.notifyFailed)
                Text("Only one passcode reminder is sent per backup attempt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Could not change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Device

private struct DeviceSettingsView: View {
    let device: DeviceState
    @Binding var settings: DeviceSettings
    let onForget: () -> Void
    @State private var confirmForget = false

    private static let weekdays: [(number: Int, name: String)] = [
        (2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Back up automatically", isOn: $settings.enabled)
                Text("The iPhone asks for its passcode at the start of every backup, so it must be unlocked when the backup starts.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(device.name)
            }

            Section("Schedule") {
                Picker("Frequency", selection: $settings.frequency) {
                    Text("Daily").tag(DeviceSettings.FrequencyKind.daily)
                    Text("Every N hours").tag(DeviceSettings.FrequencyKind.everyHours)
                    Text("Weekly, on selected days").tag(DeviceSettings.FrequencyKind.weekly)
                }
                if settings.frequency == .everyHours {
                    Stepper("Every \(settings.everyHours) h", value: $settings.everyHours, in: 1...168)
                }
                if settings.frequency == .weekly {
                    HStack {
                        ForEach(Self.weekdays, id: \.number) { day in
                            Toggle(day.name, isOn: dayBinding(day.number)).toggleStyle(.button)
                        }
                    }
                }
                Toggle("Only start inside a time window", isOn: $settings.windowEnabled)
                if settings.windowEnabled {
                    DatePicker("From", selection: minuteBinding($settings.windowStartMinute), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minuteBinding($settings.windowEndMinute), displayedComponents: .hourAndMinute)
                    if settings.windowEndMinute <= settings.windowStartMinute {
                        Text(settings.windowEndMinute == settings.windowStartMinute
                             ? "Same start and end: the whole day."
                             : "The window runs past midnight into the next day.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Stepper(
                    settings.minIntervalHours == 0 ? "Minimum time since last backup: none"
                        : "Minimum time since last backup: \(settings.minIntervalHours) h",
                    value: $settings.minIntervalHours, in: 0...720)
                Text("Backups made in Finder count too.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Conditions") {
                Picker("Connection", selection: $settings.connectionPolicy) {
                    Text("USB only").tag(DeviceSettings.ConnectionPolicy.usbOnly)
                    Text("USB or Wi-Fi").tag(DeviceSettings.ConnectionPolicy.usbOrWiFi)
                }
                Stepper(
                    settings.minBatteryPercent == 0 ? "Minimum battery: none" : "Minimum battery: \(settings.minBatteryPercent)%",
                    value: $settings.minBatteryPercent, in: 0...100, step: 5)
                Toggle("Ignore the battery level while charging", isOn: $settings.ignoreBatteryIfCharging)
                    .disabled(settings.minBatteryPercent == 0)
                Toggle("Only when this Mac is on AC power", isOn: $settings.requireACPower)
                Stepper(
                    settings.minFreeDiskGB == 0 ? "Minimum free disk space: none" : "Minimum free disk space: \(settings.minFreeDiskGB) GB",
                    value: $settings.minFreeDiskGB, in: 0...2_000, step: 5)
            }

            Section("Passcode and retries") {
                Stepper(
                    "Wait for the passcode: \(Int(settings.passcodeWaitSeconds / 60)) min",
                    value: passcodeMinutes, in: 1...60)
                Stepper(
                    "Retry after a failed attempt: \(settings.retryIntervalMinutes) min",
                    value: $settings.retryIntervalMinutes, in: 5...480, step: 5)
                Text("Retries only happen while the time window is open.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Forget this device…", role: .destructive) { confirmForget = true }
                    .disabled(device.isReachable)
                    .help(device.isReachable ? "Disconnect the device first." : "Removes the device and its settings from this app.")
                Text("Existing backups in the MobileSync folder are not deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget “\(device.name)”?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive, action: onForget)
        } message: {
            Text("Its settings are removed. Backups on disk stay where they are.")
        }
    }

    private var passcodeMinutes: Binding<Int> {
        Binding(
            get: { max(1, Int((settings.passcodeWaitSeconds / 60).rounded())) },
            set: { settings.passcodeWaitSeconds = TimeInterval($0 * 60) })
    }

    private func dayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { settings.weeklyDays.contains(weekday) },
            set: { on in
                if on { settings.weeklyDays.insert(weekday) } else { settings.weeklyDays.remove(weekday) }
            })
    }

    /// Minute-of-day <-> a Date on a fixed reference day (only hour and minute are shown).
    private func minuteBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                var c = DateComponents(year: 2001, month: 1, day: 1)
                c.hour = minute.wrappedValue / 60
                c.minute = minute.wrappedValue % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                minute.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }
}
