import Foundation

/// One local session trace with counters and failure reasons, never transcript or audio content.
@MainActor
enum DictationDiagnostics {
    static let url = URL(fileURLWithPath: "/tmp/Dictation-session-diagnostics.json")
    private static var events: [[String: String]] = []
    private static var active = false

    static func begin(target: String, model: String) {
        events = []
        active = true
        record("session.begin", ["target": target, "model": model])
    }

    static func record(_ event: String, _ fields: [String: String] = [:]) {
        guard active else { return }
        var entry = fields
        entry["event"] = event
        entry["time"] = String(ProcessInfo.processInfo.systemUptime)
        events.append(entry)
        if events.count > 80 { events.remove(at: 3) }
        guard let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func finish() {
        guard active else { return }
        record("session.end")
        let historyURL = URL(fileURLWithPath: "/tmp/Dictation-recent-sessions.json")
        var history = (try? Data(contentsOf: historyURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[[String: String]]] } ?? []
        history.append(events)
        if let data = try? JSONSerialization.data(withJSONObject: Array(history.suffix(5)), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: historyURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        }
        active = false
    }
}
