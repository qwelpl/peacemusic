import Foundation

// A song, album, playlist, artist or station, from the catalog or the user's library.
struct MediaItem: Identifiable, Hashable {
    enum Kind: String {
        case song, album, playlist, artist, station, video, other

        // The key MusicKit's setQueue, playNext and playLater expect.
        var queueKey: String? {
            switch self {
            case .song: "song"
            case .album: "album"
            case .playlist: "playlist"
            case .station: "station"
            case .video: "musicVideo"
            case .artist, .other: nil
            }
        }

        var ratingPath: String? {
            switch self {
            case .song: "songs"
            case .album: "albums"
            case .playlist: "playlists"
            default: nil
            }
        }
    }

    let id: String
    let kind: Kind
    let isLibrary: Bool
    let title: String
    let subtitle: String
    let artwork: String?
    let duration: Double
    let playID: String?
    let catalogID: String?
    let trackNumber: Int?
    let isExplicit: Bool
    let album: String
    let note: String?
    let releaseDate: String?
    let genres: [String]
    let composer: String?
    let artistID: String?
    let albumID: String?
    // A library playlist the account can change.
    let canEdit: Bool
    // A library playlist's public id (pl.u-…), which is what other pages link to.
    let globalID: String?

    var isPlayable: Bool { kind.queueKey != nil && (playID ?? id).isEmpty == false }
    var queueID: String { playID ?? id }

    func artworkURL(_ size: Int) -> URL? {
        guard let artwork else { return nil }
        return URL(string: artwork
            .replacingOccurrences(of: "{w}", with: String(size))
            .replacingOccurrences(of: "{h}", with: String(size))
            .replacingOccurrences(of: "{f}", with: "jpg")
            .replacingOccurrences(of: "{c}", with: ""))
    }

    init?(_ resource: [String: Any]) {
        guard let id = resource["id"] as? String, let type = resource["type"] as? String else { return nil }
        let attributes = resource["attributes"] as? [String: Any] ?? [:]
        let base = type.replacingOccurrences(of: "library-", with: "")
        self.id = id
        isLibrary = type.hasPrefix("library-")
        kind = switch base {
        case "songs": .song
        case "albums": .album
        case "playlists": .playlist
        case "artists": .artist
        case "stations": .station
        case "music-videos": .video
        default: .other
        }
        title = attributes["name"] as? String ?? ""
        let curator = attributes["curatorName"] as? String
        subtitle = attributes["artistName"] as? String ?? curator ?? ""
        artwork = (attributes["artwork"] as? [String: Any])?["url"] as? String
        duration = (attributes["durationInMillis"] as? Double ?? 0) / 1000
        let playParams = attributes["playParams"] as? [String: Any]
        playID = playParams?["id"] as? String
        catalogID = playParams?["catalogId"] as? String
        trackNumber = attributes["trackNumber"] as? Int
        isExplicit = attributes["contentRating"] as? String == "explicit"
        album = attributes["albumName"] as? String ?? ""
        let notes = attributes["editorialNotes"] as? [String: Any]
        let description = attributes["description"] as? [String: Any]
        note = (notes?["short"] ?? notes?["standard"] ?? description?["short"] ?? description?["standard"]) as? String
        releaseDate = attributes["releaseDate"] as? String
        genres = (attributes["genreNames"] as? [String] ?? []).filter { $0 != "Music" }
        composer = attributes["composerName"] as? String
        let relationships = resource["relationships"] as? [String: Any]
        artistID = ((relationships?["artists"] as? [String: Any])?["data"] as? [[String: Any]])?.first?["id"] as? String
        albumID = ((relationships?["albums"] as? [String: Any])?["data"] as? [[String: Any]])?.first?["id"] as? String
        canEdit = attributes["canEdit"] as? Bool ?? false
        globalID = playParams?["globalId"] as? String
    }

    static func list(_ value: Any?) -> [MediaItem] {
        ((value as? [String: Any])?["data"] as? [[String: Any]] ?? value as? [[String: Any]] ?? []).compactMap(MediaItem.init)
    }
}

