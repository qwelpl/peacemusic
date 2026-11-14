import AVKit
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home, new, radio, library

    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"
        case .new: "New"
        case .radio: "Radio"
        case .library: "Library"
        }
    }
}

enum LibrarySection: String, CaseIterable, Identifiable {
    case recent, playlists, albums, artists, songs

    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: "Recently Added"
        case .playlists: "Playlists"
        case .albums: "Albums"
        case .artists: "Artists"
        case .songs: "Songs"
        }
    }
}

// The whole app. The current song's colors wash through everything, the navigation and
// player float on glass, and Now Playing grows out of the player.
struct MusicAppView: View {
    @Environment(PlayerStore.self) private var store

    @AppStorage("appTab") private var tab = AppTab.home
    @State private var path: [MediaItem] = []
    @State private var query = ""
    @State private var showsNowPlaying = false
    @State private var showsQueue = false

    var body: some View {
        ZStack {
            AmbientBackground()
            if store.status == .signedOut {
                SignInView()
            } else {
                browser
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { store.start() }
        .task(id: store.status) {
            if store.status == .ok { await store.refreshLibraryPlaylists() }
        }
    }

    private var browser: some View {
        ZStack {
            pages
                .environment(\.openItem) { item in
                    if item.kind == .song {
                        store.play([item], at: 0, in: nil)
                    } else {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { path.append(item) }
                    }
                }

            VStack(spacing: 0) {
                TopBar(tab: $tab, query: $query, canGoBack: !path.isEmpty, goBack: goBack, selectTab: select)
                Spacer()
                PlayerDock(showsNowPlaying: $showsNowPlaying, showsQueue: $showsQueue)
                    .padding(.bottom, 18)
            }

            if showsQueue {
                HStack {
                    Spacer()
                    QueuePanel(close: { withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { showsQueue = false } })
                        .frame(width: 330)
                        .padding(.top, Layout.topInset - 8)
                        .padding(.bottom, Layout.bottomInset - 10)
                        .padding(.trailing, 18)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if showsNowPlaying {
                NowPlayingView(onClose: { withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { showsNowPlaying = false } })
                    .clipShape(.rect(cornerRadius: 0))
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .bottom).combined(with: .opacity)))
                    .zIndex(2)
            }
        }
        .onChange(of: query) { if !query.isEmpty { path = [] } }
    }

    @ViewBuilder
    private var pages: some View {
        ZStack {
            if let item = path.last {
                DetailPage(item: item)
                    .id(item.id + "\(path.count)")
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else if !query.isEmpty {
                SearchPage(query: query).transition(.opacity)
            } else {
                switch tab {
                case .home: HomePage().transition(.opacity)
                case .new: ShelfPage(title: "New", subtitle: "Charts and releases", id: "new") { await store.catalog.browse() }.transition(.opacity)
                case .radio: ShelfPage(title: "Radio", subtitle: "Stations and live shows", id: "radio") { await store.catalog.radio() }.transition(.opacity)
                case .library: LibraryPage().transition(.opacity)
                }
            }
        }
    }

    private func goBack() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { _ = path.popLast() }
    }

    private func select(_ next: AppTab) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            tab = next
            path = []
            query = ""
        }
    }
}

// MARK: Backdrop

