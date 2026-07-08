import Foundation
import Observation

// MARK: - Event model

struct SweepEvent: Codable, Identifiable, Sendable {
    enum Severity: String, Codable, Sendable {
        case info      // something happened (a cleanup, a routine scan)
        case action    // a recommendation — something worth doing
        case warning   // something changed that deserves attention
    }

    var id = UUID()
    var date = Date()
    var severity: Severity
    var title: String
    var detail: String?
}

// MARK: - Store (shared between the GUI and the headless scheduled scan)

enum EventStore {
    private static let queue = DispatchQueue(label: "au.com.thehartmanns.sweep.events")
    private static let maxEvents = 200

    static var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sweep")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("events.json")
    }

    static func append(_ severity: SweepEvent.Severity, _ title: String, detail: String? = nil) {
        let event = SweepEvent(severity: severity, title: title, detail: detail)
        queue.async {
            var events = loadLocked()
            events.insert(event, at: 0)
            if events.count > maxEvents { events = Array(events.prefix(maxEvents)) }
            if let data = try? JSONEncoder().encode(events) {
                try? data.write(to: fileURL)
            }
        }
    }

    static func load() -> [SweepEvent] {
        queue.sync { loadLocked() }
    }

    static func clear() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Blocks until pending appends hit disk — call before a headless process exits.
    static func flush() {
        queue.sync {}
    }

    private static func loadLocked() -> [SweepEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let events = try? JSONDecoder().decode([SweepEvent].self, from: data) else { return [] }
        return events
    }
}

// MARK: - GUI model

@MainActor
@Observable
final class EventLogModel {
    var events: [SweepEvent] = []

    func refresh() async {
        events = await Task.detached { EventStore.load() }.value
    }

    func clear() {
        EventStore.clear()
        events = []
    }
}
