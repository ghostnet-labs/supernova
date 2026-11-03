import AppKit
import SwiftUI

/// A bounded lexical highlighter: token positions are independent of the selected theme.
enum SyntaxHighlighting {
    enum Kind { case keyword, string, number, typeName, function, property, comment }
    struct Token { let range: NSRange; let kind: Kind }
    enum Language: String {
        case swift, python, javascript, typescript, c, cpp, csharp, java, go, rust
        case shell, json, yaml, toml, sql, css, html, markdown

        static func resolve(_ label: String) -> Self? {
            let name = label.lowercased().split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            return aliases[name] ?? Self(rawValue: name)
        }
        private static let aliases: [String: Self] = [
            "py": .python, "python3": .python, "js": .javascript, "jsx": .javascript, "ts": .typescript, "tsx": .typescript,
            "sh": .shell, "bash": .shell, "zsh": .shell, "shellscript": .shell, "console": .shell,
            "yml": .yaml, "jsonc": .json, "json5": .json, "c++": .cpp, "cc": .cpp, "c#": .csharp, "cs": .csharp,
            "golang": .go, "rs": .rust, "xml": .html, "htm": .html, "md": .markdown, "scss": .css
        ]
        var hashComments: Bool { [.python, .shell, .yaml, .toml].contains(self) }
        var slashComments: Bool { [.swift, .javascript, .typescript, .c, .cpp, .csharp, .java, .go, .rust, .json].contains(self) }
        var blockComments: Bool { slashComments || self == .sql || self == .css }
    }

    private final class Document {
        let tokens: [Token]
        init(_ tokens: [Token]) { self.tokens = tokens }
    }
    private final class StyledDocument {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    private static let documents: NSCache<NSString, Document> = {
        let cache = NSCache<NSString, Document>(); cache.totalCostLimit = 4_000_000; cache.countLimit = 200; return cache
    }()
    private static let styledDocuments: NSCache<NSString, StyledDocument> = {
        let cache = NSCache<NSString, StyledDocument>(); cache.totalCostLimit = 4_000_000; cache.countLimit = 200; return cache
    }()
    static let maximumBytes = 100_000

    static func highlight(_ text: String, language label: String) -> AttributedString {
        guard text.utf8.count <= maximumBytes, let language = Language.resolve(label) else { return AttributedString(text) }
        let theme = AppTheme.shared.palette?.id ?? "system"
        let key = language.rawValue + "\0" + text
        let styleKey = (theme + "\0" + key) as NSString
        if let cached = styledDocuments.object(forKey: styleKey) { return cached.value }
        let document = documents.object(forKey: key as NSString) ?? Document(tokens(in: text, language: language))
        documents.setObject(document, forKey: key as NSString, cost: text.utf8.count + document.tokens.count * 24)
        let colors = AppTheme.syntax
        let source = text as NSString
        var result = AttributedString(), cursor = 0
        for token in document.tokens {
            let color: Color
            switch token.kind {
            case .keyword: color = colors.keyword
            case .string: color = colors.string
            case .number: color = colors.number
            case .typeName: color = colors.typeName
            case .function, .property: color = colors.function
            case .comment: color = colors.comment
            }
            if cursor < token.range.location {
                result.append(AttributedString(source.substring(with: NSRange(location: cursor, length: token.range.location - cursor))))
            }
            var span = AttributedString(source.substring(with: token.range))
            span.foregroundColor = color
            result.append(span)
            cursor = NSMaxRange(token.range)
        }
        if cursor < source.length { result.append(AttributedString(source.substring(from: cursor))) }
        styledDocuments.setObject(StyledDocument(result), forKey: styleKey, cost: text.utf8.count * 2 + document.tokens.count * 128)
        return result
    }