private struct AmbientBackground: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        ZStack {
            FluidBackground(colors: store.meshColors, trackID: store.track?.id, isPlaying: store.isPlaying)
                .opacity(0.55)
            // Darker toward the bottom so lists stay easy to read.
            LinearGradient(
                colors: [.black.opacity(0.25), .black.opacity(0.6), .black.opacity(0.82)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(colors: [.clear, .black.opacity(0.5)], center: .center, startRadius: 300, endRadius: 1100)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: Navigation

private struct TopBar: View {
    @Binding var tab: AppTab
    @Binding var query: String
    let canGoBack: Bool
    let goBack: () -> Void
    let selectTab: (AppTab) -> Void

    @Namespace private var selection
    @FocusState private var searching: Bool

    var body: some View {
        ZStack {
            tabs
            HStack(spacing: 10) {
                if canGoBack {
                    GlassIconButton(symbol: "chevron.left", size: 38, action: goBack)
                        .keyboardShortcut("[", modifiers: .command)
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer()
                search
            }
        }
        // Clears the window's traffic lights.
        .padding(.leading, 84)
        .padding(.trailing, 20)
        .padding(.top, 14)
        .frame(height: 64)
    }

    private var tabs: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(AppTab.allCases) { item in
                    Button { selectTab(item) } label: {
                        Text(item.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tab == item && query.isEmpty ? .black : .white.opacity(0.8))
                            .padding(.horizontal, 18)
                            .frame(height: 34)
                            .background {
                                if tab == item && query.isEmpty {
                                    Capsule().fill(.white).matchedGeometryEffect(id: "tab", in: selection)
                                }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($searching)
                .onSubmit {}
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: searching || !query.isEmpty ? 280 : 180, height: 38)
        .glassEffect(.regular.interactive(), in: .capsule)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: searching)
        .background {
            Button("") { searching = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }
}

// MARK: Pages

private struct Page<Content: View>: View {
    let id: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) { content }
                .padding(.top, Layout.topInset)
                .padding(.bottom, Layout.bottomInset)
        }
        .scrollIndicators(.never)
        .id(id)
    }
}

private struct HomePage: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        Page(id: "home") {
            PageTitle(title: greeting, subtitle: Date().formatted(.dateTime.weekday(.wide).month().day()))
            Loading(load: { await store.catalog.home() }, isEmpty: { $0.isEmpty }) { shelves in
                VStack(alignment: .leading, spacing: 44) {
                    if let feature = shelves.lazy.flatMap(\.items).first(where: { $0.kind == .album || $0.kind == .playlist }) {
                        HeroCard(item: feature, eyebrow: "Picked for you")
                            .padding(.horizontal, Layout.gutter)
                    }
                    ForEach(shelves) { ShelfView(shelf: $0) }
                }
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }
}

private struct ShelfPage: View {
    let title: String
    let subtitle: String
    let id: String
    let load: () async -> [Shelf]

    var body: some View {
        Page(id: id) {
            PageTitle(title: title, subtitle: subtitle)
            Loading(load: load, isEmpty: { $0.isEmpty }) { shelves in
                VStack(alignment: .leading, spacing: 44) {
                    if let feature = shelves.lazy.flatMap(\.items).first(where: { $0.kind != .song }) {
                        HeroCard(item: feature, eyebrow: shelves.first { $0.items.contains(feature) }?.title ?? title)
                            .padding(.horizontal, Layout.gutter)
                    }
                    ForEach(shelves) { ShelfView(shelf: $0) }
                }
            }
        }
    }
}

private struct LibraryPage: View {
    @Environment(PlayerStore.self) private var store
    @AppStorage("librarySection") private var section = LibrarySection.recent
    @Namespace private var selection

    var body: some View {
        Page(id: "library-\(section.rawValue)") {
            VStack(alignment: .leading, spacing: 18) {
                PageTitle(title: "Library", subtitle: "Your music")
                picker.padding(.horizontal, Layout.gutter)
            }
            switch section {
            case .recent: grid { await store.catalog.recentlyAdded() }
            case .playlists: grid { await store.catalog.libraryPlaylists() }
            case .albums: grid { await store.catalog.libraryAlbums() }
            case .artists: grid { await store.catalog.libraryArtists() }
            case .songs: LibrarySongs()
            }
        }
    }

    private var picker: some View {
        HStack(spacing: 6) {
            ForEach(LibrarySection.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { section = item }
                } label: {
                    Text(item.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(section == item ? .black : .white.opacity(0.8))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            if section == item {
                                Capsule().fill(.white).matchedGeometryEffect(id: "section", in: selection)
                            } else {
                                Capsule().fill(.white.opacity(0.08))
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func grid(_ load: @escaping () async -> [MediaItem]) -> some View {
        Loading(load: load, isEmpty: { $0.isEmpty }) { items in
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172, maximum: 210), spacing: 26, alignment: .top)], spacing: 30) {
                ForEach(items) { ItemTile(item: $0, size: 172) }
            }
            .padding(.horizontal, Layout.gutter)
        }
    }
}

private struct LibrarySongs: View {
    @Environment(PlayerStore.self) private var store
    @State private var filter = ""

    var body: some View {
        Loading(load: { await store.catalog.librarySongs() }, isEmpty: { $0.isEmpty }) { songs in
            let shown = filter.isEmpty ? songs : songs.filter {
                $0.title.localizedCaseInsensitiveContains(filter) || $0.subtitle.localizedCaseInsensitiveContains(filter)
                    || $0.album.localizedCaseInsensitiveContains(filter)
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    PlayButtons(play: { store.play(shown, at: 0, in: nil) }, shuffle: {
                        guard !shown.isEmpty else { return }
                        store.play(shown.shuffled(), at: 0, in: nil)
                    })
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.white.opacity(0.6))
                        TextField("Filter \(songs.count) songs", text: $filter).textFieldStyle(.plain)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(width: 220, height: 34)
                    .glassEffect(.regular, in: .capsule)
                }
                .padding(.horizontal, Layout.gutter)
                SongList(songs: shown).padding(.horizontal, Layout.gutter - 12)
            }
        }
    }
}

private struct SearchPage: View {
    let query: String

    @Environment(PlayerStore.self) private var store
    @State private var inLibrary = false
    @State private var shelves: [Shelf]?
    @Namespace private var selection

    var body: some View {
        Page(id: "search") {
            HStack(alignment: .bottom) {
                PageTitle(title: "“\(query)”", subtitle: "Search")
                Spacer()
                HStack(spacing: 4) {
                    scope("Apple Music", false)
                    scope("Library", true)
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)
                .padding(.trailing, Layout.gutter)
            }
            if let shelves {
                if shelves.isEmpty {
                    Text("Nothing matched. Try another spelling.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
                ForEach(shelves) { shelf in
                    if shelf.isSongs {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: shelf.title)
                            SongList(songs: Array(shelf.items.prefix(8))).padding(.horizontal, Layout.gutter - 12)
                        }
                    } else {
                        ShelfView(shelf: shelf)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .task(id: "\(query)|\(inLibrary)") {
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            let found = await store.catalog.search(query, inLibrary: inLibrary)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { shelves = found }
        }
    }

    private func scope(_ title: String, _ value: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { inLibrary = value; shelves = nil }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(inLibrary == value ? .black : .white.opacity(0.8))
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background {
                    if inLibrary == value { Capsule().fill(.white).matchedGeometryEffect(id: "scope", in: selection) }
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

// Album, playlist, artist or station.
private struct DetailPage: View {
    let item: MediaItem

    var body: some View {
        switch item.kind {
        case .artist: ArtistPage(item: item)
        case .station: StationPage(item: item)
        default: CollectionPage(item: item)
        }
    }
}

private struct CollectionPage: View {
    let item: MediaItem

    @Environment(PlayerStore.self) private var store
    @State private var detail: MediaItem?
    @State private var tracks: [MediaItem]?
    @State private var added = false

    var body: some View {
        let shown = detail ?? item
        Page(id: "collection-\(item.id)") {
            HStack(alignment: .bottom, spacing: 36) {
                Artwork(item: shown, size: 270, cornerRadius: 20, glow: 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.kind == .album ? "ALBUM" : "PLAYLIST")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(shown.title)
                        .font(.system(size: 44, weight: .heavy))
                        .tracking(-1)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    Text(shown.subtitle)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                    Text(meta(shown))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    if let note = shown.note {
                        Text(note.strippingTags)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(3)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                    HStack(spacing: 10) {
                        PlayButtons(play: { store.play(item) }, shuffle: { store.play(item, shuffle: true) })
                        if !item.isLibrary {
                            GlassIconButton(symbol: added ? "checkmark" : "plus", isOn: added) {
                                Task { await store.catalog.addToLibrary(item) }
                                withAnimation(.spring) { added = true }
                            }
                            .help("Add to Library")
                        }
                        Menu { ItemMenu(item: item) } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 40, height: 40)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                    }
                    .padding(.top, 12)
                }
            }
            .padding(.horizontal, Layout.gutter)

            if let tracks {
                SongList(songs: tracks, collection: item, showsArtwork: item.kind != .album, showsAlbum: item.kind != .album)
                    .padding(.horizontal, Layout.gutter - 12)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .background(alignment: .top) { Backdrop(item: shown) }
        .task(id: item.id) {
            let (loaded, songs) = await store.catalog.collection(item)
            withAnimation(.easeOut(duration: 0.3)) {
                detail = loaded
                tracks = songs
            }
        }
    }

    private func meta(_ shown: MediaItem) -> String {
        var parts: [String] = []
        if let year = shown.releaseDate?.prefix(4), !year.isEmpty { parts.append(String(year)) }
        if let tracks, !tracks.isEmpty {
            parts.append("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
            let minutes = Int(tracks.reduce(0) { $0 + $1.duration } / 60)
            if minutes > 0 { parts.append(minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min") }
        }
        return parts.joined(separator: " · ")
    }
}

private struct ArtistPage: View {
    let item: MediaItem

    @Environment(PlayerStore.self) private var store
    @State private var page: MusicCatalog.ArtistPage?

    var body: some View {
        let artist = page?.artist ?? item
        Page(id: "artist-\(item.id)") {
            HStack(alignment: .center, spacing: 32) {
                Artwork(item: artist, size: 210, isCircle: true, glow: 1)
                VStack(alignment: .leading, spacing: 14) {
                    Text("ARTIST")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.55))
                    Text(artist.title)
                        .font(.system(size: 56, weight: .heavy))
                        .tracking(-1.5)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                    if let songs = page?.shelves.first(where: { $0.isSongs })?.items {
                        PlayButtons(play: { store.play(songs, at: 0, in: nil) }, shuffle: { store.play(songs.shuffled(), at: 0, in: nil) })
                    }
                }
            }
            .padding(.horizontal, Layout.gutter)
            if let page {
                ForEach(page.shelves) { ShelfView(shelf: $0) }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .background(alignment: .top) { Backdrop(item: artist) }
        .task(id: item.id) {
            let loaded = await store.catalog.artist(item)
            withAnimation(.easeOut(duration: 0.3)) { page = loaded }
        }
    }
}

private struct StationPage: View {
    let item: MediaItem

    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(spacing: 20) {
            Artwork(item: item, size: 300, cornerRadius: 24, glow: 1)
            Text(item.title).font(.system(size: 40, weight: .heavy)).tracking(-1)
            if let note = item.note {
                Text(note.strippingTags).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: 480)
            }
            Button { store.play(item) } label: {
                Label("Listen Now", systemImage: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 160, height: 44)
                    .background(.white, in: .capsule)
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) { Backdrop(item: item) }
    }
}

// The cover melted into the top of a page.
private struct Backdrop: View {
    let item: MediaItem

    var body: some View {
        GeometryReader { geometry in
            Artwork(item: item, size: 400, cornerRadius: 0)
                .scaleEffect(x: max(geometry.size.width / 400, 1) * 1.3, y: 1.4)
                .frame(width: geometry.size.width, height: 520)
                .blur(radius: 90)
                .saturation(1.5)
                .opacity(0.6)
                .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        }
        .frame(height: 520)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: Sign in

private struct SignInView: View {
    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 60, weight: .semibold))
                .symbolEffect(.variableColor.iterative)
            Text("Peace").font(.system(size: 54, weight: .heavy)).tracking(-1.5)
            Text("All of Apple Music, beautifully. Sign in once with your Apple Account.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button(action: store.signIn) {
                Text("Sign In")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 160, height: 44)
                    .background(.white, in: .capsule)
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Player dock

private struct PlayerDock: View {
    @Binding var showsNowPlaying: Bool
    @Binding var showsQueue: Bool

    @Environment(PlayerStore.self) private var store
    @Environment(MiniPlayerController.self) private var miniPlayer
    @State private var dragValue: Double?
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                nowPlaying.frame(maxWidth: .infinity, alignment: .leading)
                transport
                trailing.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 70)
            progress
        }
        .frame(maxWidth: 980)
        .glassEffect(.regular, in: .rect(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .padding(.horizontal, 24)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.2)) { isHovered = hovering } }
    }

    private func openNowPlaying() {
        guard store.track != nil else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { showsNowPlaying = true }
    }

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08))
                if let artwork = store.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .shadow(color: (store.accentColors.first ?? .black).opacity(0.6), radius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.track?.title ?? "Not Playing")
                    .font(.system(size: 13, weight: .bold))
                Text(store.track?.artist ?? "Pick something to play")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
        }
        .contentShape(.rect)
        .onTapGesture(perform: openNowPlaying)
        .help("Open Now Playing")
    }

    private var transport: some View {
        HStack(spacing: 14) {
            dockButton(store.shuffle ? "shuffle" : "shuffle", size: 13, dimmed: !store.shuffle, action: store.toggleShuffle)
            dockButton("backward.fill", size: 16, action: store.previous)
            Button(action: store.togglePlayPause) {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 46, height: 46)
                    .background(.white, in: .circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            dockButton("forward.fill", size: 16, action: store.next)
            dockButton(store.repeatMode == .one ? "repeat.1" : "repeat", size: 13, dimmed: store.repeatMode == .off, action: store.cycleRepeat)
        }
    }

    private var trailing: some View {
        HStack(spacing: 6) {
            dockButton(store.favorited ? "heart.fill" : "heart", size: 14, action: store.toggleFavorite)
                .help("Love")
            dockButton("quote.bubble", size: 14, action: openNowPlaying)
                .help("Lyrics")
            dockButton("list.bullet", size: 14, dimmed: !showsQueue) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { showsQueue.toggle() }
            }
            .help("Up Next")
            dockButton("pip.enter", size: 14, action: miniPlayer.open)
                .help("Mini Player")
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            Slider(value: Binding(get: { store.volume }, set: store.setVolume), in: 0...1)
                .controlSize(.mini)
                .tint(.white)
                .frame(width: 80)
            RoutePicker().frame(width: 26, height: 26).help("AirPlay")
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = store.track?.duration ?? 0
            let position = dragValue.map { $0 * duration } ?? store.position(at: context.date)
            HStack(spacing: 10) {
                Text(SongRow.time(position)).frame(width: 36, alignment: .trailing)
                Scrubber(value: duration > 0 ? position / duration : 0) { dragValue = $0 } onCommit: { value in
                    store.seek(to: value * duration)
                    dragValue = nil
                }
                .frame(height: 12)
                Text("-" + SongRow.time(max(duration - position, 0))).frame(width: 40, alignment: .leading)
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
        .environment(\.uiTheme, .mono)
    }

    private func dockButton(_ symbol: String, size: CGFloat, dimmed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white.opacity(dimmed ? 0.45 : 0.95))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
    }
}

private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.white, for: .normal)
        return picker
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

// MARK: Queue

private struct QueuePanel: View {
    let close: () -> Void

    @Environment(PlayerStore.self) private var store
    @State private var entries: [AppleMusicEngine.QueueEntry] = []
    @State private var position = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next").font(.system(size: 20, weight: .heavy))
                Spacer()
                GlassIconButton(symbol: "xmark", size: 30, action: close)
            }
            .padding(18)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries.filter { $0.index > position }) { entry in
                        QueueRow(entry: entry) { store.bridge.jump(toQueueIndex: entry.index) }
                    }
                    if entries.filter({ $0.index > position }).isEmpty {
                        Text("Nothing queued")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 18)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .task(id: store.track?.id) {
            while !Task.isCancelled {
                (entries, position) = await store.bridge.queue()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct QueueRow: View {
    let entry: AppleMusicEngine.QueueEntry
    let play: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Artwork(item: nil, template: entry.artwork, size: 40, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.system(size: 13, weight: .semibold))
                Text(entry.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.white.opacity(isHovered ? 0.07 : 0), in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: play)
    }
}
