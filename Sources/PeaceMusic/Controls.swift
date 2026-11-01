import SwiftUI

struct Scrubber: View {
    let value: Double
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void = { _ in }

    @State private var isHovered = false
    @State private var isDragging = false

    private var height: CGFloat { isHovered || isDragging ? 10 : 6 }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.24))
                Capsule()
                    .fill(.white)
                    .frame(width: max(height, geometry.size.width * min(max(value, 0), 1)))
                    .shadow(color: .white.opacity(isDragging ? 0.6 : 0), radius: 8)
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
                .font(.system(size: 12, weight: .semibold, design: .rounded))
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

    var body: some View {
        HStack(spacing: 22) {
            ToggleIcon(symbol: "shuffle", isOn: store.shuffle, action: store.toggleShuffle)
                .help("Shuffle")
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 18) {
                HStack(spacing: 14) {
                    GlassCircleButton(symbol: "backward.fill", diameter: 50, iconSize: 18, action: store.previous)
                    GlassCircleButton(
                        symbol: store.isPlaying ? "pause.fill" : "play.fill",
                        diameter: 70,
                        iconSize: 27,
                        action: store.togglePlayPause
                    )
                    GlassCircleButton(symbol: "forward.fill", diameter: 50, iconSize: 18, action: store.next)
                }
            }
            Spacer(minLength: 0)
            ToggleIcon(
                symbol: store.repeatMode == .one ? "repeat.1" : "repeat",
                isOn: store.repeatMode != .off,
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

struct GlassCircleButton: View {
    let symbol: String
    var diameter: CGFloat = 40
    var iconSize: CGFloat = 15
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(isOn ? .clear.tint(.white.opacity(0.28)).interactive() : .clear.interactive(), in: .circle)
    }
}

private struct ToggleIcon: View {
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(isOn ? 1 : 0.5))
                .shadow(color: .white.opacity(isOn ? 0.7 : 0), radius: 7)
                .frame(width: 34, height: 34)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
