// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

/// Opt-in session policy shared by the hardware experiment and future native clients.
/// A response authorizes a device operation; it is never confirmation that it occurred.
public final class RecorderButtonHandshake: @unchecked Sendable {
    public enum Mode: String, Sendable {
        case vendor, rejectSave = "reject-save"
        // Explicit experiment only: zero is NOT a documented SDK response value.
        case rejectSaveZero = "reject-save-zero"
        // Dedicated test: try a known resume command while save is still pending.
        // It is not a save ACK, and must never become a restart after confirmed stop.
        case resumeOnSave = "resume-on-save"
    }
    public struct Response: Sendable {
        public let type: UInt8
        public let command: UInt8
        public let result: UInt8
        public let kind: String
        public let requestUptime: Double
        public let filename: String?
        public var isFocusCandidate: Bool { (type == 3 && command == 4 && result != 1) || (type == 1 && command == 3) }
    }
    private let lock = NSLock()
    private let mode: Mode
    private var connection: UUID?
    private var enabled = false
    private var baseline: Set<String> = []
    private var owned: Set<String> = []
    private var state: UInt8?
    private var filename: String?
    private var checkedAt: Double = -.infinity
    private var pending: UInt8?
    private var awaitingNewFile = false

    public init(mode: Mode) { self.mode = mode }
    private func key(_ name: String?) -> String? {
        guard let s = name?.lowercased().split(separator: ".", maxSplits: 1).first, !s.isEmpty else { return nil }
        return String(s)
    }
    public func connected(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard connection != id else { return }
        connection = id; state = nil; filename = nil; checkedAt = -.infinity
    }
    public func disconnected() {
        lock.lock(); defer { lock.unlock() }
        connection = nil; state = nil; filename = nil; checkedAt = -.infinity
    }
    public func disable() {
        lock.lock(); defer { lock.unlock() }
        enabled = false
    }
    /// Call only after fresh idle + complete catalogue, before prompting the operator.
    public func armFromIdle(baselineNames: [String], at uptime: Double) {
        lock.lock(); defer { lock.unlock() }
        baseline = Set(baselineNames.compactMap { key($0) })
        owned = []; state = 2; filename = nil; checkedAt = uptime
        pending = nil; awaitingNewFile = false; enabled = true
    }
    /// Separate explicit permission for an App-created dedicated test file.
    public func claimAppCreatedFile(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let k = key(name), !baseline.contains(k) else { return }
        owned.insert(k)
    }
    public func update(state newState: UInt8?, filename newName: String?, at uptime: Double) {
        lock.lock(); defer { lock.unlock() }
        state = newState; filename = newName; checkedAt = uptime
        if awaitingNewFile, newState == 1, let k = key(newName), !baseline.contains(k), !owned.contains(k) {
            owned.insert(k); awaitingNewFile = false; pending = nil
        }
        if pending == 3 && newState == 2 { pending = nil }
        if pending == 5 && newState == 3 { pending = nil }
        if pending == 7 && newState == 1 { pending = nil }
    }
    public func response(connection id: UUID, source: String, frame: Proto.Frame,
                         at uptime: Double) -> Response? {
        lock.lock(); defer { lock.unlock() }
        // Only physical-key notification frames observed on this device, not AE22
        // query responses, unknown payloads, stale connections or inherited recordings.
        guard enabled, connection == id, source == "AE23", frame.type == 3,
              frame.body.isEmpty, let cmd = frame.cmd, [1, 3, 5, 7].contains(cmd),
              uptime >= checkedAt, uptime - checkedAt <= 12, pending == nil else { return nil }
        let currentOwned = key(filename).map { owned.contains($0) } ?? false
        switch cmd {
        case 1: guard state == 2 else { return nil }
        case 3, 5: guard state == 1, currentOwned else { return nil }
        case 7: guard state == 3, currentOwned else { return nil }
        default: return nil
        }
        let rejecting = mode != .vendor && cmd == 3
        if !rejecting { pending = cmd }
        if cmd == 1 { awaitingNewFile = true }
        let result: UInt8 = rejecting ? (mode == .rejectSaveZero ? 0 : 2) : 1
        let resumeExperiment = mode == .resumeOnSave && cmd == 3
        return Response(type: resumeExperiment ? 1 : 3,
                        command: resumeExperiment ? 3 : cmd + 1, result: resumeExperiment ? 0 : result,
                        kind: [1: "start", 3: "save", 5: "pause", 7: "resume"][Int(cmd)]!,
                        requestUptime: uptime, filename: filename)
    }

    /// SDK construction: TYPE=0/CMD=18, 1 foreground / 2 background.
    /// This is a protocol announcement, not proof of actual iOS background execution.
    public static func appStateParameters(_ state: String) -> [UInt8]? {
        switch state { case "foreground": return [1]; case "background": return [2]; default: return nil }
    }
}
