import AppKit
import Observation
import SwiftUI

/// Swaps between the main window and a small panel pinned above everything else. The panel
/// rests as a compact pill and springs open while the pointer is over it.
@MainActor
@Observable
final class MiniPlayerController {
    static let compactSize = NSSize(width: 300, height: 72)
    static let expandedSize = NSSize(width: 430, height: 156)

    private(set) var isOpen = false
    private(set) var isExpanded = false

    private let store: PlayerStore
    private let analyzer: MusicAnalyzer
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private weak var mainWindow: NSWindow?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?

    init(store: PlayerStore, analyzer: MusicAnalyzer) {
        self.store = store
        self.analyzer = analyzer
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        isExpanded = false
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        hideMainWindow()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        collapseTask?.cancel()
        panel?.orderOut(nil)
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func setExpanded(_ expanded: Bool) {
        collapseTask?.cancel()
        guard isOpen, expanded != isExpanded, let panel else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.74)) { isExpanded = expanded }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            // Slightly overshoots, which makes the panel feel springy like the content inside it.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.35, 1)
            panel.animator().setFrame(frame(for: expanded, from: panel.frame), display: true)
        }
    }

    fileprivate func pointerEntered() {
        setExpanded(true)
    }

    /// Waits a moment, so briefly leaving the edge doesn't snap it shut.
    fileprivate func pointerExited() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.45))
            if !Task.isCancelled { self?.setExpanded(false) }
        }
    }

    /// Stays pinned by its top edge, and grows toward whichever side has room.
    private func frame(for expanded: Bool, from current: NSRect) -> NSRect {
        let size = expanded ? Self.expandedSize : Self.compactSize
        var origin = NSPoint(x: current.midX - size.width / 2, y: current.maxY - size.height)
        if let area = (panel?.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
            origin.y = max(origin.y, area.minY + 8)
        }
        return NSRect(origin: origin, size: size)
    }

    private func hideMainWindow() {
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) else { return }
        mainWindow = window
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            // Hiding a window mid-transition would strand an empty full screen Space.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.9))
                if self?.isOpen == true { window.orderOut(nil) }
            }
        } else {
            window.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Setting this resets the level, so it has to come first.
        panel.isFloatingPanel = true
        // Above the Dock, menu bar and other apps' floating windows, on every Space and over
        // full screen apps.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        let view = MiniPlayerView()
            .environment(store)
            .environment(self)
            .environment(\.musicAnalyzer, analyzer)
        let host = MiniPlayerHostingView(rootView: view)
        host.onHoverChange = { [weak self] isInside in
            if isInside { self?.pointerEntered() } else { self?.pointerExited() }
        }
        panel.contentView = host
        panel.setContentSize(Self.compactSize)
        place(panel)
        return panel
    }

    /// Returns to where it was last dragged, unless that display is gone.
    private func place(_ panel: NSPanel) {
        let autosaveName = "PeaceMiniPlayer"
        let didRestore = panel.setFrameUsingName(autosaveName)
        let isVisible = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !didRestore || !isVisible, let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: area.maxX - Self.compactSize.width - 16,
                y: area.maxY - Self.compactSize.height - 16
            ))
        }
        // The saved frame may have been taken while expanded.
        panel.setFrame(NSRect(
            x: panel.frame.minX,
            y: panel.frame.maxY - Self.compactSize.height,
            width: Self.compactSize.width,
            height: Self.compactSize.height
        ), display: false)
        panel.setFrameAutosaveName(autosaveName)
    }
}

private final class MiniPlayerHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    /// Lets one click press a button, instead of the first click only focusing the panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The panel is never the active window, so this needs to track regardless of focus.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

private struct MiniPlayerView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(MiniPlayerController.self) private var miniPlayer
    @AppStorage("uiTheme") private var themeRaw = UITheme.glass.rawValue

    private var theme: UITheme { UITheme(rawValue: themeRaw) ?? .glass }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.cornerRadius(miniPlayer.isExpanded ? 30 : 36), style: .continuous)
    }

    var body: some View {
        Group {
            // Unloaded while hidden, which stops the animation and the audio tap.
            if miniPlayer.isOpen {
                content
            } else {
                Color.clear
            }
        }
        .environment(\.uiTheme, theme)
        .preferredColorScheme(.dark)
    }

    private var content: some View {
        ZStack {
            Color.black
            HalftoneField(minimumPitch: 7)
                .opacity(theme == .glass ? 0.62 : 0.38)
            LinearGradient(
                colors: [.black.opacity(0.62), .black.opacity(0.12)],
                startPoint: .leading, endPoint: .trailing
            )

            if miniPlayer.isExpanded {
                ExpandedMini().transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                CompactMini().transition(.opacity)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(theme == .glass ? 0.18 : 0.75), lineWidth: 1))
    }
}

private struct CompactMini: View {
    @Environment(PlayerStore.self) private var store
    @Environment(\.uiTheme) private var theme

