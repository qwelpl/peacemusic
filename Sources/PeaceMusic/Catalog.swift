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
    }

    static func list(_ value: Any?) -> [MediaItem] {
        ((value as? [String: Any])?["data"] as? [[String: Any]] ?? value as? [[String: Any]] ?? []).compactMap(MediaItem.init)
    }
}

// A titled row of items, as on Home, Browse and Radio.
struct Shelf: Identifiable {
    let id = UUID()
    let title: String
    let items: [MediaItem]
    var isSongs: Bool { items.first?.kind == .song }
}

// Everything the browsing screens ask Apple Music for.
@MainActor
struct MusicCatalog {
    let engine: AppleMusicEngine

    // MARK: Apple Music

    func home() async -> [Shelf] {
        async let recent = engine.api("/v1/me/recent/played", ["limit": 10])
        async let rotation = engine.api("/v1/me/history/heavy-rotation", ["limit": 10])
        async let recommendations = engine.api("/v1/me/recommendations", ["limit": 12])
        var shelves: [Shelf] = []
        let played = MediaItem.list(await recent)
        if !played.isEmpty { shelves.append(Shelf(title: "Recently Played", items: played)) }
        let heavy = MediaItem.list(await rotation)
        if !heavy.isEmpty { shelves.append(Shelf(title: "Heavy Rotation", items: heavy)) }
        for group in (await recommendations)?["data"] as? [[String: Any]] ?? [] {
            let attributes = group["attributes"] as? [String: Any]
            let title = (attributes?["title"] as? [String: Any])?["stringForDisplay"] as? String ?? ""
            let contents = (group["relationships"] as? [String: Any])?["contents"]
            let items = MediaItem.list(contents)
            if !title.isEmpty, !items.isEmpty { shelves.append(Shelf(title: title, items: items)) }
        }
        return shelves
    }

    func browse() async -> [Shelf] {
        let response = await engine.api("/v1/catalog/{storefront}/charts", ["types": "songs,albums,playlists", "limit": 24])
        let results = response?["results"] as? [String: Any] ?? [:]
        var shelves: [Shelf] = []
        for (key, fallback) in [("songs", "Top Songs"), ("albums", "Top Albums"), ("playlists", "Top Playlists")] {
            for chart in results[key] as? [[String: Any]] ?? [] {
                let items = MediaItem.list(chart)
                if !items.isEmpty { shelves.append(Shelf(title: chart["name"] as? String ?? fallback, items: items)) }
            }
        }
        return shelves
    }

    func radio() async -> [Shelf] {
        async let live = engine.api("/v1/catalog/{storefront}/stations", ["filter[featured]": "apple-music-live-radio"])
        async let personal = engine.api("/v1/catalog/{storefront}/stations", ["filter[identity]": "personal"])
        async let recent = engine.api("/v1/me/recent/radio-stations", ["limit": 10])
        var shelves: [Shelf] = []
        let mine = MediaItem.list(await personal)
        if !mine.isEmpty { shelves.append(Shelf(title: "Your Station", items: mine)) }
        let broadcasts = MediaItem.list(await live)
        if !broadcasts.isEmpty { shelves.append(Shelf(title: "Live Radio", items: broadcasts)) }
        let played = MediaItem.list(await recent)
        if !played.isEmpty { shelves.append(Shelf(title: "Recently Played Stations", items: played)) }
        return shelves
    }

    func search(_ term: String, inLibrary: Bool) async -> [Shelf] {
        let response: [String: Any]?
        let order: [(String, String)]
        if inLibrary {
            response = await engine.api("/v1/me/library/search", [
                "term": term, "types": "library-songs,library-albums,library-artists,library-playlists", "limit": 25,
            ])
            order = [("library-songs", "Songs"), ("library-albums", "Albums"), ("library-artists", "Artists"), ("library-playlists", "Playlists")]
        } else {
            response = await engine.api("/v1/catalog/{storefront}/search", [
                "term": term, "types": "songs,albums,artists,playlists,stations", "limit": 20,
            ])
            order = [("songs", "Songs"), ("albums", "Albums"), ("artists", "Artists"), ("playlists", "Playlists"), ("stations", "Stations")]
        }
        let results = response?["results"] as? [String: Any] ?? [:]
        return order.compactMap { key, title in
            let items = MediaItem.list(results[key])
            return items.isEmpty ? nil : Shelf(title: title, items: items)
        }
    }

