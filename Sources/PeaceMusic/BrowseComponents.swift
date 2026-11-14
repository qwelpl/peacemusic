import AppKit
import SwiftUI

// MARK: Artwork

@MainActor
private final class ArtworkCache {
    static let shared = ArtworkCache()
    private let images = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let cached = image(for: url) { return cached }
        guard let data = try? await URLSession.shared.data(from: url).0, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct Artwork: View {
    let item: MediaItem?
    var template: String? = nil
    var size: CGFloat
    var cornerRadius: CGFloat = 8
    var isCircle = false

    @State private var image: NSImage?

    private var url: URL? {
        let pixels = Int(size * 2)
        if let item { return item.artworkURL(pixels) }
        guard let template else { return nil }
        return URL(string: template.replacingOccurrences(of: "{w}", with: "\(pixels)").replacingOccurrences(of: "{h}", with: "\(pixels)"))
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.07))
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: placeholder)
                    .font(.system(size: size * 0.3, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(isCircle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        .overlay {
            if !isCircle {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ArtworkCache.shared.image(for: url) { image = cached; return }
            image = nil
            let loaded = await ArtworkCache.shared.load(url)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }

    private var placeholder: String {
        switch item?.kind {
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        case .station: "dot.radiowaves.left.and.right"
        default: "music.note"
        }
    }
}

// MARK: Actions

extension PlayerStore {
    var catalog: MusicCatalog { MusicCatalog(engine: bridge) }

    func play(_ item: MediaItem, shuffle: Bool = false) {
        guard let key = item.kind.queueKey else { return }
        bridge.play(kind: key, id: item.queueID, shuffle: shuffle)
    }

    /// Plays a track inside the album or playlist it was picked from, so the rest follows.
    func play(_ tracks: [MediaItem], at index: Int, in collection: MediaItem?) {
        if let collection, let key = collection.kind.queueKey, collection.kind != .station {
            bridge.play(kind: key, id: collection.queueID, startWith: index)
        } else {
            bridge.play(songs: tracks.map(\.queueID), startWith: index)
        }
    }

    func playNext(_ item: MediaItem) {
        guard let key = item.kind.queueKey else { return }
        bridge.playNext(kind: key, id: item.queueID)
    }

    func playLater(_ item: MediaItem) {
        guard let key = item.kind.queueKey else { return }
        bridge.playLater(kind: key, id: item.queueID)
    }

    func isCurrent(_ item: MediaItem) -> Bool {
        guard let id = track?.id else { return false }
        return id == item.id || id == item.playID || id == item.catalogID
    }
}

// Right-click menu shared by tiles and rows.
struct ItemMenu: View {
    let item: MediaItem

    @Environment(PlayerStore.self) private var store

    var body: some View {
        if item.isPlayable {
            Button("Play", systemImage: "play") { store.play(item) }
            if item.kind == .album || item.kind == .playlist {
                Button("Shuffle", systemImage: "shuffle") { store.play(item, shuffle: true) }
            }
            Divider()
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { store.playNext(item) }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { store.playLater(item) }
        }
        if !item.isLibrary, item.kind.ratingPath != nil {
            Divider()
            Button("Add to Library", systemImage: "plus") {
                Task { await store.catalog.addToLibrary(item) }
            }
        }
        if item.kind == .song {
            Menu("Add to Playlist") {
                Button("New Playlist…") { PlaylistNamer.ask { name in Task { await store.catalog.createPlaylist(named: name, with: item); await store.refreshLibraryPlaylists() } } }
                Divider()
                ForEach(store.libraryPlaylists) { playlist in
                    Button(playlist.title) { Task { await store.catalog.add(item, toPlaylist: playlist) } }
                }
            }
        }
        if item.kind.ratingPath != nil {
            Divider()
            Button("Love", systemImage: "heart") { Task { await store.catalog.rate(item, 1) } }
            Button("Suggest Less", systemImage: "hand.thumbsdown") { Task { await store.catalog.rate(item, -1) } }
        }
    }
}

@MainActor
enum PlaylistNamer {
    static func ask(_ completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Playlist"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Playlist name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { completion(name) }
    }
}

// MARK: Tiles

struct ItemTile: View {
    let item: MediaItem
    var size: CGFloat = 170

    @Environment(PlayerStore.self) private var store
    @State private var isHovered = false

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 6) {
                Artwork(item: item, size: size, cornerRadius: 10, isCircle: item.kind == .artist)
                    .shadow(color: .black.opacity(0.35), radius: isHovered ? 12 : 6, y: 4)
                    .overlay(alignment: .bottomLeading) {
                        if item.isPlayable, isHovered {
                            Button { store.play(item) } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .frame(width: 34, height: 34)
                                    .background(.ultraThinMaterial, in: .circle)
                            }
                            .buttonStyle(.plain)
                            .padding(9)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
                VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(item.title).lineLimit(1)
                        if item.isExplicit { ExplicitBadge() }
                    }
                    .font(.system(size: 13, weight: .medium))
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: size, alignment: item.kind == .artist ? .center : .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering } }
        .contextMenu { ItemMenu(item: item) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { if item.kind == .station { store.play(item) } })
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 8, weight: .heavy))
            .frame(width: 12, height: 12)
            .background(.white.opacity(0.28), in: .rect(cornerRadius: 2))
    }
}

