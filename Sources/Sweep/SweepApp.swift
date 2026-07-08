import SwiftUI
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, cleanup, uninstaller, largeFiles, performance, security, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .cleanup: "Cleanup"
        case .uninstaller: "Uninstaller"
        case .largeFiles: "Large & Old Files"
        case .performance: "Performance"
        case .security: "Security"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.medium"
        case .cleanup: "sparkles"
        case .uninstaller: "app.dashed"
        case .largeFiles: "doc.badge.clock"
        case .performance: "speedometer"
        case .security: "lock.shield"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var section: AppSection = .dashboard
    let cleanup: [CleanupCategoryState]
    let largeFiles = LargeFilesModel()
    let stats = StatsModel()
    let launchItems = LaunchItemsModel()
    let security = SecurityModel()
    let uninstaller = UninstallerModel()
    let orphans = OrphansModel()
    let events = EventLogModel()

    init() {
        cleanup = CategorySpec.all().map(CleanupCategoryState.init)
    }
}

@main
enum SweepMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--background-scan") {
            BackgroundScan.run()
            return
        }
        // Debug/verification CLI, e.g.: Sweep --leftovers "/Applications/Google Chrome.app"
        if let index = args.firstIndex(of: "--leftovers"), args.count > index + 1 {
            DebugCLI.leftovers(appPath: args[index + 1])
            return
        }
        if args.contains("--orphans") {
            DebugCLI.orphans()
            return
        }
        SweepApp.main()
    }
}

struct SweepApp: App {
    @State private var app = AppModel()
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(app)
        }
        .defaultSize(width: 1040, height: 680)

        MenuBarExtra("Sweep", systemImage: "sparkles", isInserted: $menuBarEnabled) {
            MenuBarView()
                .environment(app)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(BackgroundScan.bytesKey) private var lastBackgroundScanBytes = 0

    /// Sidebar badge — the macOS-native "something to consider here" affordance.
    private func badge(for section: AppSection) -> Text? {
        switch section {
        case .cleanup:
            // Live in-app totals when available, otherwise the scheduled scan's figure.
            let scanned = app.cleanup.filter { $0.hasScanned && $0.spec.id != "downloads" }
            let total = scanned.isEmpty
                ? Int64(lastBackgroundScanBytes)
                : scanned.reduce(Int64(0)) { $0 + $1.totalSize }
            return total >= BackgroundScan.junkThreshold ? Text(formatBytes(total)) : nil
        case .security:
            guard app.security.hasRun else { return nil }
            let count = app.security.warningCount + app.launchItems.flagged.count
            return count > 0 ? Text("\(count)") : nil
        default:
            return nil
        }
    }

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(
                get: { Optional(app.section) },
                set: { if let section = $0 { app.section = section } }
            )) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(badge(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch app.section {
            case .dashboard: DashboardView()
            case .cleanup: CleanupView()
            case .uninstaller: UninstallerView()
            case .largeFiles: LargeFilesView()
            case .performance: PerformanceView()
            case .security: SecurityView()
            case .settings: SettingsView()
            }
        }
    }
}