    // MARK: Pages

    /// An album's or playlist's details and tracks.
    func collection(_ item: MediaItem) async -> (MediaItem, [MediaItem]) {
        let type = item.kind == .album ? "albums" : "playlists"
        let path = item.isLibrary ? "/v1/me/library/\(type)/\(item.id)" : "/v1/catalog/{storefront}/\(type)/\(item.id)"
        let response = await engine.api(path, ["include": "tracks"])
        let resource = (response?["data"] as? [[String: Any]])?.first
        let detail = resource.flatMap(MediaItem.init) ?? item
        var tracks = MediaItem.list((resource?["relationships"] as? [String: Any])?["tracks"])
        // Long playlists come back a page at a time.
        var next = ((resource?["relationships"] as? [String: Any])?["tracks"] as? [String: Any])?["next"] as? String
        while let page = next, tracks.count < 1000 {
            let more = await engine.api(page, ["limit": 100])
            tracks += MediaItem.list(more)
            next = more?["next"] as? String
        }
        if item.isLibrary, item.kind == .playlist, tracks.isEmpty {
            tracks = await pages("/v1/me/library/playlists/\(item.id)/tracks", limit: 1000)
        }
        return (detail, tracks)
    }

    struct ArtistPage {
        var artist: MediaItem
        var shelves: [Shelf]
    }

    func artist(_ item: MediaItem) async -> ArtistPage {
        if item.isLibrary {
            let albums = await pages("/v1/me/library/artists/\(item.id)/albums", limit: 300)
            return ArtistPage(artist: item, shelves: albums.isEmpty ? [] : [Shelf(title: "Albums", items: albums)])
        }
        let response = await engine.api("/v1/catalog/{storefront}/artists/\(item.id)", [
            "views": "top-songs,latest-release,full-albums,singles,live-albums,compilation-albums,appears-on-albums,top-music-videos,similar-artists",
        ])
        let resource = (response?["data"] as? [[String: Any]])?.first
        let views = resource?["views"] as? [String: Any] ?? [:]
        let order = [
            ("latest-release", "Latest Release"), ("top-songs", "Top Songs"), ("full-albums", "Albums"),
            ("singles", "Singles & EPs"), ("live-albums", "Live Albums"), ("compilation-albums", "Compilations"),
            ("appears-on-albums", "Appears On"), ("top-music-videos", "Music Videos"), ("similar-artists", "Similar Artists"),
        ]
        let shelves = order.compactMap { key, title -> Shelf? in
            let view = views[key] as? [String: Any]
            let items = MediaItem.list(view)
            let named = ((view?["attributes"] as? [String: Any])?["title"] as? String) ?? title
            return items.isEmpty ? nil : Shelf(title: named, items: items)
        }
        return ArtistPage(artist: resource.flatMap(MediaItem.init) ?? item, shelves: shelves)
    }

    // MARK: Library

    func recentlyAdded() async -> [MediaItem] {
        await pages("/v1/me/library/recently-added", limit: 100, pageSize: 25)
    }

    func libraryAlbums() async -> [MediaItem] { await pages("/v1/me/library/albums", limit: 2000) }
    func libraryArtists() async -> [MediaItem] { await pages("/v1/me/library/artists", limit: 2000) }
    func librarySongs() async -> [MediaItem] { await pages("/v1/me/library/songs", limit: 5000) }
    func libraryPlaylists() async -> [MediaItem] { await pages("/v1/me/library/playlists", limit: 500) }

    private func pages(_ path: String, limit: Int, pageSize: Int = 100) async -> [MediaItem] {
        var items: [MediaItem] = []
        var next: String? = path
        var parameters: [String: Any] = ["limit": pageSize]
        while let page = next, items.count < limit {
            guard let response = await engine.api(page, parameters) else { break }
            let found = MediaItem.list(response)
            items += found
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
