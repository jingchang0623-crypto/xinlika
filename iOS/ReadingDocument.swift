import CryptoKit
import Foundation
import Markdown

struct ReadingDocument: Sendable {
    struct Heading: Identifiable, Sendable {
        let id: String
        let title: String
        let level: Int
    }
    let revision: String
    let blocks: [ReadingBlock]
    let headings: [Heading]
    static let empty = Self(revision: "", blocks: [], headings: [])
}

struct ReadingBlock: Identifiable, Sendable {
    enum Kind: Sendable { case heading(Int), paragraph, code, table, divider }
    let id: String
    let kind: Kind
    let text: AttributedString
    let depth: Int
    let quoteDepth: Int
    var marker: String? = nil
    var table: ReadingTable? = nil
}

struct ReadingTable: Sendable {
    struct Column: Identifiable, Sendable {
        enum Alignment: Sendable { case leading, center, trailing }
        let id: String
        let title: AttributedString
        let alignment: Alignment
    }
    struct Cell: Identifiable, Sendable {
        let id: String
        let columnID: String
        let text: AttributedString
    }
    struct Row: Identifiable, Sendable {
        let id: String
        let cells: [Cell]
    }
    let columns: [Column]
    let rows: [Row]
}

enum ReadingLinkPolicy {
    static func allowed(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") &&
        !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }
}

/// An actor keeps parsing off the main actor. No global cache retains another account's report.
actor ReadingDocumentLoader {
    func load(_ source: String) throws -> ReadingDocument {
        try ReadingDocumentParser.parse(source)
    }
}

enum ReadingDocumentParser {
    static func parse(_ source: String) throws -> ReadingDocument {
        try Task.checkCancellation()
        let revision = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let document = Document(parsing: source, options: [.disableSmartOpts])
        var blocks: [ReadingBlock] = []
        for child in document.children {
            try append(child, path: "\(child.indexInParent)", revision: revision, depth: 0, quoteDepth: 0, to: &blocks)
        }
        let headings = blocks.compactMap { block -> ReadingDocument.Heading? in
            guard case .heading(let level) = block.kind else { return nil }
            return .init(id: block.id, title: String(block.text.characters), level: level)
        }
        return .init(revision: revision, blocks: blocks, headings: headings)
    }

    private static func append(_ node: Markup, path: String, revision: String, depth: Int, quoteDepth: Int, to blocks: inout [ReadingBlock]) throws {
        try Task.checkCancellation()
        // IDs belong to an immutable document revision, not mutable list positions in the UI.
        let id = "\(revision.prefix(20))-\(path)"
        func block(_ kind: ReadingBlock.Kind, _ text: AttributedString) -> ReadingBlock {
            .init(id: id, kind: kind, text: text, depth: depth, quoteDepth: quoteDepth)
        }
        if depth + quoteDepth > 32 {
            blocks.append(block(.paragraph, AttributedString(node.format())))
            return
        }
        switch node {
        case let heading as Markdown.Heading:
            blocks.append(block(.heading(heading.level), inline(heading)))
        case let paragraph as Paragraph:
            blocks.append(block(.paragraph, inline(paragraph)))
        case let code as CodeBlock:
            blocks.append(block(.code, AttributedString(code.code)))
        case is ThematicBreak:
            blocks.append(block(.divider, AttributedString()))
        case let table as Markdown.Table:
            let columns = table.head.cells.enumerated().map { offset, cell in
                let alignment: ReadingTable.Column.Alignment
                switch table.columnAlignments[offset] {
                case .center: alignment = .center
                case .right: alignment = .trailing
                default: alignment = .leading
                }
                return ReadingTable.Column(id: "\(id)-column-\(offset)", title: inline(cell), alignment: alignment)
            }
            let rows = table.body.rows.enumerated().map { offset, row in
                let rowID = "\(id)-row-\(offset)"
                return ReadingTable.Row(id: rowID, cells: row.cells.enumerated().map { column, cell in
                    ReadingTable.Cell(id: "\(rowID)-cell-\(column)", columnID: columns[column].id, text: inline(cell))
                })
            }
            var result = block(.table, AttributedString())
            result.table = ReadingTable(columns: columns, rows: rows)
            blocks.append(result)
        case is OrderedList, is UnorderedList:
            let start = (node as? OrderedList).map { Int(clamping: $0.startIndex) }
            for child in node.children {
                let first = blocks.count
                for nested in child.children {
                    try append(nested, path: "\(path).\(child.indexInParent).\(nested.indexInParent)", revision: revision,
                               depth: depth + 1, quoteDepth: quoteDepth, to: &blocks)
                }
                let marker: String
                if let checkbox = (child as? ListItem)?.checkbox {
                    marker = checkbox == .checked ? "☑︎" : "☐"
                } else { marker = start.map { "\($0 + child.indexInParent)." } ?? "•" }
                if first < blocks.count { blocks[first].marker = marker }
                else {
                    var empty = ReadingBlock(id: "\(id).\(child.indexInParent)", kind: .paragraph, text: AttributedString(" "), depth: depth + 1, quoteDepth: quoteDepth)
                    empty.marker = marker
                    blocks.append(empty)
                }
            }
        case is BlockQuote:
            for child in node.children {
                try append(child, path: "\(path).\(child.indexInParent)", revision: revision, depth: depth, quoteDepth: quoteDepth + 1, to: &blocks)
            }
        case let html as HTMLBlock:
            // HTML is visible source text, never executable web content.
            blocks.append(block(.code, AttributedString(html.rawHTML)))
        default:
            blocks.append(block(.paragraph, AttributedString(node.format())))
        }
    }

    private static func inline(_ node: Markup) -> AttributedString {
        if let text = node as? Markdown.Text { return AttributedString(text.string) }
        if node is SoftBreak { return AttributedString(" ") }
        if node is LineBreak { return AttributedString("\n") }
        if let code = node as? InlineCode {
            var value = AttributedString(code.code)
            value.inlinePresentationIntent = .code
            return value
        }
        if let html = node as? InlineHTML {
            if ["<br>", "<br/>", "<br />"].contains(html.rawHTML.lowercased()) { return AttributedString("\n") }
            return AttributedString(html.rawHTML)
        }
        if let image = node as? Markdown.Image {
            return AttributedString("[图片：\(image.plainText.isEmpty ? "未命名" : image.plainText)，未自动加载]")
        }
        var result = AttributedString()
        for child in node.children { result.append(inline(child)) }
        let intent: InlinePresentationIntent?
        switch node {
        case is Strong: intent = .stronglyEmphasized
        case is Emphasis: intent = .emphasized
        case is Strikethrough: intent = .strikethrough
        default: intent = nil
        }
        if let intent {
            for run in Array(result.runs) {
                result[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(intent)
            }
        }
        if let link = node as? Markdown.Link, let destination = link.destination,
           let url = URL(string: destination), ReadingLinkPolicy.allowed(url) { result.link = url }
        return result
    }
}
