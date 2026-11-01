import Foundation

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String

    /// Instrumental break, drawn as breathing dots.
    var isInterlude: Bool { text.isEmpty }
}

enum Lyrics: Equatable {
    case none
    case loading
    case instrumental
    case plain(String)
    case synced([LyricLine])
}

enum LRCParser {
    private static let interludeGap = 7.0

    static func parse(_ lrc: String, duration: Double) -> [LyricLine] {
        let pattern = /\[(\d+):(\d+(?:\.\d+)?)\]/
        var timed: [(Double, String)] = []
        for raw in lrc.split(separator: "\n") {
            let matches = raw.matches(of: pattern)
            guard let last = matches.last else { continue }
            let text = raw[last.range.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                timed.append((Double(match.1)! * 60 + Double(match.2)!, text))
            }
        }
        timed.sort { $0.0 < $1.0 }

        var lines: [LyricLine] = []
        func add(_ time: Double, _ text: String) {
            lines.append(LyricLine(id: lines.count, time: time, text: text))
        }
        if let first = timed.first(where: { !$0.1.isEmpty }), first.0 >= interludeGap {
            add(0, "")
        }
        for (index, entry) in timed.enumerated() {
            if entry.1.isEmpty {
                // A blank marker only earns dots when the silence is long enough to notice.
                let nextTime = index + 1 < timed.count ? timed[index + 1].0 : duration
                if nextTime - entry.0 >= interludeGap, !lines.isEmpty, !(lines.last?.isInterlude ?? false) {
                    add(entry.0, "")
                }
            } else {
                add(entry.0, entry.1)
            }
        }
        return lines
    }
}

/// Fetches lyrics from LRCLIB, caching responses on disk per track.
final class LyricsClient: @unchecked Sendable {
    private struct Response: Codable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("PeaceMusic/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func lyrics(for track: Track) async -> Lyrics {
        let safeID = track.id.filter { $0.isLetter || $0.isNumber }
        let cacheFile = cacheDirectory.appendingPathComponent("\(safeID).json")
        if !safeID.isEmpty,
           let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode(Response.self, from: data) {
            return convert(cached, track: track)
        }

        guard let response = await lookup(track) else { return .none }
        if !safeID.isEmpty, let data = try? JSONEncoder().encode(response) {
            try? data.write(to: cacheFile)
        }
        return convert(response, track: track)
    }

    private func convert(_ response: Response, track: Track) -> Lyrics {
        if response.instrumental == true { return .instrumental }
        if let synced = response.syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced, duration: track.duration)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = response.plainLyrics, !plain.isEmpty { return .plain(plain) }
        return .none
    }

    private func lookup(_ track: Track) async -> Response? {
        let title = Self.cleanTitle(track.title)
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: track.artist),
            .init(name: "album_name", value: track.album),
            .init(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        if let response: Response = await fetch(exact.url!), response.syncedLyrics != nil || response.instrumental == true {
            return response
        }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: track.artist),
        ]
        guard let results: [Response] = await fetch(search.url!) else { return nil }
        let close = results.filter { abs(($0.duration ?? 0) - track.duration) < 5 }
        return close.first { $0.syncedLyrics != nil } ?? close.first ?? results.first { $0.plainLyrics != nil }
    }

    private func fetch<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("PeaceMusic/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// "Song (feat. X) - Remastered 2011" becomes "Song".
    static func cleanTitle(_ title: String) -> String {
        var cleaned = title
        cleaned.replace(/\s*[\(\[](feat|ft|with)\.?\s[^\)\]]*[\)\]]/.ignoresCase(), with: "")
        cleaned.replace(/\s+-\s+.*(remaster|version|edit|mix|live).*$/.ignoresCase(), with: "")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
