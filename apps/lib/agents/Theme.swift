import AppKit
import Observation
import SwiftUI

@Observable final class AppTheme {
    struct SyntaxPalette {
        let keyword, string, number, typeName, function: UInt32
    }

    struct SyntaxColors {
        let keyword, string, number, typeName, function, comment: Color

        static func readable(_ palette: SyntaxPalette, background: UInt32, foreground: UInt32) -> Self {
            func components(_ hex: UInt32) -> [Double] {
                [16, 8, 0].map { Double((hex >> $0) & 255) / 255 }
            }
            func luminance(_ rgb: [Double]) -> Double {
                let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
            }
            let base = components(background), text = components(foreground), light = luminance(base)
            // Adjust toward black or white so softer prose doesn't wash out syntax hues.
            let target = Array(repeating: luminance(text) > light ? 1.0 : 0.0, count: 3)
            func readable(_ rgb: [Double]) -> Color {
                var adjusted = rgb
                // Resolve once per palette, including readable but quieter comments.
                for step in 0...20 {
                    adjusted = zip(rgb, target).map { $0 + ($1 - $0) * Double(step) / 20 }
                    let value = luminance(adjusted)
                    if (max(value, light) + 0.05) / (min(value, light) + 0.05) >= 4.5 { break }
                }
                return Color(.sRGB, red: adjusted[0], green: adjusted[1], blue: adjusted[2], opacity: 1)
            }
            return Self(keyword: readable(components(palette.keyword)), string: readable(components(palette.string)),
                        number: readable(components(palette.number)), typeName: readable(components(palette.typeName)),
                        function: readable(components(palette.function)), comment: readable(zip(base, text).map { $0 + ($1 - $0) * 0.55 }))
        }
    }

    struct Palette: Identifiable {
        let id: String
        let name: String
        let scheme: ColorScheme
        let background, surface, foreground, accent, success, warning, error: Color
        let sidebar, inlineCode, inlineCodeBackground: Color
        let syntax: SyntaxColors

        init(_ id: String, _ name: String, _ scheme: ColorScheme,
             background: UInt32, surface: UInt32, foreground: UInt32,
             accent: UInt32, success: UInt32, warning: UInt32, error: UInt32, syntax: SyntaxPalette? = nil) {
            self.id = id; self.name = name; self.scheme = scheme
            func color(_ hex: UInt32, toward other: UInt32 = 0, by fraction: Double = 0) -> Color {
                func channel(_ shift: UInt32) -> Double {
                    (Double((hex >> shift) & 255) * (1 - fraction) + Double((other >> shift) & 255) * fraction) / 255
                }
                return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0), opacity: 1)
            }
            // Preserve the sidebar's hue: the conversation is only 10% brighter,
            // without mixing in a neutral gray or white that would wash it out.
            self.background = color(background, by: scheme == .dark ? 0.12 : 0)
            self.surface = color(surface)
            self.foreground = color(foreground); self.accent = color(accent)
            self.success = color(success); self.warning = color(warning); self.error = color(error)
            // Related tones separate navigation and code without competing with the content.
            sidebar = color(background, by: scheme == .dark ? 0.2 : 0.03)
            inlineCode = color(error, toward: foreground, by: 0.55)
            inlineCodeBackground = color(background, toward: foreground, by: 0.08)
            self.syntax = .readable(syntax ?? SyntaxPalette(keyword: error, string: success, number: warning,
                                                           typeName: warning, function: accent),
                                    background: surface, foreground: foreground)
        }
    }

    // Observation invalidates only views that read these colors; switching never
    // replaces the view tree or reloads sessions. Other apps retain system colors.
    static let shared = AppTheme()
    var palette: Palette?
    var systemForeground: Color = .primary
    static var background: Color { shared.palette?.background ?? Color(nsColor: .windowBackgroundColor) }
    static var sidebar: Color { shared.palette?.sidebar ?? systemSidebar }
    static var surface: Color { shared.palette?.surface ?? Color.primary.opacity(0.035) }
    static var inlineCode: Color { shared.palette?.inlineCode ?? systemInlineCode }
    static var inlineCodeBackground: Color { shared.palette?.inlineCodeBackground ?? systemInlineCodeBackground }
    static var foreground: Color { shared.palette?.foreground ?? shared.systemForeground }
    static var separator: Color { shared.palette?.foreground.opacity(0.16) ?? Color(nsColor: .separatorColor) }
    static var accent: Color { shared.palette?.accent ?? .accentColor }
    static var success: Color { shared.palette?.success ?? Color(nsColor: .systemGreen) }
    static var warning: Color { shared.palette?.warning ?? Color(nsColor: .systemOrange) }
    static var error: Color { shared.palette?.error ?? Color(nsColor: .systemRed) }
    static var syntax: SyntaxColors { shared.palette?.syntax ?? systemSyntax }

    private static let systemSyntax = SyntaxColors(
        keyword: adaptiveColor(light: 0xA626A4, dark: 0xD2A8FF), string: adaptiveColor(light: 0x246D32, dark: 0x9ECE6A),
        number: adaptiveColor(light: 0x885500, dark: 0xF2C66D), typeName: adaptiveColor(light: 0x16636A, dark: 0x7DCFFF),
        function: adaptiveColor(light: 0x005CC5, dark: 0x7AB7FF), comment: adaptiveColor(light: 0x606060, dark: 0xB0B0B0))

    private static let systemSidebar = adaptiveColor(light: 0xE5E5E5, dark: 0x202020)
    private static let systemInlineCode = adaptiveColor(light: 0xA72D46, dark: 0xFFA198)
    private static let systemInlineCodeBackground = adaptiveColor(light: 0xE8E8E8, dark: 0x383838)

    private static func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }

    static func messageFill(isUser: Bool, scheme: ColorScheme) -> Color {
        let stronger = isUser ? scheme == .light : scheme == .dark
        return foreground.opacity(stronger ? 0.08 : 0.035)
    }
}
