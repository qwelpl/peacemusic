import AppKit
import Observation
import SwiftUI

/// Swaps between the main window and a small panel pinned above everything else.
@MainActor
@Observable
final class MiniPlayerController {
    static let size = NSSize(width: 400, height: 112)

    private(set) var isOpen = false

    private let store: PlayerStore
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private weak var mainWindow: NSWindow?

    init(store: PlayerStore) {
        self.store = store
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
        hideMainWindow()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        panel?.orderOut(nil)
        NSApp.activate()
        mainWindow?.makeKeyAndOrderFront(nil)
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
            contentRect: NSRect(origin: .zero, size: Self.size),
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

        let view = MiniPlayerView().environment(store).environment(self)
        panel.contentView = FirstClickHostingView(rootView: view)
        panel.setContentSize(Self.size)
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
                x: area.maxX - Self.size.width - 16,
                y: area.maxY - Self.size.height - 16
            ))
        }
        panel.setFrameAutosaveName(autosaveName)
    }
}

/// Lets one click press a button, instead of the first click only focusing the panel.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MiniPlayerView: View {
    @Environment(PlayerStore.self) private var store
    @Environment(MiniPlayerController.self) private var miniPlayer
    @AppStorage("uiTheme") private var themeRaw = UITheme.glass.rawValue

    private var theme: UITheme { UITheme(rawValue: themeRaw) ?? .glass }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.cornerRadius(24), style: .continuous)
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(image: store.artwork)
                .frame(width: 84, height: 84)
                .clipShape(.rect(cornerRadius: theme.cornerRadius(14), style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(store.track?.title ?? "Nothing playing")
                    .font(theme.font(14, .heavy))
                    .foregroundStyle(.white)
                Text(store.track?.artist ?? "")
                    .font(theme.font(12))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer(minLength: 0)
                Text(lyricLine)
                    .font(theme.font(12, .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: lyricLine)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                PlayerButton(
                    symbol: "arrow.up.left.and.arrow.down.right",
                    title: "OPEN",
                    diameter: 26,
                    iconSize: 10,
                    action: miniPlayer.close
                )
                .help("Back to the full player")
                Spacer(minLength: 0)
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 4) {
                        PlayerButton(symbol: "backward.fill", title: "|<", diameter: 32, iconSize: 11, action: store.previous)
                        PlayerButton(
                            symbol: store.isPlaying ? "pause.fill" : "play.fill",
                            title: store.isPlaying ? "||" : ">",
                            diameter: 38,
                            iconSize: 14,
                            monoWidth: 38,
                            action: store.togglePlayPause
                        )
                        PlayerButton(symbol: "forward.fill", title: ">|", diameter: 32, iconSize: 11, action: store.next)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(14)
        .frame(width: MiniPlayerController.size.width, height: MiniPlayerController.size.height)
        .background { background }
        .overlay(alignment: .bottom) { MiniProgress().padding(.horizontal, theme == .glass ? 22 : 0) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(theme == .glass ? 0.16 : 0.75), lineWidth: 1))
        .environment(\.uiTheme, theme)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var background: some View {
        switch theme {
        case .glass:
            FluidBackground(colors: store.meshColors, trackID: store.track?.id, isPlaying: store.isPlaying)
        case .mono:
            Color.black
        }
    }

    private var lyricLine: String {
        switch store.lyrics {
        case .synced(let lines):
            guard let index = store.lyricIndex, !lines[index].isInterlude else { return "···" }
            return lines[index].text
        default:
            return store.track?.album ?? ""
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
                    Rectangle().fill(.white.opacity(0.2))
                    Rectangle().fill(.white).frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: 2)
        }
        .allowsHitTesting(false)
    }
}
