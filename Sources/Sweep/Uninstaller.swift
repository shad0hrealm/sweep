import SwiftUI
import Observation

// MARK: - Model types

struct AppInfo: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let bundleID: String?
    let size: Int64
    let lastUsed: Date?
}

struct LeftoverItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let kind: String
}

// MARK: - App list

@MainActor
@Observable
final class UninstallerModel {
    var apps: [AppInfo] = []
    var isScanning = false
    var hasScanned = false
    var measuredCount = 0
    var totalCount = 0
    var search = ""

    var filteredApps: [AppInfo] {
        guard !search.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        measuredCount = 0

        let bundles = await Task.detached(priority: .userInitiated) { Self.appBundles() }.value
        totalCount = bundles.count

        let lastUsedDates = await Task.detached(priority: .userInitiated) {
            Self.lastUsedDates(for: bundles)
        }.value

        var results: [AppInfo] = []
        await withTaskGroup(of: AppInfo.self) { group in
            for url in bundles {
                group.addTask {
                    let bundleID = Bundle(url: url)?.bundleIdentifier
                    let size = allocatedSize(of: url)
                    return AppInfo(url: url,
                                   name: url.deletingPathExtension().lastPathComponent,
                                   bundleID: bundleID,
                                   size: size,
                                   lastUsed: lastUsedDates[url])
                }
            }
            for await info in group {
                results.append(info)
                measuredCount += 1
            }
        }

        apps = results.sorted { $0.size > $1.size }
        hasScanned = true
        isScanning = false
    }

    func remove(_ app: AppInfo) {
        apps.removeAll { $0.id == app.id }
    }

    nonisolated private static func appBundles() -> [URL] {
        let fm = FileManager.default
        let dirs = [URL(fileURLWithPath: "/Applications"),
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var bundles: [URL] = []
        for dir in dirs {
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]) else { continue }
            bundles += children.filter { $0.pathExtension == "app" }
        }
        return bundles
    }

    /// Batch-reads Spotlight's "last used" date for all apps in one mdls call.
    nonisolated private static func lastUsedDates(for urls: [URL]) -> [URL: Date] {
        guard !urls.isEmpty else { return [:] }
        let output = Shell.run("/usr/bin/mdls", ["-name", "kMDItemLastUsedDate", "-raw"] + urls.map(\.path))
        let values = output.components(separatedBy: "\0")
        guard values.count >= urls.count else { return [:] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var result: [URL: Date] = [:]
        for (url, value) in zip(urls, values) {
            if let date = formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                result[url] = date
            }
        }
        return result
    }
}

// MARK: - Leftover hunting

@MainActor
@Observable
final class LeftoverState {
    let app: AppInfo
    var items: [LeftoverItem] = []
    var selected: Set<URL> = []
    var includeApp = true
    var isScanning = false
    var hasScanned = false
    var resultMessage: String?

    init(app: AppInfo) {
        self.app = app
    }

