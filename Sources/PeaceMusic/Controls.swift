import SwiftUI

struct Scrubber: View {
    let value: Double
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void = { _ in }

    @Environment(\.uiTheme) private var theme
    @State private var isHovered = false
    @State private var isDragging = false

    private var isExpanded: Bool { isHovered || isDragging }
    private var height: CGFloat {
        switch theme {
        case .glass: isExpanded ? 10 : 6
        case .mono: isExpanded ? 4 : 2
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: theme.cornerRadius(height / 2))
            ZStack(alignment: .leading) {
                shape.fill(.white.opacity(0.24))
                shape
                    .fill(.white)
                    .frame(width: max(height, geometry.size.width * min(max(value, 0), 1)))
                    .shadow(color: .white.opacity(isDragging && theme == .glass ? 0.6 : 0), radius: 8)
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        onChange(fraction(drag.location.x, width: geometry.size.width))
                    }
                    .onEnded { drag in
                        isDragging = false
                        onCommit(fraction(drag.location.x, width: geometry.size.width))
                    }
            )
        }
        .frame(height: 20)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: height)
    }

    private func fraction(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }
}

struct ProgressRow: View {
    @Environment(PlayerStore.self) private var store
    @Environment(\.uiTheme) private var theme
    @State private var dragValue: Double?

    private var duration: Double { store.track?.duration ?? 0 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let position = store.position(at: context.date)
            let shown = dragValue ?? (duration > 0 ? position / duration : 0)
            VStack(spacing: 2) {
                Scrubber(value: shown) { dragValue = $0 } onCommit: { value in
                    store.seek(to: value * duration)
                    dragValue = nil
                }
                HStack {
                    Text(Self.format(shown * duration))
                    Spacer()
                    Text("-" + Self.format(max(duration - shown * duration, 0)))
                }
                .font(theme.font(12, .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct TransportRow: View {
    @Environment(PlayerStore.self) private var store
    @Environment(\.uiTheme) private var theme

    var body: some View {
        HStack(spacing: theme == .glass ? 22 : 6) {
            PlayerButton(symbol: "shuffle", title: "SHUF", isOn: store.shuffle, style: .quiet, action: store.toggleShuffle)
                .help("Shuffle")
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 18) {
                HStack(spacing: theme == .glass ? 14 : 6) {
                    PlayerButton(symbol: "backward.fill", title: "PREV", diameter: 50, iconSize: 18, action: store.previous)
                    PlayerButton(
                        symbol: store.isPlaying ? "pause.fill" : "play.fill",
                        title: store.isPlaying ? "PAUSE" : "PLAY",
                        diameter: 70,
                        iconSize: 27,
                        monoWidth: 70,
                        action: store.togglePlayPause
                    )
                    PlayerButton(symbol: "forward.fill", title: "NEXT", diameter: 50, iconSize: 18, action: store.next)
                }
            }
            Spacer(minLength: 0)
            PlayerButton(
                symbol: store.repeatMode == .one ? "repeat.1" : "repeat",
                title: store.repeatMode == .one ? "RPT 1" : "RPT",
                isOn: store.repeatMode != .off,
                style: .quiet,
                action: store.cycleRepeat
            )
            .help("Repeat")
        }
    }
}

struct VolumeRow: View {
    @Environment(PlayerStore.self) private var store
    @State private var lastSent = Date.distantPast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            Scrubber(value: store.volume) { value in
                // Apple Events are slow, so a drag sends at most 20 per second.
                if Date().timeIntervalSince(lastSent) > 0.05 {
                    lastSent = Date()
                    store.setVolume(value)
                }
            } onCommit: { store.setVolume($0) }
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.6))
    }
}

/// A liquid glass circle with an icon, or a square outlined label in the Mono theme.
struct PlayerButton: View {
    enum Style {
        case regular
        /// No glass surface, for secondary toggles.
        case quiet
    }

    let symbol: String
    let title: String
    var diameter: CGFloat = 40
    var iconSize: CGFloat = 15
    var isOn = false
    var style: Style = .regular
    var monoWidth: CGFloat?
    let action: () -> Void

    @Environment(\.uiTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        switch theme {
        case .glass: glassBody
        case .mono: monoBody
        }
    }

    @ViewBuilder
    private var glassBody: some View {
        let button = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white.opacity(style == .quiet && !isOn ? 0.5 : 1))
                .shadow(color: .white.opacity(style == .quiet && isOn ? 0.7 : 0), radius: 7)
                .frame(width: style == .quiet ? 34 : diameter, height: style == .quiet ? 34 : diameter)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)

        switch style {
        case .regular:
            button.glassEffect(isOn ? .clear.tint(.white.opacity(0.28)).interactive() : .clear.interactive(), in: .circle)
        case .quiet:
            button
        }
    }

    private var monoBody: some View {
        let isFilled = isOn || isHovered
        return Button(action: action) {
            Text(title)
                .font(theme.font(12, .bold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isFilled ? .black : .white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(minWidth: monoWidth)
                .background(isFilled ? Color.white : Color.black.opacity(0.35))
                .overlay(Rectangle().strokeBorder(.white.opacity(0.75), lineWidth: 1))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