    var body: some View {
        HStack(spacing: 11) {
            MiniDisc(size: 60)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.track?.title ?? "Nothing playing")
                    .font(theme.font(13, .heavy))
                    .foregroundStyle(.white)
                MiniLyricLine()
                    .font(theme.font(11, .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            MiniEqualizer()
                .frame(width: 34, height: 26)
        }
        .padding(.leading, 7)
        .padding(.trailing, 18)
    }
}

private struct ExpandedMini: View {
    @Environment(PlayerStore.self) private var store
    @Environment(MiniPlayerController.self) private var miniPlayer
    @Environment(\.uiTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            MiniDisc(size: 134)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.track?.title ?? "Nothing playing")
                            .font(theme.font(15, .heavy))
                            .foregroundStyle(.white)
                        Text(store.track?.artist ?? "")
                            .font(theme.font(12))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    PlayerButton(
                        symbol: "arrow.up.left.and.arrow.down.right",
                        title: "OPEN",
                        diameter: 26,
                        iconSize: 10,
                        action: miniPlayer.close
                    )
                    .help("Back to the full player")
                }
                Spacer(minLength: 2)
                MiniLyricLine()
                    .font(theme.font(13, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 2)
                HStack(spacing: 8) {
                    MiniProgress()
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 4) {
                            PlayerButton(symbol: "backward.fill", title: "|<", diameter: 30, iconSize: 10, action: store.previous)
                            PlayerButton(
                                symbol: store.isPlaying ? "pause.fill" : "play.fill",
                                title: store.isPlaying ? "||" : ">",
                                diameter: 36,
                                iconSize: 13,
                                monoWidth: 38,
                                action: store.togglePlayPause
                            )
                            PlayerButton(symbol: "forward.fill", title: ">|", diameter: 30, iconSize: 10, action: store.next)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.leading, 11)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
    }
}

/// A spinning record with the cover as its label, ringed by the live spectrum.
private struct MiniDisc: View {
    let size: CGFloat

    @Environment(PlayerStore.self) private var store
    @Environment(\.musicAnalyzer) private var analyzer
    @Environment(\.uiTheme) private var theme
    @State private var clock = SpinClock()

    private var discSize: CGFloat { size * 0.68 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45, paused: !store.isPlaying)) { context in
            let audio = analyzer.reading
            let angle = clock.angle(at: context.date, spinning: store.isPlaying)
            ZStack {
                MiniSpectrumRing(spectrum: audio.spectrum, innerRadius: discSize / 2 + size * 0.025, reach: size * 0.125)
                disc
                    .rotationEffect(.degrees(angle))
                    .scaleEffect(1 + audio.bass * 0.05)
            }
        }
        .frame(width: size, height: size)
    }

    private var disc: some View {
        ZStack {
            Circle().fill(Color(white: 0.05))
            ForEach(1..<4, id: \.self) { ring in
                Circle()
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                    .frame(
                        width: discSize * (0.58 + CGFloat(ring) * 0.13),
                        height: discSize * (0.58 + CGFloat(ring) * 0.13)
                    )
            }
            ArtworkImage(image: store.artwork)
                .frame(width: discSize * 0.56, height: discSize * 0.56)
                .clipShape(.circle)
            Circle()
                .fill(Color(white: 0.05))
                .frame(width: max(discSize * 0.07, 3), height: max(discSize * 0.07, 3))
        }
        .frame(width: discSize, height: discSize)
    }
}

private struct MiniSpectrumRing: View {
    let spectrum: [Float]
    let innerRadius: CGFloat
    let reach: CGFloat

    /// Each half of the ring runs lowest to highest, so bass kicks out from one side.
    private static let barCount = SpectrumAnalyzer.bandCount * 2

    var body: some View {
        Canvas { context, canvas in
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            var bars = Path()
            for bar in 0..<Self.barCount {
                let band = bar < spectrum.count ? bar : Self.barCount - 1 - bar
                let value = CGFloat(spectrum[band])
                let angle = Double(bar) / Double(Self.barCount) * 2 * .pi - .pi / 2
                let start = innerRadius
                let end = start + max(reach * value, 0.8)
                bars.move(to: CGPoint(x: center.x + cos(angle) * start, y: center.y + sin(angle) * start))
                bars.addLine(to: CGPoint(x: center.x + cos(angle) * end, y: center.y + sin(angle) * end))
            }
            let width = max(innerRadius * 2 * .pi / CGFloat(Self.barCount) * 0.55, 1)
            context.stroke(bars, with: .color(.white.opacity(0.92)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }
}

private struct MiniEqualizer: View {
    @Environment(PlayerStore.self) private var store
    @Environment(\.musicAnalyzer) private var analyzer
    @Environment(\.uiTheme) private var theme

    private static let barCount = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45, paused: !store.isPlaying)) { _ in
            let spectrum = analyzer.reading.spectrum
            Canvas { context, canvas in
                let gap: CGFloat = 3
                let width = (canvas.width - gap * CGFloat(Self.barCount - 1)) / CGFloat(Self.barCount)
                for bar in 0..<Self.barCount {
                    // Averages neighboring bands, since five bars cover the whole range.
                    let start = bar * spectrum.count / Self.barCount
                    let end = (bar + 1) * spectrum.count / Self.barCount
                    let value = spectrum[start..<end].reduce(0, +) / Float(end - start)
                    let height = max(canvas.height * CGFloat(value), width)
                    let rect = CGRect(
                        x: CGFloat(bar) * (width + gap),
                        y: canvas.height - height,
                        width: width,
                        height: height
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: theme.cornerRadius(width / 2)),
                        with: .color(.white)
                    )
                }
            }
        }
    }
}

private struct MiniLyricLine: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Text(text)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: text)
    }

    private var text: String {
        switch store.lyrics {
        case .synced(let lines):
            guard let index = store.lyricIndex, !lines[index].isInterlude else {
                return store.track?.artist ?? ""
            }
            return lines[index].text
        default:
            return store.track?.artist ?? ""
        }
    }
}

private struct MiniProgress: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = store.track?.duration ?? 0
            let progress = duration > 0 ? min(store.position(at: context.date) / duration, 1) : 0
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.25))
                    Rectangle().fill(.white).frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 2)
        }
        .allowsHitTesting(false)
    }
}