// A titled row of items, as on Home, Browse and Radio.
struct Shelf: Identifiable {
    // Stable across partial loads, so a shelf that's already showing isn't rebuilt.
    var id: String { title + (items.first?.id ?? "") }
    let title: String
    let items: [MediaItem]
    var isSongs: Bool { items.first?.kind == .song }
}

// Results that arrive one at a time, kept in the order they were asked for.
@MainActor
private final class Slots<T> {
    var values: [T?]
    init(_ count: Int) { values = Array(repeating: nil, count: count) }
    var arrived: [T] { values.compactMap { $0 } }
}

// Everything the browsing screens ask Apple Music for. Calls that take `update` report
// what's arrived so far, so pages fill in piece by piece.
@MainActor
struct MusicCatalog {
    let engine: AppleMusicEngine

    /// Runs the loaders side by side and reports each as it lands, in the loaders' order.
    private func gather<T>(_ loaders: [@MainActor () async -> T], update: @escaping ([T]) -> Void) async -> [T] {
        let slots = Slots<T>(loaders.count)
        let tasks = loaders.enumerated().map { index, load in
            Task { @MainActor in
                let value = await load()
                slots.values[index] = value
                update(slots.arrived)
            }
        }
        for task in tasks { await task.value }
        return slots.arrived
    }

    // MARK: Apple Music

    func home(update: @escaping ([Shelf]) -> Void = { _ in }) async -> [Shelf] {
        let loaders: [@MainActor () async -> [Shelf]] = [
            { shelf("Recently Played", await engine.api("/v1/me/recent/played", ["limit": 10])) },
            { shelf("Heavy Rotation", await engine.api("/v1/me/history/heavy-rotation", ["limit": 10])) },
            {
                let response = await engine.api("/v1/me/recommendations", ["limit": 12])
                return (response?["data"] as? [[String: Any]] ?? []).compactMap { group -> Shelf? in
                    let attributes = group["attributes"] as? [String: Any]
                    let title = (attributes?["title"] as? [String: Any])?["stringForDisplay"] as? String ?? ""
                    let items = MediaItem.list((group["relationships"] as? [String: Any])?["contents"])
                    return title.isEmpty || items.isEmpty ? nil : Shelf(title: title, items: items)
                }
            },
        ]
        return await gather(loaders) { update($0.flatMap { $0 }) }.flatMap { $0 }
    }

    func browse(update: @escaping ([Shelf]) -> Void = { _ in }) async -> [Shelf] {
        let loaders: [@MainActor () async -> [Shelf]] = [("songs", "Top Songs"), ("albums", "Top Albums"), ("playlists", "Top Playlists")].map { key, fallback in
            {
                let response = await engine.api("/v1/catalog/{storefront}/charts", ["types": key, "limit": 24])
                let charts = (response?["results"] as? [String: Any])?[key] as? [[String: Any]] ?? []
                return charts.compactMap { chart in
                    let items = MediaItem.list(chart)
                    return items.isEmpty ? nil : Shelf(title: chart["name"] as? String ?? fallback, items: items)
                }
            }
        }
        return await gather(loaders) { update($0.flatMap { $0 }) }.flatMap { $0 }
    }

    func radio(update: @escaping ([Shelf]) -> Void = { _ in }) async -> [Shelf] {
        let loaders: [@MainActor () async -> [Shelf]] = [
            { shelf("Your Station", await engine.api("/v1/catalog/{storefront}/stations", ["filter[identity]": "personal"])) },
            { shelf("Live Radio", await engine.api("/v1/catalog/{storefront}/stations", ["filter[featured]": "apple-music-live-radio"])) },
            { shelf("Recently Played Stations", await engine.api("/v1/me/recent/radio-stations", ["limit": 10])) },
        ]
        return await gather(loaders) { update($0.flatMap { $0 }) }.flatMap { $0 }
    }

