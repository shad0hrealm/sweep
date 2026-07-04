import SwiftUI
import Observation

// MARK: - Model

struct SecurityCheck: Identifiable, Sendable {
    enum Status: Sendable {
        case pass, warn, unknown

        var icon: String {
            switch self {
            case .pass: "checkmark.shield.fill"
            case .warn: "exclamationmark.triangle.fill"
            case .unknown: "questionmark.circle"
            }
        }

        var color: Color {
            switch self {
            case .pass: .green
            case .warn: .orange
            case .unknown: .secondary
            }
        }
    }

    let id: String
    let title: String
    let status: Status
    let detail: String
    let advice: String?
}

@MainActor
@Observable
final class SecurityModel {
    var checks: [SecurityCheck] = []
    var isRunning = false
    var hasRun = false

    var warningCount: Int { checks.filter { if case .warn = $0.status { return true } else { return false } }.count }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        let results = await Task.detached(priority: .userInitiated) { Self.runAll() }.value
        checks = results
        hasRun = true
        isRunning = false
    }

    nonisolated static func runAll() -> [SecurityCheck] {
        var results: [SecurityCheck] = []

        // FileVault
        let fv = Shell.run("/usr/bin/fdesetup", ["status"])
        if fv.contains("FileVault is On") {
            results.append(SecurityCheck(id: "filevault", title: "FileVault disk encryption", status: .pass,
                                         detail: "Your startup disk is encrypted.", advice: nil))
        } else if fv.contains("FileVault is Off") {
            results.append(SecurityCheck(id: "filevault", title: "FileVault disk encryption", status: .warn,
                                         detail: "Your startup disk is not encrypted. Anyone with physical access to this Mac can read your files.",
                                         advice: "Turn on FileVault in System Settings → Privacy & Security."))
        } else {
            results.append(SecurityCheck(id: "filevault", title: "FileVault disk encryption", status: .unknown,
                                         detail: "Couldn't determine FileVault status.", advice: nil))
        }

        // Gatekeeper
        let gk = Shell.run("/usr/sbin/spctl", ["--status"])
        results.append(SecurityCheck(
            id: "gatekeeper", title: "Gatekeeper",
            status: gk.contains("assessments enabled") ? .pass : (gk.contains("disabled") ? .warn : .unknown),
            detail: gk.contains("assessments enabled")
                ? "Downloaded apps are checked for known malware before they run."
                : "Gatekeeper app verification appears to be disabled.",
            advice: gk.contains("disabled") ? "Re-enable with: sudo spctl --global-enable" : nil))

        // System Integrity Protection
        let sip = Shell.run("/usr/bin/csrutil", ["status"])
        results.append(SecurityCheck(
            id: "sip", title: "System Integrity Protection",
            status: sip.contains("enabled") ? .pass : (sip.contains("disabled") ? .warn : .unknown),
            detail: sip.contains("enabled")
                ? "System files are protected from modification, even by root."
                : "SIP is disabled — system files can be modified by any process running as root.",
            advice: sip.contains("disabled") ? "Re-enable by booting into Recovery and running: csrutil enable" : nil))

        // Firewall
        var fwStatus = SecurityCheck.Status.unknown
        var fwDetail = "Couldn't determine firewall status."
        let fw = Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        if fw.contains("enabled") {
            fwStatus = .pass; fwDetail = "The application firewall is blocking unsolicited incoming connections."
        } else if fw.contains("disabled") {
            fwStatus = .warn; fwDetail = "The application firewall is off. Incoming connections are not filtered."
        } else {
            let alf = Shell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.alf", "globalstate"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if alf == "1" || alf == "2" {
                fwStatus = .pass; fwDetail = "The application firewall is blocking unsolicited incoming connections."
            } else if alf == "0" {
                fwStatus = .warn; fwDetail = "The application firewall is off. Incoming connections are not filtered."
            }
        }
        results.append(SecurityCheck(id: "firewall", title: "Firewall", status: fwStatus, detail: fwDetail,
                                     advice: fwStatus == .warn ? "Turn it on in System Settings → Network → Firewall." : nil))

        // Time Machine
        let tm = Shell.run("/usr/bin/tmutil", ["destinationinfo"])
        if tm.contains("No destinations configured") {
            results.append(SecurityCheck(id: "backup", title: "Backups", status: .warn,
                                         detail: "No Time Machine backup destination is configured.",
                                         advice: "Ransomware protection and disaster recovery both start with a backup. Set one up in System Settings → General → Time Machine."))
        } else if tm.contains("Kind") {
            results.append(SecurityCheck(id: "backup", title: "Backups", status: .pass,
                                         detail: "A Time Machine backup destination is configured.", advice: nil))
        } else {
            results.append(SecurityCheck(id: "backup", title: "Backups", status: .unknown,
                                         detail: "Couldn't determine Time Machine status (this may require Full Disk Access).", advice: nil))
        }

        // Automatic update checks
        let au = Shell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticCheckEnabled"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if au == "1" {
            results.append(SecurityCheck(id: "updates", title: "Automatic update checks", status: .pass,
                                         detail: "macOS checks for software updates automatically.", advice: nil))
        } else if au == "0" {
            results.append(SecurityCheck(id: "updates", title: "Automatic update checks", status: .warn,
                                         detail: "Automatic update checking is turned off.",
                                         advice: "Enable it in System Settings → General → Software Update."))
        }

        return results
    }
}

