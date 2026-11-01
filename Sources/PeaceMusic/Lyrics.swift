import Foundation

struct LyricWord: Equatable {
    let text: String
    let time: Double
    let duration: Double
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
    /// Real per-word timing. Nil when the source only times whole lines.
    var words: [LyricWord]? = nil

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

enum LyricsSource: String, Codable {
    case netEaseWords = "NetEase word timing"
    case netEaseLines = "NetEase line timing"
    case lrclib = "LRCLIB line timing"
    case plain = "unsynced"
}

private let interludeGap = 7.0

/// Credit lines such as "Written by: X" that some sources store as timed lyrics.
private func isCredit(_ text: String) -> Bool {
    text.contains(#/^.{0,24}(作词|作曲|编曲|制作|词|曲|lyrics by|written by|composed by|producer|produced by)\s*[:：]/#.ignoresCase())
}

enum LRCParser {
    static func parse(_ lrc: String, duration: Double) -> [LyricLine] {
        let pattern = #/\[(\d+):(\d+(?:\.\d+)?)\]/#
        var timed: [(Double, String)] = []
        for raw in lrc.split(separator: "\n") {
            let matches = raw.matches(of: pattern)
            guard let last = matches.last else { continue }
            let text = raw[last.range.upperBound...].trimmingCharacters(in: .whitespaces)
            if isCredit(text) { continue }
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

/// Parses NetEase YRC lines: `[lineStartMs,lineMs](wordStartMs,wordMs,0)word (…)word`.
enum YRCParser {
    static func parse(_ yrc: String) -> [LyricLine] {
        let header = #/^\[(\d+),(\d+)\]/#
        let token = #/\((\d+),(\d+),\d+\)([^(]*(?:\((?!\d+,\d+,\d+\))[^(]*)*)/#

        var lines: [LyricLine] = []
        var previousEnd = 0.0
        for raw in yrc.split(separator: "\n") {
            guard let match = raw.firstMatch(of: header) else { continue }
            let start = Double(match.1)! / 1000
            let end = start + Double(match.2)! / 1000

            var words: [LyricWord] = []
            var continuesWord = false
            for part in raw.matches(of: token) {
                let text = String(part.3)
                let cleaned = text.trimmingCharacters(in: .whitespaces)
                let time = Double(part.1)! / 1000
                let wordDuration = Double(part.2)! / 1000
                if !cleaned.isEmpty {
                    // Tokens with no space between them, like "know" + ",", are one visible word.
                    if continuesWord, let last = words.last {
                        words[words.count - 1] = LyricWord(
                            text: last.text + cleaned,
                            time: last.time,
                            duration: time + wordDuration - last.time
                        )
                    } else {
                        words.append(LyricWord(text: cleaned, time: time, duration: wordDuration))
                    }
                }
                continuesWord = !(text.last?.isWhitespace ?? true)
            }
            let text = words.map(\.text).joined(separator: " ")
            guard !text.isEmpty, !isCredit(text) else { continue }

            if start - previousEnd >= interludeGap {
                lines.append(LyricLine(id: lines.count, time: previousEnd, text: ""))
            }
            lines.append(LyricLine(id: lines.count, time: start, text: text, words: words))
            previousEnd = end
        }
        return lines
    }
}

/// Finds the best lyrics across sources and caches the winner on disk per track.
final class LyricsClient: @unchecked Sendable {
    private struct LRCLIBItem: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private struct NetEaseSearch: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            struct Artist: Decodable { let name: String? }
            let id: Int
            let name: String
            let duration: Double?
            let artists: [Artist]?
        }
        let result: Result?
    }

    private struct NetEaseLyric: Decodable {
        struct Body: Decodable { let lyric: String? }
        let lrc: Body?
        let yrc: Body?
    }

    /// The chosen lyrics in source form.
    struct Resolved: Codable {
        var source: LyricsSource?
        var instrumental = false
        var lrc: String?
        var yrc: String?
        var plain: String?
    }

    private static let durationTolerance = 2.5
    /// How much of a song's length a version may leave uncovered compared to the fullest one.
    private static let maxMissingShare = 0.12
    /// Word timing further than this from LRCLIB's timeline is probably a different master.
    private static let maxWordTimingOffset = 1.0
    private static let userAgent = "Mozilla/5.0 PeaceMusic/1.0"

    /// NetEase answers searches with unrelated songs once its cookie is sent back.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent("PeaceMusic", isDirectory: true)
        // Older caches may hold picks made without the completeness check.
        for old in ["lyrics", "lyrics-v2"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(old))
        }
        let url = root.appendingPathComponent("lyrics-v3", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func lyrics(for track: Track) async -> (Lyrics, LyricsSource?) {
        let safeID = track.id.filter { $0.isLetter || $0.isNumber }
        let cacheFile = cacheDirectory.appendingPathComponent("\(safeID).json")
        if !safeID.isEmpty,
           let data = try? Data(contentsOf: cacheFile),
           let cached = try? JSONDecoder().decode(Resolved.self, from: data) {
            return Self.convert(cached, track: track)
        }

        let (resolved, isComplete) = await resolve(track)
        // A source that failed may have had something better, so the result isn't final.
        if isComplete, !safeID.isEmpty, let data = try? JSONEncoder().encode(resolved) {
            try? data.write(to: cacheFile)
        }
        return Self.convert(resolved, track: track)
    }

    private static func convert(_ resolved: Resolved, track: Track) -> (Lyrics, LyricsSource?) {
        if resolved.instrumental { return (.instrumental, nil) }
        if let yrc = resolved.yrc {
            let lines = YRCParser.parse(yrc)
            if !lines.isEmpty { return (.synced(lines), resolved.source) }
        }
        if let lrc = resolved.lrc {
            let lines = LRCParser.parse(lrc, duration: track.duration)
            if !lines.isEmpty { return (.synced(lines), resolved.source) }
        }
        if let plain = resolved.plain, !plain.isEmpty { return (.plain(plain), .plain) }
        return (.none, nil)
    }

    private func resolve(_ track: Track) async -> (Resolved, Bool) {
        async let lrclibResult = lrclibCandidates(track)
        async let netEaseResult = netEaseLyrics(track)
        let lrclib = await lrclibResult
        let netEase = await netEaseResult
        let allSourcesAnswered = lrclib != nil && netEase != nil

        let candidates = lrclib ?? []
        let close = candidates.filter { abs(($0.duration ?? 0) - track.duration) <= Self.durationTolerance }
        let synced = close.compactMap(\.syncedLyrics).filter { !$0.isEmpty }
        let parsed = synced.map { LRCParser.parse($0, duration: track.duration) }
        let wordLines = netEase?.yrc.map(YRCParser.parse) ?? []
        let netEaseLines = netEase?.lrc.map { LRCParser.parse($0, duration: track.duration) } ?? []

        // A length match can't be trusted alone: databases hold lyrics from a shorter edit
        // filed under the full song. Anything well short of the fullest version is out.
        let bestCoverage = (parsed + [wordLines, netEaseLines]).map(Self.coverage).max() ?? 0
        func isComplete(_ lines: [LyricLine]) -> Bool {
            !lines.isEmpty && Self.coverage(lines) >= bestCoverage - track.duration * Self.maxMissingShare
        }

        let completeVersions = zip(synced, parsed).filter { isComplete($0.1) }.map(\.0)
        let reference = Self.consensus(completeVersions, duration: track.duration)
        let referenceLines = reference.map { LRCParser.parse($0, duration: track.duration) }
        let offset = (referenceLines ?? parsed.first).flatMap { Self.medianOffset(wordLines, $0) }

        if isComplete(wordLines), abs(offset ?? 0) <= Self.maxWordTimingOffset, let yrc = netEase?.yrc {
            return (Resolved(source: .netEaseWords, yrc: yrc), allSourcesAnswered)
        }
        if let reference {
            return (Resolved(source: .lrclib, lrc: reference), allSourcesAnswered)
        }
        if isComplete(netEaseLines), let lrc = netEase?.lrc {
            return (Resolved(source: .netEaseLines, lrc: lrc), allSourcesAnswered)
        }
        if close.contains(where: { $0.instrumental == true }) {
            return (Resolved(instrumental: true), allSourcesAnswered)
        }
        let plain = (close + candidates).compactMap(\.plainLyrics).first { !$0.isEmpty }
        return (Resolved(source: .plain, plain: plain), allSourcesAnswered)
    }

    // MARK: Scoring

    /// Seconds of the song a version accounts for. Each line only counts for a few seconds,
    /// so both an early ending and a missing verse in the middle lower the total.
    private static func coverage(_ lines: [LyricLine]) -> Double {
        var total = 0.0
        for (line, next) in zip(lines, lines.dropFirst()) where !line.isInterlude {
            total += min(next.time - line.time, 8)
        }
        return total
    }

    /// Picks the version whose timeline agrees most with the others, which screens out
    /// the occasional submission that is shifted or timed by hand against a different cut.
    private static func consensus(_ versions: [String], duration: Double) -> String? {
        guard versions.count > 2 else { return versions.first }
        let parsed = versions.prefix(12).map { LRCParser.parse($0, duration: duration) }
        var best: (index: Int, disagreement: Double)?
        for (index, lines) in parsed.enumerated() {
            let offsets = parsed.enumerated()
                .filter { $0.offset != index }
                .compactMap { medianOffset(lines, $0.element).map(abs) }
            guard let disagreement = median(offsets) else { continue }
            if best == nil || disagreement < best!.disagreement {
                best = (index, disagreement)
            }
        }
        return best.map { versions[$0.index] } ?? versions.first
    }

    /// Typical time difference across lines that appear in both, if enough of them match.
    static func medianOffset(_ first: [LyricLine], _ second: [LyricLine]) -> Double? {
        var times: [String: Double] = [:]
        for line in second where !line.isInterlude {
            let key = normalized(line.text)
            if times[key] == nil { times[key] = line.time }
        }
        var seen = Set<String>()
        var offsets: [Double] = []
        for line in first where !line.isInterlude {
            let key = normalized(line.text)
            if seen.insert(key).inserted, let other = times[key] {
                offsets.append(line.time - other)
            }
        }
        return offsets.count >= 5 ? median(offsets) : nil
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Compares titles with any bracketed suffix removed, rejecting other recordings of the song.
    private static func isSameSong(candidate: String, track: Track) -> Bool {
        let variants = ["remix", "mix", "edit", "club", "dub", "live", "cover", "instrumental", "karaoke", "acoustic", "伴奏"]
        let lowerCandidate = candidate.lowercased()
        let lowerTitle = track.title.lowercased()
        for variant in variants where lowerCandidate.contains(variant) && !lowerTitle.contains(variant) {
            return false
        }
        func stripped(_ title: String) -> String {
            var result = title
            result.replace(#/\s*[\(\[（【].*?[\)\]）】]/#, with: "")
            return normalized(cleanTitle(result))
        }
        return stripped(candidate) == stripped(track.title)
    }

    private static func isSameArtist(candidates: [String], track: Track) -> Bool {
        let artist = normalized(track.artist)
        return candidates.map(normalized).contains { name in
            !name.isEmpty && (artist.contains(name) || name.contains(artist))
        }
    }

    /// "Official髭男dism" and "OFFICIAL HIGE DANDISM" share no spelling, so a non-Latin artist
    /// name is accepted on an identical title and a near-identical length instead.
    private static func isSameSongInAnotherScript(
        _ title: String, artists: [String], difference: Double, track: Track
    ) -> Bool {
        let hasNonLatinName = artists.contains { name in
            name.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x24F }
        }
        return hasNonLatinName && difference <= 1 && normalized(title) == normalized(cleanTitle(track.title))
    }

    // MARK: Sources

    /// Nil means the request failed, as opposed to finding nothing.
    private func lrclibCandidates(_ track: Track) async -> [LRCLIBItem]? {
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            .init(name: "track_name", value: Self.cleanTitle(track.title)),
            .init(name: "artist_name", value: track.artist),
        ]
        return await fetch(search.url!)
    }

    /// Nil means the request failed. Empty means no matching song.
    private func netEaseLyrics(_ track: Track) async -> (lrc: String?, yrc: String?)? {
        var search = URLComponents(string: "https://music.163.com/api/search/get")!
        search.queryItems = [
            .init(name: "s", value: "\(Self.cleanTitle(track.title)) \(track.artist)"),
            .init(name: "type", value: "1"),
            .init(name: "limit", value: "8"),
        ]
        guard let response: NetEaseSearch = await fetch(search.url!) else { return nil }

        let matches = (response.result?.songs ?? [])
            .filter { song in
                let difference = abs((song.duration ?? 0) / 1000 - track.duration)
                let artists = (song.artists ?? []).compactMap(\.name)
                guard difference <= Self.durationTolerance, Self.isSameSong(candidate: song.name, track: track) else {
                    return false
                }
                return Self.isSameArtist(candidates: artists, track: track)
                    || Self.isSameSongInAnotherScript(song.name, artists: artists, difference: difference, track: track)
            }
            .sorted { abs(($0.duration ?? 0) / 1000 - track.duration) < abs(($1.duration ?? 0) / 1000 - track.duration) }

        var lineLyrics: String?
        for song in matches.prefix(3) {
            var request = URLComponents(string: "https://music.163.com/api/song/lyric/v1")!
            request.queryItems = ["cp=false", "tv=0", "lv=0", "rv=0", "kv=0", "yv=0", "ytv=0", "yrv=0"].map {
                let pair = $0.split(separator: "=")
                return URLQueryItem(name: String(pair[0]), value: String(pair[1]))
            } + [URLQueryItem(name: "id", value: String(song.id))]
            guard let lyric: NetEaseLyric = await fetch(request.url!) else { continue }
            if let yrc = lyric.yrc?.lyric, !yrc.isEmpty {
                return (lyric.lrc?.lyric, yrc)
            }
            lineLyrics = lineLyrics ?? lyric.lrc?.lyric
        }
        return (lineLyrics, nil)
    }

    private func fetch<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for attempt in 0...1 {
            guard let (data, response) = try? await session.data(for: request),
                  let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
            if status == 200 { return try? JSONDecoder().decode(T.self, from: data) }
            guard attempt == 0, status == 429 || status >= 500 else { return nil }
            try? await Task.sleep(for: .seconds(1.5))
        }
        return nil
    }

    /// "Song (feat. X) - Remastered 2011" becomes "Song".
    static func cleanTitle(_ title: String) -> String {
        var cleaned = title
        cleaned.replace(#/\s*[\(\[](feat|ft|with)\.?\s[^\)\]]*[\)\]]/#.ignoresCase(), with: "")
        cleaned.replace(#/\s+-\s+.*(remaster|version|edit|mix|live).*$/#.ignoresCase(), with: "")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
