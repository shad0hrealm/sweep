import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var app

    private var scannedTotal: Int64 {
        app.cleanup.filter(\.hasScanned).reduce(0) { $0 + $1.totalSize }
    }

    private var anyScanning: Bool {
        app.cleanup.contains { $0.isScanning }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.cleanup) { category in
                        NavigationLink(value: category.id) {
                            CategoryRow(category: category)
                        }
                    }
                } header: {
                    if scannedTotal > 0 {
                        Text("\(formatBytes(scannedTotal)) found across scanned categories")
                    }
                }
            }
            .listStyle(.inset)
            .navigationTitle("Cleanup")
            .navigationDestination(for: String.self) { id in
                if let category = app.cleanup.first(where: { $0.id == id }) {
                    CategoryDetailView(category: category)
                }
            }
            .toolbar {
                Button {
                    Task {
                        await withTaskGroup(of: Void.self) { group in
                            for category in app.cleanup {
                                group.addTask { @MainActor in await category.scan() }
                            }
                        }
                    }
                } label: {
                    if anyScanning {
                        Label("Scanning…", systemImage: "hourglass")
                    } else {
                        Label("Scan All", systemImage: "magnifyingglass")
                    }
                }
                .disabled(anyScanning)
            }
        }
    }
}

struct CategoryRow: View {
    let category: CleanupCategoryState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.spec.icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.spec.title)
                    .fontWeight(.medium)
                Text(category.spec.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if category.isScanning {
                ProgressView().controlSize(.small)
            } else if category.hasScanned {
                Text(formatBytes(category.totalSize))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct CategoryDetailView: View {
    let category: CleanupCategoryState
    @State private var confirmClean = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if category.isScanning {
                Spacer()
                ProgressView("Measuring sizes…")
                Spacer()
            } else if category.items.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "checkmark.circle",
                                       description: Text(category.hasScanned ? "This category is already clean." : "Scan to see what can be cleaned."))
            } else {
                itemList
            }
        }
        .navigationTitle(category.spec.title)
        .toolbar {
            Button(category.selected.count == category.items.count && !category.items.isEmpty ? "Deselect All" : "Select All") {
                if category.selected.count == category.items.count {
                    category.selected.removeAll()
                } else {
                    category.selected = Set(category.items.map(\.url))
                }
            }
            .disabled(category.items.isEmpty)

            Button {
                Task { await category.scan() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(category.isScanning)

            Button(role: .destructive) {
                confirmClean = true
            } label: {
                Label("Clean \(formatBytes(category.selectedSize))", systemImage: "sparkles")
            }
            .disabled(category.selected.isEmpty || category.isCleaning)
        }
        .task {
            if !category.hasScanned { await category.scan() }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmClean) {
            Button(category.spec.deletion == .permanent ? "Delete Permanently" : "Move to Trash",
                   role: .destructive) {
                Task { await category.cleanSelected() }
            }
        } message: {
            Text(category.spec.deletion == .permanent
                 ? "This permanently deletes \(category.selected.count) item(s) — they cannot be recovered."
                 : "Items are moved to the Trash, so you can recover them if anything is missed.")
        }
    }

    private var confirmTitle: String {
        "Clean \(category.selected.count) item\(category.selected.count == 1 ? "" : "s") (\(formatBytes(category.selectedSize)))?"
    }

    private var headerBar: some View {
        HStack {
            Text(category.spec.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let message = category.lastMessage {
                Label(message, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
        .padding(12)
    }

    private var itemList: some View {
        List {
            ForEach(category.items) { item in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { category.selected.contains(item.url) },
                        set: { on in
                            if on { category.selected.insert(item.url) } else { category.selected.remove(item.url) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    Text(item.name)
                        .lineLimit(1)
                        .help(item.url.path)
                    Spacer()
                    if category.spec.showsDates {
                        Text(relativeDate(item.modified))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text(formatBytes(item.size))
                        .font(.callout.monospacedDigit())
                        .frame(width: 90, alignment: .trailing)
                }
                .contextMenu {
                    Button("Reveal in Finder") { revealInFinder(item.url) }
                }
            }
        }
        .listStyle(.inset)
    }
}
