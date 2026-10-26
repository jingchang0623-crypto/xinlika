import SwiftUI

struct MeetingOverview: View {
    let meeting: Meeting
    let summary: ReadingDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                ReadingSectionHeading(title: "内容摘要")
                if summary.blocks.isEmpty {
                    Text("暂无摘要，可以查看完整分析或原始转写。")
                        .font(.body).foregroundStyle(ShennaoTheme.supportingText)
                } else {
                    ForEach(summary.blocks) { ReadingBlockView(block: $0, compact: true) }
                }
            }.readingCard(tinted: true)

            if !meeting.judgments.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ReadingSectionHeading(title: "关键判断", detail: "\(meeting.judgments.count) 条")
                    ForEach(meeting.judgments) { JudgmentCard(judgment: $0) }
                }
            }
            if !meeting.commitments.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    ReadingSectionHeading(title: "对话中的行动", detail: "\(meeting.commitments.count) 条")
                    Text("以下内容来自对话，不代表已创建或完成待办。")
                        .font(.footnote).foregroundStyle(ShennaoTheme.supportingText)
                    ForEach(meeting.commitments) { commitment in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(commitment.statement).font(.body).lineSpacing(5).textSelection(.enabled)
                            if let speaker = commitment.speaker {
                                Label(speaker, systemImage: "person").font(.subheadline)
                                    .foregroundStyle(ShennaoTheme.supportingText)
                            }
                            if let date = commitment.dueDate {
                                Label(date, systemImage: "calendar").font(.subheadline)
                                    .foregroundStyle(ShennaoTheme.supportingText)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).readingCard()
                    }
                }
            }
            if !meeting.speakers.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ReadingSectionHeading(title: "对话参与者")
                    Text(meeting.speakers.joined(separator: "、")).font(.body).textSelection(.enabled)
                }
            }
        }
    }
}

private struct JudgmentCard: View {
    let judgment: Meeting.Judgment
    @State private var showsQuote = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let subject = judgment.subject {
                Text(subject).font(.subheadline.weight(.medium)).foregroundStyle(ShennaoTheme.supportingText)
            }
            Text(judgment.statement).font(.body.weight(.medium)).lineSpacing(5).textSelection(.enabled)
            if let quote = judgment.quote {
                DisclosureGroup("查看对话原句", isExpanded: $showsQuote) {
                    Text(quote).font(.body).lineSpacing(5).textSelection(.enabled)
                        .foregroundStyle(ShennaoTheme.supportingText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                }
                .font(.subheadline).accessibilityIdentifier("quote-\(judgment.id)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).readingCard()
    }
}
