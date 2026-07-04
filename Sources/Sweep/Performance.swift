import SwiftUI
import Observation

// MARK: - System stats

struct MemorySnapshot: Sendable {
    var total: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    var used: Int64 = 0
    var compressed: Int64 = 0
}

struct DiskSnapshot: Sendable {
    var total: Int64 = 0
    var free: Int64 = 0
    var used: Int64 { max(0, total - free) }
}

@MainActor
@Observable
final class StatsModel {
    var memory = MemorySnapshot()
    var disk = DiskSnapshot()
    var loadAverage: Double = 0
    var processes: [ProcessRow] = []
    var uptime: String = ""
    let coreCount = ProcessInfo.processInfo.activeProcessorCount

    func refresh() async {
        let snapshot = await Task.detached(priority: .utility) { () -> (MemorySnapshot, DiskSnapshot, Double, [ProcessRow], String) in
            (Self.readMemory(), Self.readDisk(), Self.readLoad(), Self.readProcesses(), Self.readUptime())
        }.value
        memory = snapshot.0
        disk = snapshot.1
        loadAverage = snapshot.2
        processes = snapshot.3
        uptime = snapshot.4
    }

    nonisolated static func readMemory() -> MemorySnapshot {
        var snap = MemorySnapshot()
        let output = Shell.run("/usr/bin/vm_stat")
        var pageSize: Int64 = 16384
        // First line: "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
        if let range = output.range(of: "page size of ") {
            let tail = output[range.upperBound...].prefix(while: \.isNumber)
            pageSize = Int64(tail) ?? pageSize
        }
        func pages(_ label: String) -> Int64 {
            guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix(label) }),
                  let value = line.split(separator: ":").last?
                      .trimmingCharacters(in: .whitespaces)
                      .trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                  let n = Int64(value) else { return 0 }
            return n
        }
        let active = pages("Pages active")
        let wired = pages("Pages wired down")
        let compressed = pages("Pages occupied by compressor")
        snap.used = (active + wired + compressed) * pageSize
        snap.compressed = compressed * pageSize
        return snap
    }

    nonisolated static func readDisk() -> DiskSnapshot {
        var snap = DiskSnapshot()
        let url = URL(fileURLWithPath: "/")
        if let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            snap.total = Int64(values.volumeTotalCapacity ?? 0)
            snap.free = values.volumeAvailableCapacityForImportantUsage ?? 0
        }
        return snap
    }

    nonisolated static func readLoad() -> Double {
        // "{ 1.23 1.45 1.60 }"
        let output = Shell.run("/usr/sbin/sysctl", ["-n", "vm.loadavg"])
        let parts = output.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .split(separator: " ")
        return parts.first.flatMap { Double($0) } ?? 0
    }

    nonisolated static func readUptime() -> String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    nonisolated static func readProcesses() -> [ProcessRow] {
        let output = Shell.run("/bin/ps", ["-Aceo", "pid,pcpu,rss,comm", "-r"])
        var rows: [ProcessRow] = []
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4,
                  let pid = Int(fields[0]),
                  let cpu = Double(fields[1]),
                  let rssKB = Int64(fields[2]) else { continue }
            rows.append(ProcessRow(pid: pid, cpu: cpu, memory: rssKB * 1024,
                                   name: String(fields[3]).trimmingCharacters(in: .whitespaces)))
            if rows.count >= 15 { break }
        }
        return rows
    }
}

struct ProcessRow: Identifiable, Sendable {
    var id: Int { pid }
    let pid: Int
    let cpu: Double
    let memory: Int64
    let name: String
}

// MARK: - Launch items

struct LaunchItem: Identifiable, Hashable, Sendable {
    enum Scope: String, Sendable {
        case userAgent = "Your login items"
        case globalAgent = "All-user agents"
        case daemon = "System daemons"
    }

    var id: URL { plistURL }
    let plistURL: URL
    let label: String
    let program: String?
    let scope: Scope
    let warnings: [String]

    var isUserRemovable: Bool { scope == .userAgent }
}

@MainActor
@Observable
final class LaunchItemsModel {
    var items: [LaunchItem] = []
    var isScanning = false
    var hasScanned = false

