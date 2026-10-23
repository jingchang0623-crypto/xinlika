// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import CB08ProbeSupport
import LuyinbiCore

var failures = 0
var checks = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if condition() { print("PASS \(name)") }
    else { failures += 1; print("FAIL \(name)") }
}
func rejects(_ arguments: [String]) -> Bool {
    do { _ = try ProbeConfiguration(arguments: arguments); return false } catch { return true }
}
let id = UUID().uuidString
check("clock sync requires a new owned start", rejects(["capture", "--device", id, "--sync-clock-before-start"]))
check("catalog never synchronizes clock", rejects(["catalog", "--device", id, "--sync-clock-before-start"]))
check("clock sync is opt-in for measurement probes", (try? ProbeConfiguration(arguments: ["capture", "--device", id]).syncClockBeforeStart) == false)
check("recording or unknown state cannot authorize clock sync", !ProbePolicy.maySyncClock(startIfIdle: true, state: 1) && !ProbePolicy.maySyncClock(startIfIdle: true, state: nil))
check("fresh idle state authorizes only owned start clock sync", ProbePolicy.maySyncClock(startIfIdle: true, state: 2) && !ProbePolicy.maySyncClock(startIfIdle: false, state: 2))
check("capture refuses unspecified target", rejects(["capture"]))
check("catalog requires explicit target", rejects(["catalog"]))
check("catalog cannot start recording", rejects(["catalog", "--device", id, "--start-if-idle"]))
check("catalog cannot select or download a file", rejects(["catalog", "--device", id, "--filename", "test.opus"]))
check("catalog cannot inject recovery commands", rejects(["catalog", "--device", id, "--recovery", "start"]))
check("catalog accepts only target and evidence output", (try? ProbeConfiguration(arguments: ["catalog", "--device", id, "--output", "/tmp/cb08-catalog-test"]).mode) == .catalog)
check("reference requires exact filename and explicit target", rejects(["reference", "--device", id]))
check("reference refuses traversal filenames", rejects(["reference", "--device", id, "--filename", "../test.opus"]))
check("reference cannot also start a recording", rejects(["reference", "--device", id, "--filename", "test.opus", "--start-if-idle"]))
for number in ["nan", "inf", "-1", "0", "86401"] {
    check("reject invalid duration \(number)", rejects(["capture", "--device", id, "--seconds", number]))
}
check("reject duplicate flags", rejects(["capture", "--device", id, "--device", id]))
check("no experimental rearm on attached recording", rejects(["capture", "--device", id, "--recovery", "start", "--disconnect-at", "30"]))
check("no rearm without planned trial", rejects(["capture", "--device", id, "--start-if-idle", "--recovery", "resume"]))
check("reserve a meaningful recovery window", rejects(["capture", "--device", id, "--seconds", "40", "--disconnect-at", "30"]))
let boundary = try ProbeConfiguration(arguments: ["capture", "--device", id, "--seconds", "12000", "--start-if-idle"])
let buttonObserver = try ProbeConfiguration(arguments: ["capture", "--device", id, "--observe-buttons"])
check("button observation never implicitly starts or saves", buttonObserver.observeButtons && !buttonObserver.startIfIdle && !buttonObserver.stopOwnedAtEnd)
check("catalog rejects button experiment options", rejects(["catalog", "--device", id, "--observe-buttons"]))
check("boundary run does not inject a disconnect by default", boundary.disconnectAt == nil)
check("boundary run does not rearm or stop by default", boundary.recovery == .passive && !boundary.stopOwnedAtEnd)

func snap(_ name: String? = "note20261020-120000.opus", state: UInt8? = 1,
          seconds: Int? = 10, bytes: UInt32? = 20000) -> ProbeSnapshot {
    ProbeSnapshot(uptime: 100, state: state, filename: name, seconds: seconds, bytes: bytes)
}
let before = snap()
let advancing = snap("NOTE20261020-120000.", seconds: 20, bytes: 40000)
check("normalize truncated extension without merging different files", before.sameFile(as: advancing))
check("missing identities never compare equal", !snap(nil).sameFile(as: snap(nil)))
check("no permission inherited from already-active card", !ProbePolicy.mayRearm(ownedFile: nil, before: before, current: advancing))
check("owned and freshly checked recording can enter single trial", ProbePolicy.mayRearm(ownedFile: before.filename, before: before, current: advancing))
check("file rollover revokes permission", !ProbePolicy.mayRearm(ownedFile: before.filename, before: before, current: snap("next.opus")))
check("paused/unknown state revokes permission", !ProbePolicy.mayRearm(ownedFile: before.filename, before: before, current: snap(state: nil)))
check("card growth alone is not realtime recovery", ProbePolicy.recoveryEvidence(before: before, after: advancing, audioFrames: 0) == "same_file_card_advancing_no_live_delivery_in_window")
check("audio arriving after start of a different file is not same-stream success", ProbePolicy.recoveryEvidence(before: before, after: snap("next.opus", seconds: 1, bytes: 2000), audioFrames: 20) == "different_file_not_same_stream")
check("state=recording with frozen counters is inconclusive", ProbePolicy.recoveryEvidence(before: before, after: before, audioFrames: 10) == "inconclusive_counter_not_advancing")
check("delivery evidence still requires decoding and reference", ProbePolicy.recoveryEvidence(before: before, after: advancing, audioFrames: 10).hasSuffix("decode_and_reference_required"))

