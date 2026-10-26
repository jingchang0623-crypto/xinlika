#if DEBUG
import Foundation

/// In-memory hardware only. The real protocol decisions and AppModel task arbitration still run.
@MainActor
final class RecorderSimulation {
    let scenario: String
    private(set) var commands: [UInt8] = []
    private(set) var actions: [RecorderAction] = []
    let filename = "note20260907-131301.opus"
    private(set) var files: [FileEntry] = []
    private var state: RecorderState
    private var reads = 0
    private var didMutate = false
    init(scenario: String) {
        self.scenario = scenario
        state = scenario == "recording" || scenario == "physical-stop" ? .recording : scenario == "paused" ? .paused : .idle
        if scenario == "catalog-short" {
            files = [FileEntry(time: 22, size: 44000, name: "note20260907-131301.", rawName: [])]
        }
    }
    func connect() throws {
        if scenario == "disconnected" { throw BLEError.notConnected }
    }
    func exchange(_ command: UInt8, _ reply: UInt8) async throws -> [UInt8]? {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(80))
        commands.append(command)
        if command == Proto.KeyCmd.statusReq {
            reads += 1
            if scenario == "unknown" || (scenario == "readback-unknown" && didMutate) { return nil }
            if scenario == "physical-start", reads >= 2 { state = .recording }
            if scenario == "physical-stop", reads >= 2 { state = .idle }
            return [state.rawValue]
        }
        if command == Proto.KeyCmd.timeReq { return [0x30, 0x2A, 0, 0, 0, 0] } // 3 hours
        return nil
    }
    func send(_ action: RecorderAction) async throws {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(80))
        actions.append(action)
        if scenario == "rejected" { return }
        didMutate = true
        if action == .save, state != .idle {
            files = [FileEntry(time: 22, size: 44000, name: "note20260907-131301.", rawName: [])]
        }
        state = action.expectedState
    }
}
#endif
