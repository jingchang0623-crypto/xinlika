// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

/// A logical capture session groups minute storage batches; focus ranges remain separate.
public struct HeartballRecordCollection: Identifiable, Sendable {
    public let id: String
    public let documents: [HeartballAgentState.Document]
    public let focuses: [HeartballAgentState.Document]
    public var representative: HeartballAgentState.Document {
        documents.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? documents[0]
    }
    public var title: String { representative.title }
    public var isFocus: Bool { id.hasPrefix("focus:") }

    public static func make(_ input: [HeartballAgentState.Document], focusOnly: Bool) -> [Self] {
        let documents = input.filter { $0.status != "superseded" }
        if focusOnly {
            return documents.filter { $0.kind == "focus" }.map {
                Self(id: "focus:" + $0.id, documents: [$0], focuses: [])
            }
        }
        // A minute batch is storage, not a new conversation. Missing identities
        // stay independent rather than being combined under a shared nil key.
        var keys: [String] = []
        var grouped: [String: [HeartballAgentState.Document]] = [:]
        for document in documents {
            let sessionID = document.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "session:" + ((sessionID?.isEmpty == false ? sessionID : nil) ?? document.id)
            if grouped[key] == nil { keys.append(key) }
            grouped[key, default: []].append(document)
        }
        return keys.compactMap { key in
            guard let all = grouped[key], !all.isEmpty else { return nil }
            let ambient = all.filter { $0.kind != "focus" }
            return Self(id: key, documents: ambient.isEmpty ? all : ambient, focuses: all.filter { $0.kind == "focus" })
        }
    }
}