let root = FileManager.default.temporaryDirectory.appendingPathComponent("CB08ProbeSelfTest-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let out = root.appendingPathComponent("capture")
let journal = try CaptureJournal(directory: out)
let a = UUID(), b = UUID()
func receive(_ link: UUID, _ source: String, _ seq: UInt8, _ bytes: [UInt8], _ uptime: Double) {
    journal.receive(BLEFrameObservation(connectionID: link, source: source,
                                       frame: Proto.Frame(seq: seq, data: [1, 1] + bytes), uptime: uptime))
}
// Deliberately split a nominal 40-byte codec packet across business frames: no bytes may be trimmed.
receive(a, "AE22", 255, Array(repeating: 0x11, count: 13), 100)
receive(a, "AE22", 0, Array(repeating: 0x22, count: 27), 100.2)
// Same sequence is retained, not deduped using an unverified device counter.
receive(a, "AE22", 0, [0x33], 100.3)
receive(b, "AE22", 1, [0x44, 0x45], 110)
receive(b, "AE23", 2, [0x55], 110.2)
journal.record("snapshot", fields: ["filename": "test.opus"])
let status = journal.status()
check("all original bytes preserved", status.audio.bytes == 44)
check("bounded stats separate connections and notification sources", status.streams.count == 3)
check("arrival gap measured over disconnect", abs(status.audio.maxArrivalGapSeconds - 9.7) < 0.0001)
try journal.close(outcome: "synthetic_test_only")
try journal.close(outcome: "second_close_must_not_overwrite")
let oldRaw = try Data(contentsOf: out.appendingPathComponent("audio-\(a.uuidString)-AE22.bin"))
check("partial packet and repeated sequence remain byte exact", oldRaw == Data(Array(repeating: 0x11, count: 13) + Array(repeating: 0x22, count: 27) + [0x33]))
let rows = try String(contentsOf: out.appendingPathComponent("events.ndjson"), encoding: .utf8).split(separator: "\n").map {
    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
}
check("each payload has a durable index row", rows.filter { $0["audioFile"] != nil }.count == 5)
check("sequence wrap is accepted, repeated sequence remains diagnostic", rows.filter { $0["sequenceDiscontinuity"] as? Bool == true }.count == 1)
let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("capture-summary.json"))) as! [String: Any]
check("completion never fabricated as hardware continuity", (summary["continuityVerdict"] as? String)?.hasPrefix("not_established") == true)
check("cannot overwrite prior experiment", { do { _ = try CaptureJournal(directory: out); return false } catch { return true } }())

let overflow = try CaptureJournal(directory: root.appendingPathComponent("overflow"), maxPendingBytes: 1)
overflow.receive(BLEFrameObservation(connectionID: a, source: "AE22", frame: Proto.Frame(seq: 1, data: [1, 1, 2])))
check("queue overflow is visible and invalidates evidence", overflow.status().droppedSubmissions == 1 && overflow.status().failure != nil)
try overflow.close(outcome: "synthetic_overflow")
check("overflow cannot be reported healthy", { do { try overflow.checkHealthy(); return false } catch { return true } }())

let disk = try CaptureJournal(directory: root.appendingPathComponent("disk-failure"))
try FileManager.default.createDirectory(at: disk.directory.appendingPathComponent("audio-\(a.uuidString)-AE22.bin"), withIntermediateDirectories: false)
disk.receive(BLEFrameObservation(connectionID: a, source: "AE22", frame: Proto.Frame(seq: 1, data: [1, 1, 2])))
check("disk failure does not count unpersisted audio as captured", disk.status().failure != nil && disk.status().audio.bytes == 0)
try disk.close(outcome: "synthetic_disk_failure")

