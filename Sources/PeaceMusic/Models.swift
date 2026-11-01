import Foundation

enum PlayState: String {
    case playing, paused, stopped
}

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

struct Track: Equatable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
}

struct PlayerSnapshot {
    var state: PlayState = .stopped
    var track: Track?
    var position: Double = 0
    var volume: Double = 1
    var shuffle = false
    var repeatMode: RepeatMode = .off
    var favorited = false
    var capturedAt = Date()
}

struct Playlist: Identifiable, Hashable {
    let id: String
    let name: String
    let trackCount: Int
}

enum BridgeStatus: Equatable {
    case ok
    case musicNotRunning
    case notAuthorized
}
