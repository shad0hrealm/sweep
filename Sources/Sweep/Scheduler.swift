import SwiftUI
import UserNotifications

// MARK: - launchd agent management

enum ScanScheduler {
    static let label = "au.com.thehartmanns.sweep.scan"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Writes and loads a launchd agent that runs `Sweep --background-scan`.
    /// Daily at 12:30, or Mondays at 12:30 when weekly.
    static func install(weekly: Bool) throws {
        guard let exe = Bundle.main.executablePath else { return }
        var interval: [String: Int] = ["Hour": 12, "Minute": 30]
        if weekly { interval["Weekday"] = 1 }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--background-scan"],
            "StartCalendarInterval": interval,
            "RunAtLoad": false,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: agentURL)
        let uid = getuid()
        Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", agentURL.path])
    }

    static func remove() {
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: agentURL)
    }

    /// Fires the agent immediately (for testing the schedule end to end).
    static func kickstart() {
        Shell.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(label)"])
    }
}

// MARK: - Headless scan (run via `Sweep --background-scan`)

/// Snapshot from the previous scheduled run, used to detect changes.
private struct ScanState: Codable {
    var launchItemPaths: [String] = []
    var securityWarnIDs: [String] = []
}

enum BackgroundScan {
    static let dateKey = "lastBackgroundScanDate"
    static let bytesKey = "lastBackgroundScanBytes"
    static let junkThreshold: Int64 = 1_000_000_000

    private static var stateURL: URL {
        EventStore.fileURL.deletingLastPathComponent().appendingPathComponent("scan-state.json")
    }

    static func run() {
        let junk = measureJunk()
        let defaults = UserDefaults.standard
        defaults.set(Date().timeIntervalSince1970, forKey: dateKey)
        defaults.set(junk, forKey: bytesKey)

        // (severity, title, detail) — anything non-info triggers a notification.
        var findings: [(SweepEvent.Severity, String, String?)] = []

        if junk >= junkThreshold {
            findings.append((.action, "\(formatBytes(junk)) of junk ready to review",
                             "Caches, logs, Trash and developer leftovers. Open Sweep → Cleanup."))
        }

        let disk = StatsModel.readDisk()
        if disk.total > 0, Double(disk.free) / Double(disk.total) < 0.10 {
            findings.append((.warning, "Startup disk is nearly full — \(formatBytes(disk.free)) free",
                             "Try Cleanup, Large & Old Files, and Orphaned Leftovers."))
        }

        let previous = loadState()
        let launchItems = LaunchItemsModel.scanAll()
        let securityChecks = SecurityModel.runAll()
        let ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredSecurityChecks") ?? [])
        let warnIDs = securityChecks.compactMap { check -> String? in
            if case .warn = check.status, !ignored.contains(check.id) { return check.id }
            return nil
        }

        // Only diff when a baseline exists — the first run just records one.
        if let previous {
            let knownPaths = Set(previous.launchItemPaths)
            for item in launchItems where !knownPaths.contains(item.plistURL.path) {
                let suspicious = !item.warnings.isEmpty
                findings.append((suspicious ? .warning : .info,
                                 "New \(suspicious ? "suspicious " : "")background item: \(item.label)",
                                 item.warnings.first ?? item.plistURL.path))
            }
            for id in warnIDs where !previous.securityWarnIDs.contains(id) {
                if let check = securityChecks.first(where: { $0.id == id }) {
                    findings.append((.warning, "New security warning: \(check.title)", check.detail))
                }
            }
        }

        saveState(ScanState(launchItemPaths: launchItems.map(\.plistURL.path),
                            securityWarnIDs: warnIDs))

        for finding in findings {
            EventStore.append(finding.0, finding.1, detail: finding.2)
        }
        EventStore.append(.info, "Scheduled scan finished — \(formatBytes(junk)) of junk found",
                          detail: previous == nil ? "First run: recorded a baseline of background items and security status." : nil)
        EventStore.flush()

        // Notify only when there's something to act on; quiet runs just log.
        let noteworthy = findings.filter { $0.0 != .info }
        if !noteworthy.isEmpty {
            notify(title: noteworthy.count == 1 ? noteworthy[0].1 : "Sweep: \(noteworthy.count) things worth a look",
                   body: noteworthy.count == 1
                       ? (noteworthy[0].2 ?? "Open Sweep for details.")
                       : noteworthy.map(\.1).joined(separator: "\n"))
        }
    }

