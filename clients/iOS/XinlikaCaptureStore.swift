// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import CryptoKit
import Darwin

/// Synchronous, serialized disk admission gives BLE a bounded queue (one callback).
/// Raw audio is synced before its journal row; sealing never trims a codec packet.
final class XinlikaCaptureStore: @unchecked Sendable {
    struct Session: Codable {
        var id: String
        var deviceID: String
        var startedAt: String
        var cardFile: String
        var batchSeconds: Int
        var sourceKind: String
        var processing: Bool
        var status: String
        var streams: [Stream] = []
        var gaps: Int = 0
        var sequence: Int = 0
        var focus: Focus?
        var referenceQueued: Bool?
        var serviceURL: String?
        // Nil in old ledgers: never silently import historical recordings.
        var automaticReference: Bool?
        var referenceAttempts: Int?
        var referenceRetryAt: Date?
        var unresolvedGap: Bool?
        var endedAt: String?
        var discoveryComplete: Bool?
        var recoveredSegments: [RecoveredSegment]?
    }
    struct RecoveredSegment: Codable {
        var filename: String
        var bytes: Int
        var sha256: String
        var startedAt: String
    }
    struct Stream: Codable {
        var id: String
        var connection: String
        var startedAt: String
        var receivedAt: String
        var received: Int = 0
        var sealed: Int = 0
        var lastUptime: Double?
    }
    struct Focus: Codable {
        var id: String
        var startedAt: String
        var starts: [String: Int]
    }
    struct Message: Codable, Identifiable {
        var id: String
        var file: String
        var sessionID: String?
        var status: String = "pending"
        var attempts: Int = 0
        var serviceURL: String?
    }
    struct State: Codable {
        var sessions: [Session] = []
        var outbox: [Message] = []
        var error: String?
        var heldSessionIDs: Set<String> { Set(outbox.filter { $0.status == "blocked" }.compactMap(\.sessionID)) }
        var heldCount: Int {
            let ids = heldSessionIDs
            return outbox.filter { $0.status != "accepted" && ($0.status == "blocked" || ids.contains($0.sessionID ?? "")) }.count
        }
        var pendingCount: Int { outbox.filter { $0.status != "accepted" }.count - heldCount }
        func counts(for serviceURL: String?) -> (pending: Int, held: Int) {
            let messages = outbox.filter { $0.serviceURL == serviceURL && $0.status != "accepted" }
            let blocked = Set(messages.filter { $0.status == "blocked" }.compactMap(\.sessionID))
            let held = messages.filter { $0.status == "blocked" || blocked.contains($0.sessionID ?? "") }.count
            return (messages.count - held, held)
        }
        func historicalCount(excluding serviceURL: String?) -> Int {
            outbox.filter { $0.serviceURL != serviceURL && $0.status != "accepted" }.count
        }

    }
    let root: URL
    private let queue = DispatchQueue(label: "xinlika.capture.disk")
    private var state: State
    private var leaseFD: Int32 = -1
    var onChange: (@Sendable () -> Void)?
    static func stamp(_ date: Date = .now) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let ledger = root.appendingPathComponent("capture.json")
        state = FileManager.default.fileExists(atPath: ledger.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: ledger)) : State()
        let descriptor = Darwin.open(root.appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw NSError(domain: "Xinlika", code: 2, userInfo: [NSLocalizedDescriptionKey: "采集账本已有接收者，未重复恢复或连接设备"])
        }
        leaseFD = descriptor
        var keepLease = false
        defer { if !keepLease { flock(descriptor, LOCK_UN); Darwin.close(descriptor); leaseFD = -1 } }
        for i in state.outbox.indices where state.outbox[i].sessionID == nil {
            let data = try Data(contentsOf: root.appendingPathComponent(state.outbox[i].file))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            state.outbox[i].sessionID = (body?["session"] as? [String: Any])?["id"] as? String
        }
        for i in state.sessions.indices where state.sessions[i].status == "completed" && state.sessions[i].endedAt == nil {
            for message in state.outbox where message.sessionID == state.sessions[i].id {
                let body = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(message.file))) as? [String: Any]
                if body?["kind"] as? String == "finish" { state.sessions[i].endedAt = body?["at"] as? String }
            }
        }
        // A process death is a real gap. Recover only journal-committed bytes from
        // the previous stream; keep raw excess as evidence, never merge connections.
        for i in state.sessions.indices where ["recording", "preparing", "reconnecting", "waiting_audio"].contains(state.sessions[i].status) {
            for j in state.sessions[i].streams.indices {
                let stream = state.sessions[i].streams[j]
                let journal = root.appendingPathComponent(stream.id + ".journal")
                if let h = try? FileHandle(forReadingFrom: journal) {
                    let size = (try? h.seekToEnd()) ?? 0
                    try h.seek(toOffset: size > 8192 ? size - 8192 : 0)
                    let tail = try h.readToEnd() ?? Data(); try h.close()
                    if let line = String(data: tail, encoding: .utf8)?.split(separator: "\n").last,
                       let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                       let bytes = row["end"] as? Int, let at = row["at"] as? String {
                        state.sessions[i].streams[j].received = bytes
                        state.sessions[i].streams[j].receivedAt = at
                    }
                }
            }
            state.sessions[i].status = "interrupted"
            state.sessions[i].gaps += 1
            if !state.sessions[i].cardFile.isEmpty {
                try sealAll(i, reason: "process_interrupted")
                try enqueue(i, fields: ["kind": "gap", "at": Self.stamp(), "reason": "process_interrupted_unverified_card_range"])
            }
        }
        try persist()
        keepLease = true
    }
    deinit { if leaseFD >= 0 { flock(leaseFD, LOCK_UN); Darwin.close(leaseFD) } }
    func snapshot() -> State { queue.sync { state } }
    func nextUpload(serviceURL: String? = nil) -> Message? {
        queue.sync {
            guard state.error == nil else { return nil }
            let blocked = state.heldSessionIDs
            return state.outbox.first { $0.status != "accepted" && $0.status != "blocked" && !blocked.contains($0.sessionID ?? "") && (serviceURL == nil || $0.serviceURL == serviceURL) }
        }
    }
    /// Migrate the pre-cloud ledger using its existing connection, never the
    /// newly chosen server. Immutable upload bodies and audio stay unchanged.
    func bindLegacyUploads(to serviceURL: String) throws {
        try queue.sync {
            for i in state.sessions.indices where state.sessions[i].serviceURL == nil { state.sessions[i].serviceURL = serviceURL }
            for i in state.outbox.indices where state.outbox[i].serviceURL == nil {
                state.outbox[i].serviceURL = state.sessions.first { $0.id == state.outbox[i].sessionID }?.serviceURL ?? serviceURL
            }
            try persist()
        }
    }
    func active() -> Session? { queue.sync { state.sessions.last } }
    private func persist() throws {
        do {
            try JSONEncoder().encode(state).write(to: root.appendingPathComponent("capture.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            state.error = "采集账本未能保存，已暂停接收和上传；卡上原声保留"
            throw error
        }
    }
    func begin(device: UUID, seconds: Int = 60, source: String, processing: Bool, serviceURL: String? = nil) throws {
        try queue.sync {
            guard (60...300).contains(seconds), state.sessions.last.map({ ["completed", "failed"].contains($0.status) }) ?? true else {
                throw NSError(domain: "Xinlika", code: 1, userInfo: [NSLocalizedDescriptionKey: "上一段录音需先恢复或结束"])
            }
            state.sessions.append(Session(id: UUID().uuidString.lowercased(), deviceID: device.uuidString.lowercased(),
                startedAt: Self.stamp(), cardFile: "", batchSeconds: seconds, sourceKind: source, processing: processing, status: "preparing", serviceURL: serviceURL, automaticReference: true))
            try persist()
        }
    }
    func ownedFile(_ name: String, waiting: Bool = false) throws {
        try queue.sync {
            let i = state.sessions.count - 1
            state.sessions[i].cardFile = name
            state.sessions[i].status = waiting ? "waiting_audio" : "recording"
            try sealAll(i, reason: "duration")
            try persist()
        }
    }
    func receive(_ observation: BLEFrameObservation) {
        guard RecordingFramePolicy.isLiveAudio(observation.frame), observation.source == "AE22" else { return }
        queue.sync {
            guard let last = state.sessions.last, ["preparing", "recording", "waiting_audio"].contains(last.status), state.error == nil else { return }
            let i = state.sessions.count - 1
            do {
                let data = Data(observation.frame.body)
                guard !data.isEmpty else { return }
                let wasWaiting = state.sessions[i].status == "waiting_audio"
                state.sessions[i].status = "recording"
                let connection = observation.connectionID.uuidString.lowercased()
                let alreadyMissing = state.sessions[i].unresolvedGap == true
                let arrivalGap = !alreadyMissing && state.sessions[i].streams.last?.connection == connection
                    && (state.sessions[i].streams.last?.lastUptime.map { observation.uptime - $0 > 2 } ?? false)
                if arrivalGap, !state.sessions[i].cardFile.isEmpty {
                    try sealAll(i, reason: "arrival_gap")
                    state.sessions[i].gaps += 1
                    try enqueue(i, fields: ["kind": "gap", "at": Self.stamp(observation.receivedAt), "reason": "arrival_gap_unresolved"])
                }
                if state.sessions[i].streams.last?.connection != connection || arrivalGap || alreadyMissing {
                    try sealAll(i, reason: "connection_change")
                    let first = observation.receivedAt.addingTimeInterval(-Double(data.count / 40) * 0.02)
                    state.sessions[i].streams.append(Stream(id: UUID().uuidString.lowercased(), connection: connection,
                        startedAt: Self.stamp(first), receivedAt: Self.stamp(observation.receivedAt)))
                    try persist()
                }
                let j = state.sessions[i].streams.count - 1
                let stream = state.sessions[i].streams[j]
                try append(data, to: root.appendingPathComponent(stream.id + ".raw"))
                let end = stream.received + data.count
                let at = Self.stamp(observation.receivedAt)
                let journal = try JSONSerialization.data(withJSONObject: ["end": end, "at": at, "uptime": observation.uptime, "sequence": observation.frame.seq]) + Data([10])
                try append(journal, to: root.appendingPathComponent(stream.id + ".journal"))
                state.sessions[i].streams[j].received = end
                state.sessions[i].streams[j].receivedAt = at
                state.sessions[i].streams[j].lastUptime = observation.uptime
                state.sessions[i].unresolvedGap = false
                if wasWaiting { try persist(); onChange?() }
                if end - stream.sealed >= state.sessions[i].batchSeconds * 2000, !state.sessions[i].cardFile.isEmpty {
                    try sealAll(i, reason: "duration"); try persist(); onChange?()
                }
            } catch { state.error = "录音落盘失败，请检查空间；卡上录音未停止"; try? persist(); onChange?() }
        }
    }
    private func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data); try file.synchronize()
    }
    private func manifest(_ s: Session) -> [String: Any] {
        ["id": s.id, "device_id": s.deviceID, "started_at": s.startedAt, "card_file": s.cardFile,
         "batch_seconds": s.batchSeconds, "processing": ["asr": s.processing, "agent": s.processing, "source_kind": s.sourceKind]]
    }
    private func enqueue(_ i: Int, fields: [String: Any]) throws {
        let id = UUID().uuidString.lowercased()
        var body = fields
        body["id"] = id; body["session"] = manifest(state.sessions[i])
        let name = id + ".upload.json"
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]).write(to: root.appendingPathComponent(name),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state.outbox.append(Message(id: id, file: name, sessionID: state.sessions[i].id, serviceURL: state.sessions[i].serviceURL))
    }
    private func sealAll(_ i: Int, reason: String) throws {
        guard !state.sessions[i].cardFile.isEmpty else { return }
        for j in state.sessions[i].streams.indices {
            while true {
                let stream = state.sessions[i].streams[j]
                let available = stream.received / 40 * 40 - stream.sealed
                let size = state.sessions[i].batchSeconds * 2000
                guard available > 0, reason != "duration" || available >= size else { break }
                let count = min(available, size)
                let h = try FileHandle(forReadingFrom: root.appendingPathComponent(stream.id + ".raw"))
                try h.seek(toOffset: UInt64(stream.sealed))
                let raw = try h.read(upToCount: count) ?? Data(); try h.close()
                guard raw.count == count else { throw CocoaError(.fileReadCorruptFile) }
                try enqueue(i, fields: ["kind": "batch", "stream_id": stream.id, "stream_started_at": stream.startedAt,
                    "received_at": stream.receivedAt, "start_byte": stream.sealed, "end_byte": stream.sealed + count,
                    "sequence": state.sessions[i].sequence, "sha256": Self.hash(raw), "audio_base64": raw.base64EncodedString(), "reason": reason])
                state.sessions[i].streams[j].sealed += count
                state.sessions[i].sequence += 1
            }
        }
    }
    func gap(_ reason: String) throws {
        try queue.sync {
            guard !state.sessions.isEmpty else { return }
            let i = state.sessions.count - 1
            guard !["completed", "failed"].contains(state.sessions[i].status) else { return }
            try sealAll(i, reason: "bluetooth_gap")
            let newGap = state.sessions[i].unresolvedGap != true
            if newGap { state.sessions[i].gaps += 1 }
            state.sessions[i].unresolvedGap = true
            state.sessions[i].status = reason == "physical_file_changed_unresolved" ? "attention" : "reconnecting"
            if newGap, !state.sessions[i].cardFile.isEmpty { try enqueue(i, fields: ["kind": "gap", "at": Self.stamp(), "reason": reason]) }
            try persist()
        }
    }
    /// A notification subscription is not evidence of audio. Silence in this
    /// firmware still produces codec frames, so a stalled transport is unresolved.
    @discardableResult
    func detectStall(uptime: Double, threshold: Double = 10) throws -> Bool {
        let current = active()
        guard current?.status == "recording", let last = current?.streams.last?.lastUptime,
              uptime >= last, uptime - last >= threshold else { return false }
        try gap("audio_stalled_unresolved")
        return true
    }

    func nextReference(serviceURL: String, now: Date = .now) -> Session? {
        queue.sync {
            state.sessions.first { $0.status == "completed" && $0.automaticReference == true &&
                !$0.cardFile.isEmpty && ($0.referenceQueued != true || $0.discoveryComplete != true) && $0.serviceURL == serviceURL &&
                ($0.referenceRetryAt.map { $0 <= now } ?? true) }
        }
    }
    func referenceAttempt(_ id: String, now: Date = .now) throws {
        try queue.sync {
            guard let i = state.sessions.firstIndex(where: { $0.id == id }) else { return }
            let attempt = (state.sessions[i].referenceAttempts ?? 0) + 1
            state.sessions[i].referenceAttempts = attempt
            // Persist before BLE I/O: process death resumes the checkpoint after
            // bounded backoff instead of creating a tight reconnect loop.
            state.sessions[i].referenceRetryAt = now.addingTimeInterval(min(300, 15 * pow(2, Double(min(attempt - 1, 5)))))
            try persist()
        }
    }
    func toggleFocus() throws {
        try queue.sync {
            let i = state.sessions.count - 1
            guard i >= 0, state.sessions[i].status == "recording" || state.sessions[i].focus != nil else { throw BLEError.notConnected }
            try sealAll(i, reason: "focus_boundary")
            if let focus = state.sessions[i].focus {
                let ranges: [[String: Any]] = state.sessions[i].streams.compactMap { s in
                    let begin = focus.starts[s.id] ?? 0, end = s.received / 40 * 40
                    return end > begin ? ["stream_id": s.id, "start_byte": begin, "end_byte": end] : nil
                }
                if !ranges.isEmpty { try enqueue(i, fields: ["kind": "focus", "focus_id": focus.id, "started_at": focus.startedAt,
                    "ended_at": Self.stamp(), "ranges": ranges]) }
                state.sessions[i].focus = nil
            } else {
                state.sessions[i].focus = Focus(id: UUID().uuidString.lowercased(), startedAt: Self.stamp(),
                    starts: Dictionary(uniqueKeysWithValues: state.sessions[i].streams.map { ($0.id, $0.received / 40 * 40) }))
            }
            try persist()
        }
    }
    func finish(saved: Bool) throws {
        if snapshot().sessions.last?.focus != nil { try toggleFocus() }
        try queue.sync {
            guard !state.sessions.isEmpty else { return }
            let i = state.sessions.count - 1
            guard state.sessions[i].status != "completed" else { return }
            try sealAll(i, reason: "capture_end")
            state.sessions[i].status = saved ? "completed" : "interrupted"
            if saved { state.sessions[i].endedAt = Self.stamp() }
            if saved { try enqueue(i, fields: ["kind": "finish", "at": state.sessions[i].endedAt!]) }
            try persist()
        }
    }
    func acknowledge(_ id: String, status: String) throws {
        try queue.sync {
            guard let i = state.outbox.firstIndex(where: { $0.id == id }) else { return }
            state.outbox[i].status = status
            state.outbox[i].attempts += 1
            try persist()
        }
    }

    func enqueueReference(_ raw: Data, expected: Int, filename: String, endCode: UInt8, sessionID: String? = nil) throws {
        try queue.sync {
            let i = sessionID.flatMap { id in state.sessions.firstIndex { $0.id == id } } ?? (sessionID == nil ? state.sessions.count - 1 : -1)
            guard i >= 0, state.sessions[i].status == "completed", state.sessions[i].cardFile == filename,
                  raw.count == expected, expected > 0, expected % 40 == 0, endCode == 0 else { throw DownloadFailure.wrongFile }
            guard state.sessions[i].referenceQueued != true else { return }
            for start in stride(from: 0, to: raw.count, by: 600000) {
                let part = raw.subdata(in: start..<min(raw.count, start + 600000))
                try enqueue(i, fields: ["kind": "reference_chunk", "offset": start,
                    "sha256": Self.hash(part), "audio_base64": part.base64EncodedString()])
            }
            try enqueue(i, fields: ["kind": "reference_complete", "card_file": filename,
                "expected_bytes": expected, "end_code": Int(endCode), "sha256": Self.hash(raw)])
            state.sessions[i].referenceQueued = true
            try persist()
        }
    }
    func retainCloudSegment(_ segment: RecoveredSegment, sessionID: String) throws {
        try queue.sync {
            guard let i = state.sessions.firstIndex(where: { $0.id == sessionID }), state.sessions[i].status == "completed" else { throw DownloadFailure.wrongFile }
            if !(state.sessions[i].recoveredSegments ?? []).contains(where: { $0.filename == segment.filename }) {
                state.sessions[i].recoveredSegments = (state.sessions[i].recoveredSegments ?? []) + [segment]; try persist()
            }
        }
    }
    func completeDiscovery(_ sessionID: String) throws {
        try queue.sync {
            guard let i = state.sessions.firstIndex(where: { $0.id == sessionID }), state.sessions[i].status == "completed" else { throw DownloadFailure.wrongFile }
            state.sessions[i].discoveryComplete = true; try persist()
        }
    }
    func enqueueSegment(_ raw: Data, filename: String, previous: String, previousHash: String, sessionID: String) throws {
        try queue.sync {
            guard let i = state.sessions.firstIndex(where: { $0.id == sessionID }), state.sessions[i].status == "completed",
                  let ended = state.sessions[i].endedAt else { throw DownloadFailure.wrongFile }
            let session = state.sessions[i], name = CardSegmentDiscovery.canonical(filename)
            guard !(session.recoveredSegments ?? []).contains(where: { $0.filename == name }) else { return }
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let start = f.date(from: session.startedAt), let end = f.date(from: ended),
                  let rootClock = CardSegmentDiscovery.clock(session.cardFile), let clock = CardSegmentDiscovery.clock(name) else { throw DownloadFailure.wrongFile }
            let at = start.addingTimeInterval(clock.timeIntervalSince(rootClock))
            guard at < end, !raw.isEmpty, raw.count % 40 == 0 else { throw DownloadFailure.wrongFile }
            let digest = Self.hash(raw), child = CardSegmentDiscovery.id(root: sessionID, filename: name)
            var manifest = self.manifest(session)
            manifest["id"] = child; manifest["card_file"] = name; manifest["started_at"] = Self.stamp(at)
            manifest["recovery"] = ["root_id": sessionID, "previous_file": CardSegmentDiscovery.canonical(previous), "previous_sha256": previousHash, "expected_bytes": raw.count, "sha256": digest] as [String: Any]
            var stagedMessages: [Message] = []
            func save(_ fields: [String: Any]) throws {
                let id = UUID().uuidString.lowercased(); var body = fields; body["id"] = id; body["session"] = manifest
                let file = "out-" + id + ".json"
                try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]).write(to: root.appendingPathComponent(file), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                // Parent identity keeps the entire lineage in the original service's ordered queue.
                stagedMessages.append(Message(id: id, file: file, sessionID: sessionID, serviceURL: session.serviceURL))
            }
            try save(["kind": "finish", "at": Self.stamp(at.addingTimeInterval(Double(raw.count) / 2000))])
            for begin in stride(from: 0, to: raw.count, by: 600000) {
                let data = raw.subdata(in: begin..<min(raw.count, begin + 600000))
                try save(["kind": "reference_chunk", "offset": begin, "sha256": Self.hash(data), "audio_base64": data.base64EncodedString()])
            }
            try save(["kind": "reference_complete", "card_file": name, "expected_bytes": raw.count, "end_code": 0, "sha256": digest])
            state.outbox += stagedMessages
            state.sessions[i].recoveredSegments = (session.recoveredSegments ?? []) + [RecoveredSegment(filename: name, bytes: raw.count, sha256: digest, startedAt: Self.stamp(at))]
            try persist()
        }
    }

}
