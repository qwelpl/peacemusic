import SwiftUI

enum LyricFont: String, CaseIterable, Identifiable {
    case theme, sfPro, sfRounded, newYork, helveticaNeue, avenirNext, futura, didot

    var id: Self { self }

    var title: String {
        switch self {
        case .theme: "Theme Default"
        case .sfPro: "SF Pro"
        case .sfRounded: "SF Rounded"
        case .newYork: "New York"
        case .helveticaNeue: "Helvetica Neue"
        case .avenirNext: "Avenir Next"
        case .futura: "Futura"
        case .didot: "Didot"
        }
    }

    func font(_ size: CGFloat, _ weight: Font.Weight, theme: UITheme) -> Font {
        switch self {
        case .theme: theme.font(size, weight)
        case .sfPro: .system(size: size, weight: weight)
        case .sfRounded: .system(size: size, weight: weight, design: .rounded)
        case .newYork: .system(size: size, weight: weight, design: .serif)
        case .helveticaNeue: .custom("Helvetica Neue", size: size).weight(weight)
        case .avenirNext: .custom("Avenir Next", size: size).weight(weight)
        case .futura: .custom("Futura", size: size).weight(weight)
        case .didot: .custom("Didot", size: size).weight(weight)
        }
    }
}

enum LyricSettings {
    static let fontKey = "lyricFont"
    static let scaleKey = "lyricScale"
    static let scaleRange = 0.6...1.6
    static let scaleStep = 0.1

    static func clampedScale(_ scale: Double) -> Double {
        min(max((scale * 10).rounded() / 10, scaleRange.lowerBound), scaleRange.upperBound)
    }
}

extension EnvironmentValues {
    @Entry var lyricFont: LyricFont = .theme
    @Entry var lyricScale: CGFloat = 1
}
