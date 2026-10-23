// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation

/// A single selected saved file. Keeps every received byte, including partial codec
/// packets; resumption validates a short overlap before appending new bytes.
public final class ReferenceDownloadSink {
    public enum Failure: Error { case overflow, overlapMismatch, incomplete }
    public let expectedBytes: Int
    public private(set) var receivedBytes = 0
    private let handle: FileHandle
    private var tail = Data()
    private var overlap = Data()
    private var overlapPosition = 0

    public init(file: URL, expectedBytes: Int) throws {
        guard expectedBytes > 0 else { throw Failure.incomplete }
        self.expectedBytes = expectedBytes
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw ProbeError.invalid("不能覆盖既有参考文件")
        }
        try Data().write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        handle = try FileHandle(forWritingTo: file)
    }

    deinit { try? handle.close() }

    public func beginAttempt() throws -> UInt32 {
        try handle.synchronize()
        overlap = tail
        overlapPosition = 0
        return UInt32(receivedBytes - overlap.count)
    }

    public func append(_ bytes: [UInt8]) throws {
        let comparing = min(bytes.count, overlap.count - overlapPosition)
        if comparing > 0 {
            guard Array(bytes.prefix(comparing)) == Array(overlap[overlapPosition..<overlapPosition + comparing]) else {
                throw Failure.overlapMismatch
            }
            overlapPosition += comparing
        }
        let fresh = Data(bytes.dropFirst(comparing))
        guard receivedBytes + fresh.count <= expectedBytes else { throw Failure.overflow }
        try handle.write(contentsOf: fresh)
        receivedBytes += fresh.count
        tail.append(fresh)
        tail = Data(tail.suffix(160))
    }

    public func flush() throws { try handle.synchronize() }

    public func confirm(endCode: UInt8?) throws {
        guard endCode == 0, receivedBytes == expectedBytes, overlapPosition == overlap.count else {
            throw Failure.incomplete
        }
        try flush()
    }
}
