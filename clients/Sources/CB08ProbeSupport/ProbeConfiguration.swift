// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import LuyinbiCore

public enum ProbeError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let text): return text } }
}

public struct ProbeConfiguration: Sendable {
    public enum Mode: String, Sendable { case scan, capture, reference, catalog }
    public enum Recovery: String, Sendable { case passive, resume, start }
    public var mode: Mode
    public var deviceID: UUID?
    public var filename: String?
    public var output: URL
    public var seconds: Double = 90
    public var disconnectAt: Double?
    public var disconnectFor: Double = 3
    public var recovery: Recovery = .passive
    public var startIfIdle = false
    public var syncClockBeforeStart = false
    public var stopOwnedAtEnd = false
    public var observeButtons = false
    public var buttonResponse: RecorderButtonHandshake.Mode?
    public var appState: String?
    public var appStateFile: URL?

    public init(arguments: [String], outputRoot: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws {
        guard let first = arguments.first, let mode = Mode(rawValue: first) else {
            throw ProbeError.invalid("命令必须是 scan、capture、reference 或 catalog；使用 --help 查看用法")
        }
        self.mode = mode
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        output = outputRoot.appendingPathComponent(".build/cb08-captures/\(stamp)-\(UUID().uuidString.prefix(8))")
        var i = 1
        var seen: Set<String> = []
        while i < arguments.count {
            let key = arguments[i]
            guard seen.insert(key).inserted else { throw ProbeError.invalid("重复参数：\(key)") }
            if key == "--start-if-idle" { startIfIdle = true; i += 1; continue }
            if key == "--sync-clock-before-start" { syncClockBeforeStart = true; i += 1; continue }
            if key == "--stop-owned-at-end" { stopOwnedAtEnd = true; i += 1; continue }
            if key == "--observe-buttons" { observeButtons = true; i += 1; continue }
            guard i + 1 < arguments.count else { throw ProbeError.invalid("参数缺值：\(key)") }
            let value = arguments[i + 1]
            func number() throws -> Double {
                guard let n = Double(value), n.isFinite, n > 0 else { throw ProbeError.invalid("\(key) 必须为有限正数") }
                return n
            }
            switch key {
            case "--button-response":
                guard let mode = RecorderButtonHandshake.Mode(rawValue: value) else {
                    throw ProbeError.invalid("button-response 只能是 vendor/reject-save/reject-save-zero/resume-on-save")
                }
                buttonResponse = mode
            case "--app-state":
                guard RecorderButtonHandshake.appStateParameters(value) != nil else {
                    throw ProbeError.invalid("app-state 只能是 foreground/background")
                }
                appState = value
            case "--app-state-file": appStateFile = URL(fileURLWithPath: value, relativeTo: outputRoot).standardizedFileURL
            case "--device":
                guard let id = UUID(uuidString: value) else { throw ProbeError.invalid("设备必须为扫描输出的 UUID") }
                deviceID = id
            case "--filename":
                guard value.utf8.count <= 24, value.range(of: #"^[A-Za-z0-9_-]+\.opus$"#, options: .regularExpression) != nil else {
                    throw ProbeError.invalid("reference 文件名须为不超过 24 字节的普通 .opus 文件名")
                }
                filename = value
            case "--output": output = URL(fileURLWithPath: value, relativeTo: outputRoot).standardizedFileURL
            case "--seconds": seconds = try number()
            case "--disconnect-at": disconnectAt = try number()
            case "--disconnect-for": disconnectFor = try number()
            case "--recovery":
                guard let strategy = Recovery(rawValue: value) else { throw ProbeError.invalid("recovery 只能是 passive/resume/start") }
                recovery = strategy
            default: throw ProbeError.invalid("未知参数：\(key)")
            }
            i += 2
        }
        guard seconds <= 86400, disconnectFor <= 300 else { throw ProbeError.invalid("单次实验最多 24 小时，计划断开最多 300 秒") }
        if mode == .scan {
            guard seen.isSubset(of: ["--seconds"]) else { throw ProbeError.invalid("scan 仅接收 --seconds") }
            if !seen.contains("--seconds") { seconds = 8 }
            guard seconds <= 30 else { throw ProbeError.invalid("扫描最多 30 秒") }
        } else if mode == .catalog {
            guard deviceID != nil, seen.isSubset(of: ["--device", "--output"]) else {
                throw ProbeError.invalid("catalog 需要 --device UUID，可选 --output 新目录；不接受录音控制参数")
            }
        } else if mode == .reference {
            guard deviceID != nil, filename != nil,
                  seen.isSubset(of: ["--device", "--filename", "--output"]) else {
                throw ProbeError.invalid("reference 需要 --device UUID --filename name.opus，可选 --output 新目录")
            }
        } else {
            if syncClockBeforeStart && !startIfIdle {
                throw ProbeError.invalid("校时仅允许在 --start-if-idle 创建新录音前执行")
            }
            if buttonResponse != nil {
                guard observeButtons, appState != nil else {
                    throw ProbeError.invalid("按键回应实验须显式指定 --observe-buttons 和 --app-state")
                }
                guard disconnectAt == nil, recovery == .passive else {
                    throw ProbeError.invalid("按键握手与计划断连实验须分开")
                }
            }
            if appStateFile != nil && appState == nil { throw ProbeError.invalid("app-state-file 需要初始 --app-state") }
            if appState != nil && !observeButtons { throw ProbeError.invalid("前后台握手实验需要 --observe-buttons") }
            guard filename == nil else { throw ProbeError.invalid("capture 不接收 --filename") }
            guard deviceID != nil else { throw ProbeError.invalid("capture 必须显式指定 --device UUID") }
            if let at = disconnectAt {
                guard at + disconnectFor + 25 < seconds else {
                    throw ProbeError.invalid("断连后至少预留 25 秒观察时间")
                }
            }
            if recovery != .passive {
                guard startIfIdle, disconnectAt != nil else {
                    throw ProbeError.invalid("重发控制命令仅用于 --start-if-idle 创建的测试录音，并须设置 --disconnect-at")
                }
            }
        }
    }
}

public struct ProbeSnapshot: Codable, Equatable, Sendable {
    public let uptime: Double
    public let state: UInt8?
    public let filename: String?
    public let seconds: Int?
    public let bytes: UInt32?
    public init(uptime: Double, state: UInt8?, filename: String?, seconds: Int?, bytes: UInt32?) {
        self.uptime = uptime; self.state = state; self.filename = filename
        self.seconds = seconds; self.bytes = bytes
    }
    public var fileKey: String? { Self.fileKey(filename) }
    public static func fileKey(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let stem = name.lowercased().split(separator: ".", maxSplits: 1).first.map(String.init)
        return stem?.isEmpty == false ? stem : nil
    }
    public func sameFile(as other: Self) -> Bool { fileKey != nil && fileKey == other.fileKey }
}

public enum ProbePolicy {
    public static func maySyncClock(startIfIdle: Bool, state: UInt8?) -> Bool {
        startIfIdle && state == 2
    }