let referenceFile = root.appendingPathComponent("reference-partial.bin")
let referenceSink = try ReferenceDownloadSink(file: referenceFile, expectedBytes: 400)
check("new reference starts at zero", (try? referenceSink.beginAttempt()) == 0)
let prefix = (0..<237).map { UInt8($0 % 251) }
try referenceSink.append(prefix)
try referenceSink.flush()
check("download keeps partial codec packet unchanged", (try? Data(contentsOf: referenceFile)) == Data(prefix))
check("reconnect rewinds only overlap", (try? referenceSink.beginAttempt()) == 77)
try referenceSink.append(Array(prefix[77..<111]))
try referenceSink.append(Array(prefix[111..<237]) + [UInt8](repeating: 19, count: 163))
try referenceSink.confirm(endCode: 0)
check("split overlap is verified without duplicating bytes", (try? Data(contentsOf: referenceFile)) == Data(prefix + [UInt8](repeating: 19, count: 163)))
check("zero end code alone is insufficient", { do {
    let short = try ReferenceDownloadSink(file: root.appendingPathComponent("short.bin"), expectedBytes: 400)
    _ = try short.beginAttempt(); try short.append([1, 2, 3]); try short.confirm(endCode: 0); return false
} catch { return true } }())
check("wrong resume overlap preserves previous evidence", { do {
    _ = try referenceSink.beginAttempt(); try referenceSink.append([255]); return false
} catch { return (try? Data(contentsOf: referenceFile).count) == 400 } }())
check("excess bytes cannot fabricate complete reference", { do {
    let excess = try ReferenceDownloadSink(file: root.appendingPathComponent("excess.bin"), expectedBytes: 40)
    _ = try excess.beginAttempt(); try excess.append([UInt8](repeating: 1, count: 41)); return false
} catch { return true } }())

for (command, expected) in [(UInt8(1), "start"), (3, "save"), (5, "pause"), (7, "resume")] {
    check("observe vendor button request \(command)", DeviceButtonCandidate(source: "AE23", frame: .init(seq: 0, data: [3, command]))?.kind.rawValue == expected)
}
check("recording query reply is not a button request", DeviceButtonCandidate(source: "AE23", frame: .init(seq: 0, data: [3, 20, 1])) == nil)
check("button acknowledgement is not a request", DeviceButtonCandidate(source: "AE23", frame: .init(seq: 0, data: [3, 2, 1])) == nil)
check("live audio is not a button press", DeviceButtonCandidate(source: "AE22", frame: .init(seq: 0, data: [1, 1, 7])) == nil)
check("outbound command is not an observed device button", DeviceButtonCandidate(source: "AE21", frame: .init(seq: 0, data: [3, 1])) == nil)
let buttonJournal = try CaptureJournal(directory: root.appendingPathComponent("button-candidates"))
for _ in 0..<2 {
    buttonJournal.receive(BLEFrameObservation(connectionID: a, source: "AE23", frame: .init(seq: 0, data: [3, 1, 9])))
}
try buttonJournal.close(outcome: "synthetic_button_observation_only")
let buttonRows = try String(contentsOf: buttonJournal.directory.appendingPathComponent("events.ndjson"), encoding: .utf8)
    .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
check("repeated 8-bit sequence preserves both button candidates", buttonRows.filter { ($0["buttonRequestCandidate"] as? String) == "start" }.count == 2)
check("button payload kept for protocol verification without claiming success", buttonRows.allSatisfy {
    ($0["buttonBodyHex"] as? String) == "09" && ($0["buttonInterpretation"] as? String)?.contains("not_confirmed") == true
})

