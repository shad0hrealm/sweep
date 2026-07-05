import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var app

    private var junkFound: Int64 {
        app.cleanup.filter(\.hasScanned).reduce(0) { $0 + $1.totalSize }
    }

    private var anyCleanupScanned: Bool {
        app.cleanup.contains(where: \.hasScanned)
    }

    var body: some View {
        let stats = app.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sweep")
                        .font(.largeTitle.weight(.semibold))
                    Text("Cleanup, performance and security for this Mac. Nothing is removed without your say-so.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                HStack(spacing: 14) {
                    gaugeCard(
                        title: "Storage",
                        fraction: stats.disk.total > 0 ? Double(stats.disk.used) / Double(stats.disk.total) : 0,
                        primary: formatBytes(stats.disk.free),
                        secondary: "free of \(formatBytes(stats.disk.total))"
                    )
                    gaugeCard(
                        title: "Memory",
                        fraction: stats.memory.total > 0 ? Double(stats.memory.used) / Double(stats.memory.total) : 0,
                        primary: formatBytes(stats.memory.used),
                        secondary: "used of \(formatBytes(stats.memory.total))"
                    )
                    securityCard
                }

                GroupBox {
                    VStack(spacing: 0) {
                        actionRow(
                            icon: "sparkles",
                            title: anyCleanupScanned ? "\(formatBytes(junkFound)) of removable junk found" : "Scan for junk files",
                            subtitle: "Caches, logs, developer leftovers, Trash and old downloads",
                            buttonTitle: anyCleanupScanned ? "Review & Clean" : "Open Cleanup"
                        ) { app.section = .cleanup }
                        Divider()
                        actionRow(
                            icon: "app.dashed",
                            title: "Uninstall apps completely",
                            subtitle: "Remove apps along with their support files and caches",
                            buttonTitle: "Open"
                        ) { app.section = .uninstaller }
                        Divider()
                        actionRow(
                            icon: "doc.badge.clock",
                            title: "Find large & old files",
                            subtitle: "Hunt down the big files you forgot about",
                            buttonTitle: "Open"
                        ) { app.section = .largeFiles }
                        Divider()
                        actionRow(
                            icon: "speedometer",
                            title: "Review performance",
                            subtitle: "Memory pressure, heavy processes, login items",
                            buttonTitle: "Open"
                        ) { app.section = .performance }
                    }
                    .padding(6)
                } label: {
                    Text("Quick Actions")
                }

                Spacer()
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .task {
            await app.stats.refresh()
            if !app.security.hasRun { await app.security.run() }
            if !app.launchItems.hasScanned { await app.launchItems.scan() }
        }
    }

    private func gaugeCard(title: String, fraction: Double, primary: String, secondary: String) -> some View {
        GroupBox {
            HStack(spacing: 14) {
                Gauge(value: min(max(fraction, 0), 1)) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(.callout, design: .rounded).weight(.medium))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(fraction > 0.85 ? .orange : .accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(primary)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
    }

    private var securityCard: some View {
        let warnings = app.security.warningCount + app.launchItems.flagged.count
        let ok = app.security.hasRun && warnings == 0
        return GroupBox {
            HStack(spacing: 14) {
                Image(systemName: ok ? "checkmark.shield.fill" : (app.security.hasRun ? "exclamationmark.shield.fill" : "shield"))
                    .font(.system(size: 34))
                    .foregroundStyle(ok ? Color.green : (app.security.hasRun ? Color.orange : Color.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Security")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !app.security.hasRun {
                        Text("Checking…")
                            .font(.title3.weight(.semibold))
                    } else if ok {
                        Text("Looking good")
                            .font(.title3.weight(.semibold))
                        Text("All checks passed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(warnings) item\(warnings == 1 ? "" : "s") to review")
                            .font(.title3.weight(.semibold))
                        Button("Review") { app.section = .security }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
        }
    }

    private func actionRow(icon: String, title: String, subtitle: String,
                           buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(buttonTitle, action: action)
        }
        .padding(.vertical, 8)
    }
}