    /// No retry/control mutation is allowed on a recording merely discovered already running.
    public static func mayRearm(ownedFile: String?, before: ProbeSnapshot, current: ProbeSnapshot) -> Bool {
        guard let owned = ProbeSnapshot.fileKey(ownedFile) else { return false }
        return before.state == 1 && current.state == 1 && before.fileKey == owned && current.fileKey == owned
    }

    /// This is delivery evidence, deliberately NOT a claim of sample continuity or audio validity.
    public static func recoveryEvidence(before: ProbeSnapshot, after: ProbeSnapshot, audioFrames: Int) -> String {
        guard before.state != nil, after.state != nil, before.fileKey != nil, after.fileKey != nil else { return "inconclusive_missing_identity_or_state" }
        guard before.sameFile(as: after) else { return "different_file_not_same_stream" }
        guard before.state == 1, after.state == 1 else { return "inconclusive_not_recording" }
        guard let a = before.bytes, let b = after.bytes, let sa = before.seconds, let sb = after.seconds,
              b >= a, sb >= sa, b > a || sb > sa else { return "inconclusive_counter_not_advancing" }
        return audioFrames > 0 ? "same_file_live_delivery_observed_decode_and_reference_required" : "same_file_card_advancing_no_live_delivery_in_window"
    }
}
