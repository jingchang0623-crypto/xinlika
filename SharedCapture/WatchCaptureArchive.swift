import Foundation

/// One serialized disk owner on each device. A sender retains files after transport
/// completion; only an application receipt marks them safe for eventual cleanup.
final class WatchCaptureArchive: @unchecked Sendable {
    struct Draft: Codable {
        let id: UUID
        let sequence: Int
        let offsetMilliseconds: Int
    }
    struct CloudGrant: Codable, Equatable {
        let bindingID: String
        let serviceURL: String
        let sourceKind: String
    }
    struct FocusDraft: Codable { let id: UUID; let startMilliseconds: Int }
    struct Record: Codable, Identifiable {
        let header: WatchRecordingHeader
        var segments: [WatchAudioSegment] = []
        var events: [WatchCaptureEvent] = []
        var receipts: [WatchCaptureReceipt] = []
        var draft: Draft?
        var focusDraft: FocusDraft?
        var cloudGrant: CloudGrant?
        var cloudAccepted: Set<String> = []
        // Optional for backward-compatible decoding of existing phone/Watch ledgers.
        var cloudAudioReceipts: [WatchCloudAudioReceipt]?
        var id: UUID { header.id }
        var ended: WatchCaptureEvent? { events.first { $0.kind == .ended } }
        var complete: Bool {
            guard let count = ended?.finalSegmentCount, segments.count == count else { return false }
            return segments.map(\.sequence).sorted() == Array(0..<count)
        }
        var seconds: Double { segments.reduce(0) { $0 + $1.duration } }
        var pending: Int { segments.count + events.count - receipts.count }
    }
    struct State: Codable { var installationID = UUID(); var recordings: [Record] = [] }
    let root: URL
    private let lock = NSRecursiveLock()
    private var state: State
    private let allowsCloudEviction: Bool
    init(root: URL, recoverDrafts: Bool = false, allowsCloudEviction: Bool = false) throws {
        self.root = root
        self.allowsCloudEviction = allowsCloudEviction
        #if os(iOS) || os(watchOS)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        #else
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #endif
        let file = root.appendingPathComponent("archive.json")
        state = FileManager.default.fileExists(atPath: file.path)
            ? try WatchCaptureProtocol.decode(State.self, Data(contentsOf: file)) : State()
        try persist()
        if recoverDrafts {
            for id in state.recordings.filter({ $0.ended == nil }).map(\.id) {
                try seal(id)
                let r = try record(id)
                let offset = r.segments.last.map { $0.offsetMilliseconds + Int($0.duration * 1000) } ?? 0
                try closeFocus(id, offset: offset)
                try event(id, .init(id: UUID(), kind: .interrupted, offsetMilliseconds: offset, endMilliseconds: nil,
                                    finalSegmentCount: nil, reason: "process_interrupted"))
                try end(id, offset: offset)
            }
        }
    }
    private func synchronized<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
    private func persist() throws {
        let data = try WatchCaptureProtocol.encode(state)
        #if os(iOS) || os(watchOS)
        try data.write(to: root.appendingPathComponent("archive.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: root.appendingPathComponent("archive.json"), options: .atomic)
        #endif
    }
    private func mutate(_ body: (inout State) throws -> Void) throws {
        let previous = state
        do { try body(&state); try persist() } catch { state = previous; throw error }
    }
    func snapshot() -> State { synchronized { state } }
    func record(_ id: UUID) throws -> Record {
        try synchronized { guard let r = state.recordings.first(where: { $0.id == id }) else { throw WatchCaptureError.noRecording }; return r }
    }
    func file(_ segment: WatchAudioSegment) -> URL { root.appendingPathComponent(segment.filename) }
    private func raw(_ draft: Draft) -> URL { root.appendingPathComponent(draft.id.uuidString.lowercased() + ".pcm") }
    @discardableResult
    func begin(bindingID: String?, now: Date = .now) throws -> WatchRecordingHeader {
        try synchronized {
            guard !state.recordings.contains(where: { $0.ended == nil }) else { throw WatchCaptureError.conflict }
            let header = WatchRecordingHeader(schemaVersion: 1, id: UUID(), installationID: state.installationID,
                bindingID: bindingID, startedAt: now, timeZone: TimeZone.current.identifier)
            try header.validate()
            try mutate { $0.recordings.append(Record(header: header)) }
            return header
        }
    }
    /// PCM writes precede the segment manifest. The active draft can be recovered
    /// from its on-disk size after a crash, without trusting a UI timer.
    func append(_ pcm: Data, recording id: UUID, offsetMilliseconds: Int) throws {
        try synchronized {
            guard pcm.count % 2 == 0, !pcm.isEmpty else { throw WatchCaptureError.invalidEvidence }
            let capacity = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? Int.max
            guard capacity > pcm.count + 8_000_000 else { throw WatchCaptureError.storage }
            var remaining = pcm
            var consumed = 0
            while !remaining.isEmpty {
                let r = try record(id)
                guard r.ended == nil else { throw WatchCaptureError.noRecording }
                if r.draft == nil {
                    let draft = Draft(id: UUID(), sequence: r.segments.count,
                        offsetMilliseconds: offsetMilliseconds + consumed / 32)
                    try mutate { s in s.recordings[s.recordings.firstIndex { $0.id == id }!].draft = draft }
                }
                let draft = try record(id).draft!
                let url = raw(draft)
                if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
                let handle = try FileHandle(forWritingTo: url)
                do {
                    let size = Int(try handle.seekToEnd())
                    let count = min(WatchCaptureProtocol.segmentFrames * 2 - size, remaining.count)
                    guard count > 0 else { try handle.close(); try seal(id); continue }
                    try handle.write(contentsOf: remaining.prefix(count)); try handle.synchronize(); try handle.close()
                    remaining.removeFirst(count); consumed += count
                    if size + count == WatchCaptureProtocol.segmentFrames * 2 { try seal(id) }
                } catch { try? handle.close(); throw error }
            }
        }
    }
    func seal(_ id: UUID) throws {
        try synchronized {
            guard let draft = try record(id).draft else { return }
            let path = raw(draft)
            let rawData = FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : Data()
            let pcm = Data(rawData.prefix(rawData.count / 2 * 2))
            guard pcm.count <= WatchCaptureProtocol.segmentFrames * 2 else { throw WatchCaptureError.invalidEvidence }
            if !pcm.isEmpty {
                let wav = WatchCaptureProtocol.wav(pcm)
                let segment = WatchAudioSegment(id: draft.id, sequence: draft.sequence, offsetMilliseconds: draft.offsetMilliseconds,
                    frameCount: pcm.count / 2, byteCount: wav.count, sha256: WatchCaptureProtocol.hash(wav))
                try wav.write(to: file(segment), options: .atomic)
                try mutate { s in
                    let i = s.recordings.firstIndex { $0.id == id }!
                    s.recordings[i].segments.append(segment); s.recordings[i].draft = nil
                }
            } else { try mutate { s in s.recordings[s.recordings.firstIndex { $0.id == id }!].draft = nil } }
            // A failed deletion is safe; the manifest is already committed.
            try? FileManager.default.removeItem(at: path)
        }
    }
    func event(_ id: UUID, _ event: WatchCaptureEvent) throws {
        try synchronized {
            try event.validate(); let r = try record(id)
            if let old = r.events.first(where: { $0.id == event.id }) { guard old == event else { throw WatchCaptureError.conflict }; return }
            guard r.ended == nil else { throw WatchCaptureError.conflict }
            try mutate { s in s.recordings[s.recordings.firstIndex { $0.id == id }!].events.append(event) }
        }
    }
    @discardableResult
    func toggleFocus(_ id: UUID, offset: Int) throws -> Int? {
        try synchronized {
            let r = try record(id)
            guard r.ended == nil else { throw WatchCaptureError.noRecording }
            if r.focusDraft != nil { try closeFocus(id, offset: offset); return nil }
            try mutate { s in s.recordings[s.recordings.firstIndex { $0.id == id }!].focusDraft = .init(id: UUID(), startMilliseconds: offset) }
            return offset
        }
    }
    func closeFocus(_ id: UUID, offset: Int) throws {
        try synchronized {
            guard let focus = try record(id).focusDraft else { return }
            try mutate { s in
                let i = s.recordings.firstIndex { $0.id == id }!
                if offset > focus.startMilliseconds {
                    s.recordings[i].events.append(.init(id: focus.id, kind: .focus,
                        offsetMilliseconds: focus.startMilliseconds, endMilliseconds: offset, finalSegmentCount: nil, reason: nil))
                }
                s.recordings[i].focusDraft = nil
            }
        }
    }
    func end(_ id: UUID, offset: Int) throws {
        try synchronized {
            if try record(id).ended != nil { return }
            try seal(id)
            try closeFocus(id, offset: offset)
            try event(id, .init(id: UUID(), kind: .ended, offsetMilliseconds: offset, endMilliseconds: nil,
                finalSegmentCount: try record(id).segments.count, reason: nil))
        }
    }
    /// Both methods are safe against out-of-order file and event delivery.
    func receive(_ envelope: WatchFileEnvelope, temporaryFile: URL) throws -> WatchCaptureReceipt {
        try synchronized {
            try envelope.recording.validate()
            guard !state.recordings.contains(where: { $0.id != envelope.recording.id && $0.segments.contains(where: { $0.id == envelope.segment.id }) })
            else { throw WatchCaptureError.conflict }
            let data = try Data(contentsOf: temporaryFile, options: .mappedIfSafe)
            try WatchCaptureProtocol.validate(data, segment: envelope.segment)
            try ensure(envelope.recording)
            let r = try record(envelope.recording.id)
            if let old = r.segments.first(where: { $0.id == envelope.segment.id || $0.sequence == envelope.segment.sequence }) {
                guard old == envelope.segment else { throw WatchCaptureError.conflict }
                // A repeated delivery repairs a missing receiver-side file before
                // another acknowledgement is sent.
                if !FileManager.default.fileExists(atPath: file(old).path) {
                    try data.write(to: file(old), options: .atomic)
                } else if try Data(contentsOf: file(old)) != data { throw WatchCaptureError.conflict }
            } else {
                if let count = r.ended?.finalSegmentCount, envelope.segment.sequence >= count { throw WatchCaptureError.conflict }
                let destination = file(envelope.segment)
                if FileManager.default.fileExists(atPath: destination.path), try Data(contentsOf: destination) != data { throw WatchCaptureError.conflict }
                try data.write(to: destination, options: .atomic)
                try mutate { s in s.recordings[s.recordings.firstIndex { $0.id == r.id }!].segments.append(envelope.segment) }
            }
            return .init(recordingID: r.id, itemID: envelope.segment.id, sha256: envelope.segment.sha256)
        }
    }
    func receive(_ envelope: WatchEventEnvelope) throws -> WatchCaptureReceipt {
        try synchronized {
            try envelope.recording.validate(); try envelope.event.validate(); try ensure(envelope.recording)
            let r = try record(envelope.recording.id), event = envelope.event
            if let old = r.events.first(where: { $0.id == event.id }) { guard old == event else { throw WatchCaptureError.conflict } }
            else {
                if event.kind == .ended {
                    guard r.ended == nil, r.segments.allSatisfy({ $0.sequence < event.finalSegmentCount! }) else { throw WatchCaptureError.conflict }
                }
                try mutate { s in s.recordings[s.recordings.firstIndex { $0.id == r.id }!].events.append(event) }
            }
            return .init(recordingID: r.id, itemID: event.id, sha256: WatchCaptureProtocol.hash(try WatchCaptureProtocol.encode(envelope)))
        }
    }
    private func ensure(_ header: WatchRecordingHeader) throws {
        if let old = state.recordings.first(where: { $0.id == header.id }) {
            guard old.header == header else { throw WatchCaptureError.conflict }
        } else { try mutate { $0.recordings.append(Record(header: header)) } }
    }
    func acknowledge(_ receipt: WatchCaptureReceipt) throws {
        try synchronized {
            let r = try record(receipt.recordingID)
            let digest = r.segments.first(where: { $0.id == receipt.itemID })?.sha256
                ?? r.events.first(where: { $0.id == receipt.itemID }).flatMap { try? WatchCaptureProtocol.hash(WatchCaptureProtocol.encode(WatchEventEnvelope(recording: r.header, event: $0))) }
            guard digest == receipt.sha256 else { throw WatchCaptureError.conflict }
            if r.receipts.contains(where: { $0.itemID == receipt.itemID }) { return }
            try mutate { s in s.recordings[s.recordings.firstIndex { $0.id == r.id }!].receipts.append(receipt) }
        }
    }
    func grant(_ id: UUID, _ grant: CloudGrant) throws {
        try synchronized {
            let r = try record(id)
            guard r.header.bindingID == nil || r.header.bindingID == grant.bindingID,
                  r.cloudGrant == nil || r.cloudGrant == grant else { throw WatchCaptureError.conflict }
            try mutate { s in s.recordings[s.recordings.firstIndex { $0.id == id }!].cloudGrant = grant }
        }
    }
    func cloudAccepted(_ id: UUID, key: String) throws {
        try synchronized {
            let r = try record(id)
            guard r.segments.contains(where: { $0.id.uuidString.lowercased() == key }) || r.events.contains(where: { $0.id.uuidString.lowercased() == key })
            else { throw WatchCaptureError.conflict }
            try mutate { s in s.recordings[s.recordings.firstIndex { $0.id == id }!].cloudAccepted.insert(key) }
        }
    }

    /// Commit the remote proof before deleting anything. A crash at either side
    /// of deletion is recoverable by calling this again with the same proof.
    func releasePhoneAudio(_ receipt: WatchCloudAudioReceipt, target: WatchCloudStorageTarget) throws {
        try synchronized {
            guard allowsCloudEviction else { throw WatchCaptureError.conflict }
            let r = try record(receipt.recordingID)
            guard let segment = r.segments.first(where: { $0.id == receipt.segmentID }),
                  r.cloudGrant?.bindingID == target.bindingID, r.cloudGrant?.serviceURL == target.serviceURL,
                  r.cloudAccepted.contains(segment.id.uuidString.lowercased()),
                  receipt.matches(recording: r.id, segment: segment, target: target)
            else { throw WatchCaptureError.conflict }
            let path = file(segment)
            if FileManager.default.fileExists(atPath: path.path) {
                try WatchCaptureProtocol.validate(Data(contentsOf: path), segment: segment)
            }
            if let old = r.cloudAudioReceipts?.first(where: { $0.segmentID == segment.id }) {
                guard old == receipt else { throw WatchCaptureError.conflict }
            } else {
                try mutate { s in
                    let i = s.recordings.firstIndex { $0.id == r.id }!
                    s.recordings[i].cloudAudioReceipts = (s.recordings[i].cloudAudioReceipts ?? []) + [receipt]
                }
            }
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
            try removeAcceptedUpload(r.id, key: segment.id.uuidString.lowercased())
        }
    }

    /// Control envelopes are derivable from the journal; audio envelopes may be
    /// removed only after a verified cloud proof has been durably recorded.
    func removeAcceptedUpload(_ id: UUID, key: String) throws {
        try synchronized {
            guard allowsCloudEviction else { throw WatchCaptureError.conflict }
            let r = try record(id)
            guard r.cloudAccepted.contains(key) else { throw WatchCaptureError.conflict }
            if let segment = r.segments.first(where: { $0.id.uuidString.lowercased() == key }) {
                guard r.cloudAudioReceipts?.contains(where: { $0.segmentID == segment.id && $0.sha256 == segment.sha256 }) == true
                else { throw WatchCaptureError.conflict }
            } else {
                guard r.events.contains(where: { $0.id.uuidString.lowercased() == key }) else { throw WatchCaptureError.conflict }
            }
            let url = root.appendingPathComponent(key + ".upload.json")
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    func localStorageBytes() -> Int64 {
        synchronized {
            let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return urls.filter { $0.pathExtension == "wav" || $0.lastPathComponent.hasSuffix(".upload.json") }
                .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
    }
}