check("button ACK requires explicit observation", rejects(["capture", "--device", id, "--button-response", "vendor", "--app-state", "foreground"]))
check("button ACK requires explicit foreground/background handshake", rejects(["capture", "--device", id, "--observe-buttons", "--button-response", "vendor"]))
check("catalog cannot send lifecycle announcements", rejects(["catalog", "--device", id, "--app-state", "foreground"]))
check("invalid lifecycle file without initial state is refused", rejects(["capture", "--device", id, "--observe-buttons", "--app-state-file", "/tmp/state"]))
let handshake = RecorderButtonHandshake(mode: .vendor)
let keyStart = Proto.Frame(seq: 17, data: [3, 1])
let keySave = Proto.Frame(seq: 18, data: [3, 3])
handshake.connected(a)
check("unarmed connection cannot ACK physical recording", handshake.response(connection: a, source: "AE23", frame: keyStart, at: 100) == nil)
handshake.armFromIdle(baselineNames: ["old.opus"], at: 100)
check("AE22 response cannot authorize physical key mutation", handshake.response(connection: a, source: "AE22", frame: keyStart, at: 101) == nil)
let acceptedStart = handshake.response(connection: a, source: "AE23", frame: keyStart, at: 101)
check("SDK start response permits dedicated physical start", acceptedStart?.command == 2 && acceptedStart?.result == 1)
check("pending request cannot trigger repeated start", handshake.response(connection: a, source: "AE23", frame: keyStart, at: 101.1) == nil)
handshake.update(state: 1, filename: "old.opus", at: 102)
check("old file cannot be adopted from a start request", handshake.response(connection: a, source: "AE23", frame: keySave, at: 103) == nil)
handshake.update(state: 1, filename: "new.opus", at: 104)
let acceptedSave = handshake.response(connection: a, source: "AE23", frame: keySave, at: 105)
check("new physical test identity permits SDK save response", acceptedSave?.command == 4 && acceptedSave?.result == 1)
handshake.update(state: 2, filename: nil, at: 106)
check("stale idle cache cannot authorize another start", handshake.response(connection: a, source: "AE23", frame: keyStart, at: 119) == nil)
handshake.update(state: 2, filename: nil, at: 120)
handshake.connected(b)
check("new connection requires fresh state", handshake.response(connection: b, source: "AE23", frame: keyStart, at: 121) == nil)
handshake.update(state: 2, filename: nil, at: 122)
check("stale connection events cannot mutate current device", handshake.response(connection: a, source: "AE23", frame: keyStart, at: 123) == nil)
let preserve = RecorderButtonHandshake(mode: .rejectSave)
preserve.connected(a); preserve.armFromIdle(baselineNames: ["old.opus"], at: 200)
preserve.update(state: 1, filename: "other.opus", at: 201)
check("preservation experiment never inherits unknown recording", preserve.response(connection: a, source: "AE23", frame: keySave, at: 202) == nil)
preserve.claimAppCreatedFile("other.opus")
let declinedSave = preserve.response(connection: a, source: "AE23", frame: keySave, at: 203)
check("preservation sends documented failure not false success", declinedSave?.command == 4 && declinedSave?.result == 2 && declinedSave?.isFocusCandidate == true)
preserve.disconnected()
check("disconnect revokes response permission", preserve.response(connection: a, source: "AE23", frame: keySave, at: 204) == nil)
check("lifecycle frame payloads follow SDK", RecorderButtonHandshake.appStateParameters("foreground") == [1] && RecorderButtonHandshake.appStateParameters("background") == [2] && RecorderButtonHandshake.appStateParameters("other") == nil)
let zero = RecorderButtonHandshake(mode: .rejectSaveZero)
zero.connected(a); zero.armFromIdle(baselineNames: [], at: 300)
zero.update(state: 1, filename: "dedicated.opus", at: 301)
check("zero variation still requires dedicated ownership", zero.response(connection: a, source: "AE23", frame: keySave, at: 302) == nil)
zero.claimAppCreatedFile("dedicated.opus")
let zeroSave = zero.response(connection: a, source: "AE23", frame: keySave, at: 303)
check("zero variation returns zero without pretending operation succeeded", zeroSave?.command == 4 && zeroSave?.result == 0 && zeroSave?.isFocusCandidate == true)
zero.update(state: 1, filename: "replaced.opus", at: 304)
check("file replacement revokes experimental response", zero.response(connection: a, source: "AE23", frame: keySave, at: 305) == nil)
let cancel = RecorderButtonHandshake(mode: .resumeOnSave)
cancel.connected(a); cancel.armFromIdle(baselineNames: [], at: 400)
cancel.update(state: 1, filename: "owned.opus", at: 401)
check("resume cancellation trial cannot touch an inherited file", cancel.response(connection: a, source: "AE23", frame: keySave, at: 402) == nil)
cancel.claimAppCreatedFile("owned.opus")
let cancelRequest = cancel.response(connection: a, source: "AE23", frame: keySave, at: 403)
check("cancellation sends resume not start or success ACK", cancelRequest?.type == 1 && cancelRequest?.command == 3 && cancelRequest?.result == 0)
cancel.update(state: 2, filename: nil, at: 404)
check("no resume after stop was confirmed", cancel.response(connection: a, source: "AE23", frame: keySave, at: 405) == nil)
let controlJournal = try CaptureJournal(directory: root.appendingPathComponent("control-bodies"), recordControlBodies: true)
controlJournal.receive(BLEFrameObservation(connectionID: a, source: "AE23", frame: .init(seq: 1, data: [3, 29] + [UInt8](repeating: 7, count: 100))))
controlJournal.receive(BLEFrameObservation(connectionID: a, source: "AE22", frame: .init(seq: 2, data: [1, 1] + [UInt8](repeating: 8, count: 160))))
controlJournal.receive(BLEFrameObservation(connectionID: a, source: "AE22", frame: .init(seq: 3, data: [2, 4, 1, 2, 3])))
try controlJournal.close(outcome: "synthetic_control_capture")
let controlRows = try String(contentsOf: controlJournal.directory.appendingPathComponent("events.ndjson"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
check("unknown control payload capture is bounded and marked truncated", (controlRows[0]["controlBodyHex"] as? String)?.count == 128 && controlRows[0]["controlBodyTruncated"] as? Bool == true)
check("file and audio bytes cannot enter control payload logs", controlRows.dropFirst().allSatisfy { $0["controlBodyHex"] == nil })

print("\(checks - failures)/\(checks) passed; synthetic evidence only, no physical recorder used")
exit(failures == 0 ? 0 : 1)