// MARK: - View

struct SecurityView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmTrashItem: LaunchItem?

    var body: some View {
        let security = app.security
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("System Protection") {
                    VStack(spacing: 0) {
                        if security.isRunning && security.checks.isEmpty {
                            ProgressView("Checking…").padding()
                        }
                        ForEach(security.checks) { check in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: check.status.icon)
                                    .foregroundStyle(check.status.color)
                                    .frame(width: 20)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(check.title).fontWeight(.medium)
                                    Text(check.detail)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    if let advice = check.advice {
                                        Text(advice)
                                            .font(.callout)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            if check.id != security.checks.last?.id { Divider() }
                        }
                    }
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        let flagged = app.launchItems.flagged
                        if !app.launchItems.hasScanned {
                            ProgressView().padding()
                        } else if flagged.isEmpty {
                            Label("No suspicious launch agents or daemons found.", systemImage: "checkmark.shield")
                                .foregroundStyle(.secondary)
                                .padding(8)
                        } else {
                            Text("These items launch automatically and have traits worth reviewing. Legitimate tools sometimes trip these heuristics — check before removing.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 6)
                            ForEach(flagged) { item in
                                LaunchItemRow(item: item) { confirmTrashItem = item }
                                if item.id != flagged.last?.id { Divider() }
                            }
                        }
                    }
                    .padding(6)
                } label: {
                    Text("Startup Item Review")
                }

                GroupBox("Privacy Sweep") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clear app caches, logs and old downloads")
                            Text("Caches and logs can contain browsing traces and document history. The Cleanup tab removes them.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Cleanup") { app.section = .cleanup }
                    }
                    .padding(6)
                }
            }
            .padding(20)
        }
        .navigationTitle("Security")
        .toolbar {
            Button {
                Task {
                    await security.run()
                    await app.launchItems.scan()
                }
            } label: {
                Label("Re-run Checks", systemImage: "arrow.clockwise")
            }
            .disabled(security.isRunning)
        }
        .task {
            if !security.hasRun { await security.run() }
            if !app.launchItems.hasScanned { await app.launchItems.scan() }
        }
        .confirmationDialog(
            "Remove “\(confirmTrashItem?.label ?? "")”?",
            isPresented: Binding(get: { confirmTrashItem != nil }, set: { if !$0 { confirmTrashItem = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let item = confirmTrashItem { app.launchItems.trash(item) }
                confirmTrashItem = nil
            }
        } message: {
            Text("The agent's configuration file is moved to the Trash and stops loading at your next login.")
        }
    }
}
