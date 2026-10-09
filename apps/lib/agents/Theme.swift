import AppKit
import SwiftUI

enum AppTheme {
    // Semantic system colors follow macOS appearance and accent preferences.
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color.primary.opacity(0.035)
    static let separator = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)

    static func messageFill(isUser: Bool, scheme: ColorScheme) -> Color {
        let stronger = isUser ? scheme == .light : scheme == .dark
        return Color.primary.opacity(stronger ? 0.08 : 0.035)
    }
}
