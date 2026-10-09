import AppKit
import SwiftUI

/// Common title and metadata hierarchy for the menu bar and conversation header.
struct SessionTitle: View {
    let title: String
    let status: String
    var elapsed = ""
    var font: Font = .headline

    var body: some View {
        HStack {
            Text(title).font(font).lineLimit(1).truncationMode(.tail).help(title)
            Spacer(minLength: 4)
            StatusPill(status: status, elapsed: elapsed)
        }
    }
}

struct SessionMetadata: View {
    let repository: String
    let branch: String
    var git: GitStatus?
    let model: String
    var source = ""
    let effort: String
    let totalTokens: Int?
    let contextUsed: Int?
    let contextWindow: Int?
    var contextEstimated = false
    /// Off where the surrounding row already names the repository and branch.
    var showsLocation = true
    /// A fixed width for the context bar; nil lets it fill the line.
    var contextBarWidth: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsLocation {
                HStack(spacing: 10) {
                    Label { Text((repository as NSString).abbreviatingWithTildeInPath) } icon: {
                        Octicons.swiftUIImage("repo").resizable().frame(width: 12, height: 12)
                    }
                    .lineLimit(1).truncationMode(.middle).help(repository)
                    if !branch.isEmpty && branch != "-" {
                        BranchRef(name: branch).help("Branch: \(branch)")
                    }
                    if let git { GitCounts(git: git).fixedSize() }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    modelDetails.fixedSize()
                    context.frame(minWidth: contextBarWidth == nil ? 190 : nil)
                }
                VStack(alignment: .leading, spacing: 3) {
                    modelDetails
                    context
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var modelDetails: some View {
        HStack(spacing: 10) {
            if !model.isEmpty && model != "-" {
                Label { Text(model) } icon: { ModelLogo(model: model, source: source) }
                    .lineLimit(1).truncationMode(.middle).help(model)
            }
            if !effort.isEmpty && effort != "-" {
                Label(effort, systemImage: "brain").fixedSize().help("Reasoning effort")
            }
            if let tokens = totalTokens {
                Text("\(tokens.formatted(.number.notation(.compactName))) tokens").fixedSize()
            }
        }
    }

    @ViewBuilder private var context: some View {
        if let used = contextUsed, let window = contextWindow, window > 0 {
            ContextBar(used: used, window: window, estimated: contextEstimated, barWidth: contextBarWidth)
        }
    }
}

/// Status colors. Darker shades in light mode keep colored text readable on light backgrounds.
enum Palette {
    private static func shade(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    static let green = shade(light: NSColor(red: 0.11, green: 0.47, blue: 0.20, alpha: 1), dark: .systemGreen)
    static let orange = shade(light: NSColor(red: 0.70, green: 0.33, blue: 0.0, alpha: 1), dark: .systemOrange)
    static let gray = shade(light: NSColor(white: 0.40, alpha: 1), dark: .systemGray)
    static let yellow = shade(light: NSColor(red: 0.60, green: 0.47, blue: 0.0, alpha: 1), dark: .systemYellow)
    static let blue = shade(light: NSColor(red: 0.04, green: 0.42, blue: 0.76, alpha: 1), dark: .systemBlue)
    static let red = shade(light: NSColor(red: 0.75, green: 0.11, blue: 0.11, alpha: 1), dark: .systemRed)
}

/// Git counts in p10k's order and colors: ⇣behind⇡ahead *stashes ~conflicted +staged !unstaged ?untracked.
struct GitCounts: View {
    let git: GitStatus

    var body: some View {
        var segments: [(String, Color)] = []
        let sync = (git.behind > 0 ? "⇣\(git.behind)" : "") + (git.ahead > 0 ? "⇡\(git.ahead)" : "")
        if !sync.isEmpty { segments.append((sync, Palette.green)) }
        if git.stashes > 0 { segments.append(("*\(git.stashes)", Palette.green)) }
        if git.conflicted > 0 { segments.append(("~\(git.conflicted)", Palette.red)) }
        if git.staged > 0 { segments.append(("+\(git.staged)", Palette.yellow)) }
        if git.unstaged > 0 { segments.append(("!\(git.unstaged)", Palette.yellow)) }
        if git.untracked > 0 { segments.append(("?\(git.untracked)", Palette.blue)) }
        return segments.enumerated().reduce(Text("")) { text, item in
            text + Text(item.offset == 0 ? "" : " ") + Text(item.element.0).foregroundStyle(item.element.1)
        }
        .monospacedDigit()
        .help(git.summary)
        .accessibilityLabel(git.summary)
    }
}

// Use the installed apps' current monochrome marks, cached once per provider.
struct ModelLogo: View {
    let model: String
    var source = ""
    private enum Provider: String { case codex = "Codex", claude = "Claude Code", unknown = "Model" }
    private static let claude = load(["com.anthropic.claudefordesktop"], resource: "TrayIconTemplate")
    private static let codex = load(["com.openai.codex.beta", "com.openai.codex"], resource: "codexTemplate")

    private var provider: Provider {
        let name = model.lowercased()
        if name.hasPrefix("claude") { return .claude }
        if name.hasPrefix("gpt") || name.hasPrefix("codex") || name.hasPrefix("chatgpt")
            || name.range(of: #"^o\d"#, options: .regularExpression) != nil { return .codex }
        return Provider(rawValue: source) ?? .unknown
    }

    var body: some View {
        Group {
            if let image = provider == .claude ? Self.claude : provider == .codex ? Self.codex : nil {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                    .frame(width: provider == .claude ? 14 : 11, height: 14)
            } else {
                Image(systemName: provider == .claude ? "sparkle" : provider == .codex ? "terminal" : "cpu")
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityLabel(provider.rawValue)
        .help(provider.rawValue)
    }

    private static func load(_ bundleIDs: [String], resource: String) -> NSImage? {
        for bundleID in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  let image = Bundle(url: url)?.image(forResource: resource) else { continue }
            image.isTemplate = true
            return image
        }
        return nil
    }
}

/// How full the agent's context window is, colored like the Claude status line by what is left:
/// green from 50%, yellow below 50%, red below 20%.
struct ContextBar: View {
    let used: Int
    let window: Int
    var estimated = false
    /// Nil fills the space it's given.
    var barWidth: CGFloat?

    var body: some View {
        let fraction = min(1, max(0, Double(used) / Double(max(1, window))))
        let left = Int(((1 - fraction) * 100).rounded())
        let color = left < 20 ? Palette.red : left < 50 ? Palette.yellow : Palette.green
        let compact = IntegerFormatStyle<Int>.number.notation(.compactName)
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(color).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(width: barWidth, height: 5)
            Text("\(used.formatted(compact)) / \(window.formatted(compact)) · \(estimated ? "≈" : "")\(left)% left")
                .monospacedDigit()
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(estimated ? "approximately " : "")\(left) percent left")
        .help(estimated
              ? "Estimated using the model’s standard context capacity; session overrides may differ. Usage includes cached input tokens."
              : "Context usage reported by the session. The bar shows usage; the percentage shows remaining capacity.")
    }
}

/// The status in words and color, with how long the agent has been in it ("Waiting 21m").
struct StatusPill: View {
    let status: String
    var elapsed = ""
    var compact = false

    private var color: Color {
        switch status.uppercased() {
        case "BUSY", "ACTIVE": return Palette.green
        case "WAITING": return Palette.orange
        case "INTERRUPTED": return Palette.red
        default: return Palette.gray
        }
    }

    static func elapsed(since start: Date?, until end: Date = Date()) -> String {
        guard let start else { return "" }
        let seconds = Int(max(0, end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(status.capitalized).fontWeight(.semibold)
            if !elapsed.isEmpty && elapsed != "-" { Text(elapsed).monospacedDigit().opacity(0.85) }
        }
        .font(compact ? .caption2 : .caption)
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 6 : 7).padding(.vertical, compact ? 1 : 2)
        .background(color.opacity(0.14), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct SubagentToggle: View {
    let count: Int
    let running: Int
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("\(count) subagent\(count == 1 ? "" : "s")")
                if running > 0 { Text("· \(running) running") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide subagents" : "Show subagents")
    }
}