    var flagged: [LaunchItem] { items.filter { !$0.warnings.isEmpty } }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let found = await Task.detached(priority: .userInitiated) { Self.scanAll() }.value
        items = found
        hasScanned = true
        isScanning = false
    }

    nonisolated static func scanAll() -> [LaunchItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let sources: [(URL, LaunchItem.Scope)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon),
        ]
        var items: [LaunchItem] = []
        for (dir, scope) in sources {
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for plist in children where plist.pathExtension == "plist" {
                items.append(parse(plist: plist, scope: scope, home: home))
            }
        }
        return items.sorted { ($0.warnings.isEmpty ? 1 : 0, $0.label) < ($1.warnings.isEmpty ? 1 : 0, $1.label) }
    }

    nonisolated private static func parse(plist url: URL, scope: LaunchItem.Scope, home: URL) -> LaunchItem {
        let fm = FileManager.default
        var label = url.deletingPathExtension().lastPathComponent
        var program: String?

        if let data = try? Data(contentsOf: url),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            label = dict["Label"] as? String ?? label
            program = dict["Program"] as? String
            if program == nil, let args = dict["ProgramArguments"] as? [String] {
                program = args.first
            }
        }

        var warnings: [String] = []
        if label.hasPrefix("com.apple."), !url.path.hasPrefix("/System/") {
            warnings.append("Uses an Apple-style identifier but isn't installed by macOS — a common malware disguise")
        }
        if let program {
            let expanded = (program as NSString).expandingTildeInPath
            if expanded.hasPrefix("/tmp/") || expanded.hasPrefix("/private/tmp/") || expanded.hasPrefix("/var/tmp/") {
                warnings.append("Runs an executable from a temporary directory")
            }
            if !fm.fileExists(atPath: expanded) {
                warnings.append("Its executable no longer exists (likely leftover from an uninstalled app)")
            }
        } else {
            warnings.append("Declares no executable")
        }

        return LaunchItem(plistURL: url, label: label, program: program, scope: scope, warnings: warnings)
    }

    func trash(_ item: LaunchItem) {
        guard item.isUserRemovable else { return }
        try? FileManager.default.trashItem(at: item.plistURL, resultingItemURL: nil)
        items.removeAll { $0.id == item.id }
    }
}

// MARK: - View

struct PerformanceView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmTrashItem: LaunchItem?
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let stats = app.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    StatCard(title: "Memory",
                             value: formatBytes(stats.memory.used),
                             detail: "of \(formatBytes(stats.memory.total)) — \(formatBytes(stats.memory.compressed)) compressed",
                             fraction: stats.memory.total > 0 ? Double(stats.memory.used) / Double(stats.memory.total) : 0)
                    StatCard(title: "Disk",
                             value: formatBytes(stats.disk.free) + " free",
                             detail: "of \(formatBytes(stats.disk.total))",
                             fraction: stats.disk.total > 0 ? Double(stats.disk.used) / Double(stats.disk.total) : 0)
                    StatCard(title: "CPU load",
                             value: String(format: "%.2f", stats.loadAverage),
                             detail: "1-min average, \(stats.coreCount) cores",
                             fraction: min(1, stats.loadAverage / Double(stats.coreCount)))
                    StatCard(title: "Uptime", value: stats.uptime, detail: "since last restart", fraction: nil)
                }

                GroupBox("Top Processes") {
                    processTable
                }

                GroupBox {
                    launchItemsList
                } label: {
                    HStack {
                        Text("Login Items & Background Agents")
                        Spacer()
                        Button("Open System Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Performance")
        .task {
            await app.stats.refresh()
            await app.launchItems.scan()
        }
        .onReceive(timer) { _ in
            Task { await app.stats.refresh() }
        }
        .confirmationDialog(
            "Remove “\(confirmTrashItem?.label ?? "")” from your login items?",
            isPresented: Binding(get: { confirmTrashItem != nil }, set: { if !$0 { confirmTrashItem = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let item = confirmTrashItem { app.launchItems.trash(item) }
                confirmTrashItem = nil
            }
        } message: {
            Text("The agent's configuration file is moved to the Trash. It stops loading at your next login. The app it belongs to is not removed.")
        }
    }

    private var processTable: some View {
        let stats = app.stats
        return VStack(spacing: 0) {
            ForEach(stats.processes) { proc in
                HStack {
                    Text(proc.name).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f%% CPU", proc.cpu))
                        .foregroundStyle(.secondary)
                        .font(.callout.monospacedDigit())
                        .frame(width: 90, alignment: .trailing)
                    Text(formatBytes(proc.memory))
                        .foregroundStyle(.secondary)
                        .font(.callout.monospacedDigit())
                        .frame(width: 90, alignment: .trailing)
                }
                .padding(.vertical, 3)
                if proc.id != stats.processes.last?.id { Divider() }
            }
            if stats.processes.isEmpty {
                Text("Loading…").foregroundStyle(.secondary).padding()
            }
        }
        .padding(6)
    }

    private var launchItemsList: some View {
        let launch = app.launchItems
        return VStack(alignment: .leading, spacing: 0) {
            if launch.isScanning {
                ProgressView().padding()
            } else if launch.items.isEmpty {
                Text("No third-party launch agents or daemons found.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
            ForEach(launch.items) { item in
                LaunchItemRow(item: item) {
                    confirmTrashItem = item
                }
                if item.id != launch.items.last?.id { Divider() }
            }
        }
        .padding(6)
    }
}

struct LaunchItemRow: View {
    let item: LaunchItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.warnings.isEmpty ? "gearshape" : "exclamationmark.triangle.fill")
                .foregroundStyle(item.warnings.isEmpty ? Color.secondary : Color.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                Text(item.program ?? item.plistURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ForEach(item.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Text(item.scope.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Button("Reveal") { revealInFinder(item.plistURL) }
                .buttonStyle(.link)
                .font(.callout)
            if item.isUserRemovable {
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let detail: String
    let fraction: Double?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(fraction > 0.85 ? .orange : .accentColor)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}
