import AppKit
import SwiftUI

enum WorkspaceThemes {
    static let preferenceKey = "Workspace.theme"
    static let fontPreferenceKey = "Workspace.font"
    // Familiar editor hues with softer text for long conversations. Build colors once.
    static let all: [AppTheme.Palette] = [
        .init("tokyo-night", "Tokyo Night", .dark,
              background: 0x1A1B26, surface: 0x24283B, foreground: 0xA0AACB,
              accent: 0x7AA2F7, success: 0x9ECE6A, warning: 0xE0AF68, error: 0xF7768E,
              syntax: .init(keyword: 0xBB9AF7, string: 0x9ECE6A, number: 0xFF9E64, typeName: 0x2AC3DE, function: 0x7AA2F7)),
        .init("vscode", "VS Code", .dark,
              background: 0x1E1E1E, surface: 0x252526, foreground: 0xAEB0B4,
              accent: 0x4DAAFC, success: 0x89D185, warning: 0xCCA700, error: 0xF48771,
              syntax: .init(keyword: 0xC586C0, string: 0xCE9178, number: 0xB5CEA8, typeName: 0x4EC9B0, function: 0xDCDCAA)),
        .init("github-dark", "GitHub Dark", .dark,
              background: 0x0D1117, surface: 0x161B22, foreground: 0xA3AAB2,
              accent: 0x58A6FF, success: 0x3FB950, warning: 0xD29922, error: 0xF85149,
              syntax: .init(keyword: 0xFF7B72, string: 0xA5D6FF, number: 0x79C0FF, typeName: 0xFFA657, function: 0xD2A8FF)),
        .init("dracula", "Dracula", .dark,
              background: 0x282A36, surface: 0x343746, foreground: 0xBCBCC0,
              accent: 0xBD93F9, success: 0x50FA7B, warning: 0xF1FA8C, error: 0xFF5555,
              syntax: .init(keyword: 0xFF79C6, string: 0xF1FA8C, number: 0xBD93F9, typeName: 0x8BE9FD, function: 0x50FA7B)),
        .init("nord", "Nord", .dark,
              background: 0x2E3440, surface: 0x3B4252, foreground: 0xC0C4CC,
              accent: 0x88C0D0, success: 0xA3BE8C, warning: 0xEBCB8B, error: 0xBF616A,
              syntax: .init(keyword: 0x81A1C1, string: 0xA3BE8C, number: 0xB48EAD, typeName: 0x8FBCBB, function: 0x88C0D0)),
        .init("catppuccin-mocha", "Catppuccin Mocha", .dark,
              background: 0x1E1E2E, surface: 0x313244, foreground: 0xA9B1C8,
              accent: 0xCBA6F7, success: 0xA6E3A1, warning: 0xF9E2AF, error: 0xF38BA8,
              syntax: .init(keyword: 0xCBA6F7, string: 0xA6E3A1, number: 0xFAB387, typeName: 0xF9E2AF, function: 0x89B4FA)),
        .init("gruvbox-dark", "Gruvbox Dark", .dark,
              background: 0x282828, surface: 0x3C3836, foreground: 0xBEB397,
              accent: 0x83A598, success: 0xB8BB26, warning: 0xFABD2F, error: 0xFB4934,
              syntax: .init(keyword: 0xFB4934, string: 0xB8BB26, number: 0xD3869B, typeName: 0xFABD2F, function: 0x8EC07C)),
        .init("obsidian", "Obsidian", .dark,
              background: 0x1E1E1E, surface: 0x262626, foreground: 0xB2B2B2,
              accent: 0xA88BFA, success: 0xA9C665, warning: 0xE0B866, error: 0xF28B82,
              syntax: .init(keyword: 0xC4A0FA, string: 0xA9C665, number: 0xE0B866, typeName: 0x8CD5CE, function: 0x82B7F2)),
        .init("one-dark", "One Dark", .dark,
              background: 0x282C34, surface: 0x353B45, foreground: 0x9EA5B2,
              accent: 0x61AFEF, success: 0x98C379, warning: 0xE5C07B, error: 0xE06C75,
              syntax: .init(keyword: 0xC678DD, string: 0x98C379, number: 0xD19A66, typeName: 0xE5C07B, function: 0x61AFEF)),
        .init("rose-pine", "Rosé Pine", .dark,
              background: 0x191724, surface: 0x26233A, foreground: 0xACABC3,
              accent: 0xC4A7E7, success: 0x9CCFD8, warning: 0xF6C177, error: 0xEB6F92,
              syntax: .init(keyword: 0xC4A7E7, string: 0xF6C177, number: 0xEBBCBA, typeName: 0x9CCFD8, function: 0xEB6F92))
    ]

