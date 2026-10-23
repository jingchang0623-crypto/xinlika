// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

public enum RecorderState: UInt8, Sendable {
    case recording = 1, idle = 2, paused = 3
}

public enum RecorderAction: Sendable {
    case start, save, resume

    public var request: UInt8 {
        switch self {
        case .start: return Proto.AudioCmd.start
        case .save: return Proto.AudioCmd.stop
        case .resume: return Proto.AudioCmd.pauseResume
        }
    }
    public var parameters: [UInt8] { self == .resume ? [0] : [] }
    public func frame(sequence: UInt8) -> [UInt8] {
        Proto.buildFrame(Proto.T.audio, request, parameters, seq: sequence)
    }
    public var expectedState: RecorderState { self == .save ? .idle : .recording }

    public func canSend(in state: RecorderState) -> Bool {
        switch self {
        case .start: return state == .idle
        case .save: return state != .idle
        case .resume: return state == .paused
        }
    }
}

public enum RecordingControlError: Error, LocalizedError, Equatable {
    case busy, stateUnknown, unconfirmed
    public var errorDescription: String? {
        switch self {
        case .busy: return "正在读取设备，请稍后重试"
        case .stateUnknown: return "未能确认录音状态，请靠近设备后刷新"
        case .unconfirmed: return "操作结果未确认，请刷新状态或查看录音卡"
        }
    }
}

public struct RecorderReading: Equatable, Sendable {
    public let state: RecorderState
    public let seconds: Int?
    public let confirmedAt: Date

    public func isFresh(at date: Date) -> Bool {
        (0...12).contains(date.timeIntervalSince(confirmedAt))
    }

    public static func decodeTime(_ body: [UInt8]) -> (seconds: Int, bytes: UInt32)? {
        guard body.count >= 6 else { return nil }
        return (Int(body[0]) | Int(body[1]) << 8,
                UInt32(body[2]) | UInt32(body[3]) << 8 | UInt32(body[4]) << 16 | UInt32(body[5]) << 24)
    }
}

/// The caller serializes recording requests; a file stream may run alongside read-only queries.
/// Actions are sent once, after a fresh state check, and are always followed by a readback.
public enum RecordingControl {
    /// Queries use TYPE=3; mutations use the physically verified TYPE=1 commands.
    public typealias Exchange = (UInt8, UInt8) async throws -> [UInt8]?
    public typealias Send = (RecorderAction) async throws -> Void

    public struct ConfirmationPolicy {
        public var attempts: Int
        public var interval: Duration
        public init(attempts: Int = 24, interval: Duration = .milliseconds(500)) {
            self.attempts = max(1, min(24, attempts))
            self.interval = interval
        }
    }

    public static func read(includeTime: Bool = true, exchange: Exchange) async throws -> RecorderReading {
        try Task.checkCancellation()
        guard let body = try await exchange(Proto.KeyCmd.statusReq, Proto.KeyCmd.statusAck),
              let raw = body.first, let state = RecorderState(rawValue: raw) else {
            throw RecordingControlError.stateUnknown
        }
        let confirmedAt = Date()
        var seconds: Int?
        if includeTime, state != .idle {
            if let body = try? await exchange(Proto.KeyCmd.timeReq, Proto.KeyCmd.timeAck) {
                seconds = RecorderReading.decodeTime(body)?.seconds
            }
        }
        try Task.checkCancellation()
        return RecorderReading(state: state, seconds: seconds, confirmedAt: confirmedAt)
    }

    public struct Result: Sendable {
        public let reading: RecorderReading
        public let message: String?
        public let saved: Bool
    }

