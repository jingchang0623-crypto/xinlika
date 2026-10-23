// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import LuyinbiCore

/// Local opt-in audio capture. A bounded submission queue separates BLE callbacks from disk I/O.
/// Raw files are split by BLE connection AND characteristic, never silently joined over a gap.
public final class CaptureJournal: @unchecked Sendable {
    public struct AudioStats: Codable, Sendable {
        public var frames = 0
        public var bytes = 0
        public var firstUptime: Double?
        public var lastUptime: Double?
        public var maxArrivalGapSeconds: Double = 0
        public var byteLengths: [String: Int] = [:]
    }
    public struct Status: Codable, Sendable {
        public var audio = AudioStats()
        public var streams: [String: AudioStats] = [:]
        public var droppedSubmissions = 0
        public var failure: String?
    }
    public let directory: URL
    private let queue = DispatchQueue(label: "org.xinlika.capture-disk")
    private let lock = NSLock()
    private let maxPendingBytes: Int
    private let recordControlBodies: Bool
    private var pendingBytes = 0
    private var accepting = true
    private var droppedSubmissions = 0
    private var failure: String?
    // Everything below is owned exclusively by queue.
    private let events: FileHandle
    private var files: [String: FileHandle] = [:]
    private var stats = Status()
    private var previousSequence: [String: UInt8] = [:]
    private var lastSync = ProcessInfo.processInfo.systemUptime
    private var closed = false

