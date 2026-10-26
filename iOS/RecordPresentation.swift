import Foundation

/// Read-only presentation; upload/transcription/analysis state stays in the ledger.
struct RecordPresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date?
    let metadata: String
    let excerpt: String
    let status: String
    let symbol: String
    let needsAttention: Bool
    let isWorking: Bool

    init(_ item: LedgerItem) {
        id = item.id
        title = item.meeting?.title ?? item.title
        date = item.recordedAt
        let timestamp = date.map { $0.formatted(date: .omitted, time: .shortened) } ?? "录音时间未标注"
        metadata = "\(timestamp) · \(item.displayDuration)"
        let summary = item.meeting?.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !summary.isEmpty {
            let bounded = String(summary.prefix(240))
            let plain = (try? AttributedString(markdown: bounded)).map { String($0.characters) } ?? bounded
            excerpt = plain.replacingOccurrences(of: "\n", with: " ")
        } else {
            excerpt = item.cloud?.headline ?? item.meeting?.analysisAbsentReason ?? (item.meeting?.analysis?.markdown != nil ? "完整分析已返回，打开查看详细内容。" : "")
        }
        needsAttention = item.state == .failed || item.state == .paused || item.meeting?.analysis?.status == "failed" || item.resultError != nil || item.cloud?.stage == "failed"
        if item.isCloudOnly, item.cloud?.stage == "failed" {
            status = "云端处理失败"; symbol = "exclamationmark.circle"
        } else if item.state == .failed || item.state == .paused {
            status = item.state == .paused ? "同步待恢复" : "上传需处理"
            symbol = "exclamationmark.circle"
        } else if let meeting = item.meeting, let analysis = meeting.analysis {
            status = meeting.analysisLabel
            symbol = analysis.status == "done" ? "checkmark.circle" : analysis.status == "failed" ? "exclamationmark.circle" : "clock"
        } else if item.meeting?.analysisAbsentReason != nil {
            status = "未自动分析"; symbol = "info.circle"
        } else {
            status = item.resultLabel
            symbol = item.state == .ready ? "doc.text" : "clock"
        }
        isWorking = (item.isCloudOnly ? item.cloud?.stage == "delivered" : [.downloading, .uploading, .processing].contains(item.state)) || item.meeting?.needsPolling == true
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "时长未知" }
        let total = Int(seconds)
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分钟" }
        return "\(total / 3600) 小时 \(total / 60 % 60) 分钟"
    }
}

struct RecordDateGroup: Identifiable {
    let id: String
    let title: String
    let rows: [RecordPresentation]

    static func make(_ rows: [RecordPresentation], query: String, now: Date = Date(), calendar: Calendar = .current) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = rows.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.excerpt.localizedStandardContains(query) }
        let sorted = filtered.sorted {
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return $0.id < $1.id
        }
        let days = Dictionary(grouping: sorted) { $0.date.map { calendar.startOfDay(for: $0) } }
        return days.keys.sorted { ($0 ?? .distantPast) > ($1 ?? .distantPast) }.map { day in
            let title: String
            if let day {
                if calendar.isDate(day, inSameDayAs: now) { title = "今天" }
                else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { title = "昨天" }
                else { title = day.formatted(date: .abbreviated, time: .omitted) }
            } else { title = "录音日期未标注" }
            return Self(id: day.map { String($0.timeIntervalSince1970) } ?? "undated", title: title, rows: days[day] ?? [])
        }
    }
}
