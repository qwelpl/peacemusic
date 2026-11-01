import AppKit
import SwiftUI

enum PlayerMode: String, CaseIterable {
    case turntable, stage

    var next: PlayerMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

struct NowPlayingView: View {
    @Environment(PlayerStore.self) private var store

    @AppStorage("playerMode") private var modeRaw = PlayerMode.turntable.rawValue
    @AppStorage("heroStyle") private var heroStyleRaw = HeroStyle.vinyl.rawValue
    @AppStorage("showsLyrics") private var showsLyrics = true
    @State private var showsLibrary = false
    @State private var lastActivity = Date()
    @State private var isIdle = false
    @FocusState private var isFocused: Bool

    private var mode: PlayerMode { PlayerMode(rawValue: modeRaw) ?? .turntable }
    private var heroStyle: HeroStyle { HeroStyle(rawValue: heroStyleRaw) ?? .vinyl }
    private var chromeVisible: Bool { !isIdle || !store.isPlaying || showsLibrary }

    var body: some View {
        ZStack {
            if store.track == nil || mode == .turntable {
                FluidBackground(
                    colors: store.meshColors,
                    trackID: store.track?.id,
                    isPlaying: store.isPlaying
                )
            }

            if store.track == nil {
                EmptyStateView(openLibrary: { showsLibrary = true })
            } else {
                switch mode {
                case .turntable:
                    player.transition(.opacity)
                case .stage:
                    StageView(chromeVisible: chromeVisible).transition(.opacity)
                }
            }

            libraryOverlay
        }
        .overlay(alignment: .topTrailing) { topBar }
        .overlay(alignment: .top) { syncToast }
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            store.start()
            isFocused = true
        }
        .onKeyPress(.space) { store.togglePlayPause(); return .handled }
        .onKeyPress(.leftArrow) { store.previous(); return .handled }
        .onKeyPress(.rightArrow) { store.next(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "m")) { _ in switchMode(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "[")) { _ in store.nudgeLyrics(by: -0.1); return .handled }
        .onKeyPress(characters: .init(charactersIn: "]")) { _ in store.nudgeLyrics(by: 0.1); return .handled }
        .onKeyPress(characters: .init(charactersIn: "\\")) { _ in store.resetLyricOffset(); return .handled }
        .onKeyPress(characters: .init(charactersIn: "l")) { _ in
            guard mode == .turntable else { return .ignored }
            showsLyrics.toggle()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "v")) { _ in
            guard mode == .turntable else { return .ignored }
            toggleHero()
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "f")) { _ in toggleFullScreen(); return .handled }
        .onContinuousHover { _ in markActivity() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let idle = Date().timeIntervalSince(lastActivity) > 3.5
                if idle != isIdle {
                    withAnimation(.easeInOut(duration: 0.5)) { isIdle = idle }
                }
            }
        }
    }

    private func markActivity() {
        lastActivity = Date()
        if isIdle {
            withAnimation(.easeOut(duration: 0.2)) { isIdle = false }
        }
    }

    private func switchMode() {
        withAnimation(.easeInOut(duration: 0.5)) { modeRaw = mode.next.rawValue }
    }

    private func toggleHero() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            heroStyleRaw = (heroStyle == .vinyl ? HeroStyle.cover : .vinyl).rawValue
        }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: Layout

    private var lyricsVisible: Bool {
        guard showsLyrics else { return false }
        if case .none = store.lyrics { return false }
        return true
    }

    private var player: some View {
        GeometryReader { geometry in
            let columnWidth = min(geometry.size.width * (lyricsVisible ? 0.4 : 0.5), 520)
            let chromeHeight: CGFloat = 270
            let heroSize = min(columnWidth, max(geometry.size.height - chromeHeight - 70, 180))

            HStack(spacing: 56) {
                if !lyricsVisible { Spacer(minLength: 0) }
                VStack(spacing: 22) {
                    hero(size: heroSize)
                    details
                }
                .frame(width: columnWidth)
                // Recenters the record and title once the controls below them fade out.
                .offset(y: chromeVisible ? 0 : 85)

                if lyricsVisible {
                    LyricsPanel()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 28)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: lyricsVisible)
        }
    }

    @ViewBuilder
    private func hero(size: CGFloat) -> some View {
        Group {
            switch heroStyle {
            case .vinyl:
                VinylHeroProgress(size: size)
            case .cover:
                CoverHero(image: store.artwork, isPlaying: store.isPlaying, size: size)
            }
        }
        .frame(width: size, height: size)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .id(heroStyle)
    }

    private var details: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.track?.title ?? "")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                    Text([store.track?.artist, store.track?.album]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .contentTransition(.opacity)
                Spacer(minLength: 0)
                GlassCircleButton(
                    symbol: store.favorited ? "heart.fill" : "heart",
                    diameter: 38,
                    iconSize: 15,
                    isOn: store.favorited,
                    action: store.toggleFavorite
                )
                .help("Favorite")
                .opacity(chromeVisible ? 1 : 0)
            }
            VStack(spacing: 12) {
                ProgressRow()
                TransportRow()
                VolumeRow()
            }
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible)
        }
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                GlassCircleButton(symbol: "music.note.list", isOn: showsLibrary) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { showsLibrary.toggle() }
                }
                .help("Library")
                GlassCircleButton(symbol: "sparkles", action: switchMode)
                    .help("Switch mode (M)")
                if mode == .turntable {
                    GlassCircleButton(symbol: heroStyle == .vinyl ? "photo" : "record.circle", action: toggleHero)
                        .help("Switch between vinyl and cover (V)")
                    GlassCircleButton(symbol: "quote.bubble", isOn: showsLyrics) { showsLyrics.toggle() }
                        .help("Lyrics (L)")
                }
                GlassCircleButton(symbol: "arrow.up.left.and.arrow.down.right", action: toggleFullScreen)
                    .help("Full screen (F)")
            }
        }
        .padding(16)
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible)
    }

    @ViewBuilder
    private var syncToast: some View {
        if let message = store.syncMessage {
            Text(message)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 20)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var libraryOverlay: some View {
        if showsLibrary {
            HStack {
                LibraryPanel {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { showsLibrary = false }
                }
                Spacer()
            }
            .padding(.top, 24)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }
}

/// Isolates the once-a-second progress read so that it doesn't re-render the whole player.
private struct VinylHeroProgress: View {
    let size: CGFloat

    @Environment(PlayerStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = store.track?.duration ?? 0
            VinylHero(
                image: store.artwork,
                isPlaying: store.isPlaying,
                progress: duration > 0 ? store.position(at: context.date) / duration : 0,
                size: size
            )
        }
    }
}

private struct EmptyStateView: View {
    let openLibrary: () -> Void

    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 56, weight: .light))
            Text(title)
                .font(.system(size: 32, weight: .heavy, design: .rounded))
            Text(message)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.clear.interactive(), in: .capsule)
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
    }

    private var icon: String {
        store.status == .notAuthorized ? "lock.fill" : "music.note"
    }

    private var title: String {
        switch store.status {
        case .notAuthorized: "Peace needs permission"
        case .musicNotRunning: "Music isn't open"
        case .ok: "Nothing playing"
        }
    }

    private var message: String {
        switch store.status {
        case .notAuthorized: "Allow Peace to control Music in System Settings, under Privacy & Security > Automation."
        case .musicNotRunning: "Peace plays through the Music app. Open it and your song shows up here."
        case .ok: "Pick something from your library to get started."
        }
    }

    private var buttonTitle: String {
        switch store.status {
        case .notAuthorized: "Open System Settings"
        case .musicNotRunning: "Open Music"
        case .ok: "Browse Library"
        }
    }

    private func action() {
        switch store.status {
        case .notAuthorized: store.openAutomationSettings()
        case .musicNotRunning: store.openMusic()
        case .ok: openLibrary()
        }
    }
}
