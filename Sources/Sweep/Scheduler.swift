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

        // Update check — install automatically if enabled, otherwise recommend.
        if Updater.flag(Updater.checkKey),
           let release = Updater.fetchLatest(),
           Updater.isNewer(release.version, than: Updater.currentVersion) {
            if Updater.flag(Updater.autoInstallKey) {
                do {
                    _ = try Updater.install(release)
                    EventStore.append(.info, "Sweep updated itself to \(release.version)",
                                      detail: "The previous version is in the Trash.")
                } catch {
                    findings.append((.action, "Sweep \(release.version) is available (auto-install failed)",
                                     error.localizedDescription))
                }
            } else {
                findings.append((.action, "Sweep \(release.version) is available",
                                 "Install it from Settings → Updates."))
            }
            EventStore.flush()
        }

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

// MARK: - Appearance

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static let key = "appearance"

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applyStored() {
        Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "system")?.apply()
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("scheduleEnabled") private var scheduleEnabled = false
    @AppStorage("scheduleWeekly") private var scheduleWeekly = false
    @AppStorage(BackgroundScan.dateKey) private var lastScanDate = 0.0
    @AppStorage(BackgroundScan.bytesKey) private var lastScanBytes = 0
    @AppStorage(Updater.checkKey) private var updateCheckEnabled = true
    @AppStorage(Updater.autoInstallKey) private var autoInstallUpdates = true
    @AppStorage(Appearance.key) private var appearanceRaw = "system"
    @State private var scheduleError: String?
    @State private var updateStatus: String?
    @State private var availableRelease: Updater.Release?
    @State private var isCheckingUpdate = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceRaw) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

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

            Section("Updates") {
                LabeledContent("Version", value: Updater.currentVersion)
                if Updater.repo.isEmpty {
                    Text("Update checks are disabled in this build (no release repository configured).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Check for updates during scheduled scans", isOn: $updateCheckEnabled)
                    Toggle("Install updates automatically", isOn: $autoInstallUpdates)
                        .disabled(!updateCheckEnabled)
                    Text("Automatic installs happen during the scheduled scan; the replaced version goes to the Trash. Turn this off to just get a recommendation in the Activity log instead.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button(isCheckingUpdate ? "Checking…" : "Check Now") {
                            checkForUpdate()
                        }
                        .disabled(isCheckingUpdate)
                        if let updateStatus {
                            Text(updateStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let release = availableRelease {
                            Button("Install \(release.version) & Relaunch") {
                                installUpdate(release)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Location", value: Bundle.main.bundlePath)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onChange(of: appearanceRaw) { _, raw in
            Appearance(rawValue: raw)?.apply()
        }
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

    private func checkForUpdate() {
        isCheckingUpdate = true
        updateStatus = nil
        availableRelease = nil
        Task {
            let release = await Task.detached { Updater.fetchLatest() }.value
            isCheckingUpdate = false
            guard let release else {
                updateStatus = "Couldn't reach GitHub — check your connection."
                return
            }
            if Updater.isNewer(release.version, than: Updater.currentVersion) {
                availableRelease = release
                updateStatus = "Version \(release.version) is available."
            } else {
                updateStatus = "You're up to date (\(Updater.currentVersion))."
            }
        }
    }

    private func installUpdate(_ release: Updater.Release) {
        updateStatus = "Installing…"
        Task {
            do {
                EventStore.append(.info, "Updating Sweep \(Updater.currentVersion) → \(release.version)")
                EventStore.flush()
                try Updater.installAndRelaunch(release)
            } catch {
                updateStatus = "Update failed: \(error.localizedDescription)"
                availableRelease = release
            }
        }
    }
}
