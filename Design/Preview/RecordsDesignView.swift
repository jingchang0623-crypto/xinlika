import SwiftUI

struct RecordsDesignView: View {
    @State private var query = ""
    @State private var state: String
    @State private var showAbout = false

    init(initialState: String) { _state = State(initialValue: initialState) }

    private var records: [DesignRecord] {
        let source = state == "empty" ? [] : PreviewFixtures.records
        return query.isEmpty ? source : source.filter {
            $0.title.localizedStandardContains(query) || $0.excerpt.localizedStandardContains(query)
        }
    }

    var body: some View {
        List {
            if state != "empty" && query.isEmpty {
                Text("示例内容 · 2 份分析已就绪")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .listRowSeparator(.hidden)
            }
            if state == "error" {
                VStack(alignment: .leading, spacing: 8) {
                    Label("暂时无法刷新", systemImage: "wifi.exclamationmark")
                        .font(.headline)
                    Text("已保存的记录仍可阅读。请检查网络后重试。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("演示恢复") { state = "records" }
                        .frame(minHeight: 44)
                }
                .padding(.vertical, 8)
            }
            ForEach(["今天", "昨天"], id: \.self) { group in
                let grouped = records.filter { $0.group == group }
                if !grouped.isEmpty {
                    Section {
                        ForEach(grouped) { record in
                            NavigationLink(value: PreviewRoute.record(record.id)) {
                                RecordingDesignRow(record: record)
                            }
                            .accessibilityIdentifier("record-\(record.id)")
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        }
                    } header: {
                        Text(group).font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary.opacity(0.65)).textCase(nil)
                    }
                }
            }
            if !records.isEmpty {
                PreviewNote().padding(.vertical, 24).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .listRowSpacing(4)
        .listSectionSpacing(12)
        .overlay {
            if records.isEmpty {
                if query.isEmpty {
                    ContentUnavailableView("还没有录音", systemImage: "waveform", description: Text("在“设备”中连接灵魂卡，\n同步后就能在这里回顾。"))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle("记录")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题或摘要")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("预览选项", systemImage: "ellipsis") {
                    Button("正常记录") { state = "records" }
                    Button("空状态") { state = "empty" }
                    Button("刷新失败") { state = "error" }
                    Divider()
                    Button("关于设计预览") { showAbout = true }
                }
            }
        }
        .sheet(isPresented: $showAbout) { PreviewExplanation() }
    }
}

struct RecordingDesignRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let record: DesignRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(record.title)
                .font(.headline).foregroundStyle(.primary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(record.time)  ·  \(record.duration)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(record.excerpt)
                .font(.subheadline).foregroundStyle(DesignTheme.supportingText)
                .lineSpacing(4).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            HStack(spacing: 5) {
                Image(systemName: record.status == .ready ? "checkmark.circle" : "clock")
                    .accessibilityHidden(true)
                Text(record.status.rawValue)
            }
                .font(.footnote.weight(.medium))
                .foregroundStyle(record.status == .ready ? Color.secondary : DesignTheme.accent)
                .padding(.top, 2)
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}