    static func restore(defaults: UserDefaults = .standard) {
        let saved = defaults.string(forKey: preferenceKey)
        // Keep users of the retired light presets on a named, dark counterpart.
        let id = saved == "github-light" ? "github-dark" : saved == "solarized-light" ? "obsidian" : saved
        if id != saved { defaults.set(id, forKey: preferenceKey) }
        apply(all.first { $0.id == id })
        applyFont(WorkspaceFont(rawValue: defaults.string(forKey: fontPreferenceKey) ?? "") ?? .system)
    }

    static var font: WorkspaceFont {
        WorkspaceFont(rawValue: AppFont.shared.selection) ?? .system
    }

    static func selectFont(_ font: WorkspaceFont, defaults: UserDefaults = .standard) {
        if font == .system { defaults.removeObject(forKey: fontPreferenceKey) }
        else { defaults.set(font.rawValue, forKey: fontPreferenceKey) }
        applyFont(font)
    }

    private static func applyFont(_ font: WorkspaceFont) {
        AppFont.shared.family = WorkspaceFontLoader.load(font)
        AppFont.shared.design = font.design
        AppFont.shared.unavailable = font.postscriptName != nil && AppFont.shared.family == nil
        AppFont.shared.selection = font.rawValue
    }

    static func select(_ palette: AppTheme.Palette?, defaults: UserDefaults = .standard) {
        if let palette { defaults.set(palette.id, forKey: preferenceKey) }
        else { defaults.removeObject(forKey: preferenceKey) }
        apply(palette)
    }

    private static let systemForeground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.7, green: 0.7, blue: 0.7, alpha: 1) : .labelColor
    })

    private static func apply(_ palette: AppTheme.Palette?) {
        AppTheme.shared.systemForeground = systemForeground
        AppTheme.shared.palette = palette
        // Native controls, sheets, and title bars match the selected light/dark mode.
        NSApp?.appearance = palette.map { NSAppearance(named: $0.scheme == .dark ? .darkAqua : .aqua)! }
    }
}

struct WorkspaceThemePicker: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Appearance").font(AppFont.headline)
                    Text("Applies instantly and is saved for next time.")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close appearance settings")
                    .accessibilityLabel("Close appearance settings")
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fontSection
                    Divider()
                    Text("Theme").font(AppFont.subheadline.weight(.semibold))
                    systemTheme
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                        ForEach(WorkspaceThemes.all) { palette in themeCard(palette) }
                    }
                }.padding(2)
            }.frame(height: 490)
        }
        .padding(18).frame(width: 420)
        .foregroundStyle(AppTheme.foreground).background(AppTheme.background)
        .tint(AppTheme.accent)
        .font(AppFont.body)
        .fontDesign(AppFont.shared.design)
        .preferredColorScheme(AppTheme.shared.palette?.scheme)
    }

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Font", selection: Binding(get: { WorkspaceThemes.font }, set: { WorkspaceThemes.selectFont($0) })) {
                ForEach(WorkspaceFont.allCases) { font in Text(font.rawValue).tag(font) }
            }
            .accessibilityIdentifier("workspace.appearance.font")
            Text(AppFont.shared.unavailable ? "\(WorkspaceThemes.font.typeface) unavailable; using System." : WorkspaceThemes.font.typeface)
                .font(AppFont.caption).foregroundStyle(.secondary)
            Text("The quick brown fox · Aa Bb 0123")
                .font(AppFont.system(size: 15)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            Text("Applies throughout the app. Code and diffs stay monospaced.")
                .font(AppFont.caption).foregroundStyle(.secondary)
        }
    }

    private var systemTheme: some View {
        Button { WorkspaceThemes.select(nil) } label: {
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled").font(AppFont.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System").font(AppFont.callout.weight(.medium))
                    Text("Follow macOS appearance").font(AppFont.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if AppTheme.shared.palette == nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.accent) }
            }.padding(10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityAddTraits(AppTheme.shared.palette == nil ? .isSelected : [])
        .accessibilityIdentifier("workspace.theme.system")
    }

    private func themeCard(_ palette: AppTheme.Palette) -> some View {
        let selected = AppTheme.shared.palette?.id == palette.id
        return Button { WorkspaceThemes.select(palette) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(0..<4) { index in
                        Circle().fill([palette.accent, palette.success, palette.warning, palette.error][index])
                            .frame(width: 10, height: 10)
                    }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? palette.accent : palette.foreground.opacity(0.3))
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(palette.name).font(AppFont.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(palette.scheme == .dark ? "Dark" : "Light").font(AppFont.system(size: 10))
                        .foregroundStyle(palette.foreground.opacity(0.7))
                }
            }
            .foregroundStyle(palette.foreground)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? palette.accent : palette.foreground.opacity(0.2), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.name + (palette.scheme == .dark ? ", dark theme" : ", light theme"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("workspace.theme.\(palette.id)")
    }
}
