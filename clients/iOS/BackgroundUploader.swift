// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import UIKit

enum TransferError: Error, CustomStringConvertible {
    case storage, invalidAddress, interrupted(Int)
    var description: String {
        switch self {
        case .storage: return "无法保存传输状态，请检查可用空间；录音仍保留"
        case .invalidAddress: return "上传地址无效"
        case .interrupted: return "后台传输暂时中断，恢复网络后可继续"
        }
    }
}

struct TransferReceipt: Codable {
    var key: String
    var status: Int
    var errorCode: Int?
}

@MainActor
final class BackgroundUploader: NSObject {
    static let shared = BackgroundUploader()
    static let identifier = "org.xinlika.app.audio-upload.v1"
    static let finished = Notification.Name("ShennaoBackgroundUploadFinished")
    var backgroundCompletion: (() -> Void)?
    private var waiters: [String: [CheckedContinuation<Int, Error>]] = [:]
    private var generation = 0
    private var cancelledTasks = Set<Int>()
    private let directory: URL
    private var needsPostReconciliation = true
    private(set) var storageError: Error?
    private let postRedirectDelegate = XinlikaPostRedirectDelegate()
    private lazy var immediateSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 45
        c.httpMaximumConnectionsPerHost = 1
        c.allowsCellularAccess = true
        c.allowsExpensiveNetworkAccess = true
        c.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: c, delegate: postRedirectDelegate, delegateQueue: nil)
    }()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 24 * 3600
        c.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Xinlika/Transfers", isDirectory: true)
        super.init()
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { storageError = error }
    }
    /// Isolated transport tests use a private receipt directory and URLProtocol;
    /// they never attach to the user's system background transfer session.
    init(directory: URL, postSession: URLSession) {
        self.directory = directory
        super.init()
        immediateSession = postSession
        needsPostReconciliation = false
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { storageError = error }
    }

    func restore() { _ = session }

    /// Minute-sized live envelopes should run immediately while the app has
    /// execution time, rather than queue behind the OS background scheduler.
    /// Durable outbox identities make interrupted requests safe to replay.
    func postFile(_ file: URL, to url: URL, token: String, identity: String, attempt: Int) async throws -> Int {
        try Task.checkCancellation()
        guard XinlikaConnection.isAllowed(url), !token.isEmpty else { throw TransferError.invalidAddress }
        guard storageError == nil else { throw TransferError.storage }
        let key = CaptureDigest.sha256(url.absoluteString + "|" + CaptureDigest.sha256(token) + "|" + identity + "|" + CaptureDigest.sha256(try Data(contentsOf: file)))
        if let status = successfulPostReceipt(key) { return status }
        // Adopt the previous process's POST by immutable identity. Cancel only
        // that request before expediting it; unrelated legacy PUTs stay intact.
        if needsPostReconciliation {
            needsPostReconciliation = false
            // A slow nsurlsessiond task inventory must not block live uploads.
            // If both requests reach the server during reconciliation, its
            // immutable message receipt deduplicates the replay.
            Task { [weak self] in
                guard let self else { return }
                let previous = await tasks()
                guard waiters[key] == nil else { return }
                for task in previous where Self.transferKey(task.taskDescription) == key &&
                    task.originalRequest?.httpMethod == "POST" && task.state != .completed && task.state != .canceling {
                    cancelledTasks.insert(task.taskIdentifier); task.cancel()
                }
            }
        }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let sending = Task { try await immediateSession.upload(for: request, fromFile: file) }
        var leaseExpired = false
        let lease = BackgroundLease(name: "XinlikaLiveUpload") { leaseExpired = true; sending.cancel() }
        defer { lease.end() }
        do {
            let (_, response) = try await withTaskCancellationHandler { try await sending.value }
                onCancel: { sending.cancel() }
            try Task.checkCancellation()
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let receipt = TransferReceipt(key: key, status: status, errorCode: nil)
            do {
                try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent(key + ".json"),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { throw TransferError.storage }
            return status
        } catch {
            try Task.checkCancellation()
            // Only expiration of the OS execution grant hands this request to
            // background URLSession. Ordinary network failures use queue backoff.
            if leaseExpired { return try await postBackgroundFile(file, to: url, token: token, identity: identity) }
            throw error
        }
    }
    private func successfulPostReceipt(_ key: String) -> Int? {
        guard let receipt = try? JSONDecoder().decode(TransferReceipt.self,
            from: Data(contentsOf: directory.appendingPathComponent(key + ".json"))),
            receipt.key == key, receipt.errorCode == nil, receipt.status == 200 else { return nil }
        return receipt.status
    }
    /// System-owned fallback survives suspension/relaunch. When execution
    /// resumes, its watchdog prevents a stalled POST from holding the queue all day.
    private func postBackgroundFile(_ file: URL, to url: URL, token: String, identity: String) async throws -> Int {
        needsPostReconciliation = true
        guard XinlikaConnection.isAllowed(url), !token.isEmpty else { throw TransferError.invalidAddress }
        guard storageError == nil else { throw TransferError.storage }
        let key = CaptureDigest.sha256(url.absoluteString + "|" + CaptureDigest.sha256(token) + "|" + identity + "|" + CaptureDigest.sha256(try Data(contentsOf: file)))
        let receiptURL = directory.appendingPathComponent(key + ".json")
        func successfulReceipt() -> Int? {
            guard let receipt = try? JSONDecoder().decode(TransferReceipt.self, from: Data(contentsOf: receiptURL)),
                  receipt.errorCode == nil, receipt.status == 200 else { return nil }
            return receipt.status
        }
        if let status = successfulReceipt() { return status }
        let live = await tasks().first { Self.transferKey($0.taskDescription) == key && $0.state != .completed && $0.state != .canceling }
        if let status = successfulReceipt() { return status }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let task = live ?? session.uploadTask(with: request, fromFile: file)
        task.taskDescription = identity + "|" + key
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            self?.cancelPost(task, key: key, error: TransferError.interrupted(NSURLErrorTimedOut))
        }
        defer { watchdog.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                guard !Task.isCancelled else { cont.resume(throwing: CancellationError()); return }
                waiters[key, default: []].append(cont)
                task.resume()
            }
        } onCancel: { Task { @MainActor in self.cancelPost(task, key: key, error: CancellationError()) } }
    }
    private func cancelPost(_ task: URLSessionTask, key: String, error: Error) {
        guard let continuations = waiters.removeValue(forKey: key) else { return }
        cancelledTasks.insert(task.taskIdentifier); task.cancel()
        for continuation in continuations { continuation.resume(throwing: error) }
    }
    func cancelAll() async {
        generation += 1
        let waiting = waiters.values.flatMap { $0 }
        waiters.removeAll()
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
        for task in await tasks() {
            cancelledTasks.insert(task.taskIdentifier)
            task.cancel()
        }
    }

    func put(_ data: Data, to url: URL, mime: String, identity: String, recordID: String) async throws -> Int {
        try Task.checkCancellation()
        let startedGeneration = generation
        guard storageError == nil else { throw TransferError.storage }
        guard url.scheme == "https", url.host != nil else { throw TransferError.invalidAddress }
        let key = CaptureDigest.sha256(identity + "|" + CaptureDigest.sha256(data))
        let receiptURL = directory.appendingPathComponent(key + ".json")
        if let receipt = try? JSONDecoder().decode(TransferReceipt.self, from: Data(contentsOf: receiptURL)),
           receipt.key == key, receipt.errorCode == nil, (200..<300).contains(receipt.status) {
            return receipt.status
        }
        let tasks = await tasks()
        try Task.checkCancellation()
        guard startedGeneration == generation else { throw CancellationError() }
        // A task surviving process termination is reattached, not uploaded twice.
        let live = tasks.first { Self.transferKey($0.taskDescription) == key && $0.state != .completed && $0.state != .canceling }
        if live == nil {
            let file = directory.appendingPathComponent(key + ".part")
            do {
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { throw TransferError.storage }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue(mime, forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = recordID + "|" + key
            // Register before resume: a small local/fast transfer can finish immediately.
            return try await withCheckedThrowingContinuation { cont in
                waiters[key, default: []].append(cont)
                Diagnostics.event("background_put_started", record: key, bytes: data.count)
                task.resume()
            }
        }
        // A completion may have arrived while getAllTasks was suspended.
        if let receipt = try? JSONDecoder().decode(TransferReceipt.self, from: Data(contentsOf: receiptURL)),
           receipt.key == key, receipt.errorCode == nil, (200..<300).contains(receipt.status) {
            return receipt.status
        }
        return try await withCheckedThrowingContinuation { cont in
            waiters[key, default: []].append(cont)
            live?.resume()
        }
    }

    private func tasks() async -> [URLSessionTask] {
        await withCheckedContinuation { cont in session.getAllTasks { cont.resume(returning: $0) } }
    }

    nonisolated static func transferKey(_ description: String?) -> String? {
        guard let key = description?.split(separator: "|", maxSplits: 1).last.map(String.init),
              key.count == 64, key.allSatisfy({ $0.isHexDigit }) else { return nil }
        return key
    }

    private func complete(taskID: Int, key: String, status: Int, errorCode: Int?) {
        // A late cancellation from an older PUT must not fail a resumed transfer with the same key.
        guard cancelledTasks.remove(taskID) == nil else { return }
        var result: Result<Int, Error>
        do {
            let receipt = TransferReceipt(key: key, status: status, errorCode: errorCode)
            try JSONEncoder().encode(receipt).write(to: directory.appendingPathComponent(key + ".json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            if let errorCode { result = .failure(TransferError.interrupted(errorCode)) }
            else { result = .success(status) }
        } catch { result = .failure(TransferError.storage) }
        let continuations = waiters.removeValue(forKey: key) ?? []
        for cont in continuations { cont.resume(with: result) }
        Diagnostics.event("background_put_finished", record: key)
        NotificationCenter.default.post(name: Self.finished, object: nil)
    }
}

private final class XinlikaPostRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

extension BackgroundUploader: URLSessionTaskDelegate, URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(task.originalRequest?.httpMethod == "POST" ? nil : request)
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let key = Self.transferKey(task.taskDescription) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let errorCode = (error as NSError?)?.code
        let taskID = task.taskIdentifier
        Task { @MainActor in self.complete(taskID: taskID, key: key, status: status, errorCode: errorCode) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            NotificationCenter.default.post(name: Self.finished, object: nil)
            let completion = self.backgroundCompletion
            self.backgroundCompletion = nil
            completion?()
        }
    }
}

final class ShennaoAppDelegate: NSObject, UIApplicationDelegate {
    private var usesXinlika: Bool {
        let environment = ProcessInfo.processInfo.environment
        return !["SHENNAO_UI_FIXTURE", "SHENNAO_SYNC_FIXTURE", "SHENNAO_LEGACY"].contains { environment[$0] == "1" }
    }
    func application(_ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Restore the owner before a scene is rendered, including Bluetooth wakes.
        if usesXinlika { _ = XinlikaModel.shared }
        return true
    }
    func application(_ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.identifier else { completionHandler(); return }
        BackgroundUploader.shared.backgroundCompletion = completionHandler
        if usesXinlika { _ = XinlikaModel.shared }
        BackgroundUploader.shared.restore()
    }
}

/// Time for short control-plane steps only. Audio PUT itself is owned by the system.
@MainActor
final class BackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init(name: String, expired: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            expired()
            self?.end()
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
