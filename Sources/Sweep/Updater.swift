import AppKit

enum Updater {
    /// "owner/repo" on GitHub. Empty disables update checks entirely.
    static let repo = "shad0hrealm/sweep"

    static let checkKey = "updateCheckEnabled"
    static let autoInstallKey = "autoInstallUpdates"

    struct Release: Sendable {
        let version: String
        let zipURL: URL
        let pageURL: URL
    }

    enum UpdateError: LocalizedError {
        case downloadFailed, badArchive

        var errorDescription: String? {
            switch self {
            case .downloadFailed: "The update download failed. Check your network connection."
            case .badArchive: "The downloaded update didn't contain a valid Sweep.app."
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Reads a defaults flag that should DEFAULT TO TRUE when never set —
    /// mirrors the @AppStorage defaults used in Settings.
    static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Synchronous (usable from the headless scan); call via Task.detached from the GUI.
    static func fetchLatest() -> Release? {
        guard !repo.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let semaphore = DispatchSemaphore(value: 0)
        var result: Release?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zip = assets.compactMap { asset -> URL? in
                guard let name = asset["name"] as? String, name.hasSuffix(".zip"),
                      let download = asset["browser_download_url"] as? String else { return nil }
                return URL(string: download)
            }.first
            if let zip {
                result = Release(version: version, zipURL: zip, pageURL: page)
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return result
    }

    /// Downloads the release and swaps the current app bundle in place.
    /// The old version goes to the Trash. Returns the updated app's URL.
    static func install(_ release: Release) throws -> URL {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        let workDir = fm.temporaryDirectory.appendingPathComponent("sweep-update-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // Download the zip.
        let zipPath = workDir.appendingPathComponent("update.zip")
        let semaphore = DispatchSemaphore(value: 0)
        var downloaded = false
        URLSession.shared.downloadTask(with: release.zipURL) { location, _, _ in
            defer { semaphore.signal() }
            if let location, (try? fm.moveItem(at: location, to: zipPath)) != nil {
                downloaded = true
            }
        }.resume()
        _ = semaphore.wait(timeout: .now() + 180)
        guard downloaded else { throw UpdateError.downloadFailed }

        // Unpack with ditto (preserves signatures and extended attributes).
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", zipPath.path, workDir.path]
        try unzip.run()
        unzip.waitUntilExit()

        let newApp = workDir.appendingPathComponent("Sweep.app")
        guard unzip.terminationStatus == 0,
              fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/Sweep").path) else {
            throw UpdateError.badArchive
        }

        // Swap: old version to the Trash, new version into place.
        try? fm.trashItem(at: appURL, resultingItemURL: nil)
        if fm.fileExists(atPath: appURL.path) {
            try fm.removeItem(at: appURL)
        }
        try fm.moveItem(at: newApp, to: appURL)
        return appURL
    }

    /// GUI path: install, then relaunch the new copy and quit this one.
    @MainActor
    static func installAndRelaunch(_ release: Release) throws {
        let updated = try install(release)
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"\(updated.path)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
