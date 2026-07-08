import Foundation
import Observation

// MARK: - Model types

struct CleanupItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let modified: Date?
    var name: String { url.lastPathComponent }
}

struct CategorySpec: Identifiable, Sendable {
    enum Deletion: Sendable { case trash, permanent }

    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let deletion: Deletion
    /// Immediate children of these directories become individual items.
    let roots: [URL]
    /// These paths become single items (cleaned wholesale).
    let wholeItems: [URL]
    /// Child names to never list (protected caches, etc.).
    let exclude: Set<String>
    /// Show modification dates in the item list.
    let showsDates: Bool
    let includeHidden: Bool

    static func all() -> [CategorySpec] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let lib = home.appendingPathComponent("Library")

        func existing(_ urls: [URL]) -> [URL] {
            urls.filter { fm.fileExists(atPath: $0.path) }
        }

        return [
            CategorySpec(
                id: "caches",
                title: "User Caches",
                subtitle: "App caches that are rebuilt automatically as needed",
                icon: "internaldrive",
                deletion: .trash,
                roots: existing([lib.appendingPathComponent("Caches")]),
                wholeItems: [],
                exclude: ["com.apple.bird", "CloudKit", "com.apple.CloudKit",
                          "FamilyCircle", "com.apple.HomeKit", "Homebrew"],
                showsDates: false,
                includeHidden: false
            ),
            CategorySpec(
                id: "logs",
                title: "Logs & Diagnostics",
                subtitle: "Application logs and diagnostic reports",
                icon: "doc.text.magnifyingglass",
                deletion: .trash,
                roots: existing([lib.appendingPathComponent("Logs")]),
                wholeItems: [],
                exclude: [],
                showsDates: true,
                includeHidden: false
            ),
            CategorySpec(
                id: "trash",
                title: "Trash",
                subtitle: "Items already in the Trash — cleaning here deletes them permanently",
                icon: "trash",
                deletion: .permanent,
                roots: existing([home.appendingPathComponent(".Trash")]),
                wholeItems: [],
                exclude: [],
                showsDates: true,
                includeHidden: true
            ),
            CategorySpec(
                id: "dev",
                title: "Developer Junk",
                subtitle: "Xcode derived data, simulator caches, package-manager caches",
                icon: "hammer",
                deletion: .trash,
                roots: existing([
                    lib.appendingPathComponent("Developer/Xcode/DerivedData"),
                    lib.appendingPathComponent("Developer/Xcode/iOS DeviceSupport"),
                ]),
                wholeItems: existing([
                    lib.appendingPathComponent("Developer/CoreSimulator/Caches"),
                    lib.appendingPathComponent("Caches/Homebrew"),
                    home.appendingPathComponent(".npm/_cacache"),
                    lib.appendingPathComponent("pnpm/store"),
                    lib.appendingPathComponent("Caches/go-build"),
                ]),
                exclude: [],
                showsDates: true,
                includeHidden: false
            ),
            CategorySpec(
                id: "downloads",
                title: "Downloads",
                subtitle: "Everything in your Downloads folder, largest first — review before cleaning",
                icon: "arrow.down.circle",
                deletion: .trash,
                roots: existing([home.appendingPathComponent("Downloads")]),
                wholeItems: [],
                exclude: [],
                showsDates: true,
                includeHidden: false
            ),
        ].filter { !$0.roots.isEmpty || !$0.wholeItems.isEmpty }
    }
}

// MARK: - Per-category state

@MainActor
@Observable
final class CleanupCategoryState: Identifiable {
    let spec: CategorySpec
    var items: [CleanupItem] = []
    var selected: Set<URL> = []
    var isScanning = false
    var isCleaning = false
    var hasScanned = false
    var lastMessage: String?

    nonisolated var id: String { spec.id }

    init(spec: CategorySpec) {
        self.spec = spec
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastMessage = nil
        let spec = self.spec

        let found = await Task.detached(priority: .userInitiated) { () -> [CleanupItem] in
            let fm = FileManager.default
            var result: [CleanupItem] = []
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            let options: FileManager.DirectoryEnumerationOptions = spec.includeHidden ? [] : [.skipsHiddenFiles]

            for root in spec.roots {
                guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: options) else { continue }
                for child in children where !spec.exclude.contains(child.lastPathComponent) {
                    let modified = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    result.append(CleanupItem(url: child, size: allocatedSize(of: child), modified: modified))
                }
            }
            for whole in spec.wholeItems {
                let modified = (try? whole.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                result.append(CleanupItem(url: whole, size: allocatedSize(of: whole), modified: modified))
            }
            return result.sorted { $0.size > $1.size }
        }.value

        items = found
        selected.formIntersection(Set(found.map(\.url)))
        hasScanned = true
        isScanning = false
    }

    /// Removes the selected items. Returns bytes reclaimed.
    func cleanSelected() async {
        guard !isCleaning, !selected.isEmpty else { return }
        isCleaning = true
        let targets = items.filter { selected.contains($0.url) }
        let permanent = spec.deletion == .permanent

        let outcome = await Task.detached(priority: .userInitiated) { () -> (removed: Int, bytes: Int64, failures: Int) in
            let fm = FileManager.default
            var removed = 0
            var bytes: Int64 = 0
            var failures = 0
            for item in targets {
                do {
                    if permanent {
                        try fm.removeItem(at: item.url)
                    } else {
                        try fm.trashItem(at: item.url, resultingItemURL: nil)
                    }
                    removed += 1
                    bytes += item.size
                } catch {
                    failures += 1
                }
            }
            return (removed, bytes, failures)
        }.value

        selected.removeAll()
        isCleaning = false
        var message = permanent
            ? "Deleted \(outcome.removed) item\(outcome.removed == 1 ? "" : "s") (\(formatBytes(outcome.bytes)))"
            : "Moved \(outcome.removed) item\(outcome.removed == 1 ? "" : "s") to Trash (\(formatBytes(outcome.bytes)))"
        if outcome.failures > 0 {
            message += " — \(outcome.failures) could not be removed (in use or permission denied)"
        }
        lastMessage = message
        if outcome.removed > 0 {
            EventStore.append(.info, "Cleaned \(spec.title) — \(formatBytes(outcome.bytes)) freed",
                              detail: permanent ? "Deleted permanently from the Trash." : "Items moved to the Trash.")
        }
        await scan()
    }
}
