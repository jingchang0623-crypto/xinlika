// SPDX-License-Identifier: GPL-3.0-only
// See clients/LICENSE and clients/PROVENANCE.md for source and authorization.
import SwiftUI

struct XinlikaInterestBadge: View {
    @Bindable var model: XinlikaModel
    let event: HeartballAgentState.SemanticEvent
    var body: some View {
        HStack(spacing: 6) {
            switch model.interest(for: event) {
            case "important": Label("重要", systemImage: "star.fill").foregroundStyle(.orange)
            case "unimportant": Label("不重要", systemImage: "minus.circle").foregroundStyle(.secondary)
            default:
                if event.suggestedInterest == "high" { Label("猜你关注", systemImage: "sparkles").foregroundStyle(.secondary) }
                else if event.suggestedInterest == "low" { Label("猜你少关注", systemImage: "sparkles").foregroundStyle(.secondary) }
            }
            if model.interestBlocked(event) {
                Label("需重新标记", systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            } else if model.interestPending(event) {
                Label("待同步", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary)
            }
        }.font(.caption)
    }
}
