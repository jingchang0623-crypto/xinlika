import Foundation

enum RetryPolicy {
    static func delay(attempt: Int) -> TimeInterval {
        min(900, 30 * pow(2, Double(max(0, min(5, attempt - 1)))))
    }
    static func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case TransferError.interrupted = error { return true }
        if case DeepBrainError.http(let step, let code, _) = error {
            return code == 408 || code == 429 || code >= 500 || (step == "直传 COS" && code == 403)
        }
        return false
    }
}
