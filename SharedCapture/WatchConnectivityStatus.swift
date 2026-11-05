#if os(iOS) || os(watchOS)
import Foundation
import WatchConnectivity

/// Fixed diagnostic names, counts and numeric errors only; never audio, text,
/// credentials or transfer metadata. Useful when background delivery is delayed.
enum WatchConnectivityStatus {
    private static let lock = NSLock()
    static func save(_ event: String, session: WCSession, root: URL, error: Error? = nil) {
        lock.lock(); defer { lock.unlock() }
        let file = root.appendingPathComponent("connectivity-status.json")
        let previous = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var status: [String: Any] = ["event": event, "at": ISO8601DateFormatter().string(from: .now),
            "activation": session.activationState.rawValue, "reachable": session.isReachable,
            "files": session.outstandingFileTransfers.count, "events": session.outstandingUserInfoTransfers.count,
            "pending": session.hasContentPending, "errorCode": (error as NSError?)?.code ?? 0]
        if let error = error as NSError? {
            status["lastErrorCode"] = error.code; status["lastErrorDomain"] = error.domain
        } else {
            status["lastErrorCode"] = previous?["lastErrorCode"]
            status["lastErrorDomain"] = previous?["lastErrorDomain"]
        }
        for (name, trigger) in [("lastHandshakeAt", "handshake_received"), ("lastFileReceivedAt", "file_received"),
                                ("lastEventReceivedAt", "event_received"), ("lastReceiptAt", "receipt_received")] {
            status[name] = event == trigger ? status["at"] : previous?[name]
        }
        #if os(iOS)
        status["paired"] = session.isPaired
        status["watchAppInstalled"] = session.isWatchAppInstalled
        #else
        status["phoneAppInstalled"] = session.isCompanionAppInstalled
        #endif
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
            try? data.write(to: file,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}
#endif