// MARK: Song rows

struct SongRow: View {
    let song: MediaItem
    let index: Int
    var showsArtwork = true
    var showsAlbum = true
    let play: () -> Void

    @Environment(PlayerStore.self) private var store
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(song.title).lineLimit(1)
                    if song.isExplicit { ExplicitBadge() }
                }
                .font(.system(size: 13, weight: store.isCurrent(song) ? .semibold : .regular))
                if showsArtwork {
                    Text(song.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsAlbum {
                Text(song.album)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Menu {
                ItemMenu(item: song)
            } label: {
                Image(systemName: "ellipsis").frame(width: 22, height: 22).contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .opacity(isHovered ? 1 : 0)
            Text(Self.time(song.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: showsArtwork ? 52 : 40)
        .background(isHovered ? Color.white.opacity(0.07) : index.isMultiple(of: 2) ? Color.white.opacity(0.025) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu { ItemMenu(item: song) }
    }

    @ViewBuilder
    private var leading: some View {
        ZStack {
            if showsArtwork {
                Artwork(item: song, size: 38, cornerRadius: 5)
                    .opacity(isHovered || store.isCurrent(song) ? 0.45 : 1)
            }
            if isHovered {
                Button(action: play) { Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)) }
                    .buttonStyle(.plain)
            } else if store.isCurrent(song) {
                Image(systemName: store.isPlaying ? "waveform" : "speaker.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: store.isPlaying)
            } else if !showsArtwork {
                Text("\(song.trackNumber ?? index + 1)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: showsArtwork ? 38 : 24)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct SongList: View {
    let songs: [MediaItem]
    var collection: MediaItem? = nil
    var showsArtwork = true
    var showsAlbum = true

    @Environment(PlayerStore.self) private var store

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
                SongRow(song: song, index: index, showsArtwork: showsArtwork, showsAlbum: showsAlbum) {
                    store.play(songs, at: index, in: collection)
                }
            }
        }
    }
}

// MARK: Shelves

struct ShelfView: View {
    let shelf: Shelf

    @Environment(PlayerStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf.title)
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 32)
            ScrollView(.horizontal, showsIndicators: false) {
                if shelf.isSongs {
                    LazyHGrid(rows: Array(repeating: GridItem(.fixed(52), spacing: 4), count: min(4, shelf.items.count)), spacing: 20) {
                        ForEach(Array(shelf.items.enumerated()), id: \.offset) { index, song in
                            SongRow(song: song, index: 1, showsAlbum: false) {
                                store.play(shelf.items, at: index, in: nil)
                            }
                            .frame(width: 330)
                        }
                    }
                    .padding(.horizontal, 32)
                } else {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(shelf.items) { ItemTile(item: $0) }
                    }
                    .padding(.horizontal, 32)
                }
            }
            .scrollClipDisabled()
        }
    }
}

struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 30, weight: .bold))
            .padding(.horizontal, 32)
            .padding(.top, 28)
    }
}

// Loads once, shows a spinner meanwhile and a retry button if nothing came back.
struct Loading<Value, Content: View>: View {
    let load: () async -> Value
    var isEmpty: (Value) -> Bool = { _ in false }
    @ViewBuilder let content: (Value) -> Content

    @State private var value: Value?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let value, !isEmpty(value) {
                content(value)
            } else if value != nil {
                VStack(spacing: 10) {
                    Text("Nothing here yet").font(.system(size: 15, weight: .semibold))
                    Button("Try Again") { self.value = nil; attempt += 1 }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .task(id: attempt) {
            guard value == nil else { return }
            value = await load()
        }
    }
}
