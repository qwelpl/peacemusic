import AppKit
import Foundation

/// Talks to Music.app over Apple Events. All scripts run on one serial queue so
/// that a slow library query never blocks the UI.
final class MusicBridge: @unchecked Sendable {
    private let queue = DispatchQueue(label: "peace.music-bridge", qos: .userInitiated)

    private static let notAuthorizedCode = -1743

    private enum ScriptError: Error {
        case failed(code: Int)
    }

    private func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw ScriptError.failed(code: 0) }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info {
            throw ScriptError.failed(code: info[NSAppleScript.errorNumber] as? Int ?? 0)
        }
        return result
    }

    /// Escapes a value for use inside an AppleScript string literal.
    private func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    // MARK: Status

    /// A nil snapshot means the script failed, which is normal for a moment between tracks.
    func fetchSnapshot(completion: @escaping @Sendable (PlayerSnapshot?, BridgeStatus) -> Void) {
        queue.async { [self] in
            guard isRunning else {
                completion(PlayerSnapshot(), .musicNotRunning)
                return
            }
            let source = """
            tell application "Music"
                set s to player state as text
                set v to sound volume
                set sh to shuffle enabled
                set r to song repeat as text
                if s is "stopped" then return {s, v, sh, r}
                set t to current track
                set fav to false
                try
                    set fav to favorited of t
                end try
                set d to 0
                try
                    set d to duration of t
                end try
                set p to 0
                try
                    set p to player position
                end try
                return {s, v, sh, r, persistent ID of t, name of t, artist of t, album of t, d, p, fav}
            end tell
            """
            do {
                let list = try run(source)
                completion(parseSnapshot(list), .ok)
            } catch ScriptError.failed(let code) where code == Self.notAuthorizedCode {
                completion(PlayerSnapshot(), .notAuthorized)
            } catch {
                completion(nil, .ok)
            }
        }
    }

    private func parseSnapshot(_ list: NSAppleEventDescriptor) -> PlayerSnapshot {
        var snapshot = PlayerSnapshot()
        snapshot.state = PlayState(rawValue: list.atIndex(1)?.stringValue ?? "") ?? .stopped
        snapshot.volume = Double(list.atIndex(2)?.int32Value ?? 100) / 100
        snapshot.shuffle = list.atIndex(3)?.booleanValue ?? false
        snapshot.repeatMode = RepeatMode(rawValue: list.atIndex(4)?.stringValue ?? "") ?? .off
        guard list.numberOfItems >= 11 else { return snapshot }
        snapshot.track = Track(
            id: list.atIndex(5)?.stringValue ?? "",
            title: list.atIndex(6)?.stringValue ?? "",
            artist: list.atIndex(7)?.stringValue ?? "",
            album: list.atIndex(8)?.stringValue ?? "",
            duration: list.atIndex(9)?.doubleValue ?? 0
        )
        snapshot.position = list.atIndex(10)?.doubleValue ?? 0
        snapshot.favorited = list.atIndex(11)?.booleanValue ?? false
        return snapshot
    }

    func fetchCurrentArtwork(completion: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            let data = try? run("""
            tell application "Music" to get raw data of artwork 1 of current track
            """).data
            completion(data)
        }
    }

    // MARK: Transport

    private func send(_ command: String) {
        queue.async { [self] in
            guard isRunning else { return }
            _ = try? run("tell application \"Music\" to \(command)")
        }
    }

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("back track") }
    func seek(to seconds: Double) { send("set player position to \(seconds)") }
    func setVolume(_ volume: Double) { send("set sound volume to \(Int((volume * 100).rounded()))") }
    func setShuffle(_ on: Bool) { send("set shuffle enabled to \(on)") }
    func setRepeat(_ mode: RepeatMode) { send("set song repeat to \(mode.rawValue)") }
    func setFavorited(_ on: Bool) { send("set favorited of current track to \(on)") }

    func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: Library

    func fetchPlaylists(completion: @escaping @Sendable ([Playlist]) -> Void) {
        queue.async { [self] in
            let source = """
            tell application "Music"
                set out to {}
                repeat with p in (get user playlists)
                    set end of out to {persistent ID of p, name of p, count of tracks of p}
                end repeat
                return out
            end tell
            """
            guard let list = try? run(source) else {
                completion([])
                return
            }
            completion(descriptors(in: list).compactMap { item in
                guard let id = item.atIndex(1)?.stringValue, let name = item.atIndex(2)?.stringValue else { return nil }
                return Playlist(id: id, name: name, trackCount: Int(item.atIndex(3)?.int32Value ?? 0))
            })
        }
    }

    func fetchTracks(playlistID: String, limit: Int = 300, completion: @escaping @Sendable ([Track]) -> Void) {
        fetchTrackList(from: """
        set found to tracks of (first playlist whose persistent ID is \(quoted(playlistID)))
        """, limit: limit, completion: completion)
    }

    func search(_ query: String, limit: Int = 60, completion: @escaping @Sendable ([Track]) -> Void) {
        fetchTrackList(from: """
        set found to search library playlist 1 for \(quoted(query))
        """, limit: limit, completion: completion)
    }

    private func fetchTrackList(from selection: String, limit: Int, completion: @escaping @Sendable ([Track]) -> Void) {
        queue.async { [self] in
            let source = """
            tell application "Music"
                \(selection)
                set out to {}
                set i to 0
                repeat with t in found
                    set i to i + 1
                    if i > \(limit) then exit repeat
                    set end of out to {persistent ID of t, name of t, artist of t, album of t, duration of t}
                end repeat
                return out
            end tell
            """
            guard let list = try? run(source) else {
                completion([])
                return
            }
            completion(descriptors(in: list).compactMap { item in
                guard let id = item.atIndex(1)?.stringValue else { return nil }
                return Track(
                    id: id,
                    title: item.atIndex(2)?.stringValue ?? "",
                    artist: item.atIndex(3)?.stringValue ?? "",
                    album: item.atIndex(4)?.stringValue ?? "",
                    duration: item.atIndex(5)?.doubleValue ?? 0
                )
            })
        }
    }

    func fetchPlaylistArtwork(playlistID: String, completion: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            let data = try? run("""
            tell application "Music" to get raw data of artwork 1 of track 1 of (first playlist whose persistent ID is \(quoted(playlistID)))
            """).data
            completion(data)
        }
    }

    func play(playlistID: String) {
        send("play (first playlist whose persistent ID is \(quoted(playlistID)))")
    }

    /// Playing from a playlist keeps that playlist as the queue.
    func play(trackID: String, playlistID: String?) {
        let container = playlistID.map { "(first playlist whose persistent ID is \(quoted($0)))" } ?? "library playlist 1"
        send("play (first track of \(container) whose persistent ID is \(quoted(trackID)))")
    }

    private func descriptors(in list: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { list.atIndex($0) }
    }
}
