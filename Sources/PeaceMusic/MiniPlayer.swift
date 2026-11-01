import AppKit
import Observation
import SwiftUI

struct MiniPlayerCorner: Equatable {
    var isLeading = false
    var isTop = true

    var alignment: Alignment {
        switch (isLeading, isTop) {
        case (true, true): .topLeading
        case (false, true): .topTrailing
        case (true, false): .bottomLeading
        case (false, false): .bottomTrailing
        }
    }
}

// The panel stays a fixed size. Resizing it during SwiftUI layout aborts with too many constraint passes.
@MainActor
@Observable
final class MiniPlayerController {
    static let compactSize = NSSize(width: 300, height: 72)
    static let expandedSize = NSSize(width: 430, height: 156)
    static let margin: CGFloat = 24
    static let panelSize = NSSize(
        width: expandedSize.width + margin * 2,
        height: expandedSize.height + margin * 2
    )

    private(set) var isOpen = false
    private(set) var isExpanded = false
    private(set) var corner = MiniPlayerCorner()

    private let store: PlayerStore
    private let analyzer: MusicAnalyzer
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private weak var mainWindow: NSWindow?
    @ObservationIgnored var openMainWindow: () -> Void = {}
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
        revealMainWindow()
    }

    func showMainWindow() {
        if isOpen { close() } else { revealMainWindow() }
    }

    private func revealMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow()
        }
    }

    func setExpanded(_ expanded: Bool) {
        collapseTask?.cancel()
        guard isOpen, expanded != isExpanded else { return }
        // Expanded pill fills the panel, so the corner can change without a jump.
        if !expanded, let panel { settle(panel, animated: true) }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { isExpanded = expanded }
    }

    fileprivate func pointerEntered() {
        setExpanded(true)
    }

    fileprivate func pointerExited() {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.45))
            if !Task.isCancelled { self?.setExpanded(false) }
        }
    }

    private func hideMainWindow() {
        mainWindow = nil
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain && $0.isVisible }) else { return }
        mainWindow = window
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            // Hiding mid-transition strands an empty full screen Space.
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
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Resets the level, so set it first.
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        let view = MiniPlayerView()
            .environment(store)
            .environment(self)
            .environment(\.musicAnalyzer, analyzer)
        let host = MiniPlayerHostingView(rootView: view)
        // Panel size is fixed, don't let SwiftUI resize it.
        host.sizingOptions = []
        host.pillSize = { [weak self] in
            self?.isExpanded == true ? Self.expandedSize : Self.compactSize
        }
        host.pillCorner = { [weak self] in self?.corner ?? MiniPlayerCorner() }
        host.onHoverChange = { [weak self] isInside in
            if isInside { self?.pointerEntered() } else { self?.pointerExited() }
        }
        panel.contentView = host
        panel.setContentSize(Self.panelSize)
        place(panel)
        return panel
    }

    private func place(_ panel: NSPanel) {
        let autosaveName = "PeaceMiniPlayer"
        let didRestore = panel.setFrameUsingName(autosaveName)
        let isVisible = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !didRestore || !isVisible, let screen = NSScreen.main ?? NSScreen.screens.first {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: area.maxX - Self.panelSize.width,
                y: area.maxY - Self.panelSize.height
            ))
        }
        panel.setFrame(NSRect(
            x: panel.frame.midX - Self.panelSize.width / 2,
            y: panel.frame.maxY - Self.panelSize.height,
            width: Self.panelSize.width,
            height: Self.panelSize.height
        ), display: false)
        panel.setFrameAutosaveName(autosaveName)
        settle(panel, animated: false)
    }

    private func settle(_ panel: NSPanel, animated: Bool) {
        guard let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = panel.frame
        corner = MiniPlayerCorner(isLeading: frame.midX < area.midX, isTop: frame.midY >= area.midY)

        frame.origin.x = max(area.minX - Self.margin, min(frame.minX, area.maxX + Self.margin - frame.width))
        frame.origin.y = max(area.minY - Self.margin, min(frame.minY, area.maxY + Self.margin - frame.height))
        guard frame != panel.frame else { return }
        if animated {
            panel.animator().setFrame(frame, display: true)
        } else {
            panel.setFrame(frame, display: false)
        }
    }
}

private final class MiniPlayerHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    var pillSize: () -> NSSize = { .zero }
    var pillCorner: () -> MiniPlayerCorner = { MiniPlayerCorner() }
    private var hoverArea: NSTrackingArea?
    private var isInsidePill = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setInside(false)
    }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let size = pillSize()
        let margin = MiniPlayerController.margin
        let corner = pillCorner()
        let x = corner.isLeading ? margin : bounds.maxX - margin - size.width
        let y = corner.isTop != isFlipped ? bounds.maxY - margin - size.height : margin
        let pill = NSRect(x: x, y: y, width: size.width, height: size.height)
        setInside(pill.contains(point))
    }

    private func setInside(_ isInside: Bool) {
        guard isInside != isInsidePill else { return }
        isInsidePill = isInside
        onHoverChange?(isInside)
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
        .frame(width: pillSize.width, height: pillSize.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(theme == .glass ? 0.18 : 0.75), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: miniPlayer.corner.alignment)
        .padding(MiniPlayerController.margin)
    }

    private var pillSize: NSSize {
        miniPlayer.isExpanded ? MiniPlayerController.expandedSize : MiniPlayerController.compactSize
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
