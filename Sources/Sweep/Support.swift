import Foundation
import AppKit

// MARK: - Shell

enum Shell {
    /// Runs a command and returns combined stdout+stderr. Never throws; returns "" on failure.
    @discardableResult
    static func run(_ path: String, _ args: [String] = []) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Sizes

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// Allocated size of a file, or the recursive total for a directory.
func allocatedSize(of url: URL) -> Int64 {
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
       values.isRegularFile == true {
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                         options: [], errorHandler: { _, _ in true }) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
        total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
    return total
}

// MARK: - Finder helpers

@MainActor
func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

func relativeDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
