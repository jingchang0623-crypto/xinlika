import SwiftUI

struct XinlikaInterestBadge: View {
    @Bindable var model: XinlikaModel
    let event: HeartballAgentState.SemanticEvent
    var showsSuggestion = true
    var showsSelection = true
    var body: some View {
        HStack(spacing: 6) {
            switch model.interest(for: event) {
            case "important":
                if showsSelection { Label("重要", systemImage: "star.fill").foregroundStyle(.orange) }
            case "unimportant":
                if showsSelection { Label("不重要", systemImage: "minus.circle").foregroundStyle(.secondary) }
            default:
                if showsSuggestion && event.suggestedInterest == "high" { Label("猜你关注", systemImage: "sparkles").foregroundStyle(.secondary) }
                else if showsSuggestion && event.suggestedInterest == "low" { Label("猜你少关注", systemImage: "sparkles").foregroundStyle(.secondary) }
            }
            if model.interestBlocked(event) {
                Label("需重新标记", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            } else if model.interestPending(event) {
                Label("待同步", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary)
            }
        }.font(.caption)
    }
}

struct XinlikaInterestActions: View {
    @Bindable var model: XinlikaModel
    let event: HeartballAgentState.SemanticEvent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 16))
        layout {
            Button("重要", systemImage: model.interest(for: event) == "important" ? "star.fill" : "star") {
                model.rateInterest(event, value: "important")
            }
            .accessibilityValue(model.interest(for: event) == "important" ? "已选" : "未选")
            .frame(minHeight: 44)
            Button("不重要", systemImage: model.interest(for: event) == "unimportant" ? "minus.circle.fill" : "minus.circle") {
                model.rateInterest(event, value: "unimportant")
            }
            .accessibilityValue(model.interest(for: event) == "unimportant" ? "已选" : "未选")
            .frame(minHeight: 44)
            if model.interest(for: event) != "neutral" {
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Menu {
                    Button("取消标记", systemImage: "arrow.uturn.backward") {
                        model.rateInterest(event, value: "neutral")
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("标记选项").accessibilityIdentifier("interest-more")
            }
        }.buttonStyle(.borderless)
    }
}

/// One feedback region. An error takes precedence over success without hiding undo.
struct XinlikaInterestFeedbackBar: View {
    @Bindable var model: XinlikaModel
    var eventID: String?
    private var showsLastFeedback: Bool {
        guard let last = model.lastInterest else { return false }
        return eventID == nil || last.event.id == eventID
    }
    private var text: String? {
        if let notice = model.interestNotice { return notice }
        guard showsLastFeedback, let last = model.lastInterest else { return nil }
        switch model.interest(for: last.event) {
        case "important": return "已标记为重要"
        case "unimportant": return "已标记为不重要"
        default: return "已取消标记"
        }
    }
    var body: some View {
        if let text {
            HStack(spacing: 12) {
                Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                if showsLastFeedback {
                    Button("撤销") { model.undoInterest() }.frame(minHeight: 44)
                    if model.interestNotice == nil {
                        Button { model.lastInterestDismiss() } label: {
                            Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("关闭反馈提示")
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6).background(.regularMaterial)
            .accessibilityIdentifier("interest-feedback")
        }
    }
}

struct XinlikaInterestHelpView: View {
    @Bindable var model: XinlikaModel
    var body: some View {
        List {
            Section("标记事项") {
                Text("右滑重要 · 左滑不重要，可在全部事项中改回")
                Text("也可以长按事项，或打开详情选择重要程度。标记后可撤销。")
                    .foregroundStyle(.secondary)
            }
            if let profile = model.agent?.interestProfile {
                Section("整理偏好") {
                    Text("当前参考 \(profile.labelledEventCount) 项标记")
                    Text(profile.readyForSuggestions
                         ? "助手会参考多次标记中的具体关心点。建议会标为“猜你关注”或“猜你少关注”，你可以随时改回。"
                         : "积累几次反馈后，助手会开始参考你的偏好。")
                        .foregroundStyle(.secondary)
                }
            }
            Section("标记片段") {
                Text("录音时标记片段，可以留下便于回听的时间区间。标记结束后，总录音仍继续。")
                    .foregroundStyle(.secondary)
            }
        }.navigationTitle("关注偏好").navigationBarTitleDisplayMode(.inline)
    }
}