    static func tokens(in text: String, language: Language) -> [Token] {
        guard text.utf8.count <= maximumBytes else { return [] }
        // UTF-16 ranges bridge directly to attributed text, including non-ASCII source.
        let units = Array(text.utf16), count = units.count
        var index = 0, tokens: [Token] = [], commandStart = true, inTag = false
        func matches(_ sequence: [UInt16], at start: Int) -> Bool {
            start + sequence.count <= count && units[start..<(start + sequence.count)].elementsEqual(sequence)
        }
        func space(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 13 }
        func digit(_ unit: UInt16) -> Bool { (48...57).contains(unit) }
        func identifier(_ unit: UInt16) -> Bool {
            (65...90).contains(unit) || (97...122).contains(unit) || unit == 95 || unit >= 128
        }
        func nextContent(_ start: Int) -> Int {
            var next = start
            while next < count && space(units[next]) { next += 1 }
            return next
        }
        func append(_ start: Int, _ kind: Kind) { tokens.append(Token(range: NSRange(location: start, length: index - start), kind: kind)) }
        while index < count {
            // Avoid thousands of attributed runs slowing down native text layout.
            if tokens.count >= 5_000 { return [] }
            let start = index, unit = units[index]
            if space(unit) {
                if unit == 10 || unit == 13 { commandStart = true }
                index += 1; continue
            }
            let lineStart = index == 0 || units[index - 1] == 10 || units[index - 1] == 13
            let lineComment = (language.hashComments && unit == 35 && (language != .shell || index == 0 || space(units[index - 1])))
                || (language.slashComments && matches([47, 47], at: index))
                || (language == .sql && matches([45, 45], at: index))
            if lineComment || (language == .markdown && lineStart && unit == 35) {
                while index < count && units[index] != 10 && units[index] != 13 { index += 1 }
                append(start, lineComment ? .comment : .keyword); continue
            }
            let htmlComment = language == .html && matches([60, 33, 45, 45], at: index)
            if htmlComment || (language.blockComments && matches([47, 42], at: index)) {
                let end: [UInt16] = htmlComment ? [45, 45, 62] : [42, 47]
                index += htmlComment ? 4 : 2
                var depth = 1
                while index < count {
                    if matches(end, at: index) {
                        index += end.count; depth -= 1
                        if depth == 0 { break }
                    } else if [.swift, .rust].contains(language) && matches([47, 42], at: index) {
                        depth += 1; index += 2
                    } else { index += 1 }
                }
                append(start, .comment); continue
            }
            if language == .html {
                if unit == 60 { inTag = true }
                if unit == 62 { inTag = false }
                if !inTag { index += 1; continue }
            }
            // Rust lifetimes are identifiers, not unterminated character literals.
            if language == .rust && unit == 39 && index + 1 < count && identifier(units[index + 1])
                && !(index + 2 < count && units[index + 2] == 39) {
                index += 1
                while index < count && (identifier(units[index]) || digit(units[index])) { index += 1 }
                append(start, .typeName); continue
            }
            if unit == 34 || unit == 39 || (unit == 96 && [.javascript, .typescript, .shell, .go, .markdown].contains(language)) {
                let triple = [.python, .swift, .toml].contains(language) && matches([unit, unit, unit], at: index)
                let delimiter = Array(repeating: unit, count: triple ? 3 : 1)
                index += delimiter.count
                while index < count {
                    if matches(delimiter, at: index) { index += delimiter.count; break }
                    if !triple && unit != 96 && (units[index] == 10 || units[index] == 13) { break }
                    if units[index] == 92 && !(language == .shell && unit == 39) { index = min(count, index + 2) }
                    else { index += 1 }
                }
                let next = nextContent(index)
                let key = [.json, .javascript, .typescript, .yaml, .toml].contains(language)
                    && next < count && (units[next] == 58 || units[next] == 61)
                append(start, key ? .property : .string); commandStart = false; continue
            }
            if language == .shell && unit == 36 {
                index += 1
                if commandStart && index < count && space(units[index]) { continue }
                if index < count && units[index] == 123 {
                    index += 1
                    while index < count && units[index] != 125 && units[index] != 10 { index += 1 }
                    if index < count && units[index] == 125 { index += 1 }
                } else {
                    while index < count && (identifier(units[index]) || digit(units[index]) || units[index] == 63) { index += 1 }
                }
                append(start, .typeName); commandStart = false; continue
            }
            if digit(unit) {
                index += 1
                while index < count && (digit(units[index]) || (65...70).contains(units[index]) || (97...102).contains(units[index])
                    || units[index] == 120 || units[index] == 88 || units[index] == 46 || units[index] == 95
                    || ((units[index] == 43 || units[index] == 45) && (units[index - 1] == 101 || units[index - 1] == 69))) { index += 1 }
                append(start, .number); commandStart = false; continue
            }
            if identifier(unit) || (language == .shell && unit == 45 && index + 1 < count && (identifier(units[index + 1]) || units[index + 1] == 45)) {
                index += 1
                while index < count && (identifier(units[index]) || digit(units[index])
                    || ([.shell, .css, .html, .yaml].contains(language) && units[index] == 45)) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                let next = nextContent(index)
                if keywords[language, default: []].contains(language == .sql ? word.lowercased() : word) { append(start, .keyword) }
                else if language == .html { append(start, next < count && units[next] == 61 ? .property : .keyword) }
                else if language == .shell {
                    if unit == 45 || (next < count && units[next] == 61) { append(start, .property) }
                    else if commandStart { append(start, .function) }
                } else if next < count && units[next] == 40 { append(start, .function) }
                else if next < count && (units[next] == 58 || units[next] == 61) && [.json, .yaml, .toml, .css].contains(language) { append(start, .property) }
                else if (65...90).contains(unit) && ![.json, .yaml, .toml, .markdown].contains(language) { append(start, .typeName) }
                if language != .shell || !(next < count && units[next] == 61) { commandStart = false }
                continue
            }
            if language == .shell && [59, 124, 38].contains(unit) { commandStart = true }
            index += 1
        }
        return tokens
    }

