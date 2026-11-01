import AppKit
import SwiftUI

struct LibraryPanel: View {
    let onClose: () -> Void

    @Environment(PlayerStore.self) private var store
    @State private var query = ""
    @State private var results: [Track] = []
    @State private var openPlaylist: Playlist?
    @State private var playlistTracks: [Track] = []
    @State private var isLoading = false

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            searchField
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if isSearching {
                        trackRows(results, playlistID: nil)
                    } else if let openPlaylist {
                        trackRows(playlistTracks, playlistID: openPlaylist.id)
                    } else {
                        ForEach(store.playlists) { playlist in
                            PlaylistRow(playlist: playlist) { open(playlist) }
                        }
                    }
                    if isLoading {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
                    } else if showsEmptyMessage {
                        Text(isSearching ? "Nothing found in your library" : "Nothing here yet")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .padding(30)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 26, style: .continuous))
        .padding(12)
        .task { await store.refreshPlaylists() }
        .task(id: query) { await runSearch() }
    }

    private var showsEmptyMessage: Bool {
        if isSearching { return results.isEmpty }
        if openPlaylist != nil { return playlistTracks.isEmpty }
        return store.playlists.isEmpty
    }

    private var header: some View {
        HStack(spacing: 8) {
            if openPlaylist != nil, !isSearching {
                Button {
                    openPlaylist = nil
                    playlistTracks = []
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .bold)).frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
            }
            Text(isSearching ? "Search" : openPlaylist?.name ?? "Library")
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .lineLimit(1)
            Spacer()
            if let openPlaylist, !isSearching {
                Button { store.bridge.play(playlistID: openPlaylist.id) } label: {
                    Image(systemName: "play.fill").font(.system(size: 13, weight: .bold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Play playlist")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
            TextField("Songs, artists, albums", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.1), in: .capsule)
    }

    @ViewBuilder
    private func trackRows(_ tracks: [Track], playlistID: String?) -> some View {
        ForEach(tracks) { track in
            TrackRow(track: track, isCurrent: track.id == store.track?.id) {
                store.bridge.play(trackID: track.id, playlistID: playlistID)
            }
        }
    }

    private func open(_ playlist: Playlist) {
        openPlaylist = playlist
        playlistTracks = []
        isLoading = true
        Task {
            let tracks = await store.tracks(in: playlist)
            guard openPlaylist?.id == playlist.id else { return }
            playlistTracks = tracks
            isLoading = false
        }
    }

    private func runSearch() async {
        guard isSearching else {
            results = []
            return
        }
        // Waits for a typing pause. `.task(id:)` cancels this when the query changes.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        isLoading = true
        let found = await store.search(query)
        guard !Task.isCancelled else { return }
        results = found
        isLoading = false
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let action: () -> Void

    @Environment(PlayerStore.self) private var store
    @State private var artwork: NSImage?
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ArtworkImage(image: artwork)
                    .frame(width: 46, height: 46)
                    .clipShape(.rect(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text("\(playlist.trackCount) songs")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(6)
            .background(.white.opacity(isHovered ? 0.1 : 0), in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .task(id: playlist.id) {
            let data: Data? = await withCheckedContinuation { continuation in
                store.bridge.fetchPlaylistArtwork(playlistID: playlist.id) { continuation.resume(returning: $0) }
            }
            artwork = data.flatMap(NSImage.init(data:))
        }
    }
}

private struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 14, weight: isCurrent ? .heavy : .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "waveform").font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(isHovered ? 0.1 : 0), in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
