import SwiftUI
import Observation

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, cleanup, largeFiles, performance, security

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .cleanup: "Cleanup"
        case .largeFiles: "Large & Old Files"
        case .performance: "Performance"
        case .security: "Security"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.medium"
        case .cleanup: "sparkles"
        case .largeFiles: "doc.badge.clock"
        case .performance: "speedometer"
        case .security: "lock.shield"
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

    init() {
        cleanup = CategorySpec.all().map(CleanupCategoryState.init)
    }
}

@main
struct SweepApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
        }
        .defaultSize(width: 1040, height: 680)
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(
                get: { Optional(app.section) },
                set: { if let section = $0 { app.section = section } }
            )) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch app.section {
            case .dashboard: DashboardView()
            case .cleanup: CleanupView()
            case .largeFiles: LargeFilesView()
            case .performance: PerformanceView()
            case .security: SecurityView()
            }
        }
    }
}
