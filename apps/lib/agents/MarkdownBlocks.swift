import Foundation

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case listItem(String, String, Int)
    case quote(String)
    case code(String, String)
    case table([[String]])
    case rule
}

enum MessageMarkdown {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "`" || first == "~",
               trimmed.prefix(while: { $0 == first }).count >= 3 {
                flush()
                let count = trimmed.prefix(while: { $0 == first }).count
                let language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count {
                    let closing = lines[index].trimmingCharacters(in: .whitespaces)
                    if closing.count >= count && closing.allSatisfy({ $0 == first }) { index += 1; break }
                    code.append(lines[index]); index += 1
                }
                blocks.append(.code(language, code.joined(separator: "\n")))
                continue
            }
            if index + 1 < lines.count, line.contains("|"), isTableSeparator(lines[index + 1]) {
                flush()
                var rows = [cells(line)]
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index])); index += 1
                }
                blocks.append(.table(rows)); continue
            }
            if trimmed.isEmpty { flush(); index += 1; continue }
            if ["---", "***", "___"].contains(trimmed) { flush(); blocks.append(.rule); index += 1; continue }
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flush(); blocks.append(.heading(hashes, String(trimmed.dropFirst(hashes + 1)))); index += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush(); blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))); index += 1; continue
            }
            if let range = trimmed.range(of: #"^([-*+] |[0-9]+[.)] )"#, options: .regularExpression) {
                flush()
                var marker = String(trimmed[range]).trimmingCharacters(in: .whitespaces)
                var body = String(trimmed[range.upperBound...])
                if ["-", "*", "+"].contains(marker) { marker = "•" }
                if body.hasPrefix("[ ] ") { marker = "□"; body = String(body.dropFirst(4)) }
                if body.lowercased().hasPrefix("[x] ") { marker = "✓"; body = String(body.dropFirst(4)) }
                let indentation = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                blocks.append(.listItem(marker, body, min(6, indentation / 2)))
                index += 1; continue
            }
            paragraph.append(line); index += 1
        }
        flush()
        return blocks
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") { text.removeLast() }
        var cells = [""]
        var escaped = false
        var inCode = false
        for character in text {
            if character == "|", !escaped, !inCode { cells.append("") }
            else {
                if character == "`", !escaped { inCode.toggle() }
                cells[cells.count - 1].append(character)
            }
            escaped = character == "\\" && !escaped
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let columns = cells(line)
        return !columns.isEmpty && columns.allSatisfy {
            let value = $0.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }
}