    // Apple Music Replay: the year's most played songs, albums and artists, the same summary
    // music.apple.com/replay draws, then the account's Replay playlists from past years.
    func replay(update: @escaping ([Shelf]) -> Void = { _ in }) async -> [Shelf] {
        let loaders: [@MainActor () async -> [Shelf]] = [
            {
                let response = await engine.api("/v1/me/music-summaries/search", [
                    "filter[year]": "latest",
                    "views": "top-songs,top-albums,top-artists",
                ])
                guard let summary = (response?["data"] as? [[String: Any]])?.first else { return [] }
                let year = ((summary["attributes"] as? [String: Any])?["year"]).map { " of \($0)" } ?? ""
                let views = summary["views"] as? [String: Any]
                return [("top-songs", "Top Songs"), ("top-albums", "Top Albums"), ("top-artists", "Top Artists")].compactMap { key, title in
                    let items = MediaItem.list(views?[key])
                    return items.isEmpty ? nil : Shelf(title: title + year, items: items)
                }
            },
            {
                let playlists = await libraryPlaylists().filter { $0.title.hasPrefix("Replay") }
                return playlists.isEmpty ? [] : [Shelf(title: "Replay Playlists", items: playlists.sorted { $0.title > $1.title })]
            },
        ]
        return await gather(loaders) { update($0.flatMap { $0 }) }.flatMap { $0 }
    }

    private func shelf(_ title: String, _ response: [String: Any]?) -> [Shelf] {
        let items = MediaItem.list(response)
        return items.isEmpty ? [] : [Shelf(title: title, items: items)]
    }

    func search(_ term: String, inLibrary: Bool, update: @escaping ([Shelf]) -> Void = { _ in }) async -> [Shelf] {
        let kinds: [(String, String)] = inLibrary
            ? [("library-songs", "Songs"), ("library-albums", "Albums"), ("library-artists", "Artists"), ("library-playlists", "Playlists")]
            : [("songs", "Songs"), ("albums", "Albums"), ("artists", "Artists"), ("playlists", "Playlists"), ("stations", "Stations")]
        let path = inLibrary ? "/v1/me/library/search" : "/v1/catalog/{storefront}/search"
        // One request per kind, so songs can show before artists come back.
        let loaders: [@MainActor () async -> [Shelf]] = kinds.map { key, title in
            {
                let response = await engine.api(path, ["term": term, "types": key, "limit": inLibrary ? 25 : 20])
                let items = MediaItem.list((response?["results"] as? [String: Any])?[key])
                return items.isEmpty ? [] : [Shelf(title: title, items: items)]
            }
        }
        return await gather(loaders) { update($0.flatMap { $0 }) }.flatMap { $0 }
    }

    // MARK: Pages

    /// An album's or playlist's details and tracks. Tracks arrive a page at a time.
    func collection(_ item: MediaItem, update: @escaping (MediaItem, [MediaItem]) -> Void = { _, _ in }) async -> (MediaItem, [MediaItem]) {
        let type = item.kind == .album ? "albums" : "playlists"
        let path = item.isLibrary ? "/v1/me/library/\(type)/\(item.id)" : "/v1/catalog/{storefront}/\(type)/\(item.id)"
        let response = await engine.api(path, ["include": "tracks"])
        let resource = (response?["data"] as? [[String: Any]])?.first
        let detail = resource.flatMap(MediaItem.init) ?? item
        let relationship = (resource?["relationships"] as? [String: Any])?["tracks"] as? [String: Any]
        var tracks = MediaItem.list(relationship)
        update(detail, tracks)
        var next = relationship?["next"] as? String
        while let page = next, tracks.count < 1000 {
            let more = await engine.api(page, ["limit": 100])
            let found = MediaItem.list(more)
            guard !found.isEmpty else { break }
            tracks += found
            update(detail, tracks)
            next = more?["next"] as? String
        }
        if item.isLibrary, item.kind == .playlist, tracks.isEmpty {
            tracks = await pages("/v1/me/library/playlists/\(item.id)/tracks", limit: 1000) { update(detail, $0) }
        }
        return (detail, tracks)
    }

