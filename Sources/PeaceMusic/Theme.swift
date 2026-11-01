import SwiftUI

/// How controls and text are drawn, independent of the player mode.
enum UITheme: String {
    case glass, mono

    var next: UITheme { self == .glass ? .mono : .glass }

    func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        switch self {
        case .glass:
            .system(size: size, weight: weight, design: .rounded)
        case .mono:
            // Monospace runs wide, so display sizes come down to fit the same layouts.
            .system(size: size >= 20 ? size * 0.85 : size, weight: weight, design: .monospaced)
        }
    }

    func cornerRadius(_ radius: CGFloat) -> CGFloat {
        self == .mono ? 0 : radius
    }
}

extension EnvironmentValues {
    @Entry var uiTheme: UITheme = .glass
}

extension View {
    /// Background for floating panels and labels that aren't buttons.
    @ViewBuilder
    func themedPanel(_ theme: UITheme, cornerRadius: CGFloat) -> some View {
        switch theme {
        case .glass:
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
        case .mono:
            background(.black.opacity(0.97))
                .overlay(Rectangle().strokeBorder(.white.opacity(0.75), lineWidth: 1))
        }
    }
}
