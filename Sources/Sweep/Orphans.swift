import SwiftUI
import Observation

// MARK: - Model

struct OrphanGroup: Identifiable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let items: [LeftoverItem]
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

@MainActor
@Observable
final class OrphansModel {
    var groups: [OrphanGroup] = []
    var selected: Set<URL> = []
    var isScanning = false
    var hasScanned = false
    var lastMessage: String?

    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    var selectedSize: Int64 {
        groups.flatMap(\.items).filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size }
    }

    func scan(installedApps: [AppInfo]) async {
        guard !isScanning else { return }
        isScanning = true
        lastMessage = nil

        // Anything installed OR currently running counts as "still in use".
        var ids = Set(installedApps.compactMap { $0.bundleID?.lowercased() })
        for running in NSWorkspace.shared.runningApplications {
            if let id = running.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        let installedIDs = ids

        let found = await Task.detached(priority: .userInitiated) {
            Self.findOrphans(installedIDs: installedIDs)
        }.value

        groups = found
        selected.removeAll()
        hasScanned = true
        isScanning = false
    }

    func cleanSelected() async {
        let targets = groups.flatMap(\.items).filter { selected.contains($0.url) }
        guard !targets.isEmpty else { return }

        let outcome = await Task.detached(priority: .userInitiated) { () -> (Int, Int64, Int) in
            let fm = FileManager.default
            var removed = 0
            var bytes: Int64 = 0
            var failures = 0
            for item in targets {
                do {
                    try fm.trashItem(at: item.url, resultingItemURL: nil)
                    removed += 1
                    bytes += item.size
                } catch { failures += 1 }
            }
            return (removed, bytes, failures)
        }.value

        lastMessage = "Moved \(outcome.0) item\(outcome.0 == 1 ? "" : "s") to Trash (\(formatBytes(outcome.1)))"
            + (outcome.2 > 0 ? " — \(outcome.2) failed" : "")
        if outcome.0 > 0 {
            EventStore.append(.info, "Cleaned orphaned leftovers — \(formatBytes(outcome.1)) freed")
        }
        let fm = FileManager.default
        groups = groups.compactMap { group in
            let remaining = group.items.filter { fm.fileExists(atPath: $0.url.path) }
            return remaining.isEmpty ? nil : OrphanGroup(bundleID: group.bundleID, items: remaining)
        }
        selected.removeAll()
    }

    // MARK: Discovery

    nonisolated static func findOrphans(installedIDs: Set<String>) -> [OrphanGroup] {
        let fm = FileManager.default
        let userLib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let installedVendors = Set(installedIDs.compactMap(vendorPrefix(of:)))

        let sources: [(String, String)] = [
            ("Application Support", "Application Support"),
            ("Caches", "Caches"),
            ("Preferences", "Preferences"),
            ("Saved Application State", "Saved State"),
            ("Containers", "Container"),
            ("HTTPStorages", "HTTP Storage"),
            ("WebKit", "WebKit Data"),
            ("Cookies", "Cookies"),
            ("Logs", "Logs"),
            ("LaunchAgents", "Launch Agent"),
        ]
        let strippableExtensions = [".plist", ".savedState", ".binarycookies"]

        var byID: [String: [LeftoverItem]] = [:]
        for (dir, kind) in sources {
            let parent = userLib.appendingPathComponent(dir)
            guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { continue }
            for child in children {
                var name = child.lastPathComponent
                for ext in strippableExtensions where name.hasSuffix(ext) {
                    name = String(name.dropLast(ext.count))
                }
                guard let candidate = bundleIDCandidate(name) else { continue }
                let lower = candidate.lowercased()

                if lower.hasPrefix("com.apple") { continue }
                if installedIDs.contains(lower) { continue }
                // Helper/updater IDs from a vendor with an installed app stay untouched.
                if let vendor = vendorPrefix(of: lower), installedVendors.contains(vendor) { continue }
                // Ask LaunchServices — catches apps living outside /Applications.
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate) != nil { continue }
                // A launch agent whose executable still exists likely drives a living
                // CLI tool or service — that's active, not orphaned.
                if kind == "Launch Agent", agentExecutableExists(child) { continue }

                byID[lower, default: []].append(
                    LeftoverItem(url: child, size: allocatedSize(of: child), kind: kind, defaultSelected: false))
            }
        }

        return byID
            .map { OrphanGroup(bundleID: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.totalSize > $1.totalSize }
    }

    nonisolated private static func agentExecutableExists(_ plistURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        var program = dict["Program"] as? String
        if program == nil, let args = dict["ProgramArguments"] as? [String] {
            program = args.first
        }
        guard let program else { return false }
        return FileManager.default.fileExists(atPath: (program as NSString).expandingTildeInPath)
    }

    /// Accepts reverse-domain-style names ("com.spotify.client"), rejects plain
    /// folder names ("Firefox") which can't be safely attributed to one app.
    nonisolated static func bundleIDCandidate(_ name: String) -> String? {
        guard !name.contains(" ") else { return nil }
        let parts = name.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let first = parts[0]
        guard first.count >= 2, first.count <= 6, first.allSatisfy(\.isLetter) else { return nil }
        return name
    }
}

