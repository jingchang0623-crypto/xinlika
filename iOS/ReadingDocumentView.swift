import SwiftUI

struct ReadingBlockView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let block: ReadingBlock
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if block.quoteDepth > 0 {
                RoundedRectangle(cornerRadius: 2).fill(ShennaoTheme.blue.opacity(0.4)).frame(width: 3)
                    .accessibilityHidden(true)
            }
            if let marker = block.marker {
                Text(marker).font(.body).foregroundStyle(ShennaoTheme.supportingText)
                    .accessibilityLabel(marker == "☑︎" ? "原文已勾选" : marker == "☐" ? "原文未勾选" : marker)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, typeSize.isAccessibilitySize ? 0 : CGFloat(min(block.depth, 4)) * 10)
        .padding(.top, headingSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.openURL, OpenURLAction { ReadingLinkPolicy.allowed($0) ? .systemAction : .discarded })
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text).font(headingFont(level)).fontWeight(.bold)
                .textSelection(.enabled).accessibilityAddTraits(.isHeader)
        case .paragraph:
            Text(block.text).font(.body).lineSpacing(compact ? 5 : 7).textSelection(.enabled)
        case .code:
            ScrollView(.horizontal) {
                Text(block.text).font(.body.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false).padding(14)
            }.background(ShennaoTheme.quiet, in: .rect(cornerRadius: 12))
        case .table:
            if let table = block.table { ReadingTableView(table: table) }
        case .divider: Divider().padding(.vertical, 8)
        }
    }
    private var headingSpacing: CGFloat {
        if case .heading = block.kind { return compact ? 4 : 12 }
        return 0
    }
    private func headingFont(_ level: Int) -> Font {
        if compact { return .headline }
        switch level { case 1: return .title2; case 2: return .title3; default: return .headline }
    }
}

private struct ReadingTableView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let table: ReadingTable
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if typeSize.isAccessibilitySize {
                ForEach(table.rows) { row in
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(row.cells) { cell in
                            VStack(alignment: .leading, spacing: 8) {
                                if let column = table.columns.first(where: { $0.id == cell.columnID }) {
                                    Text(column.title).font(.headline)
                                }
                                Text(cell.text).font(.body).textSelection(.enabled)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }.readingCard()
                }
                if table.rows.isEmpty {
                    ForEach(table.columns) { Text($0.title).font(.headline) }
                }
            } else {
                Text("表格可左右滑动").font(.footnote).foregroundStyle(ShennaoTheme.supportingText)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(table.columns) { column in
                                Text(column.title).font(.subheadline.weight(.semibold))
                                    .frame(width: 160, alignment: alignment(column.alignment)).padding(12)
                            }
                        }.background(ShennaoTheme.blue.opacity(0.07))
                        ForEach(table.rows) { row in
                            VStack(spacing: 0) {
                                Divider()
                                HStack(alignment: .top, spacing: 0) {
                                    ForEach(row.cells) { cell in
                                        Text(cell.text).font(.body).lineSpacing(4).textSelection(.enabled)
                                            .frame(width: 160, alignment: alignment(table.columns.first { $0.id == cell.columnID }?.alignment ?? .leading))
                                            .padding(12)
                                    }
                                }
                            }
                            .accessibilityElement(children: .contain)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }.background(ShennaoTheme.quiet, in: .rect(cornerRadius: 12))
            }
        }
        .accessibilityIdentifier("analysis-table")
    }
    private func alignment(_ value: ReadingTable.Column.Alignment) -> Alignment {
        switch value { case .leading: .leading; case .center: .center; case .trailing: .trailing }
    }
}

struct ReadingContentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let headings: [ReadingDocument.Heading]
    @Binding var selection: String?
    var body: some View {
        NavigationStack {
            List(headings) { heading in
                Button {
                    selection = heading.id
                    dismiss()
                } label: {
                    Text(heading.title).font(heading.level <= 2 ? .headline : .body)
                        .foregroundStyle(.primary)
                        .padding(.leading, CGFloat(min(heading.level - 1, 3)) * 10)
                        .padding(.vertical, 10).frame(minHeight: 44)
                }
                .accessibilityIdentifier("toc-\(heading.title)")
            }
            .navigationTitle("分析目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
