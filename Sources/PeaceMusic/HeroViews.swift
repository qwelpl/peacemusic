import AppKit
import SwiftUI

enum HeroStyle: String {
    case vinyl, cover
}

struct ArtworkImage: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(.white.opacity(0.08))
                Image(systemName: "music.note")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// Square cover that leans toward the pointer and settles back when paused.
struct CoverHero: View {
    @Environment(\.uiTheme) private var theme
    let image: NSImage?
    let isPlaying: Bool
    let size: CGFloat

    @State private var tilt: CGSize = .zero

    var body: some View {
        ArtworkImage(image: image)
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: theme.cornerRadius(size * 0.05), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: theme.cornerRadius(size * 0.05), style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isPlaying ? 0.5 : 0.28), radius: isPlaying ? 44 : 18, y: isPlaying ? 26 : 10)
            .scaleEffect(isPlaying ? 1 : 0.86)
            .rotation3DEffect(.degrees(tilt.width * 9), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(-tilt.height * 9), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .animation(.spring(response: 0.6, dampingFraction: 0.72), value: isPlaying)
            .onContinuousHover { phase in
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    switch phase {
                    case .active(let point):
                        tilt = CGSize(width: point.x / size - 0.5, height: point.y / size - 0.5)
                    case .ended:
                        tilt = .zero
                    }
                }
            }
    }
}

/// Accumulates rotation only while playing, so the record stops where it was paused.
final class SpinClock {
    private var angle = 0.0
    private var last: Date?

    func angle(at date: Date, spinning: Bool) -> Double {
        if spinning, let last {
            angle += date.timeIntervalSince(last) * 200 // 33⅓ rpm
        }
        last = date
        return angle.truncatingRemainder(dividingBy: 360)
    }
}

struct VinylHero: View {
    let image: NSImage?
    let isPlaying: Bool
    let progress: Double
    let size: CGFloat

    @State private var clock = SpinClock()

    private var discSize: CGFloat { size * 0.88 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(paused: !isPlaying)) { context in
                disc.rotationEffect(.degrees(clock.angle(at: context.date, spinning: isPlaying)))
            }
            .overlay(sheen)
            .frame(width: discSize, height: discSize)
            .shadow(color: .black.opacity(0.55), radius: 36, y: 22)
            .offset(y: size * 0.06)

            Tonearm(size: size)
                .rotationEffect(
                    .degrees(isPlaying ? 20 + 12 * progress : 0),
                    anchor: UnitPoint(x: Tonearm.pivot.x, y: Tonearm.pivot.y)
                )
                .animation(.spring(response: 1.1, dampingFraction: 0.8), value: isPlaying)
        }
        .frame(width: size, height: size)
    }

    private var disc: some View {
        ZStack {
            Canvas { context, canvas in
                let radius = canvas.width / 2
                let center = CGPoint(x: radius, y: radius)
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: canvas)), with: .color(Color(white: 0.045)))
                var ring = radius * 0.4
                while ring < radius * 0.985 {
                    let box = CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)
                    let isTrackGap = Int(ring / (radius * 0.16)) % 2 == 0 && Int(ring) % 9 == 0
                    context.stroke(
                        Path(ellipseIn: box),
                        with: .color(.white.opacity(isTrackGap ? 0.1 : 0.035)),
                        lineWidth: 0.6
                    )
                    ring += 2.6
                }
            }
            ArtworkImage(image: image)
                .frame(width: discSize * 0.4, height: discSize * 0.4)
                .clipShape(.circle)
                .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
            Circle()
                .fill(Color(white: 0.06))
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .frame(width: discSize * 0.028, height: discSize * 0.028)
            Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    /// Light stays fixed while the record turns underneath it, as on a real platter.
    private var sheen: some View {
        Circle()
            .fill(AngularGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0.02),
                    .init(color: .white.opacity(0.17), location: 0.1),
                    .init(color: .white.opacity(0), location: 0.2),
                    .init(color: .white.opacity(0), location: 0.52),
                    .init(color: .white.opacity(0.13), location: 0.6),
                    .init(color: .white.opacity(0), location: 0.7),
                ],
                center: .center
            ))
            .mask {
                // Keeps the sheen on the grooves and off the label.
                ZStack {
                    Circle().fill(.white)
                    Circle().fill(.black).frame(width: discSize * 0.41, height: discSize * 0.41)
                }
                .compositingGroup()
                .luminanceToAlpha()
            }
            .allowsHitTesting(false)
    }
}

private struct Tonearm: View {
    static let pivot = CGPoint(x: 0.97, y: 0.06)

    let size: CGFloat

    var body: some View {
        Canvas { context, canvas in
            let start = CGPoint(x: canvas.width * Self.pivot.x, y: canvas.height * Self.pivot.y)
            let bend = CGPoint(x: start.x + canvas.width * 0.012, y: start.y + canvas.height * 0.5)
            let tip = CGPoint(x: start.x - canvas.width * 0.012, y: start.y + canvas.height * 0.63)

            var arm = Path()
            arm.move(to: start)
            arm.addLine(to: bend)
            arm.addLine(to: tip)
            let metal = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [Color(white: 0.92), Color(white: 0.55)]),
                startPoint: start, endPoint: tip
            )
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 5))
                layer.stroke(arm, with: metal, style: StrokeStyle(lineWidth: size * 0.011, lineCap: .round, lineJoin: .round))

                let headWidth = size * 0.032
                let headHeight = size * 0.07
                let head = Path(
                    roundedRect: CGRect(x: tip.x - headWidth / 2, y: tip.y - headHeight * 0.3, width: headWidth, height: headHeight),
                    cornerRadius: headWidth * 0.2
                )
                layer.fill(head, with: .color(Color(white: 0.8)))

                let hubSize = size * 0.075
                let hub = Path(ellipseIn: CGRect(x: start.x - hubSize / 2, y: start.y - hubSize / 2, width: hubSize, height: hubSize))
                layer.fill(hub, with: .color(Color(white: 0.75)))
                let capSize = hubSize * 0.42
                let cap = Path(ellipseIn: CGRect(x: start.x - capSize / 2, y: start.y - capSize / 2, width: capSize, height: capSize))
                layer.fill(cap, with: .color(Color(white: 0.3)))
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}
