// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import Observation

/// One durable envelope at a time: later audio must not overtake its session's
/// earlier ranges. Transient failures wait briefly and wake on connectivity.
@MainActor @Observable
final class XinlikaUploadQueue {
    enum Phase: Equatable { case idle, uploading, waiting, blocked }
    private(set) var phase = Phase.idle
    private(set) var lastHTTPStatus: Int?
    private(set) var acceptedCount = 0
    private(set) var lastAcceptedAt: Date?
    let configurationKey: String
    private let store: XinlikaCaptureStore
    private let serviceURL: String
    private let send: (XinlikaCaptureStore.Message) async throws -> Int
    private let sleep: (TimeInterval) async throws -> Void
    private let changed: () -> Void
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var retryTimer: Task<Void, Never>?
    @ObservationIgnored private var retryWaiter: CheckedContinuation<Void, Never>?

    var isRunning: Bool { worker != nil }
    init(store: XinlikaCaptureStore, serviceURL: String, configurationKey: String,
         send: @escaping (XinlikaCaptureStore.Message) async throws -> Int,
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         changed: @escaping () -> Void = {}) {
        self.store = store; self.serviceURL = serviceURL; self.configurationKey = configurationKey
        self.send = send; self.sleep = sleep; self.changed = changed
    }
    /// Disk-change notifications only start a stopped worker. They must not
    /// bypass backoff when acknowledging a failure itself changes the ledger.
    func start() {
        guard worker == nil else { return }
        guard !(phase == .blocked && [401, 403].contains(lastHTTPStatus)) else { return }
        worker = Task { await run() }
    }
    func wake(retryBlocked: Bool = false) {
        if retryBlocked, [401, 403].contains(lastHTTPStatus) { lastHTTPStatus = nil }
        if phase == .waiting { finishWait() }
        start()
    }
    func cancel() {
        worker?.cancel(); finishWait()
    }
    private func finishWait() {
        retryTimer?.cancel(); retryTimer = nil
        let waiter = retryWaiter; retryWaiter = nil; waiter?.resume()
    }
    private func wait(seconds: TimeInterval) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                retryWaiter = continuation
                retryTimer = Task {
                    do { try await sleep(seconds) } catch { return }
                    finishWait()
                }
            }
        } onCancel: { Task { @MainActor in self.finishWait() } }
    }
    private func run() async {
        defer { worker = nil; changed() }
        while !Task.isCancelled {
            guard let next = store.nextUpload(serviceURL: serviceURL) else {
                phase = store.snapshot().counts(for: serviceURL).held > 0 ? .blocked : .idle
                return
            }
            phase = .uploading; changed()
            do {
                let status = try await send(next)
                try Task.checkCancellation()
                lastHTTPStatus = status
                if status == 200 {
                    try store.acknowledge(next.id, status: "accepted")
                    acceptedCount += 1; lastAcceptedAt = .now
                    changed(); continue
                }
                if status != 0 && status < 500 && ![408, 429].contains(status) {
                    try store.acknowledge(next.id, status: "blocked")
                    phase = .blocked; changed()
                    if [401, 403].contains(status) { return }
                    continue
                }
            } catch is CancellationError { phase = .idle; return }
            catch {
                if Task.isCancelled { phase = .idle; return }
                if let transfer = error as? TransferError {
                    switch transfer {
                    case .storage, .invalidAddress:
                        // Local storage/configuration cannot be fixed by retrying
                        // the same request. Preserve the envelope for inspection.
                        try? store.acknowledge(next.id, status: "blocked")
                        phase = .blocked; changed(); return
                    case .interrupted: break
                    }
                }
                lastHTTPStatus = nil
            }
            do { try store.acknowledge(next.id, status: "pending") }
            catch { phase = .blocked; return }
            phase = .waiting; changed()
            await wait(seconds: min(30, pow(2, Double(min(next.attempts + 1, 5)))))
        }
        phase = .idle
    }
}

enum XinlikaUploadPresentation {
    static func text(pending: Int, held: Int, phase: XinlikaUploadQueue.Phase,
                     status: Int?, serviceReachable: Bool, processing: Int, hasResults: Bool,
                     failedProcessing: Int = 0) -> String {
        if [401, 403].contains(status), held > 0 { return "处理服务授权失效，请检查连接凭据；原声已保留" }
        if pending > 0 {
            return phase == .uploading ? "正在上传，尚有 \(pending) 项待传" : "\(pending) 项待传，网络恢复后自动继续"
        }
        if held > 0 { return "\(held) 项校验未通过，原声已保留" }
        if !serviceReachable { return "暂时无法读取整理结果，恢复连接后自动同步" }
        if failedProcessing > 0 { return "录音已上传，\(failedProcessing) 项整理暂未完成" }
        if processing > 0 { return "录音已上传，\(processing) 项正在处理" }
        return hasResults ? "录音已上传，整理结果已同步" : "处理服务已连接，等候新录音"
    }
}
