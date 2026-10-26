// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import Observation

/// Durable explicit intent, separate from the audio queue. Retries reuse the same
/// receipt ID, and later intent for one event cannot pass its unresolved conflict.
@MainActor @Observable
final class XinlikaInterestQueue {
    struct Change: Codable, Identifiable, Equatable {
        var id: String
        var server: String
        var eventID: String
        var eventVersion: Int
        var interestVersion: Int
        var value: String
        var status = "pending"
        var receiptVersion: Int?
        var errorCode: Int?
    }
    private(set) var changes: [Change]
    private(set) var sendingID: String?
    private(set) var errorMessage: String?
    private let file: URL
    @ObservationIgnored private var worker: Task<Void, Never>?
    init(file: URL) throws {
        self.file = file
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        changes = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode([Change].self, from: Data(contentsOf: file)) : []
    }
    private func persist() throws {
        try JSONEncoder().encode(changes).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func localValue(eventID: String, eventVersion: Int, version: Int, server: String) -> String? {
        changes.last { $0.server == server && $0.eventID == eventID && $0.eventVersion == eventVersion && $0.status != "blocked" && ($0.status != "accepted" || ($0.receiptVersion ?? 0) > version) }?.value
    }
    func pending(eventID: String, server: String) -> Bool { changes.contains { $0.server == server && $0.eventID == eventID && $0.status != "accepted" } }
    func blocked(eventID: String, server: String) -> Bool { changes.contains { $0.server == server && $0.eventID == eventID && $0.status == "blocked" } }
    func notice(server: String) -> String? {
        if let item = changes.first(where: { $0.server == server && $0.status == "blocked" }) {
            return item.errorCode == 409 ? "事项或偏好已更新，请刷新后重新标记" : "部分标记未同步，请检查服务后重新标记"
        }
        return errorMessage
    }
    func isSending(eventID: String, server: String) -> Bool { changes.contains { $0.id == sendingID && $0.server == server && $0.eventID == eventID } }
    @discardableResult
    func enqueue(eventID: String, eventVersion: Int, interestVersion: Int, value: String, server: String) throws -> String {
        guard ["important","unimportant","neutral"].contains(value) else { throw URLError(.badURL) }
        let before = changes
        // A new explicit action after refresh resolves this event's rejected intents.
        if changes.contains(where: { $0.server == server && $0.eventID == eventID && $0.status == "blocked" }) {
            changes.removeAll { $0.server == server && $0.eventID == eventID && $0.status != "accepted" }
        }
        let previous = changes.last { $0.server == server && $0.eventID == eventID }
        let nextVersion = max(interestVersion, previous.map { $0.receiptVersion ?? ($0.interestVersion + 1) } ?? 0)
        let item = Change(id: UUID().uuidString.lowercased(), server: server, eventID: eventID,
                          eventVersion: eventVersion, interestVersion: nextVersion, value: value)
        changes.append(item)
        do { try persist() } catch { changes = before; throw error }
        return item.id
    }
    func reconcile(_ events: [HeartballAgentState.SemanticEvent], server: String) {
        let versions = Dictionary(events.map { ($0.id, $0.interestVersion ?? 0) }, uniquingKeysWith: max)
        let before = changes
        changes.removeAll { $0.server == server && $0.status == "accepted" && (versions[$0.eventID] ?? -1) >= ($0.receiptVersion ?? 0) }
        do { try persist() } catch { changes = before; errorMessage = "反馈状态未能保存" }
    }
    func next(server: String) -> Change? {
        let blocked = Set(changes.filter { $0.server == server && $0.status == "blocked" }.map(\.eventID))
        return changes.first { $0.server == server && $0.status == "pending" && !blocked.contains($0.eventID) }
    }
    func acknowledge(_ item: Change, receipt: HeartballClient.InterestReceipt) throws {
        guard receipt.eventId == item.eventID, receipt.interest == item.value, receipt.interestVersion == item.interestVersion + 1,
              let index = changes.firstIndex(where: { $0.id == item.id }) else { throw URLError(.badServerResponse) }
        let before = changes
        changes[index].status = "accepted"; changes[index].receiptVersion = receipt.interestVersion
        do { try persist() } catch { changes = before; throw error }
    }
    func reject(_ item: Change, code: Int) throws {
        guard let index = changes.firstIndex(where: { $0.id == item.id }) else { return }
        let before = changes
        changes[index].status = "blocked"; changes[index].errorCode = code
        do { try persist() } catch { changes = before; throw error }
    }
    func stop() async {
        let current = worker
        current?.cancel()
        await current?.value
    }
    func wake(server: String, send: @escaping (Change) async throws -> HeartballClient.InterestReceipt) {
        guard worker == nil else { return }
        errorMessage = nil
        worker = Task {
            defer { sendingID = nil; worker = nil }
            var failures = 0
            while !Task.isCancelled, let item = next(server: server) {
                sendingID = item.id
                do {
                    let receipt = try await send(item)
                    try acknowledge(item, receipt: receipt)
                    failures = 0; errorMessage = nil
                } catch is CancellationError { return }
                catch {
                    sendingID = nil
                    let code = (error as NSError).code
                    if (400...499).contains(code), ![408,429].contains(code) {
                        do { try reject(item, code: code) } catch { errorMessage = "反馈暂存失败，请检查可用空间"; return }
                        errorMessage = code == 409 ? "事项或偏好已更新，请刷新后重新标记" : "反馈未同步，请检查服务后重新标记"
                        if [401,403].contains(code) { return }
                    } else {
                        failures += 1
                        errorMessage = "标记已保存在手机，联网后自动同步"
                        let seconds = min(30.0, pow(2.0, Double(min(failures,5))))
                        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    }
                }
                sendingID = nil
            }
        }
    }
}
