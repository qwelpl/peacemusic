import AppKit
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

    // For text that is measured in AppKit. Nil means the caller's own default.
    func nsFont(_ size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        let family: String
        switch self {
        case .theme: return nil
        case .sfPro: return system
        case .sfRounded: return system.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) }
        case .newYork: return system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) }
        case .helveticaNeue: family = "Helvetica Neue"
        case .avenirNext: family = "Avenir Next"
        case .futura: family = "Futura"
        case .didot: family = "Didot"
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: size)
    }
}

enum LyricStyle: String, CaseIterable, Identifiable {
    case classic, lens, pulse, lensPulse, terminal, terminalPulse, graph, centered, stars

    enum Layout { case classic, lens, terminal, graph, centered, stars }

    var id: Self { self }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .lens: "Lens"
        case .pulse: "Pulse"
        case .lensPulse: "Lens Pulse"
        case .terminal: "Terminal"
        case .terminalPulse: "Terminal Pulse"
        case .graph: "Graph"
        case .centered: "Centered"
        case .stars: "Stars"
        }
    }

    var layout: Layout {
        switch self {
        case .classic, .pulse: .classic
        case .lens, .lensPulse: .lens
        case .terminal, .terminalPulse: .terminal
        case .graph: .graph
        case .centered: .centered
        case .stars: .stars
        }
    }

    // Pulse styles throb the current line with the music.
    var isPulsing: Bool { self == .pulse || self == .lensPulse || self == .terminalPulse }

    var isCentered: Bool { layout == .centered }
}

enum LyricSettings {
    static let styleKey = "lyricStyle"
    static let fontKey = "lyricFont"
    static let scaleKey = "lyricScale"
    static let scaleRange = 0.6...1.6
    static let scaleStep = 0.1

    static func clampedScale(_ scale: Double) -> Double {
        min(max((scale * 10).rounded() / 10, scaleRange.lowerBound), scaleRange.upperBound)
    }
}

extension EnvironmentValues {
    @Entry var lyricStyle: LyricStyle = .classic
    @Entry var lyricFont: LyricFont = .theme
    @Entry var lyricScale: CGFloat = 1
    @Entry var lyricColors = LyricColors()
}

struct LyricColors {
    var text: Color = .white
    var highlight: Color = .white
    var secondary: Color = .white

    // Tints the lyrics with the most colorful part of the artwork.
    static func synced(from mesh: [Color]) -> LyricColors {
        let accent = mesh
            .map { NSColor($0).usingColorSpace(.sRGB) ?? .white }
            .max { $0.saturationComponent < $1.saturationComponent }
        guard let accent, accent.saturationComponent > 0.12 else { return LyricColors() }
        let hue = accent.hueComponent
        return LyricColors(
            text: .white,
            highlight: Color(hue: hue, saturation: 0.5, brightness: 1),
            secondary: Color(hue: hue, saturation: 0.22, brightness: 0.95)
        )
    }
}

enum LyricColorSlot: String, CaseIterable, Identifiable {
    case text, highlight, secondary

    var id: Self { self }
    var key: String { "lyricColor.\(rawValue)" }

    var title: String {
        switch self {
        case .text: "Lyric Text"
        case .highlight: "Highlight"
        case .secondary: "Secondary Text"
        }
    }

    static let autoSyncKey = "lyricColor.autoSync"

    static func resolved(mesh: [Color]) -> LyricColors {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: autoSyncKey) { return .synced(from: mesh) }
        func color(_ slot: LyricColorSlot) -> Color {
            defaults.string(forKey: slot.key).flatMap(Color.init(hex:)) ?? .white
        }
        return LyricColors(text: color(.text), highlight: color(.highlight), secondary: color(.secondary))
    }

    static func reset() {
        for slot in allCases { UserDefaults.standard.removeObject(forKey: slot.key) }
        UserDefaults.standard.set(false, forKey: autoSyncKey)
    }
}

@MainActor
final class LyricColorPanel: NSObject {
    static let shared = LyricColorPanel()
    private var slot: LyricColorSlot?

    func edit(_ slot: LyricColorSlot) {
        self.slot = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.title = slot.title
        panel.color = UserDefaults.standard.string(forKey: slot.key).flatMap(NSColor.init(hex:)) ?? .white
        self.slot = slot
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let slot, let hex = panel.color.hex else { return }
        UserDefaults.standard.set(hex, forKey: slot.key)
        UserDefaults.standard.set(false, forKey: LyricColorSlot.autoSyncKey)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        guard hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16), hex.count == 7 else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hex: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
}

extension Color {
    init?(hex: String) {
        guard let color = NSColor(hex: hex) else { return nil }
        self.init(nsColor: color)
    }
}
