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
    enum Domain: Sendable { case user, system }

    var id: URL { url }
    let url: URL
    let size: Int64
    let kind: String
    var domain: Domain = .user
    var note: String? = nil
    var defaultSelected: Bool = true
}

struct ReceiptInfo: Identifiable, Hashable, Sendable {
    var id: String { pkgID }
    let pkgID: String
    let location: String
    let existingPaths: [String]
}

/// "com.google.Chrome" → "com.google"; "au.com.thehartmanns.sweep" → "au.com.thehartmanns".
/// Returns nil for Apple identifiers and non-reverse-domain names.
func vendorPrefix(of bundleID: String) -> String? {
    let parts = bundleID.lowercased().split(separator: ".")
    guard parts.count >= 3 else { return nil }
    var count = 2
    // ccTLD second-level domains: au.com.vendor.app → vendor is three components.
    if parts[0].count == 2, ["com", "net", "org", "edu", "gov", "co", "ac"].contains(String(parts[1])), parts.count >= 4 {
        count = 3
    }
    let vendor = parts.prefix(count).joined(separator: ".")
    return vendor == "com.apple" ? nil : vendor
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

    nonisolated static func appBundles() -> [URL] {
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

    /// App list without size measurement — for collision checks and the debug CLI.
    nonisolated static func quickAppList() -> [AppInfo] {
        appBundles().map { url in
            AppInfo(url: url, name: url.deletingPathExtension().lastPathComponent,
                    bundleID: Bundle(url: url)?.bundleIdentifier, size: 0, lastUsed: nil)
        }
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
    var receipts: [ReceiptInfo] = []
    var selected: Set<URL> = []
    var includeApp = true
    var isScanning = false
    var hasScanned = false
    var resultMessage: String?
    private var installedAppsCache: [AppInfo] = []

    init(app: AppInfo) {
        self.app = app
    }

    var isAppRunning: Bool {
        guard let bundleID = app.bundleID else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    var userItems: [LeftoverItem] { items.filter { $0.domain == .user } }
    var systemItems: [LeftoverItem] { items.filter { $0.domain == .system } }

    var selectedSize: Int64 {
        userItems.filter { selected.contains($0.url) }.reduce(includeApp ? app.size : 0) { $0 + $1.size }
    }

    var selectedCount: Int {
        userItems.filter { selected.contains($0.url) }.count
    }

    func scan(installedApps: [AppInfo]) async {
        guard !isScanning else { return }
        isScanning = true
        installedAppsCache = installedApps
        let app = self.app

        async let foundItems = Task.detached(priority: .userInitiated) {
            Self.findLeftovers(for: app, installedApps: installedApps)
        }.value
        async let foundReceipts = Task.detached(priority: .userInitiated) {
            Self.findReceipts(for: app)
        }.value

        items = await foundItems
        receipts = await foundReceipts
        selected = Set(items.filter { $0.domain == .user && $0.defaultSelected }.map(\.url))
        hasScanned = true
        isScanning = false
    }

    /// Trashes the selected user-domain leftovers (and the app bundle if included).
    /// System-domain items are never touched. Returns true if the app bundle was removed.
    func uninstall() async -> Bool {
        let targets = userItems.filter { selected.contains($0.url) }
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
            await scan(installedApps: installedAppsCache)
        }
        return outcome.appRemoved
    }

    // MARK: Discovery

    nonisolated static func findLeftovers(for app: AppInfo, installedApps: [AppInfo]) -> [LeftoverItem] {
        let fm = FileManager.default
        let userLib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var results: [LeftoverItem] = []
        var seen = Set<URL>()

        let bundleID = app.bundleID
        let bundleLower = bundleID?.lowercased()
        let nameLower = app.name.lowercased()
        let vendor = bundleID.flatMap { vendorPrefix(of: $0) }
        let vendorFolder = vendor?.split(separator: ".").last.map(String.init)

        // Other installed apps from the same vendor — the collision guard.
        let vendorSiblings: [String] = vendor.map { v in
            installedApps
                .filter { $0.url != app.url && $0.bundleID.flatMap(vendorPrefix(of:)) == v }
                .map(\.name)
                .sorted()
        } ?? []

        let vendorNote: String?
        let vendorSelected: Bool
        if vendorSiblings.isEmpty {
            vendorNote = "Vendor files — matched by publisher, not app name"
            vendorSelected = true
        } else {
            vendorNote = "Shared with \(vendorSiblings.joined(separator: ", ")) — removing this affects those apps too"
            vendorSelected = false
        }

        func add(_ url: URL, _ kind: String, domain: LeftoverItem.Domain = .user,
                 note: String? = nil, defaultSelected: Bool = true) {
            guard !seen.contains(url), fm.fileExists(atPath: url.path) else { return }
            seen.insert(url)
            results.append(LeftoverItem(url: url, size: allocatedSize(of: url), kind: kind,
                                        domain: domain, note: note,
                                        defaultSelected: domain == .user && defaultSelected))
        }

        func isDirectMatch(_ childName: String) -> Bool {
            let lower = childName.lowercased()
            if lower == nameLower { return true }
            if let bundleLower {
                return lower == bundleLower || lower.hasPrefix(bundleLower + ".")
            }
            return false
        }

        func isVendorMatch(_ childName: String) -> Bool {
            let lower = childName.lowercased()
            if let vendorFolder, lower == vendorFolder { return true }
            if let vendor, lower.hasPrefix(vendor + ".") { return true }
            return false
        }

        // Folders commonly named after the app, its bundle ID, or its vendor.
        for (dir, kind) in [("Application Support", "Application Support"),
                            ("Caches", "Caches"),
                            ("Logs", "Logs")] {
            let parent = userLib.appendingPathComponent(dir)
            guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { continue }
            for child in children {
                if isDirectMatch(child.lastPathComponent) {
                    add(child, kind)
                } else if isVendorMatch(child.lastPathComponent) {
                    add(child, kind, note: vendorNote, defaultSelected: vendorSelected)
                }
            }
        }

        if let bundleID {
            add(userLib.appendingPathComponent("Preferences/\(bundleID).plist"), "Preferences")
            add(userLib.appendingPathComponent("Saved Application State/\(bundleID).savedState"), "Saved State")
            add(userLib.appendingPathComponent("Containers/\(bundleID)"), "Container")
            add(userLib.appendingPathComponent("WebKit/\(bundleID)"), "WebKit Data")
            add(userLib.appendingPathComponent("HTTPStorages/\(bundleID)"), "HTTP Storage")
            add(userLib.appendingPathComponent("Cookies/\(bundleID).binarycookies"), "Cookies")

            // Bundle-ID-prefixed and vendor-prefixed items across the ID-keyed folders.
            for (dir, kind) in [("Preferences", "Preferences"),
                                ("Saved Application State", "Saved State"),
                                ("Containers", "Container"),
                                ("WebKit", "WebKit Data"),
                                ("HTTPStorages", "HTTP Storage"),
                                ("Cookies", "Cookies"),
                                ("LaunchAgents", "Launch Agent")] {
                let parent = userLib.appendingPathComponent(dir)
                guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { continue }
                for child in children {
                    if isDirectMatch(child.lastPathComponent) || child.lastPathComponent.contains(bundleID) {
                        add(child, kind)
                    } else if isVendorMatch(child.lastPathComponent) {
                        add(child, kind, note: vendorNote, defaultSelected: vendorSelected)
                    }
                }
            }

            // Group containers are usually "<team-id>.<bundle-id-ish>".
            if let groups = try? fm.contentsOfDirectory(at: userLib.appendingPathComponent("Group Containers"),
                                                        includingPropertiesForKeys: nil) {
                for group in groups where group.lastPathComponent.contains(bundleID) {
                    add(group, "Group Container")
                }
            }
        }

        // System domain — surfaced for transparency, strictly reveal-only.
        let systemChecks: [(String, String)] = [("/Library/Application Support", "Application Support"),
                                                ("/Library/Caches", "Caches"),
                                                ("/Library/Preferences", "Preferences"),
                                                ("/Library/LaunchAgents", "Launch Agent"),
                                                ("/Library/LaunchDaemons", "Launch Daemon"),
                                                ("/Library/PrivilegedHelperTools", "Privileged Helper")]
        for (dir, kind) in systemChecks {
            let parent = URL(fileURLWithPath: dir)
            guard let children = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) else { continue }
            for child in children {
                let childName = child.lastPathComponent
                let matches = isDirectMatch(childName)
                    || isVendorMatch(childName)
                    || (bundleID.map { childName.contains($0) } ?? false)
                if matches {
                    add(child, kind, domain: .system, defaultSelected: false)
                }
            }
        }

        return results.sorted {
            if $0.domain != $1.domain { return $0.domain == .user }
            return $0.size > $1.size
        }
    }

    nonisolated static func findReceipts(for app: AppInfo) -> [ReceiptInfo] {
        guard let bundleLower = app.bundleID?.lowercased() else { return [] }
        let vendor = vendorPrefix(of: bundleLower)
        let allPkgs = Shell.run("/usr/sbin/pkgutil", ["--pkgs"])
            .split(separator: "\n").map(String.init)

        // For vendor-prefixed receipts, require the app's name to appear too —
        // otherwise OneDrive would claim every com.microsoft.* package on the system.
        var nameTokens = Set(app.name.lowercased().split(separator: " ").map(String.init))
        if let last = bundleLower.split(separator: ".").last { nameTokens.insert(String(last)) }
        nameTokens = nameTokens.filter { $0.count >= 3 && !(vendor ?? "").contains($0) }

        let matches = allPkgs.filter { pkg in
            let lower = pkg.lowercased()
            if lower.hasPrefix("com.apple.") { return false }
            if lower == bundleLower || lower.hasPrefix(bundleLower + ".") { return true }
            if let vendor, lower.hasPrefix(vendor + "."), nameTokens.contains(where: { lower.contains($0) }) { return true }
            return false
        }.prefix(12)

        var result: [ReceiptInfo] = []
        for pkg in matches {
            var volume = "/"
            var location = ""
            let infoOutput = Shell.run("/usr/sbin/pkgutil", ["--pkg-info-plist", pkg])
            if let data = infoOutput.data(using: .utf8),
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                volume = dict["volume"] as? String ?? "/"
                location = dict["install-location"] as? String ?? ""
            }
            let base = (volume as NSString).appendingPathComponent(location)

            var tops = Set<String>()
            let files = Shell.run("/usr/sbin/pkgutil", ["--files", pkg, "--only-dirs"])
            for line in files.split(separator: "\n") {
                if let first = line.split(separator: "/").first {
                    tops.insert(String(first))
                }
            }
            let paths = tops
                .map { (base as NSString).appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0) }
                .sorted()
            result.append(ReceiptInfo(pkgID: pkg, location: base, existingPaths: paths))
        }
        return result.sorted { $0.pkgID < $1.pkgID }
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
            .navigationDestination(for: String.self) { _ in
                OrphansView()
            }
            .toolbar {
                NavigationLink(value: "orphans") {
                    Label("Orphaned Leftovers", systemImage: "questionmark.folder")
                }
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
            .disabled(state.isScanning || (!state.includeApp && state.selectedCount == 0))
        }
        .task { await state.scan(installedApps: app.uninstaller.apps) }
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
                 ? "The app and \(state.selectedCount) related item\(state.selectedCount == 1 ? "" : "s") are moved to the Trash (\(formatBytes(state.selectedSize)))."
                 : "\(state.selectedCount) related item\(state.selectedCount == 1 ? "" : "s") are moved to the Trash — the app itself is kept.")
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
            Section(state.userItems.isEmpty
                    ? "No leftover files found in your user library"
                    : "Leftovers (\(state.userItems.count))") {
                ForEach(state.userItems) { item in
                    LeftoverRow(item: item, isSelected: Binding(
                        get: { state.selected.contains(item.url) },
                        set: { on in
                            if on { state.selected.insert(item.url) } else { state.selected.remove(item.url) }
                        }
                    ))
                }
            }

            if !state.systemItems.isEmpty {
                Section {
                    ForEach(state.systemItems) { item in
                        LeftoverRow(item: item, isSelected: nil)
                    }
                } header: {
                    Text("System files — reveal only (\(state.systemItems.count))")
                } footer: {
                    Text("These live outside your user folder and need administrator rights to remove. Sweep never deletes them — use Reveal and remove them in Finder, which will ask for your password.")
                }
            }

            if !state.receipts.isEmpty {
                Section {
                    ForEach(state.receipts) { receipt in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(receipt.pkgID)
                                .fontWeight(.medium)
                            ForEach(receipt.existingPaths, id: \.self) { path in
                                HStack {
                                    Text(path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("Reveal") { revealInFinder(URL(fileURLWithPath: path)) }
                                        .buttonStyle(.link)
                                        .font(.caption)
                                }
                            }
                            if receipt.existingPaths.isEmpty {
                                Text("No files from this package remain on disk.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } header: {
                    Text("Installer package receipts (\(state.receipts.count))")
                } footer: {
                    Text("macOS recorded these locations when the app's installer package ran. Reveal-only — useful for spotting files outside the usual folders.")
                }
            }
        }
        .listStyle(.inset)
    }
}

struct LeftoverRow: View {
    let item: LeftoverItem
    /// nil = reveal-only (system domain), no checkbox.
    let isSelected: Binding<Bool>?

    var body: some View {
        HStack(spacing: 10) {
            if let isSelected {
                Toggle("", isOn: isSelected)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            } else {
                Image(systemName: "lock")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let note = item.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(item.defaultSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
            }
            Spacer()
            Text(item.kind)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            if isSelected == nil {
                Button("Reveal") { revealInFinder(item.url) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Text(formatBytes(item.size))
                .font(.callout.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
        }
        .contextMenu {
            Button("Reveal in Finder") { revealInFinder(item.url) }
        }
    }
}
