import SwiftUI
import Observation

// MARK: - Model

struct LargeFile: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let accessed: Date?
    var name: String { url.lastPathComponent }
}

@MainActor
@Observable
final class LargeFilesModel {
    var root: URL = FileManager.default.homeDirectoryForCurrentUser
    var minSize: Int64 = 250 * 1_000_000
    var includeHidden = false
    var results: [LargeFile] = []
    var selected: Set<URL> = []
    var isScanning = false
    var hasScanned = false
    var scannedCount = 0
    var lastMessage: String?
    var sortByAge = false

    static let sizeOptions: [(String, Int64)] = [
        ("50 MB", 50 * 1_000_000),
        ("100 MB", 100 * 1_000_000),
        ("250 MB", 250 * 1_000_000),
        ("1 GB", 1_000_000_000),
        ("5 GB", 5_000_000_000),
    ]

    var sortedResults: [LargeFile] {
        if sortByAge {
            return results.sorted { ($0.accessed ?? .distantPast) < ($1.accessed ?? .distantPast) }
        }
        return results
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastMessage = nil
        scannedCount = 0
        let root = self.root
        let minSize = self.minSize
        let includeHidden = self.includeHidden
        let progress: @Sendable (Int) -> Void = { count in
            _ = Task { @MainActor [weak self] in self?.scannedCount = count }
        }

        let found = await Task.detached(priority: .userInitiated) {
            Self.walk(root: root, minSize: minSize, includeHidden: includeHidden, progress: progress)
        }.value

        results = found
        selected.removeAll()
        hasScanned = true
        isScanning = false
    }

    /// Synchronous walk, run off the main actor. Kept out of async context because
    /// FileManager's enumerator can't be iterated there.
    nonisolated private static func walk(root: URL, minSize: Int64, includeHidden: Bool,
                                         progress: @Sendable @escaping (Int) -> Void) -> [LargeFile] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey,
                                         .fileAllocatedSizeKey, .contentAccessDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }

        // Skip the user Library (surfaced by Cleanup instead) and the Trash.
        let skippedDirs = [home.appendingPathComponent("Library").path,
                           home.appendingPathComponent(".Trash").path]

        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                             options: options, errorHandler: { _, _ in true }) else { return [] }
        var found: [LargeFile] = []
        var count = 0
        for case let url as URL in enumerator {
            if skippedDirs.contains(url.path) {
                enumerator.skipDescendants()
                continue
            }
            count += 1
            if count % 5000 == 0 { progress(count) }
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if size >= minSize {
                found.append(LargeFile(url: url, size: size, accessed: values.contentAccessDate))
            }
        }
        progress(count)
        return Array(found.sorted { $0.size > $1.size }.prefix(1000))
    }

    func trashSelected() async {
        let targets = results.filter { selected.contains($0.url) }
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

        lastMessage = "Moved \(outcome.0) file\(outcome.0 == 1 ? "" : "s") to Trash (\(formatBytes(outcome.1)))"
            + (outcome.2 > 0 ? " — \(outcome.2) failed" : "")
        if outcome.0 > 0 {
            EventStore.append(.info, "Trashed \(outcome.0) large file\(outcome.0 == 1 ? "" : "s") — \(formatBytes(outcome.1)) freed")
        }
        let removedURLs = Set(targets.map(\.url))
        results.removeAll { removedURLs.contains($0.url) && !FileManager.default.fileExists(atPath: $0.url.path) }
        selected.removeAll()
    }
}

// MARK: - View

struct LargeFilesView: View {
    @Environment(AppModel.self) private var app
    @State private var showFolderPicker = false
    @State private var confirmTrash = false

    var body: some View {
        @Bindable var model = app.largeFiles
        VStack(spacing: 0) {
            controlBar
            Divider()
            if model.isScanning {
                Spacer()
                ProgressView("Scanning… \(model.scannedCount.formatted()) files examined")
                Spacer()
            } else if model.results.isEmpty {
                ContentUnavailableView(
                    model.hasScanned ? "No files over the size threshold" : "Find large & old files",
                    systemImage: "doc.badge.clock",
                    description: Text(model.hasScanned
                        ? "Try lowering the minimum size or choosing another folder."
                        : "Scans \(model.root.path) for files above the size threshold, with when they were last opened.")
                )
            } else {
                resultsList
            }
        }
        .navigationTitle("Large & Old Files")
        .toolbar {
            if !model.selected.isEmpty {
                Button(role: .destructive) {
                    confirmTrash = true
                } label: {
                    Label("Move \(model.selected.count) to Trash", systemImage: "trash")
                }
            }
            Button {
                Task { await model.scan() }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .disabled(model.isScanning)
        }
        .confirmationDialog(
            "Move \(model.selected.count) file\(model.selected.count == 1 ? "" : "s") to the Trash?",
            isPresented: $confirmTrash
        ) {
            Button("Move to Trash", role: .destructive) {
                Task { await model.trashSelected() }
            }
        } message: {
            Text("Frees \(formatBytes(model.results.filter { model.selected.contains($0.url) }.reduce(0) { $0 + $1.size })). You can restore files from the Trash.")
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.root = url
                model.hasScanned = false
                model.results = []
            }
        }
    }

    private var controlBar: some View {
        @Bindable var model = app.largeFiles
        return HStack(spacing: 16) {
            Button {
                showFolderPicker = true
            } label: {
                Label(model.root.lastPathComponent, systemImage: "folder")
            }
            .help(model.root.path)

            Picker("Larger than", selection: $model.minSize) {
                ForEach(LargeFilesModel.sizeOptions, id: \.1) { option in
                    Text(option.0).tag(option.1)
                }
            }
            .fixedSize()

            Toggle("Hidden files", isOn: $model.includeHidden)

            Picker("Sort", selection: $model.sortByAge) {
                Text("Largest").tag(false)
                Text("Least recently opened").tag(true)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()

            if let message = model.lastMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var resultsList: some View {
        @Bindable var model = app.largeFiles
        return List {
            ForEach(model.sortedResults) { file in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { model.selected.contains(file.url) },
                        set: { on in
                            if on { model.selected.insert(file.url) } else { model.selected.remove(file.url) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).lineLimit(1)
                        Text(file.url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Opened \(relativeDate(file.accessed))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(formatBytes(file.size))
                        .font(.callout.monospacedDigit())
                        .frame(width: 90, alignment: .trailing)
                }
                .contextMenu {
                    Button("Reveal in Finder") { revealInFinder(file.url) }
                }
            }
        }
        .listStyle(.inset)
    }
}
