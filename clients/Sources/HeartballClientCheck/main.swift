// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import LuyinbiCore

// Uses the same native client as the UI; default is read-only. Focus smoke needs
// an explicitly supplied runtime and active test session, never starts hardware.
let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("Usage: HeartballClientCheck runtime.json [--focus-smoke]") }
let client = try HeartballClient(runtimeFile: URL(fileURLWithPath: args[1]))
let state = try await client.state()
if args.contains("--agent-check") {
    let agent = try await client.agentState()
    if let batchID = agent.documents.flatMap(\.evidence).compactMap(\.batchId).first {
        let audio = try await client.audio(batchID: batchID)
        guard String(data: audio.prefix(4), encoding: .ascii) == "RIFF" else { fatalError("Audio evidence is not decoded WAV") }
        print("Native agent API decoded; documents=\(agent.documents.count), claims=\(agent.claims.count), answers=\(agent.answers.count); original audio WAV validated.")
    } else {
        print("Native agent API decoded; no audio document yet.")
    }
} else if args.contains("--focus-smoke") {
    guard let session = state.session, session.status == "recording" else { fatalError("No active dedicated test capture") }
    let id = UUID()
    _ = try await client.startFocus(id: id, sessionID: session.id)
    try await Task.sleep(for: .seconds(3))
    let closed = try await client.endFocus(id: id.uuidString.lowercased())
    let retry = try await client.endFocus(id: id.uuidString.lowercased())
    guard closed.focuses.count == retry.focuses.count, retry.session?.status == "recording" else {
        fatalError("Focus closure/retry changed capture or duplicated a focus")
    }
    print("Native focus start/end/retry passed; continuous capture still recording. Focus actions sent no hardware command.")
} else {
    print("Native local API decoded; session=\(state.session?.status ?? "none"), focuses=\(state.focuses.count), ASR=\(state.asrEnabled)")
}