    var isAppRunning: Bool {
        guard let bundleID = app.bundleID else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    var selectedSize: Int64 {
        items.filter { selected.contains($0.url) }.reduce(includeApp ? app.size : 0) { $0 + $1.size }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        let app = self.app
        let found = await Task.detached(priority: .userInitiated) { Self.findLeftovers(for: app) }.value
        items = found
        selected = Set(found.map(\.url))
        hasScanned = true
        isScanning = false
    }

    /// Trashes the selected leftovers (and the app bundle if included).
    /// Returns true if the app bundle itself was removed.
    func uninstall() async -> Bool {
        let targets = items.filter { selected.contains($0.url) }
        let includeApp = self.includeApp
        let appURL = app.url

        let outcome = await Task.detached(priority: .userInitiated) { () -> (removed: Int, bytes: Int64, failures: [String], appRemoved: Bool) in
            let fm = FileManager.default
            var removed = 0
            var bytes: Int64 = 0
            var failures: [String] = []
            var appRemoved = false
            if includeApp {
                do {
                    try fm.trashItem(at: appURL, resultingItemURL: nil)
                    appRemoved = true
                    removed += 1
                } catch {
                    failures.append(appURL.lastPathComponent)
                }
            }
            for item in targets {
                do {
                    try fm.trashItem(at: item.url, resultingItemURL: nil)
                    removed += 1
                    bytes += item.size
                } catch {
                    failures.append(item.url.lastPathComponent)
                }
            }
            return (removed, bytes, failures, appRemoved)
        }.value

        var message = "Moved \(outcome.removed) item\(outcome.removed == 1 ? "" : "s") to Trash"
        if !outcome.failures.isEmpty {
            message += " — couldn't remove: \(outcome.failures.joined(separator: ", "))"
        }
        resultMessage = message
        if !outcome.appRemoved || !outcome.failures.isEmpty {
            await scan()
        }
        return outcome.appRemoved
    }

    nonisolated private static func findLeftovers(for app: AppInfo) -> [LeftoverItem] {
        let fm = FileManager.default
        let lib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var results: [LeftoverItem] = []
        var seen = Set<URL>()

        func add(_ url: URL, _ kind: String) {
            guard !seen.contains(url), fm.fileExists(atPath: url.path) else { return }
            seen.insert(url)
            results.append(LeftoverItem(url: url, size: allocatedSize(of: url), kind: kind))
        }

        let bundleID = app.bundleID
        let nameLower = app.name.lowercased()

        // Folders commonly named after either the app or its bundle ID.
        let byName: [(String, String)] = [("Application Support", "Application Support"),
                                          ("Caches", "Caches"),
                                          ("Logs", "Logs")]
        for (dir, kind) in byName {
            let parent = lib.appendingPathComponent(dir)
            guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { continue }
            for child in children {
                let childName = child.lastPathComponent
                let matchesName = childName.lowercased() == nameLower
                let matchesBundle = bundleID.map { childName == $0 || childName.hasPrefix($0 + ".") } ?? false
                if matchesName || matchesBundle {
                    add(child, kind)
                }
            }
        }

        if let bundleID {
            add(lib.appendingPathComponent("Preferences/\(bundleID).plist"), "Preferences")
            add(lib.appendingPathComponent("Saved Application State/\(bundleID).savedState"), "Saved State")
            add(lib.appendingPathComponent("Containers/\(bundleID)"), "Container")
            add(lib.appendingPathComponent("WebKit/\(bundleID)"), "WebKit Data")
            add(lib.appendingPathComponent("HTTPStorages/\(bundleID)"), "HTTP Storage")
            add(lib.appendingPathComponent("Cookies/\(bundleID).binarycookies"), "Cookies")

            // Preference variants like com.example.app.helper.plist
            if let prefs = try? fm.contentsOfDirectory(at: lib.appendingPathComponent("Preferences"),
                                                       includingPropertiesForKeys: nil) {
                for pref in prefs where pref.lastPathComponent.hasPrefix(bundleID + ".") {
                    add(pref, "Preferences")
                }
            }
            // Group containers are usually "<team-id>.<bundle-id-ish>".
            if let groups = try? fm.contentsOfDirectory(at: lib.appendingPathComponent("Group Containers"),
                                                        includingPropertiesForKeys: nil) {
                for group in groups where group.lastPathComponent.contains(bundleID) {
                    add(group, "Group Container")
                }
            }
            // Launch agents installed by the app.
            if let agents = try? fm.contentsOfDirectory(at: lib.appendingPathComponent("LaunchAgents"),
                                                        includingPropertiesForKeys: nil) {
                for agent in agents where agent.lastPathComponent.contains(bundleID) {
                    add(agent, "Launch Agent")
                }
            }
        }

        return results.sorted { $0.size > $1.size }
    }
}

// MARK: - Views

struct UninstallerView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = app.uninstaller
        NavigationStack {
            Group {
                if model.isScanning {
                    VStack {
                        Spacer()
                        ProgressView("Measuring apps… \(model.measuredCount) of \(model.totalCount)")
                        Spacer()
                    }
                } else if model.apps.isEmpty {
                    ContentUnavailableView("Uninstall apps completely",
                                           systemImage: "app.dashed",
                                           description: Text("Lists your applications with their true size and last-used date, then hunts down the support files, caches and preferences they leave behind."))
                } else {
                    List(model.filteredApps) { info in
                        NavigationLink(value: info) {
                            AppRow(info: info)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Uninstaller")
            .searchable(text: $model.search, prompt: "Filter apps")
            .navigationDestination(for: AppInfo.self) { info in
                AppUninstallDetail(info: info)
            }
            .toolbar {
                Button {
                    Task { await model.scan() }
                } label: {
                    Label(model.hasScanned ? "Rescan" : "Scan Apps", systemImage: "magnifyingglass")
                }
                .disabled(model.isScanning)
            }
            .task {
                if !model.hasScanned { await model.scan() }
            }
        }
    }
}

struct AppRow: View {
    let info: AppInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: info.url.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                Text(info.lastUsed.map { "Last used \(relativeDate($0))" } ?? "Never opened (per Spotlight)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatBytes(info.size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct AppUninstallDetail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var state: LeftoverState
    @State private var confirmUninstall = false

    init(info: AppInfo) {
        _state = State(initialValue: LeftoverState(app: info))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.isScanning {
                Spacer()
                ProgressView("Hunting for leftovers…")
                Spacer()
            } else {
                leftoverList
            }
        }
        .navigationTitle(state.app.name)
        .toolbar {
            Button(role: .destructive) {
                confirmUninstall = true
            } label: {
                Label("Uninstall (\(formatBytes(state.selectedSize)))", systemImage: "trash")
            }
            .disabled(state.isScanning || (!state.includeApp && state.selected.isEmpty))
        }
        .task { await state.scan() }
        .confirmationDialog(
            "Uninstall \(state.app.name)?",
            isPresented: $confirmUninstall
        ) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    let appRemoved = await state.uninstall()
                    if appRemoved {
                        app.uninstaller.remove(state.app)
                        dismiss()
                    }
                }
            }
        } message: {
            Text(state.includeApp
                 ? "The app and \(state.selected.count) related item\(state.selected.count == 1 ? "" : "s") are moved to the Trash (\(formatBytes(state.selectedSize)))."
                 : "\(state.selected.count) related item\(state.selected.count == 1 ? "" : "s") are moved to the Trash — the app itself is kept.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: state.app.url.path))
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Toggle(isOn: Bindable(state).includeApp) {
                    Text("\(state.app.name).app — \(formatBytes(state.app.size))")
                        .fontWeight(.medium)
                }
                .toggleStyle(.checkbox)
                Text(state.app.bundleID ?? state.app.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.isAppRunning {
                    Label("This app is currently running — quit it before uninstalling.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let message = state.resultMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
        }
        .padding(14)
    }

    private var leftoverList: some View {
        List {
            Section(state.items.isEmpty
                    ? "No leftover files found outside the app bundle"
                    : "Leftovers (\(state.items.count))") {
                ForEach(state.items) { item in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { state.selected.contains(item.url) },
                            set: { on in
                                if on { state.selected.insert(item.url) } else { state.selected.remove(item.url) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.url.lastPathComponent).lineLimit(1)
                            Text(item.url.deletingLastPathComponent().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(item.kind)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Text(formatBytes(item.size))
                            .font(.callout.monospacedDigit())
                            .frame(width: 80, alignment: .trailing)
                    }
                    .contextMenu {
                        Button("Reveal in Finder") { revealInFinder(item.url) }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
