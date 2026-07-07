import AppKit

/// Headless verification of the discovery logic, without driving the UI.
/// Never deletes anything — prints what the GUI would show.
enum DebugCLI {
    static func leftovers(appPath: String) {
        let url = URL(fileURLWithPath: appPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("No app at \(appPath)")
            return
        }
        let info = AppInfo(url: url,
                           name: url.deletingPathExtension().lastPathComponent,
                           bundleID: Bundle(url: url)?.bundleIdentifier,
                           size: 0, lastUsed: nil)
        let installed = UninstallerModel.quickAppList()
        print("app: \(info.name)  bundle: \(info.bundleID ?? "?")")
        print("vendor: \(info.bundleID.flatMap(vendorPrefix(of:)) ?? "-")")

        let items = LeftoverState.findLeftovers(for: info, installedApps: installed)
        for item in items {
            let domain = item.domain == .user ? "user  " : "SYSTEM"
            let sel = item.domain == .system ? "reveal-only" : (item.defaultSelected ? "selected" : "UNSELECTED")
            print("[\(domain)] [\(sel)] \(item.kind): \(item.url.path) (\(formatBytes(item.size)))"
                  + (item.note.map { "\n           note: \($0)" } ?? ""))
        }

        let receipts = LeftoverState.findReceipts(for: info)
        for receipt in receipts {
            print("[receipt] \(receipt.pkgID) → \(receipt.location)")
            for path in receipt.existingPaths {
                print("           \(path)")
            }
        }
        print("\(items.count) items, \(receipts.count) receipts")
    }

    static func orphans() {
        let installed = UninstallerModel.quickAppList()
        var ids = Set(installed.compactMap { $0.bundleID?.lowercased() })
        for running in NSWorkspace.shared.runningApplications {
            if let id = running.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        let groups = OrphansModel.findOrphans(installedIDs: ids)
        for group in groups {
            print("\(group.bundleID) (\(formatBytes(group.totalSize)))")
            for item in group.items {
                print("    \(item.kind): \(item.url.path) (\(formatBytes(item.size)))")
            }
        }
        print("\(groups.count) orphan groups, \(formatBytes(groups.reduce(0) { $0 + $1.totalSize })) total")
    }
}