    private static func measureJunk() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        // Downloads are personal files, not junk — exclude them from the headline number.
        for spec in CategorySpec.all() where spec.id != "downloads" {
            for root in spec.roots {
                let options: FileManager.DirectoryEnumerationOptions = spec.includeHidden ? [] : [.skipsHiddenFiles]
                guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                 options: options) else { continue }
                for child in children where !spec.exclude.contains(child.lastPathComponent) {
                    total += allocatedSize(of: child)
                }
            }
            for whole in spec.wholeItems {
                total += allocatedSize(of: whole)
            }
        }
        return total
    }

    private static func loadState() -> ScanState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(ScanState.self, from: data)
    }

    private static func saveState(_ state: ScanState) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL)
        }
    }

    private static func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let semaphore = DispatchSemaphore(value: 0)
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                semaphore.signal()
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { _ in semaphore.signal() }
        }
        _ = semaphore.wait(timeout: .now() + 10)
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("scheduleEnabled") private var scheduleEnabled = false
    @AppStorage("scheduleWeekly") private var scheduleWeekly = false
    @AppStorage(BackgroundScan.dateKey) private var lastScanDate = 0.0
    @AppStorage(BackgroundScan.bytesKey) private var lastScanBytes = 0
    @State private var scheduleError: String?

    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show Sweep in the menu bar", isOn: $menuBarEnabled)
                Text("Disk, memory and junk at a glance, without opening the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Scheduled Scan") {
                Toggle("Scan for junk automatically", isOn: $scheduleEnabled)
                Picker("Frequency", selection: $scheduleWeekly) {
                    Text("Daily (12:30 pm)").tag(false)
                    Text("Weekly (Monday 12:30 pm)").tag(true)
                }
                .disabled(!scheduleEnabled)

                Text("Runs a lightweight scan in the background and notifies you of what's reclaimable. Nothing is ever cleaned automatically. If you move Sweep.app, toggle this off and on again so the schedule points at the new location.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if scheduleEnabled {
                    LabeledContent("Last scheduled scan") {
                        if lastScanDate > 0 {
                            Text("\(relativeDate(Date(timeIntervalSince1970: lastScanDate))) — \(formatBytes(Int64(lastScanBytes))) found")
                        } else {
                            Text("Hasn't run yet")
                        }
                    }
                    Button("Run Scheduled Scan Now") {
                        ScanScheduler.kickstart()
                    }
                }

                if let scheduleError {
                    Text(scheduleError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.1")
                LabeledContent("Location", value: Bundle.main.bundlePath)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onChange(of: scheduleEnabled) { _, enabled in
            scheduleError = nil
            if enabled {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
                do {
                    try ScanScheduler.install(weekly: scheduleWeekly)
                } catch {
                    scheduleError = "Couldn't install the schedule: \(error.localizedDescription)"
                    scheduleEnabled = false
                }
            } else {
                ScanScheduler.remove()
            }
        }
        .onChange(of: scheduleWeekly) { _, weekly in
            guard scheduleEnabled else { return }
            do {
                try ScanScheduler.install(weekly: weekly)
            } catch {
                scheduleError = "Couldn't update the schedule: \(error.localizedDescription)"
            }
        }
        .onAppear {
            // Heal a stale toggle if the agent file was removed out-of-band.
            if scheduleEnabled && !ScanScheduler.isInstalled {
                try? ScanScheduler.install(weekly: scheduleWeekly)
            }
        }
    }
}
