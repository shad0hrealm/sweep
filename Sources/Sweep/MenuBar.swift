import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BackgroundScan.dateKey) private var lastScanDate = 0.0
    @AppStorage(BackgroundScan.bytesKey) private var lastScanBytes = 0

    private var junkCategories: [CleanupCategoryState] {
        app.cleanup.filter { $0.spec.id != "downloads" }
    }

    private var junkScanned: Bool { junkCategories.contains(where: \.hasScanned) }
    private var junkScanning: Bool { junkCategories.contains(where: \.isScanning) }
    private var junkTotal: Int64 { junkCategories.filter(\.hasScanned).reduce(0) { $0 + $1.totalSize } }

    var body: some View {
        let stats = app.stats
        VStack(alignment: .leading, spacing: 10) {
            Text("Sweep")
                .font(.headline)

            statRow(icon: "internaldrive", label: "Disk",
                    value: "\(formatBytes(stats.disk.free)) free",
                    fraction: stats.disk.total > 0 ? Double(stats.disk.used) / Double(stats.disk.total) : 0)
            statRow(icon: "memorychip", label: "Memory",
                    value: "\(formatBytes(stats.memory.used)) used",
                    fraction: stats.memory.total > 0 ? Double(stats.memory.used) / Double(stats.memory.total) : 0)

            Divider()

            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)
                if junkScanning {
                    Text("Scanning for junk…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView().controlSize(.small)
                } else if junkScanned {
                    Text("\(formatBytes(junkTotal)) of junk")
                    Spacer()
                    Button("Review") {
                        app.section = .cleanup
                        openMainWindow()
                    }
                    .controlSize(.small)
                } else {
                    Text("Junk not scanned yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan Now") {
                        Task {
                            await withTaskGroup(of: Void.self) { group in
                                for category in junkCategories {
                                    group.addTask { @MainActor in await category.scan() }
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }

            if lastScanDate > 0 {
                Text("Scheduled scan \(relativeDate(Date(timeIntervalSince1970: lastScanDate))): \(formatBytes(Int64(lastScanBytes)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let latest = app.events.events.first(where: { $0.severity != .info }) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: latest.severity == .warning ? "exclamationmark.triangle.fill" : "sparkles")
                        .foregroundStyle(latest.severity == .warning ? Color.orange : Color.accentColor)
                        .font(.caption)
                    Text(latest.title)
                        .font(.caption)
                        .lineLimit(2)
                }
            }

            Divider()

            HStack {
                Button("Open Sweep") { openMainWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 280)
        .task {
            Appearance.applyStored()
            await app.stats.refresh()
            await app.events.refresh()
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func statRow(icon: String, label: String, value: String, fraction: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label)
                    Spacer()
                    Text(value)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
                ProgressView(value: min(max(fraction, 0), 1))
                    .tint(fraction > 0.85 ? .orange : .accentColor)
                    .controlSize(.small)
            }
        }
    }
}
