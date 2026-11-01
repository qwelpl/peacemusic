import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PlayerStore {
    private(set) var state: PlayState = .stopped
    private(set) var track: Track?
    private(set) var volume: Double = 1
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    private(set) var favorited = false
    private(set) var status: BridgeStatus = .ok

    private(set) var artwork: NSImage?
    private(set) var meshColors: [Color] = Palette.fallback
    private(set) var lyrics: Lyrics = .none
    private(set) var lyricIndex: Int?

    private(set) var playlists: [Playlist] = []

    var isPlaying: Bool { state == .playing }

    let bridge = MusicBridge()
    let isDemo = CommandLine.arguments.contains("--demo")

    private let lyricsClient = LyricsClient()
    private var anchorPosition: Double = 0
    private var anchorDate = Date()
    /// Polls that started before a command can return stale values, so local state wins briefly.
    private var commandGuardUntil = Date.distantPast
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        if isDemo {
            loadDemo()
        } else {
            DistributedNotificationCenter.default().addObserver(
                forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.poll() }
            }
            Task {
                while true {
                    await poll()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        Task {
            while true {
                updateLyricIndex()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func position(at date: Date = Date()) -> Double {
        guard isPlaying else { return anchorPosition }
        let position = anchorPosition + date.timeIntervalSince(anchorDate)
        if let duration = track?.duration, duration > 0 { return min(position, duration) }
        return position
    }

    // MARK: Polling

    private func poll() async {
        let (snapshot, newStatus) = await withCheckedContinuation { continuation in
            bridge.fetchSnapshot { continuation.resume(returning: ($0, $1)) }
        }
        status = newStatus
        if let snapshot { apply(snapshot) }
    }

    private func apply(_ snapshot: PlayerSnapshot) {
        let trackChanged = snapshot.track?.id != track?.id
        let guarded = Date() < commandGuardUntil && !trackChanged

        if !guarded {
            volume = snapshot.volume
            shuffle = snapshot.shuffle
            repeatMode = snapshot.repeatMode
            favorited = snapshot.favorited
            let drift = abs(position() - snapshot.position)
            if trackChanged || snapshot.state != state || drift > 0.75 {
                setAnchor(snapshot.position)
            }
            state = snapshot.state
        }

        if trackChanged {
            track = snapshot.track
            setAnchor(snapshot.position)
            state = snapshot.state
            lyricIndex = nil
            if let current = snapshot.track {
                loadArtwork(for: current)
                loadLyrics(for: current)
            } else {
                artwork = nil
                meshColors = Palette.fallback
                lyrics = .none
            }
        }
    }

    private func setAnchor(_ position: Double) {
        anchorPosition = position
        anchorDate = Date()
    }

    private func updateLyricIndex() {
        guard case .synced(let lines) = lyrics else {
            if lyricIndex != nil { lyricIndex = nil }
            return
        }
        // Small lead so the highlight lands with the vocal rather than after it.
        let now = position() + 0.15
        let index = lines.lastIndex { $0.time <= now }
        if index != lyricIndex { lyricIndex = index }
    }

    // MARK: Loading

    private func loadArtwork(for current: Track) {
        Task {
            let local: Data? = await withCheckedContinuation { continuation in
                bridge.fetchCurrentArtwork { continuation.resume(returning: $0) }
            }
            var image = local.flatMap(NSImage.init(data:))
            if image == nil {
                image = await ArtworkFallback.image(for: current)
            }
            guard track?.id == current.id else { return }
            artwork = image
            meshColors = image.map(Palette.meshColors(from:)) ?? Palette.fallback
        }
    }

    private func loadLyrics(for current: Track) {
        lyrics = .loading
        Task {
            let result = await lyricsClient.lyrics(for: current)
            guard track?.id == current.id else { return }
            lyrics = result
        }
    }

    // MARK: Commands

    private func guardLocalState() {
        commandGuardUntil = Date().addingTimeInterval(0.8)
    }

    func togglePlayPause() {
        guardLocalState()
        let position = position()
        state = isPlaying ? .paused : .playing
        setAnchor(position)
        if !isDemo { bridge.playPause() }
    }

    func next() {
        if !isDemo { bridge.next() }
    }

    func previous() {
        if isDemo { setAnchor(0) } else { bridge.previous() }
    }

    func seek(to seconds: Double) {
        guardLocalState()
        setAnchor(seconds)
        if !isDemo { bridge.seek(to: seconds) }
    }

    func setVolume(_ value: Double) {
        guardLocalState()
        volume = value
        if !isDemo { bridge.setVolume(value) }
    }

    func toggleShuffle() {
        guardLocalState()
        shuffle.toggle()
        if !isDemo { bridge.setShuffle(shuffle) }
    }

    func cycleRepeat() {
        guardLocalState()
        repeatMode = repeatMode.next
        if !isDemo { bridge.setRepeat(repeatMode) }
    }

    func toggleFavorite() {
        guardLocalState()
        favorited.toggle()
        if !isDemo { bridge.setFavorited(favorited) }
    }

    func openMusic() { bridge.openMusic() }

    func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Library

    func refreshPlaylists() async {
        guard !isDemo else { return }
        playlists = await withCheckedContinuation { continuation in
            bridge.fetchPlaylists { continuation.resume(returning: $0) }
        }
    }

    func tracks(in playlist: Playlist) async -> [Track] {
        await withCheckedContinuation { continuation in
            bridge.fetchTracks(playlistID: playlist.id) { continuation.resume(returning: $0) }
        }
    }

    func search(_ query: String) async -> [Track] {
        await withCheckedContinuation { continuation in
            bridge.search(query) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Demo

    private func loadDemo() {
        let current = Track(id: "demo", title: "Soft Static", artist: "Peace", album: "Demo Reel", duration: 214)
        track = current
        state = .playing
        volume = 0.7
        favorited = true
        setAnchor(21)
        let image = Palette.demoArtwork()
        artwork = image
        meshColors = Palette.meshColors(from: image)
        lyrics = .synced(LRCParser.parse("""
        [00:02.00]Porch light humming in the rain
        [00:09.00]I keep your number in a frame
        [00:15.00]Every signal fades to grey
        [00:20.00]But I can hear you anyway
        [00:26.00]Soft static on the radio
        [00:32.00]Saying things I used to know
        [00:38.00]Turn it up and let it glow
        [00:44.00]
        [00:54.00]Morning finds the window wide
        [01:00.00]Nothing left to hold inside
        """, duration: current.duration))
    }
}
