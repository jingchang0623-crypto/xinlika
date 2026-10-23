// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import LuyinbiCore

/// A vendor-documented inbound request, not proof that a physical operation
/// completed or that its audio should already become a user-focused recording.
/// This type never constructs or sends a response to the recorder.
public struct DeviceButtonCandidate: Sendable {
    public enum Kind: String, Sendable { case start, save, pause, resume }
    public let kind: Kind

    public init?(source: String, frame: Proto.Frame) {
        guard ["AE22", "AE23"].contains(source), frame.type == Proto.T.key else { return nil }
        switch frame.cmd {
        case 1: kind = .start
        case 3: kind = .save
        case 5: kind = .pause
        case 7: kind = .resume
        default: return nil
        }
    }
}