// MARK: - View

struct OrphansView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmClean = false

    var body: some View {
        let model = app.orphans
        VStack(spacing: 0) {
            HStack {
                Text("Files whose reverse-domain name matches no installed or running app — usually remnants of apps you've already deleted. Attribution is heuristic, so nothing is pre-selected: review each group before cleaning.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if let message = model.lastMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
            .padding(12)
            Divider()

            if model.isScanning {
                Spacer()
                ProgressView("Scanning for orphaned files…")
                Spacer()
            } else if model.groups.isEmpty {
                ContentUnavailableView(
                    model.hasScanned ? "No orphaned leftovers found" : "Orphaned leftovers",
                    systemImage: "questionmark.folder",
                    description: Text(model.hasScanned
                        ? "Every support file in your user library belongs to an app that's still installed."
                        : "Scan to find remnants of apps you've already deleted."))
            } else {
                groupList
            }
        }
        .navigationTitle("Orphaned Leftovers (\(formatBytes(model.totalSize)))")
        .toolbar {
            Button {
                Task { await model.scan(installedApps: app.uninstaller.apps) }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning)

            Button(role: .destructive) {
                confirmClean = true
            } label: {
                Label("Clean \(formatBytes(model.selectedSize))", systemImage: "trash")
            }
            .disabled(model.selected.isEmpty)
        }
        .task {
            if !app.uninstaller.hasScanned { await app.uninstaller.scan() }
            if !model.hasScanned { await model.scan(installedApps: app.uninstaller.apps) }
        }
        .confirmationDialog(
            "Move \(model.selected.count) orphaned item\(model.selected.count == 1 ? "" : "s") to the Trash?",
            isPresented: $confirmClean
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.cleanSelected() }
            }
        } message: {
            Text("Frees \(formatBytes(model.selectedSize)). Items go to the Trash, so you can restore them if an app turns out to still need them.")
        }
    }

    private var groupList: some View {
        let model = app.orphans
        return List {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.items) { item in
                        LeftoverRow(item: item, isSelected: Binding(
                            get: { model.selected.contains(item.url) },
                            set: { on in
                                if on { model.selected.insert(item.url) } else { model.selected.remove(item.url) }
                            }
                        ))
                    }
                } header: {
                    HStack {
                        Text(group.bundleID)
                        Spacer()
                        Text(formatBytes(group.totalSize))
                            .monospacedDigit()
                        Button(group.items.allSatisfy { model.selected.contains($0.url) } ? "Deselect All" : "Select All") {
                            let urls = group.items.map(\.url)
                            if group.items.allSatisfy({ model.selected.contains($0.url) }) {
                                model.selected.subtract(urls)
                            } else {
                                model.selected.formUnion(urls)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
