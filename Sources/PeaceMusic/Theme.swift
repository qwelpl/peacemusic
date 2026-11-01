import SwiftUI

enum UITheme: String {
    case glass, mono

    var next: UITheme { self == .glass ? .mono : .glass }

    func font(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        switch self {
        case .glass:
            .system(size: size, weight: weight, design: .rounded)
        case .mono:
            .system(size: size >= 20 ? size * 0.85 : size, weight: weight, design: .monospaced)
        }
    }

    func cornerRadius(_ radius: CGFloat) -> CGFloat {
        self == .mono ? 0 : radius
    }
}

extension EnvironmentValues {
    @Entry var uiTheme: UITheme = .glass
    @Entry var musicAnalyzer = MusicAnalyzer()
}

extension View {
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