    private static let keywords: [Language: Set<String>] = {
        let lists: [Language: String] = [
            .swift: "actor as associatedtype async await break case catch class continue default defer deinit do else enum extension false fileprivate for func guard if import in init inout internal is let nil nonisolated open override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while",
            .python: "and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield match case",
            .javascript: "async await break case catch class const continue debugger default delete do else export extends false finally for from function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while with yield",
            .typescript: "abstract any as async await boolean break case catch class const continue declare default delete do else enum export extends false finally for from function if implements import in infer instanceof interface keyof let namespace never new null number of private protected public readonly return static string super switch symbol this throw true try type typeof undefined unknown var void while yield",
            .c: "auto break case char const continue default do double else enum extern float for goto if inline int long register return short signed sizeof static struct switch typedef union unsigned void volatile while",
            .cpp: "alignas auto bool break case catch char class const constexpr continue default delete do double else enum explicit extern false float for friend if inline int long namespace new nullptr operator override private protected public return short signed sizeof static struct switch template this throw true try typedef typename union unsigned using virtual void volatile while",
            .csharp: "abstract async await bool break case catch class const continue decimal default delegate do double else enum event false finally float for foreach if in int interface internal is lock namespace new null object out override partial private protected public readonly ref return sealed short static string struct switch this throw true try typeof using var virtual void while",
            .java: "abstract boolean break byte case catch char class const continue default do double else enum extends false final finally float for if implements import instanceof int interface long native new null package private protected public return short static super switch synchronized this throw throws transient true try var void volatile while",
            .go: "break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var",
            .rust: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while",
            .shell: "if then else elif fi for while until do done case esac in function select time coproc export local readonly declare return break continue",
            .json: "true false null", .yaml: "true false null yes no on off", .toml: "true false",
            .sql: "select from where join inner outer left right full on as and or not null true false insert into values update set delete create alter drop table index view primary key foreign references distinct group by order having limit offset union all exists case when then else end asc desc count sum avg min max",
            .css: "important inherit initial unset none auto var", .html: "", .markdown: ""
        ]
        return lists.mapValues { Set($0.split(separator: " ").map(String.init)) }
    }()
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
        if SyntaxHighlighting.Language.resolve(language) != nil {
            return SyntaxHighlighting.highlight(text, language: language)
        }
        let lines = text.components(separatedBy: "\n")
        let label = language.lowercased().split(whereSeparator: { $0.isWhitespace }).first ?? ""
        let isDiff = ["diff", "patch"].contains(label) || lines.contains {
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