    public static func perform(_ action: RecorderAction, policy: ConfirmationPolicy = .init(),
                               send: Send, exchange: Exchange) async throws -> Result {
        let before = try await read(includeTime: false, exchange: exchange)
        guard action.canSend(in: before.state) else {
            return Result(reading: before,
                          message: before.state == action.expectedState ? nil : "录音状态已变化，请重新选择操作",
                          saved: false)
        }
        try Task.checkCancellation()
        // TYPE=1 start returns a filename, while stop may return no ACK at all.
        // Neither is a success boolean. Send once and confirm with TYPE=3 state.
        do { try await send(action) }
        catch is CancellationError { throw CancellationError() }
        catch { throw RecordingControlError.unconfirmed }
        try Task.checkCancellation()
        // Read-only polling allows flash finalization without retransmitting a mutation.
        let deadline = ContinuousClock.now.advanced(by: .seconds(action == .save ? 12 : 6))
        var after: RecorderReading?
        for attempt in 0..<policy.attempts {
            if attempt > 0 {
                guard ContinuousClock.now < deadline else { break }
                try await Task.sleep(for: policy.interval)
                guard ContinuousClock.now < deadline else { break }
            }
            do { after = try await read(includeTime: false, exchange: exchange) }
            catch is CancellationError { throw CancellationError() }
            catch RecordingControlError.stateUnknown { after = nil; continue }
            catch { throw RecordingControlError.unconfirmed }
            if after?.state == action.expectedState { break }
        }
        guard var after else { throw RecordingControlError.unconfirmed }
        let confirmed = after.state == action.expectedState
        if confirmed, after.state != .idle,
           let body = try? await exchange(Proto.KeyCmd.timeReq, Proto.KeyCmd.timeAck) {
            after = RecorderReading(state: after.state, seconds: RecorderReading.decodeTime(body)?.seconds,
                                    confirmedAt: after.confirmedAt)
        }
        try Task.checkCancellation()
        return Result(reading: after,
                      message: confirmed ? nil : "录音卡未执行操作，请使用机身按键",
                      saved: action == .save && confirmed)
    }
}

/// Only small control fields may enter diagnostics. Audio, filenames and device identifiers
/// are deliberately excluded even if a caller hands this initializer an unrelated frame.
public struct RecordingDiagnosticEvent: Sendable {
    public let phase: String
    public let source: String
    public let sequence: UInt8
    public let type: UInt8
    public let command: UInt8?
    public let body: [UInt8]

    public init?(phase: String, source: String, frame: Proto.Frame) {
        guard ["tx", "rx", "timeout"].contains(phase), ["AE21", "AE22", "AE23"].contains(source),
              let type = frame.type else { return nil }
        let safeBody: [UInt8]
        if type == Proto.T.key {
            guard frame.cmd.map({ [1, 2, 3, 4, 5, 6, 7, 8, 19, 20, 21, 22].contains($0) }) ?? true else { return nil }
            safeBody = Array(frame.body.prefix(6))
        } else if type == Proto.T.audio, let cmd = frame.cmd, [0, 2, 3, 4].contains(cmd) {
            // 1-0 RX contains a filename: keep only command metadata, never its bytes.
            safeBody = (cmd == 3 && phase == "tx") || cmd == 4 ? Array(frame.body.prefix(1)) : []
        } else { return nil }
        self.phase = phase
        self.source = source
        self.sequence = frame.seq
        self.type = type
        self.command = frame.cmd
        self.body = safeBody
    }
}

/// This app records on the card and imports files later. Live OPUS notifications must
/// not accumulate in memory while the foreground monitor only consumes status replies.
public enum RecordingFramePolicy {
    public static func isLiveAudio(_ frame: Proto.Frame) -> Bool {
        frame.type == Proto.T.audio && frame.cmd == Proto.AudioCmd.data
    }
}

/// Firmware-specific attach, verified separately from recording start/resume.
/// Unrecognized hardware must keep recording and use saved-card repair instead.
public enum LiveStreamAttachPolicy {
    public static func permits(recorderName: String, firmware: String?, state: UInt8?,
                               ownedFile: String, currentFile: String?, quietSeconds: Double,
                               notifications: [String: Bool]) -> Bool {
        func key(_ s: String) -> String { s.lowercased().split(separator: ".").first.map(String.init) ?? s }
        let version = firmware?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recorderName.lowercased().contains("cb08") && ["v1.0.0", "1.0.0"].contains(version ?? "") &&
            state == 1 && !ownedFile.isEmpty && currentFile.map { key($0) == key(ownedFile) } == true &&
            quietSeconds >= 10 && notifications["AE22"] == true && notifications["AE23"] == true
    }
}

/// A separate reply slot prevents file downloads from consuming recording query responses.
/// Tokens keep an old cancelled request from clearing a newer request after reconnection.
final class RecordingReplySlot: @unchecked Sendable {
    private let lock = NSLock()
    private var active: (token: UUID, command: UInt8, frame: Proto.Frame?)?

    func begin(command: UInt8) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { throw RecordingControlError.busy }
        let token = UUID()
        active = (token, command, nil)
        return token
    }
    func receive(_ frame: Proto.Frame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard frame.type == Proto.T.key, let current = active, frame.cmd == current.command else { return false }
        if current.frame == nil { active = (current.token, current.command, frame) }
        return true
    }
    func reply(for token: UUID) -> Proto.Frame? {
        lock.lock(); defer { lock.unlock() }
        return active?.token == token ? active?.frame : nil
    }
    func end(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if active?.token == token { active = nil }
    }
}
