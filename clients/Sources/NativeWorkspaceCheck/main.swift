// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import LuyinbiCore

// Read-only native integration assertion. Never connects to BLE or changes data.
guard CommandLine.arguments.count == 2 else { fatalError("Usage: NativeWorkspaceCheck connection.json") }
struct Connection: Decodable { let baseURL: URL; let token: String }
let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let client = try HeartballClient(baseURL: connection.baseURL, token: connection.token, allowPrivateHTTP: true)
let state = try await client.agentState()
guard let answer = state.answers.first(where: { $0.status == "ready" && $0.answer.contains("Thursday") }),
      !answer.refs.isEmpty, state.documents.contains(where: { $0.status != "superseded" && $0.text.contains("Thursday") }),
      (state.today?.unknownTimeCount ?? -1) == 0 else {
    fatalError("Native readback did not find source-linked corrected fixture results")
}
print("Native Mac client decoded the iPhone-created event, corrected source, recorded day and cited answer. Synthetic fixture; no hardware/model quality claim.")