    public init(directory: URL, maxPendingBytes: Int = 4 * 1024 * 1024,
                recordControlBodies: Bool = false) throws {
        guard maxPendingBytes > 0 else { throw ProbeError.invalid("采集队列容量必须大于 0") }
        self.directory = directory; self.maxPendingBytes = maxPendingBytes
        self.recordControlBodies = recordControlBodies
        let fm = FileManager.default
        // Never append a new experiment to old evidence, nor overwrite it.
        guard !fm.fileExists(atPath: directory.path) else { throw ProbeError.invalid("输出目录已存在，请使用新的目录") }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("events.ndjson")
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ProbeError.invalid("不能创建采集日志")
        }
        events = try FileHandle(forWritingTo: url)
    }

    private func submit(cost: Int, work: @escaping () throws -> Void) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        guard failure == nil else { droppedSubmissions += 1; lock.unlock(); return }
        guard cost <= maxPendingBytes - pendingBytes else {
            droppedSubmissions += 1
            failure = "capture_queue_overflow: evidence incomplete"
            lock.unlock(); return
        }
        pendingBytes += cost
        // Schedule while holding the admission lock to retain cross-thread submission order.
        queue.async { [self] in
            do { try work() }
            catch {
                lock.lock(); if failure == nil { failure = "capture_write_failed: \(error)" }; lock.unlock()
            }
            lock.lock(); pendingBytes -= cost; lock.unlock()
        }
        lock.unlock()
    }

    private func writeRow(_ row: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        try events.write(contentsOf: data + Data([10]))
        if ProcessInfo.processInfo.systemUptime - lastSync >= 1 {
            for file in files.values { try file.synchronize() }
            try events.synchronize()
            lastSync = ProcessInfo.processInfo.systemUptime
        }
    }

    public func record(_ kind: String, fields: [String: String] = [:],
                       at: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) {
        let cost = 512 + fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        submit(cost: cost) { [self] in
            var row: [String: Any] = fields
            row["event"] = kind
            row["time"] = ISO8601DateFormatter().string(from: at)
            row["uptime"] = uptime
            try writeRow(row)
        }
    }

    public func receive(_ observation: BLEFrameObservation) {
        submit(cost: observation.frame.data.count + 512) { [self] in
            let f = observation.frame
            let stream = "\(observation.connectionID.uuidString)-\(observation.source)"
            var row: [String: Any] = [
                "event": "frame", "time": ISO8601DateFormatter().string(from: observation.receivedAt),
                "uptime": observation.uptime, "connection": observation.connectionID.uuidString,
                "source": observation.source, "sequence": Int(f.seq), "dataBytes": f.data.count,
            ]
            row["type"] = f.type.map { Int($0) }
            row["command"] = f.cmd.map { Int($0) }
            if let previous = previousSequence[stream], f.seq != previous &+ 1 {
                row["sequenceDiscontinuity"] = true
                row["previousSequence"] = Int(previous)
                // Not packet-loss proof: counter semantics across notification sources are unknown.
            }
            previousSequence[stream] = f.seq
            if recordControlBodies,
               f.type == Proto.T.ctrl || f.type == Proto.T.key || (f.type == Proto.T.audio && f.cmd == Proto.AudioCmd.status) {
                // Explicit private experiment only. File/audio payloads never enter these fields.
                row["controlBodyHex"] = f.body.prefix(64).map { String(format: "%02x", $0) }.joined()
                row["controlBodyBytes"] = f.body.count
                row["controlBodyTruncated"] = f.body.count > 64
            }
            if let button = DeviceButtonCandidate(source: observation.source, frame: f) {
                row["buttonRequestCandidate"] = button.kind.rawValue
                row["buttonInterpretation"] = "vendor_request_candidate_not_confirmed_state_or_user_intent"
                row["buttonBodyHex"] = f.body.prefix(64).map { String(format: "%02x", $0) }.joined()
                row["buttonBodyBytes"] = f.body.count
                row["buttonBodyTruncated"] = f.body.count > 64
                // Observation only. No ACK, recording mutation or focus boundary is inferred.
            }
            if RecordingFramePolicy.isLiveAudio(f) {
                let filename = "audio-\(stream).bin"
                if files[stream] == nil {
                    let url = directory.appendingPathComponent(filename)
                    guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        throw ProbeError.invalid("不能创建实时音频文件")
                    }
                    files[stream] = try FileHandle(forWritingTo: url)
                }
                let body = Data(f.body)
                row["audioFile"] = filename
                row["audioOffset"] = stats.streams[stream]?.bytes ?? 0
                row["audioBytes"] = body.count
                try files[stream]!.write(contentsOf: body)
                func advance(_ value: inout AudioStats) {
                    value.frames += 1; value.bytes += body.count
                    if value.firstUptime == nil { value.firstUptime = observation.uptime }
                    if let previous = value.lastUptime {
                        value.maxArrivalGapSeconds = max(value.maxArrivalGapSeconds, observation.uptime - previous)
                    }
                    value.lastUptime = observation.uptime
                    value.byteLengths[String(body.count), default: 0] += 1
                }
                advance(&stats.audio)
                var perStream = stats.streams[stream] ?? AudioStats()
                advance(&perStream); stats.streams[stream] = perStream
            } else if f.type == Proto.T.audio, f.cmd == Proto.AudioCmd.start {
                row["announcedFilename"] = String(decoding: f.body.prefix(while: { $0 != 0 }), as: UTF8.self)
            } else if f.type == Proto.T.audio, f.cmd == Proto.AudioCmd.status {
                row["deviceStreamState"] = f.body.first.map { Int($0) }
            }
            try writeRow(row)
        }
    }

    public func status() -> Status {
        queue.sync {
            var value = stats
            lock.lock(); value.droppedSubmissions = droppedSubmissions; value.failure = failure; lock.unlock()
            return value
        }
    }

    public func checkHealthy() throws {
        lock.lock(); let problem = failure; lock.unlock()
        if let problem { throw ProbeError.invalid(problem) }
    }

    public func close(outcome: String) throws {
        lock.lock(); accepting = false; lock.unlock()
        try queue.sync {
            guard !closed else { return }
            defer { closed = true }
            for file in files.values { try file.synchronize(); try file.close() }
            try events.synchronize(); try events.close()
            var value = stats
            lock.lock(); value.droppedSubmissions = droppedSubmissions; value.failure = failure; lock.unlock()
            var summary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
            summary["outcome"] = outcome
            summary["continuityVerdict"] = "not_established_requires_decode_and_time_marked_card_reference"
            summary["hardwareVadVerdict"] = "not_established"
            summary["finishedAt"] = ISO8601DateFormatter().string(from: Date())
            let url = directory.appendingPathComponent("capture-summary.json")
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
