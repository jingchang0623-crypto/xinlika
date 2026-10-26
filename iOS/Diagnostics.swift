import Foundation
import OSLog

/// Only fixed event names, opaque identifiers and numeric error codes enter diagnostics.
enum Diagnostics {
    private static let logger = Logger(subsystem: "com.zaowuyun.shennao", category: "sync")
    private static let queue = DispatchQueue(label: "shennao.diagnostics")
    private static var events: [[String: String]] = []
    private static var loaded = false
    private static var recordingRows: [[String: String]] = []
    private static var recordingLoaded = false

    static func recordingExchange(_ event: RecordingDiagnosticEvent, run: String) {
        saveRecordingRow(["run": run, "phase": event.phase, "source": event.source,
                          "sequence": String(event.sequence), "type": String(event.type),
                          "command": event.command.map(String.init) ?? "ack",
                          "body": event.body.map { String(format: "%02x", $0) }.joined(separator: " ")])
    }

    static func recordingOperation(_ phase: String, run: String, action: RecorderAction?,
                                   state: RecorderState?, firmware: String?) {
        saveRecordingRow(["run": run, "phase": phase,
                          "type": action == nil ? "3" : "1", "command": action.map { String($0.request) } ?? "query",
                          "state": state.map { String($0.rawValue) } ?? "unknown",
                          "firmware": String((firmware ?? "unknown").prefix(32))])
    }

    private static func saveRecordingRow(_ fields: [String: String]) {
        var row = fields
        row["time"] = ISO8601DateFormatter().string(from: Date())
        row["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        queue.async {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Shennao", isDirectory: true)
            let file = root.appendingPathComponent("recording-diagnostics.json")
            if !recordingLoaded {
                recordingLoaded = true
                if let data = try? Data(contentsOf: file),
                   let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] { recordingRows = saved }
            }
            recordingRows.append(row)
            if recordingRows.count > 300 { recordingRows.removeFirst(recordingRows.count - 300) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: recordingRows).write(to: file,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { logger.error("recording_diagnostics_write_failed") }
        }
    }
    static func event(_ name: String, record: String? = nil, bytes: Int? = nil, error: Error? = nil) {
        let id = record.map { String(LedgerStore.sha256($0).prefix(8)) } ?? "-"
        let code = error.map { ($0 as NSError).code } ?? 0
        logger.info("\(name, privacy: .public) task=\(id, privacy: .public) bytes=\(bytes ?? 0) code=\(code)")
        let row = ["event": name, "task": id, "bytes": String(bytes ?? 0), "code": String(code),
                   "time": ISO8601DateFormatter().string(from: Date())]
        queue.async {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Shennao", isDirectory: true)
            if !loaded {
                loaded = true
                if let data = try? Data(contentsOf: root.appendingPathComponent("diagnostics.json")),
                   let saved = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] { events = saved }
            }
            events.append(row)
            if events.count > 200 { events.removeFirst(events.count - 200) }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: events).write(to: root.appendingPathComponent("diagnostics.json"),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { logger.error("diagnostics_write_failed") }
        }
    }
}
