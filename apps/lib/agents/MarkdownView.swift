import AppKit
import SwiftUI

private final class MarkdownDocument {
    let blocks: [MarkdownBlock]
    init(_ text: String) { blocks = MessageMarkdown.parse(text) }
    static let cache: NSCache<NSString, MarkdownDocument> = {
        let cache = NSCache<NSString, MarkdownDocument>()
        cache.totalCostLimit = 2_000_000
        cache.countLimit = 200
        return cache
    }()
}

struct MarkdownMessage: View {
    private let blocks: [MarkdownBlock]
    init(_ text: String) {
        let key = text as NSString
        let document = MarkdownDocument.cache.object(forKey: key) ?? MarkdownDocument(text)
        MarkdownDocument.cache.setObject(document, forKey: key, cost: text.utf8.count)
        blocks = document.blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .paragraph(let text): inline(text).fixedSize(horizontal: false, vertical: true)
                case .heading(let level, let text):
                    inline(text).font(.system(size: level == 1 ? 23 : level == 2 ? 20 : 17, weight: .semibold))
                        .padding(.top, index == 0 ? 0 : 8)
                case .listItem(let marker, let text, let indent):
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker).frame(minWidth: 16, alignment: .trailing)
                        inline(text).fixedSize(horizontal: false, vertical: true)
                    }.padding(.leading, CGFloat(indent) * 16)
                case .quote(let text):
                    HStack(spacing: 12) {
                        Rectangle().fill(AppTheme.separator).frame(width: 3)
                        inline(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code): CodeBlock(text: code, title: language.isEmpty ? "Code" : language)
                case .rule: Divider().padding(.vertical, 4)
                case .table(let rows): table(rows)
                }
            }
        }
        .font(.system(size: 15))
        .lineSpacing(4)
        .foregroundStyle(.primary)
        .tint(AppTheme.accent)
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        guard var value = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return Text(verbatim: text)
        }
        for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            value[run.range].font = .system(size: 13, design: .monospaced)
            value[run.range].backgroundColor = AppTheme.surface
        }
        ChangeHighlighting.counts(in: &value)
        return Text(value)
    }

    private func table(_ rows: [[String]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(0..<(rows.map(\.count).max() ?? 0), id: \.self) { column in
                            inline(column < rows[row].count ? rows[row][column] : "")
                                .fontWeight(row == 0 ? .semibold : .regular)
                                .fixedSize()
                        }
                    }
                    if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }.padding(12)
        }
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CopyTextButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }
}

struct CodeBlock: View {
    let text: String
    var title = "Code"
    var maxHeight: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyTextButton(text: text)
            }.padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            GeometryReader { geometry in
                ScrollView(maxHeight == nil ? .horizontal : [.horizontal, .vertical]) {
                    Text(ChangeHighlighting.code(text.isEmpty ? "(empty)" : text, language: title))
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(12)
                        .frame(minWidth: geometry.size.width, alignment: .leading)
                }
            }
            .frame(height: min(maxHeight ?? .greatestFiniteMagnitude, CGFloat(text.components(separatedBy: "\n").count) * 18 + 24))
        }
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.separator.opacity(0.5), lineWidth: 0.5))
    }
}

enum ChangeHighlighting {
    private static let countsPattern = try! NSRegularExpression(pattern: #"(?<![\w.])(\+\d+)\s*[/,]\s*([-−]\d+)(?![\w.])"#)

    static func counts(in value: inout AttributedString) {
        let text = String(value.characters)
        for match in countsPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for (group, color) in [(1, AppTheme.success), (2, AppTheme.error)] {
                guard let range = Range(match.range(at: group), in: text),
                      let start = AttributedString.Index(range.lowerBound, within: value),
                      let end = AttributedString.Index(range.upperBound, within: value) else { continue }
                value[start..<end].foregroundColor = color
            }
        }
    }

    static func code(_ text: String, language: String) -> AttributedString {
        let lines = text.components(separatedBy: "\n")
        let isDiff = ["diff", "patch"].contains(language.lowercased()) || lines.contains {
            $0.hasPrefix("diff --git ") || $0 == "*** Begin Patch" || $0.hasPrefix("@@ ")
        } || (lines.contains { $0.hasPrefix("--- ") } && lines.contains { $0.hasPrefix("+++ ") })
        guard isDiff else { return AttributedString(text) }
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var value = AttributedString((index == 0 ? "" : "\n") + line)
            if line.hasPrefix("+") && !line.hasPrefix("+++") { value.foregroundColor = AppTheme.success }
            else if line.hasPrefix("-") && !line.hasPrefix("---") { value.foregroundColor = AppTheme.error }
            result.append(value)
        }
        return result
    }
}
