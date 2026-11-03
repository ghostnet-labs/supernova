import AppKit
import SwiftUI

@main struct SyntaxChecks {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { print("FAIL: \(message)"); exit(1) }
    }
    static func main() {
        typealias Language = SyntaxHighlighting.Language
        typealias Kind = SyntaxHighlighting.Kind
        func tokens(_ text: String, _ language: Language) -> [(String, Kind)] {
            SyntaxHighlighting.tokens(in: text, language: language).map { ((text as NSString).substring(with: $0.range), $0.kind) }
        }
        func contains(_ values: [(String, Kind)], _ text: String, _ kind: Kind) -> Bool {
            values.contains { $0.0 == text && $0.1 == kind }
        }
        let swift = "let café = \"// 🚀 not a comment\"\n/* outer /* nested */ end */\nprint(café, 42)"
        let swiftTokens = tokens(swift, .swift)
        check(contains(swiftTokens, "let", .keyword), "Swift keyword")
        check(contains(swiftTokens, "\"// 🚀 not a comment\"", .string), "comment markers inside Unicode string stay strings")
        check(contains(swiftTokens, "/* outer /* nested */ end */", .comment), "nested Swift comments")
        check(contains(swiftTokens, "print", .function) && contains(swiftTokens, "42", .number), "function and number after Unicode")
        let python = "def greet(name):\n    text = \"\"\"first\n# still string\nlast\"\"\"\n    return True # done"
        let py = tokens(python, .python)
        check(contains(py, "def", .keyword) && contains(py, "True", .keyword), "Python keywords")
        check(contains(py, "\"\"\"first\n# still string\nlast\"\"\"", .string), "multiline Python string")
        check(contains(py, "# done", .comment), "Python line comment")
        let json = #"{"name":"a\"//b", "enabled":true, "count":-1.5e+2}"#
        let jsonTokens = tokens(json, .json)
        check(contains(jsonTokens, "\"name\"", .property) && contains(jsonTokens, "true", .keyword), "JSON keys and literals")
        check(contains(jsonTokens, #""a\"//b""#, .string), "escaped quote does not turn string into comment")
        check(contains(jsonTokens, "1.5e+2", .number), "JSON exponent")
        let shell = "# report\nghactivity --json \"$HOME # literal\" | jq .\necho ${USER} foo#bar"
        let sh = tokens(shell, .shell)
        check(contains(sh, "ghactivity", .function) && contains(sh, "jq", .function), "shell commands and pipelines")
        check(contains(sh, "--json", .property) && contains(sh, "${USER}", .typeName), "shell flags and variable")
        check(sh.filter { $0.1 == .comment }.count == 1, "shell hash inside a word is not a comment")
        check(contains(tokens("$ ghactivity --json", .shell), "ghactivity", .function), "console prompt preserves command highlighting")
        check(contains(tokens("fn borrow<'a>(x: &'a str) { let c = 'x'; }", .rust), "'a", .typeName), "Rust lifetime")
        check(contains(tokens("SELECT name FROM users WHERE enabled = true -- done", .sql), "SELECT", .keyword), "SQL case insensitive keywords")
        check(contains(tokens("<div class=\"item\">plain text<!-- comment --></div>", .html), "<!-- comment -->", .comment), "HTML comment")
        check(contains(tokens("color: #fff; /* CSS */", .css), "color", .property), "CSS property")
        check(contains(tokens("enabled: true # YAML", .yaml), "enabled", .property), "YAML key")
        check(contains(tokens("enabled = true # TOML", .toml), "enabled", .property), "TOML key")
        check(contains(tokens("# Heading\nText `command`", .markdown), "# Heading", .keyword), "Markdown heading")

        for (label, language) in [("SWIFT title=demo", Language.swift), ("py", .python), ("js", .javascript), ("ts", .typescript),
                                  ("bash", .shell), ("zsh", .shell), ("yml", .yaml), ("c++", .cpp), ("cs", .csharp), ("rs", .rust)] {
            check(Language.resolve(label) == language, "language alias \(label)")
        }
        let examples: [(String, String)] = [("swift", swift), ("python", python), ("json", json), ("sh", shell),
            ("js", "const answer = `hello\nworld`; // note\nconsole.log(42)"), ("ts", "interface User { name: string }"),
            ("c", "int main() { return 0; }"), ("cpp", "class Thing { public: bool ready = true; };"),
            ("csharp", "public string Name { get; set; }"), ("java", "public class Main { int count = 3; }"),
            ("go", "package main\nfunc main() { fmt.Println(42) }"), ("rust", "pub fn main() { let value = 42; }"),
            ("swift", "let text = \"unfinished 🚀"), ("python", "'''unfinished\nmultiline"), ("js", "/* unfinished"),
            ("unknown", "\tplain \"text\"\r\n🚀 café\n")]
        for (language, source) in examples {
            check(String(SyntaxHighlighting.highlight(source, language: language).characters) == source, "highlighting preserves exact text: \(language)")
        }
        let unknown = SyntaxHighlighting.highlight("let x = 42", language: "unknown")
        check(unknown.runs.allSatisfy { $0.foregroundColor == nil }, "unknown language stays plain")
        let large = String(repeating: "let x = 1\n", count: 12_000)
        check(SyntaxHighlighting.tokens(in: large, language: .swift).isEmpty, "large code bypasses tokenization")
        check(String(SyntaxHighlighting.highlight(large, language: "swift").characters) == large, "large fallback preserves text")
        check(SyntaxHighlighting.tokens(in: String(repeating: "1 ", count: 6_000), language: .swift).isEmpty, "attributed run limit")

        let a = AppTheme.Palette("a", "A", .dark, background: 0x101010, surface: 0x202020, foreground: 0xEEEEEE,
            accent: 0x88CCFF, success: 0x88DD88, warning: 0xDDCC88, error: 0xFF8899)
        let b = AppTheme.Palette("b", "B", .dark, background: 0x101010, surface: 0x202020, foreground: 0xEEEEEE,
            accent: 0xDD88FF, success: 0xAAEE99, warning: 0xEEDD88, error: 0x88BBFF)
        AppTheme.shared.palette = a
        let first = SyntaxHighlighting.highlight("let count = 42", language: "swift")
        check(first.runs.contains { $0.foregroundColor != nil }, "native attributed colors reach SwiftUI")
        AppTheme.shared.palette = b
        let second = SyntaxHighlighting.highlight("let count = 42", language: "swift")
        check(first != second, "same code recolors on theme change")
        AppTheme.shared.palette = a
        check(SyntaxHighlighting.highlight("let count = 42", language: "swift") == first, "cached original theme restored")
        let diff = "--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n"
        let coloredDiff = ChangeHighlighting.code(diff, language: "diff")
        check(String(coloredDiff.characters) == diff, "diff text and trailing newline preserved")
        check(coloredDiff.runs.contains { $0.foregroundColor == AppTheme.success }, "diff additions stay green")
        check(coloredDiff.runs.contains { $0.foregroundColor == AppTheme.error }, "diff removals stay red")
        check(ChangeHighlighting.code(diff, language: "Output") == coloredDiff, "tool output still detects diffs")
        let literal = "let text = \"\"\"\n@@ literal\n+not a diff\n\"\"\""
        check(ChangeHighlighting.code(literal, language: "swift") == SyntaxHighlighting.highlight(literal, language: "swift"), "known language takes precedence over diff-like string")

        AppTheme.shared.palette = nil
        var light: NSColor!, dark: NSColor!
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let value = SyntaxHighlighting.highlight("let x = 1", language: "swift")
                let color = NSColor(value.runs.first!.foregroundColor!).usingColorSpace(.sRGB)!
                if name == .aqua { light = color } else { dark = color }
            }
        }
        check(light != dark, "cached System syntax follows light and dark appearance")

        let sample = String(repeating: swift + "\n", count: 250)
        let cold = Date()
        _ = ChangeHighlighting.code(sample, language: "swift")
        let coldTime = Date().timeIntervalSince(cold)
        let warm = Date()
        for _ in 0..<100 { _ = ChangeHighlighting.code(sample, language: "swift") }
        print(String(format: "PASS: syntax, text preservation, limits, theme switching, and diffs; %.1f KB cold %.2fms, cached %.3fms",
                     Double(sample.utf8.count) / 1_000, coldTime * 1_000, Date().timeIntervalSince(warm) * 10))
    }
}
