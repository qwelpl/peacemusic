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
    private(set) var lyricsSource: LyricsSource?
    private(set) var lyricOffset: Double = 0
    private(set) var syncMessage: String?

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
    private var syncMessageTask: Task<Void, Never>?
    /// Slightly early reads as in time, where slightly late reads as broken.
    private static let lyricLead = 0.1

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

    /// The playback position that lyrics should be drawn against.
    func lyricPosition(at date: Date = Date()) -> Double {
        position(at: date) + Self.lyricLead + lyricOffset
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
            let drift = abs(position(at: snapshot.capturedAt) - snapshot.position)
            if trackChanged || snapshot.state != state || drift > 0.25 {
                setAnchor(snapshot.position, at: snapshot.capturedAt)
            }
            state = snapshot.state
        }

        if trackChanged {
            track = snapshot.track
            setAnchor(snapshot.position, at: snapshot.capturedAt)
            state = snapshot.state
            lyricIndex = nil
            lyricOffset = snapshot.track.map { savedOffset(for: $0) } ?? 0
            if let current = snapshot.track {
                loadArtwork(for: current)
                loadLyrics(for: current)
            } else {
                artwork = nil
                meshColors = Palette.fallback
                lyrics = .none
                lyricsSource = nil
            }
        }
    }

    private func setAnchor(_ position: Double, at date: Date = Date()) {
        anchorPosition = position
        anchorDate = date
    }

    private func updateLyricIndex() {
        guard case .synced(let lines) = lyrics else {
            if lyricIndex != nil { lyricIndex = nil }
            return
        }
        let now = lyricPosition()
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
        lyricsSource = nil
        Task {
            let (result, source) = await lyricsClient.lyrics(for: current)
            guard track?.id == current.id else { return }
            lyrics = result
            lyricsSource = source
        }
    }

    // MARK: Lyric sync

    private func offsetKey(for track: Track) -> String { "lyricOffset.\(track.id)" }

    private func savedOffset(for track: Track) -> Double {
        UserDefaults.standard.double(forKey: offsetKey(for: track))
    }

    /// Positive values show lyrics earlier. Remembered per song.
    func nudgeLyrics(by amount: Double) {
        setLyricOffset(((lyricOffset + amount) * 10).rounded() / 10)
    }

    func resetLyricOffset() {
        setLyricOffset(0)
    }

    private func setLyricOffset(_ offset: Double) {
        guard let track else { return }
        lyricOffset = offset
        UserDefaults.standard.set(offset, forKey: offsetKey(for: track))

        let amount = String(format: "%.1fs", abs(offset))
        let timing = offset == 0 ? "Lyrics on original timing" : "Lyrics \(amount) \(offset > 0 ? "earlier" : "later")"
        syncMessage = [timing, lyricsSource?.rawValue].compactMap { $0 }.joined(separator: " · ")
        syncMessageTask?.cancel()
        syncMessageTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { syncMessage = nil }
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
        setAnchor(18)
        let image = Palette.demoArtwork()
        artwork = image
        meshColors = Palette.meshColors(from: image)
        lyricsSource = .netEaseWords
        let demoLines = [
            (2.0, "Porch light humming in the rain"),
            (9.0, "I keep your number in a frame"),
            (15.0, "Every signal fades to grey"),
            (20.0, "But I can hear you anyway"),
            (26.0, "Soft static on the radio"),
            (32.0, "Saying things I used to know"),
            (38.0, "Turn it up and let it glow"),
            (54.0, "Morning finds the window wide"),
            (60.0, "Nothing left to hold inside"),
        ]
        let yrc = demoLines.enumerated().map { index, line in
            let start = Int(line.0 * 1000)
            let words = line.1.split(separator: " ")
            let tokens = words.enumerated().map { "(\(start + $0.offset * 420),400,0)\($0.element) " }.joined()
            return "[\(start),\(words.count * 420)]\(tokens)"
        }.joined(separator: "\n")
        lyrics = .synced(YRCParser.parse(yrc))
    }
}
