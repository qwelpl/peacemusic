import SwiftUI

enum Destination: Hashable {
    case home, new, radio
    case library(LibrarySection)
    case playlist(MediaItem)
}

// MARK: Left

// Navigation, library and playlists on a floating glass column. The window's traffic
// lights sit inside its top edge.
struct LeftSidebar: View {
    @Environment(\.songTheme) private var theme

    @Binding var destination: Destination
    @Binding var query: String
    let select: (Destination) -> Void

    @Environment(PlayerStore.self) private var store
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 34)
            searchField.padding(.horizontal, 12).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("Apple Music") {
                        row("Home", "house.fill", .home)
                        row("New", "sparkles", .new)
                        row("Radio", "dot.radiowaves.left.and.right", .radio)
                    }
                    group("Library") {
                        row("Recently Added", "clock.fill", .library(.recent))
                        row("Playlists", "music.note.list", .library(.playlists))
                        row("Albums", "square.stack.fill", .library(.albums))
                        row("Artists", "music.mic", .library(.artists))
                        row("Songs", "music.note", .library(.songs))
                    }
                    group("Playlists", action: newPlaylist) {
                        ForEach(store.libraryPlaylists) { playlist in
                            playlistRow(playlist)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
            listening
        }
        .songGlass(in: .rect(cornerRadius: 24, style: .continuous))
        .background {
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($searching)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .contentShape(.rect)
                }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.white.opacity(searching ? 0.14 : 0.08), in: .rect(cornerRadius: 11, style: .continuous))
    }

    private func group<Content: View>(_ title: String, action: (() -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                if let action {
                    Button(action: action) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .contentShape(.rect)
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.55))
                        .help("New Playlist")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            content()
        }
    }

    private func row(_ title: String, _ symbol: String, _ target: Destination) -> some View {
        let isSelected = destination == target && query.isEmpty
        return Button { select(target) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? theme.accent : .white.opacity(0.65))
                Text(title).font(.system(size: 13, weight: isSelected ? .bold : .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(isSelected ? theme.accent.opacity(0.22) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(SidebarButtonStyle())
    }

    private func playlistRow(_ playlist: MediaItem) -> some View {
        let isSelected = destination == .playlist(playlist) && query.isEmpty
        return Button { select(.playlist(playlist)) } label: {
            HStack(spacing: 10) {
                Artwork(item: playlist, size: 26, cornerRadius: 6)
                Text(playlist.title)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 36)
            .background(isSelected ? theme.accent.opacity(0.22) : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(SidebarButtonStyle())
        .contextMenu { ItemMenu(item: playlist) }
    }

    // A small live readout at the foot of the sidebar.
    @ViewBuilder
    private var listening: some View {
        if let track = store.track {
            HStack(spacing: 10) {
                Image(systemName: store.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 12, weight: .bold))
                    .symbolEffect(.variableColor.iterative, isActive: store.isPlaying)
                    .foregroundStyle(store.accentColors.first ?? .white)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.isPlaying ? "Listening" : "Paused")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.45))
                    Text(track.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
        }
    }

    private func newPlaylist() {
        PlaylistNamer.ask { name in
            Task {
                await store.catalog.createPlaylist(named: name)
                await store.refreshLibraryPlaylists()
            }
        }
    }
}

private struct SidebarButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.white.opacity(isHovered ? 0.06 : 0), in: .rect(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { isHovered = $0 }
    }
}

// MARK: Right

// Everything about the song that's playing: lyrics as they're sung, the sound itself,
// where the song comes from, who made it, and what's next.
struct NowPlayingPanel: View {
    let openNowPlaying: () -> Void

    @Environment(PlayerStore.self) private var store
    @Environment(\.openItem) private var openItem
    @State private var context: MusicCatalog.SongContext?
    @State private var upNext: [AppleMusicEngine.QueueEntry] = []
    @AppStorage("lyricsExpanded") private var lyricsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                PanelVisualizer().frame(height: 46)
                lyrics
                about
                artist
                more
                queue
            }
            .padding(18)
        }
        .scrollIndicators(.never)
        .songGlass(in: .rect(cornerRadius: 24, style: .continuous))
        .task(id: store.track?.id) {
            context = nil
            guard let id = store.track?.id else { return }
            let loaded = await store.catalog.context(forSong: id)
            withAnimation(.easeOut(duration: 0.3)) { context = loaded }
        }
        .task(id: store.track?.id) {
            while !Task.isCancelled {
                let (entries, position) = await store.bridge.queue()
                upNext = Array(entries.filter { $0.index > position }.prefix(6))
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: openNowPlaying) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.06))
                    if let artwork = store.artwork {
                        Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                .shadow(color: (store.accentColors.first ?? .black).opacity(0.7), radius: 28, y: 12)
            }
            .buttonStyle(.plain)
            .help("Open Now Playing")
            VStack(alignment: .leading, spacing: 3) {
                Text(store.track?.title ?? "")
                    .font(.system(size: 20, weight: .heavy))
                    .tracking(-0.4)
                    .lineLimit(2)
                link(store.track?.artist ?? "", item: context?.artist, size: 14, weight: .semibold, opacity: 0.85)
                link(store.track?.album ?? "", item: context?.album, size: 12, weight: .medium, opacity: 0.55)
            }
        }
    }

    private func link(_ text: String, item: MediaItem?, size: CGFloat, weight: Font.Weight, opacity: Double) -> some View {
        Button { if let item { openItem(item) } } label: {
            Text(text).font(.system(size: size, weight: weight)).foregroundStyle(.white.opacity(opacity)).lineLimit(1)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(item == nil)
    }

    // The lines around the one being sung. Clicking opens the whole song in place.
    @ViewBuilder
    private var lyrics: some View {
        if case .synced(let lines) = store.lyrics {
            let current = store.lyricIndex ?? -1
            card("Lyrics", symbol: "quote.bubble") {
                if lyricsExpanded {
                    ExpandedLyrics(lines: lines, current: current)
                } else {
                    let start = max(min(current - 1, lines.count - 5), 0)
                    let shown = Array(lines.enumerated()).dropFirst(start).prefix(5).filter { !$0.element.isInterlude }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shown, id: \.element.id) { index, line in
                            Text(line.text)
                                .font(.system(size: index == current ? 17 : 14, weight: index == current ? .heavy : .semibold))
                                .foregroundStyle(.white.opacity(index == current ? 1 : index < current ? 0.3 : 0.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: current)
                }
            } accessory: {
                Image(systemName: lyricsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .contentShape(.rect)
            .onTapGesture {
                guard !lyricsExpanded else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { lyricsExpanded = true }
            }
            .overlay(alignment: .topTrailing) {
                if lyricsExpanded {
                    Color.clear
                        .frame(width: 44, height: 40)
                        .contentShape(.rect)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { lyricsExpanded = false }
                        }
                }
            }
        } else if case .plain(let text) = store.lyrics {
            card("Lyrics", symbol: "quote.bubble") {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(lyricsExpanded ? nil : 8)
            } accessory: {
                Image(systemName: lyricsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .contentShape(.rect)
            .onTapGesture { withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { lyricsExpanded.toggle() } }
        }
    }

    @ViewBuilder
    private var about: some View {
        if let song = context?.song {
            card("About the Song", symbol: "info.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    if !song.genres.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(song.genres.prefix(3), id: \.self) { genre in
                                Text(genre)
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(.white.opacity(0.1), in: .capsule)
                            }
                        }
                    }
                    if let date = song.releaseDate.flatMap(Self.release) { fact("Released", date) }
                    if let composer = song.composer { fact("Written by", composer) }
                    if let album = context?.album, !album.title.isEmpty { fact("From", album.title) }
                }
            }
        }
    }

    @ViewBuilder
    private var artist: some View {
        if let artist = context?.artist {
            card("Artist", symbol: "music.mic") {
                VStack(alignment: .leading, spacing: 10) {
                    Button { openItem(artist) } label: {
                        HStack(spacing: 12) {
                            Artwork(item: artist, size: 52, isCircle: true, glow: 0.5)
                            Text(artist.title).font(.system(size: 15, weight: .bold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if let note = artist.note {
                        Text(note.strippingTags)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(5)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var more: some View {
        if let songs = context?.moreByArtist, !songs.isEmpty {
            card("More by \(context?.artist?.title ?? "the Artist")", symbol: "music.note") {
                VStack(spacing: 2) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                        CompactRow(title: song.title, subtitle: song.album, item: song, template: nil) {
                            store.play(songs, at: index, in: nil)
                        }
                        .contextMenu { ItemMenu(item: song) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var queue: some View {
        if !upNext.isEmpty {
            card("Up Next", symbol: "list.bullet") {
                VStack(spacing: 2) {
                    ForEach(upNext) { entry in
                        CompactRow(title: entry.title, subtitle: entry.artist, item: nil, template: entry.artwork) {
                            store.bridge.jump(toQueueIndex: entry.index)
                        }
                    }
                }
            }
        }
    }

    private func card<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        card(title, symbol: symbol, content: content) { EmptyView() }
    }

    private func card<Content: View, Accessory: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white.opacity(0.45))
                .labelStyle(.titleAndIcon)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 18, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.4))
            Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(2)
        }
    }

    private static func release(_ date: String) -> String? {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let parsed = parser.date(from: date) else { return date }
        return parsed.formatted(date: .long, time: .omitted)
    }
}

private struct CompactRow: View {
    let title: String
    let subtitle: String
    let item: MediaItem?
    let template: String?
    let play: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Artwork(item: item, template: template, size: 36, cornerRadius: 7)
                .overlay {
                    if isHovered { Image(systemName: "play.fill").font(.system(size: 11, weight: .bold)) }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(.white.opacity(isHovered ? 0.07 : 0), in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: play)
    }
}

// Spectrum bars that move with the music, in the song's colors.
private struct PanelVisualizer: View {
    @Environment(PlayerStore.self) private var store
    @Environment(\.musicAnalyzer) private var analyzer
    @AppStorage(FrameRate.key) private var frameRate = FrameRate.standard
    @AppStorage(FrameRate.savesBatteryKey) private var savesBattery = true

    var body: some View {
        // Never faster than 30 fps: it sits inside a glass panel that redraws with it.
        TimelineView(.animation(minimumInterval: max(FrameRate.interval(frameRate, savesBattery: savesBattery), 1.0 / 30), paused: !store.isPlaying)) { _ in
            let spectrum = analyzer.reading.spectrum
            let colors = store.accentColors
            Canvas { context, size in
                let count = 32
                let gap: CGFloat = 3
                let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
                for bar in 0..<count {
                    let band = spectrum.isEmpty ? 0 : min(bar * spectrum.count / count, spectrum.count - 1)
                    let value = spectrum.isEmpty ? 0 : CGFloat(spectrum[band])
                    let height = max(size.height * value, width)
                    let rect = CGRect(x: CGFloat(bar) * (width + gap), y: (size.height - height) / 2, width: width, height: height)
                    let color = colors.isEmpty ? Color.white : colors[bar * colors.count / count]
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(color.opacity(0.95)))
                }
            }
            .drawingGroup()
        }
        .listensToMusic()
    }
}

// The whole song, following along. Clicking a line jumps there.
private struct ExpandedLyrics: View {
    let lines: [LyricLine]
    let current: Int

    @Environment(PlayerStore.self) private var store

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if line.isInterlude {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundStyle(.white.opacity(index == current ? 0.9 : 0.3))
                                .id(line.id)
                        } else {
                            Text(line.text)
                                .font(.system(size: 17, weight: .heavy))
                                .foregroundStyle(.white.opacity(index == current ? 1 : index < current ? 0.3 : 0.5))
                                .scaleEffect(index == current ? 1.03 : 1, anchor: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .contentShape(.rect)
                                .onTapGesture { store.seek(to: max(line.time - store.lyricLead, 0)) }
                                .id(line.id)
                        }
                    }
                }
                .padding(.vertical, 120)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: current)
            }
            .scrollIndicators(.never)
            .frame(height: 420)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                .init(color: .black, location: 0.85), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: current) { scroll(proxy, animated: true) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard lines.indices.contains(current) else { return }
        let id = lines[current].id
        if animated {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
