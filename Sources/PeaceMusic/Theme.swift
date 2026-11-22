import AppKit
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

// The library window's look. Now Playing and the mini player stay dark either way.
enum AppLook: String {
    case dark, light

    static let key = "appLook"

    var scheme: ColorScheme { self == .light ? .light : .dark }
}

extension Color {
    // Text and lines: white in the dark look, near-black in the light one.
    fileprivate static let inkColor = Color(nsColor: NSColor(name: "PeaceInk") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? NSColor(white: 0.1, alpha: 1) : .white
    })

    // The opposite of ink, for text that sits on it.
    fileprivate static let paperColor = Color(nsColor: NSColor(name: "PeacePaper") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? .white : .black
    })
}

extension ShapeStyle where Self == Color {
    static var ink: Color { Color.inkColor }
    static var paper: Color { Color.paperColor }
}
