import SwiftUI

struct RecordDesignView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    private enum Sheet: String, Identifiable {
        case contents, transcript
        var id: String { rawValue }
    }
    let record: DesignRecord
    @State private var mode: ReadingMode
    @State private var sheet: Sheet?
    @State private var selectedChapter: String?

    init(record: DesignRecord, initialMode: ReadingMode = .overview) {
        self.record = record
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header.id("page-top")
                    if record.status == .ready {
                        modeSelector

                        if mode == .overview {
                            OverviewDesignView(record: record)
                            Button {
                                mode = .analysis
                            } label: {
                                HStack {
                                    Text("阅读完整分析")
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                }
                                .font(.headline).padding(16)
                                .background(DesignTheme.quiet, in: .rect(cornerRadius: 16))
                            }
                        } else {
                            AnalysisDesignView(chapters: record.chapters)
                        }
                    } else {
                        ProcessingDesignView()
                    }
                    PreviewNote().padding(.top, 8)
                }
                .padding(.horizontal, DesignTheme.page)
                .padding(.top, 20).padding(.bottom, 32)
            }
            .background(DesignTheme.canvas)
            .onChange(of: mode) { proxy.scrollTo("page-top", anchor: .top) }
            .sheet(item: $sheet, onDismiss: {
                if let selectedChapter {
                    // The selected chapter belongs to the already-mounted analysis view.
                    proxy.scrollTo(selectedChapter, anchor: .top)
                    self.selectedChapter = nil
                }
            }) { destination in
                switch destination {
                case .contents:
                    ContentsDesignSheet(chapters: record.chapters, selection: $selectedChapter)
                case .transcript:
                    PreviewExplanation(title: "转写与回听")
                }
            }
        }
        .navigationTitle("录音详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("转写与回听", systemImage: "waveform") { sheet = .transcript }
                    .accessibilityIdentifier("open-transcript")
            }
            if record.status == .ready {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("目录", systemImage: "list.bullet") {
                        mode = .analysis
                        sheet = .contents
                    }
                    .accessibilityIdentifier("open-contents")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(record.group) \(record.time)  ·  \(record.duration)  ·  示例录音")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(record.title)
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private var modeSelector: some View {
        if typeSize.isAccessibilitySize {
            // UISegmentedControl doesn't scale its labels with accessibility text sizes.
            Picker("阅读模式", selection: $mode) {
                ForEach(ReadingMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu).font(.body)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(12)
            .background(DesignTheme.quiet, in: .rect(cornerRadius: 12))
            .accessibilityIdentifier("reading-mode-accessible")
        } else {
            Picker("阅读模式", selection: $mode) {
                ForEach(ReadingMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reading-mode")
        }
    }
}

struct OverviewDesignView: View {
    let record: DesignRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !record.summary.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("内容摘要").font(.subheadline.weight(.semibold))
                        .foregroundStyle(DesignTheme.accent)
                        .accessibilityAddTraits(.isHeader)
                    Text(record.summary).font(.body).lineSpacing(6)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(DesignTheme.accent.opacity(0.07), in: .rect(cornerRadius: 16))
            }
            if !record.insights.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeading(title: "关键判断", caption: "\(record.insights.count) 个重点")
                    ForEach(record.insights) { InsightDesignCard(insight: $0) }
                }
            }
            if !record.actions.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(title: "行动建议")
                    ForEach(record.actions) { action in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(action.title).font(.body.weight(.medium))
                            Text(action.context).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 12)
                        .overlay(alignment: .bottom) { Divider() }
                        .accessibilityElement(children: .combine)
                    }
                    Text("建议来自示例分析，不代表已经创建待办。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct InsightDesignCard: View {
    let insight: DesignInsight
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(insight.title).font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(insight.body).font(.body).foregroundStyle(DesignTheme.supportingText).lineSpacing(5)
            DisclosureGroup("查看原话", isExpanded: $expanded) {
                Text(insight.quote).font(.body).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12).textSelection(.enabled)
            }
            .font(.subheadline).frame(minHeight: 44)
            .accessibilityIdentifier("quote-\(insight.id)")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTheme.quiet, in: .rect(cornerRadius: 16))
    }
}

struct AnalysisDesignView: View {
    let chapters: [DesignChapter]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 32) {
            Text("完整保留分析脉络，支持选中文字。")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(chapters) { chapter in
                AnalysisChapterView(chapter: chapter).id(chapter.id)
            }
            Divider()
            Text("分析供回顾与思考，重要结论请结合原始对话核实。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct AnalysisChapterView: View {
    let chapter: DesignChapter
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(chapter.title).font(.title2.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("chapter-\(chapter.id)")
                Text(chapter.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            // Fixtures are immutable and each paragraph's text is unique within its chapter.
            ForEach(chapter.paragraphs, id: \.self) { paragraph in
                Text(paragraph).font(.body).lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !chapter.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(chapter.bullets, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•").accessibilityHidden(true)
                            Text(item).lineSpacing(5)
                        }
                        .font(.body).textSelection(.enabled)
                    }
                }
            }
            if chapter.comparison { ComparisonDesignTable() }
        }
    }
}

struct ComparisonDesignTable: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    private let rows: [(id: String, content: String, container: String, reason: String)] = [
        ("summary", "摘要", "重点卡片", "快速了解内容"),
        ("judgment", "独立判断", "轻量卡片", "逐条核对依据"),
        ("report", "完整分析", "连续文档", "保留阅读节奏")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("展示方式对照").font(.headline).accessibilityAddTraits(.isHeader)
            if typeSize.isAccessibilitySize {
                ForEach(rows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.content).bold()
                        Text("形式：\(row.container)")
                        Text("目的：\(row.reason)")
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTheme.quiet, in: .rect(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                }
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                        GridRow {
                            Text("内容"); Text("呈现方式"); Text("目的")
                        }.font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(rows, id: \.id) { row in
                            GridRow {
                                Text(row.content); Text(row.container); Text(row.reason)
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    .font(.body).fixedSize(horizontal: true, vertical: false).padding(16)
                }
                .background(DesignTheme.quiet, in: .rect(cornerRadius: 12))
            }
        }
    }
}

struct ContentsDesignSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chapters: [DesignChapter]
    @Binding var selection: String?
    var body: some View {
        NavigationStack {
            List(chapters) { chapter in
                Button {
                    selection = chapter.id
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(chapter.title).font(.headline).foregroundStyle(.primary)
                        Text(chapter.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 10)
                }
                .accessibilityIdentifier("toc-\(chapter.id)")
            }
            .navigationTitle("分析目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ProcessingDesignView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("正在整理分析", systemImage: "clock")
                .font(.title3.weight(.semibold))
            Text("录音已保存，可以先离开此页面。正式 App 会在回到前台时检查分析结果。")
                .font(.body).foregroundStyle(.secondary).lineSpacing(6)
            Text("这是状态样式预览，不会发起真实分析。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20).background(DesignTheme.quiet, in: .rect(cornerRadius: 16))
    }
}
