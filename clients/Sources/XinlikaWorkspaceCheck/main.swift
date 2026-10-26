// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import Foundation
import LuyinbiCore

// These fixtures exercise session identity and focus overlap, not ASR accuracy.
func document(_ id: String, session: String? = nil, kind: String = "ambient", text: String = "已核对的测试文字", status: String = "review_pending", occurred: String? = nil, created: String? = nil) throws -> HeartballAgentState.Document {
    var value: [String: Any] = ["id": id, "kind": kind, "title": id, "summary": "测试摘要", "text": text,
                               "source_kind": "test_unverified", "status": status, "revision": 1,
                               "boundary_quality": "includes_boundary_context", "evidence": [], "validation_notes": []]
    if let session { value["session_id"] = session }
    if let occurred { value["occurred_at"] = occurred }
    if let created { value["created_at"] = created }
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(HeartballAgentState.Document.self, from: JSONSerialization.data(withJSONObject: value))
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
let fixtures = try [document("tail", session: "s1", text: ""), document("focus", session: "s1", kind: "focus"),
                    document("minute1", session: "s1"), document("minute2", session: "s1"),
                    document("other-session", session: "s2"), document("missing-a"), document("missing-b"),
                    document("empty-id-a", session: ""), document("empty-id-b", session: " "),
                    document("old-revision", session: "s1", status: "superseded")]
let sessions = HeartballRecordCollection.make(fixtures, focusOnly: false)
check(sessions.count == 6, "Minute batching must not create conversations or merge missing session identities")
check(sessions.map(\.id) == ["session:s1", "session:s2", "session:missing-a", "session:missing-b", "session:empty-id-a", "session:empty-id-b"], "Stable first-seen ordering and empty-ID isolation")
let first = sessions[0]
check(first.documents.map(\.id) == ["tail", "minute1", "minute2"], "Focus overlap must not duplicate ambient transcripts; obsolete revision must be excluded")
check(first.focuses.map(\.id) == ["focus"], "Focus remains attached to the logical source session")
check(first.representative.id == "minute1", "An empty tail must not hide the session's useful speech")
let focuses = HeartballRecordCollection.make(fixtures, focusOnly: true)
check(focuses.count == 1 && focuses[0].id == "focus:focus", "Focus filter preserves independent identity")
let orphan = HeartballRecordCollection.make(try [document("only-focus", session: "s3", kind: "focus")], focusOnly: false)
check(orphan.count == 1 && orphan[0].documents.count == 1, "A focus without an available ambient document remains reachable")
check(HeartballRecordCollection.make([], focusOnly: false).isEmpty, "An empty account must not fabricate a session")
let utc = try document("utc", occurred: "2026-10-21T15:10:00.000Z")
let local = try document("local", occurred: "2026-10-21T23:09:00+08:00")
check(local.recordingDate != nil && utc.recordingDate != nil && local.recordingDate! < utc.recordingDate!, "Sort source times by instants, not ISO string order across offsets")
let unknown = try document("unknown", created: "2026-10-22T08:00:00+08:00")
check(unknown.recordingDate == nil, "A processing timestamp must never become a recording date")
print("10 session/focus, revision and recording-clock checks passed. No hardware, ASR or model calls.")

// The canonical day is independent from activity containers and source counts.
let summaryEvent: [String: Any] = ["id":"short-feedback", "session_id":"s", "kind":"ambient", "title":"操作没有响应",
    "summary":"一条有明确现象的短反馈。", "source_kind":"unknown", "created_at":"2026-10-24T12:00:00Z", "occurred_at":"2026-10-21T14:00:00+08:00",
    "version":1, "sources":[["document_id":"d1", "revision":1, "quote":"原句"]], "category":"feedback", "card_style":"summary"]
var compactEvent = summaryEvent;compactEvent["id"]="simple-event";compactEvent["card_style"]="compact"
compactEvent["sources"] = (1...4).map { ["document_id":"d\($0)", "revision":1, "quote":"原句"] as [String:Any] }
let group: [String:Any] = ["id":"long-meeting", "kind":"meeting", "title":"一场会议", "start_local":"2026-10-21T14:00:00+08:00",
    "end_local":"2026-10-21T16:00:00+08:00", "session_count":1, "event_count":2, "focus_count":0,"events":[summaryEvent,compactEvent]]
var day: [String:Any] = ["date":"2026-10-21", "time_zone":"Asia/Shanghai", "groups":[group], "event_count":2,"focus_count":0,"unknown_time_count":0,
    "timeline":[compactEvent,summaryEvent],"timeline_version":1]
let decoder=JSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase
func readDay(_ value: [String:Any]) throws -> HeartballAgentState.Day {
    try decoder.decode(HeartballAgentState.Day.self,from:JSONSerialization.data(withJSONObject:value))
}
let canonical = try readDay(day)
check(canonical.timelineEvents.map(\.id)==["simple-event","short-feedback"],"Both clients must keep server event identity and order; a meeting container cannot replace them")
check(!canonical.timelineEvents[0].showsTimelineSummary && canonical.timelineEvents[1].showsTimelineSummary,"Card hierarchy is semantic, never source count")
day["timeline"] = []
let emptyCanonical = try readDay(day)
check(emptyCanonical.timelineEvents.isEmpty,"An explicitly empty canonical timeline must not leak hidden group contents")
day.removeValue(forKey:"timeline");day.removeValue(forKey:"timeline_version")
let legacyDay = try readDay(day)
check(legacyDay.timelineEvents.count==2,"Old servers remain readable without treating containers as events")
if let index=CommandLine.arguments.firstIndex(of:"--day-state"),CommandLine.arguments.indices.contains(index+1) {
    let state = try decoder.decode(HeartballAgentState.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[index+1])))
    guard let realDay=state.today else { fatalError("Missing real day") }
    check(realDay.timeline != nil,"Real validation must use the server canonical timeline")
    check(Set(realDay.timelineEvents.map(\.id)).count==realDay.timelineEvents.count,"No duplicate real home events")
    print("Real canonical day decoded: \(realDay.date), \(realDay.timelineEvents.count) events; no client regrouping or device access.")
}
print("4 canonical timeline, legacy compatibility and semantic-card checks passed.")