    struct ArtistPage {
        var artist: MediaItem
        var shelves: [Shelf]
    }

    private static let artistViews = [
        ("latest-release", "Latest Release"), ("top-songs", "Top Songs"), ("full-albums", "Albums"),
        ("singles", "Singles & EPs"), ("live-albums", "Live Albums"), ("compilation-albums", "Compilations"),
        ("appears-on-albums", "Appears On"), ("top-music-videos", "Music Videos"), ("similar-artists", "Similar Artists"),
    ]

    /// The artist first, then each section of their page as it loads.
    func artist(_ item: MediaItem, update: @escaping (ArtistPage) -> Void = { _ in }) async -> ArtistPage {
        if item.isLibrary {
            update(ArtistPage(artist: item, shelves: []))
            let albums = await pages("/v1/me/library/artists/\(item.id)/albums", limit: 300) { albums in
                update(ArtistPage(artist: item, shelves: [Shelf(title: "Albums", items: albums)]))
            }
            return ArtistPage(artist: item, shelves: albums.isEmpty ? [] : [Shelf(title: "Albums", items: albums)])
        }
        let page = Slots<MediaItem>(1)
        page.values[0] = item
        var shelves: [Shelf] = []
        let header: @MainActor () async -> [Shelf] = {
            let response = await engine.api("/v1/catalog/{storefront}/artists/\(item.id)", ["extend": "editorialNotes"])
            if let artist = (response?["data"] as? [[String: Any]])?.first.flatMap(MediaItem.init) { page.values[0] = artist }
            return []
        }
        let views: [@MainActor () async -> [Shelf]] = Self.artistViews.map { key, title in
            {
                let response = await engine.api("/v1/catalog/{storefront}/artists/\(item.id)/view/\(key)", ["limit": 20])
                let items = MediaItem.list(response)
                let named = (response?["attributes"] as? [String: Any])?["title"] as? String ?? title
                return items.isEmpty ? [] : [Shelf(title: named, items: items)]
            }
        }
        shelves = await gather([header] + views) { arrived in
            update(ArtistPage(artist: page.values[0] ?? item, shelves: arrived.flatMap { $0 }))
        }.flatMap { $0 }
        return ArtistPage(artist: page.values[0] ?? item, shelves: shelves)
    }

    // MARK: Now playing

    struct SongContext {
        var song: MediaItem
        var album: MediaItem?
        var artist: MediaItem?
        var moreByArtist: [MediaItem]
    }

    /// The catalog details around a playing song: the song and album first, then the artist
    /// and their other hits.
    func context(forSong id: String, update: @escaping (SongContext) -> Void = { _ in }) async -> SongContext? {
        let path = id.hasPrefix("i.") ? "/v1/me/library/songs/\(id)/catalog" : "/v1/catalog/{storefront}/songs/\(id)"
        let response = await engine.api(path, ["include": "albums,artists"])
        guard let resource = (response?["data"] as? [[String: Any]])?.first, let song = MediaItem(resource) else { return nil }
        let relationships = resource["relationships"] as? [String: Any]
        var context = SongContext(
            song: song,
            album: MediaItem.list(relationships?["albums"]).first,
            artist: MediaItem.list(relationships?["artists"]).first,
            moreByArtist: []
        )
        update(context)
        if let artistID = context.artist?.id ?? song.artistID {
            let page = await engine.api("/v1/catalog/{storefront}/artists/\(artistID)", ["views": "top-songs", "extend": "editorialNotes"])
            let resource = (page?["data"] as? [[String: Any]])?.first
            context.artist = resource.flatMap(MediaItem.init) ?? context.artist
            let views = resource?["views"] as? [String: Any]
            context.moreByArtist = Array(MediaItem.list(views?["top-songs"]).filter { $0.id != song.id }.prefix(6))
            update(context)
        }
        return context
    }

    // MARK: Library

    func recentlyAdded(update: @escaping ([MediaItem]) -> Void = { _ in }) async -> [MediaItem] {
        await pages("/v1/me/library/recently-added", limit: 100, pageSize: 25, update: update)
    }

    func libraryAlbums(update: @escaping ([MediaItem]) -> Void = { _ in }) async -> [MediaItem] {
        await pages("/v1/me/library/albums", limit: 2000, update: update)
    }

    func libraryArtists(update: @escaping ([MediaItem]) -> Void = { _ in }) async -> [MediaItem] {
        await pages("/v1/me/library/artists", limit: 2000, update: update)
    }

    func librarySongs(update: @escaping ([MediaItem]) -> Void = { _ in }) async -> [MediaItem] {
        await pages("/v1/me/library/songs", limit: 5000, update: update)
    }

    func libraryPlaylists(update: @escaping ([MediaItem]) -> Void = { _ in }) async -> [MediaItem] {
        await pages("/v1/me/library/playlists", limit: 500, update: update)
    }

    private func pages(_ path: String, limit: Int, pageSize: Int = 100, update: @escaping ([MediaItem]) -> Void = { _ in }) async -> [MediaItem] {
        var items: [MediaItem] = []
        var next: String? = path
        var parameters: [String: Any] = ["limit": pageSize]
        while let page = next, items.count < limit {
            guard let response = await engine.api(page, parameters) else { break }
            let found = MediaItem.list(response)
            items += found
            if !found.isEmpty { update(items) }
            next = found.isEmpty ? nil : response["next"] as? String
            // "next" already carries the paging parameters.
            parameters = [:]
        }
        return items
    }

    // MARK: Changes

    func addToLibrary(_ item: MediaItem) async {
        guard !item.isLibrary, let type = item.kind.ratingPath else { return }
        _ = await engine.api("/v1/me/library", ["ids[\(type)]": item.id], method: "POST")
    }

    /// 1 loves, -1 dislikes, nil clears.
    func rate(_ item: MediaItem, _ value: Int?) async {
        guard let type = item.kind.ratingPath else { return }
        let path = "/v1/me/ratings/\(item.isLibrary ? "library-" : "")\(type)/\(item.id)"
        if let value {
            _ = await engine.api(path, method: "PUT", body: ["type": "rating", "attributes": ["value": value]])
        } else {
            _ = await engine.api(path, method: "DELETE")
        }
    }

    /// Takes a song or album out of the library. True when Apple confirms it.
    func removeFromLibrary(_ item: MediaItem) async -> Bool {
        guard item.isLibrary, let type = item.kind.ratingPath else { return false }
        return Self.succeeded(await engine.api("/v1/me/library/\(type)/\(item.id)", method: "DELETE"))
    }

    /// Takes every copy of a song out of one of the account's playlists.
    func remove(_ item: MediaItem, fromPlaylist playlist: MediaItem) async -> Bool {
        let type = item.isLibrary ? "library-songs" : "songs"
        let response = await engine.api(
            "/v1/me/library/playlists/\(playlist.id)/tracks",
            ["ids[\(type)]": item.id, "mode": "all"],
            method: "DELETE"
        )
        return Self.succeeded(response)
    }

    // MusicKit hands back Apple's errors as data rather than throwing.
    private static func succeeded(_ response: [String: Any]?) -> Bool {
        guard let response else { return false }
        return response["errors"] == nil
    }

    func add(_ item: MediaItem, toPlaylist playlist: MediaItem) async {
        let type = item.isLibrary ? "library-songs" : "songs"
        _ = await engine.api("/v1/me/library/playlists/\(playlist.id)/tracks", method: "POST", body: ["data": [["id": item.id, "type": type]]])
    }

    func createPlaylist(named name: String, with item: MediaItem? = nil) async {
        var body: [String: Any] = ["attributes": ["name": name]]
        if let item {
            let type = item.isLibrary ? "library-songs" : "songs"
            body["relationships"] = ["tracks": ["data": [["id": item.id, "type": type]]]]
        }
        _ = await engine.api("/v1/me/library/playlists", method: "POST", body: body)
    }
}
