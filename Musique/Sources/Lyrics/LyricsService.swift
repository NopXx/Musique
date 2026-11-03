import Foundation
import Combine
import MusicKit
import MusanovaKit

struct TimedLyricSegment: Equatable, Encodable {
    let text: String
    let start: Double
    let end: Double

    func highlightOpacity(at position: Double) -> Double {
        if position >= end { return 1 }
        if position < start { return 0.28 }
        let duration = max(end - start, 0.01)
        let progress = min(max((position - start) / duration, 0), 1)
        return 0.35 + progress * 0.65
    }
}

struct LyricLine: Equatable, Encodable {
    let time: Double
    /// When the line stops being sung. Apple TTML and LRCLIB's `lyricsfile` carry
    /// it; plain LRC gives only a start, so a line there runs until the next one.
    var end: Double? = nil
    let text: String
    var segments: [TimedLyricSegment] = []
}

enum AppleMusicMetadataMatcher {
    /// Music.app sometimes reports only the primary artist while Apple's catalog
    /// returns every credited artist. Compare individual credits instead of the
    /// flattened display strings so `IVE` still matches `IVE & David Guetta`.
    static func artistsMatch(reported: String, catalog: String) -> Bool {
        let reportedCredits = credits(in: reported)
        let catalogCredits = credits(in: catalog)
        guard !reportedCredits.isEmpty, !catalogCredits.isEmpty else { return false }
        return !reportedCredits.isDisjoint(with: catalogCredits)
    }

    private static func credits(in value: String) -> Set<String> {
        let pattern = #"\s*(?:&|,|/|;|×|\bx\b|\bfeat(?:uring)?\.?\b|\bwith\b)\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: .caseInsensitive) else {
            return [normalized(value)]
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let separated = regex.stringByReplacingMatches(in: value, range: range,
                                                       withTemplate: "|")
        return Set(separated.split(separator: "|")
            .map { normalized(String($0)) }
            .filter { !$0.isEmpty })
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
}

enum AppleLyricsSourcePolicy {
    /// Both supported players expose enough catalog metadata to resolve the
    /// corresponding Apple Music song. The playback source must not prevent a
    /// Spotify track from using Apple TTML before the LRCLIB fallback.
    static func shouldAttemptTTML(for source: PlaybackSource) -> Bool {
        switch source {
        case .appleMusic, .spotify, .webScrobbler:
            return true
        }
    }
}

enum LyricsLookupIdentity {
    static func key(for snapshot: NowPlayingSnapshot) -> String? {
        guard snapshot.hasTrack,
              !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !snapshot.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return [snapshot.source.rawValue, snapshot.artist, snapshot.title, snapshot.album,
                String(Int(snapshot.duration.rounded()))]
            .joined(separator: "|")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

/// Application-lifetime trigger for lyrics storage. Fetching must not depend on
/// presenting a SwiftUI view: every newly selected track gets one lookup, which
/// also fills the local TTML cache.
@MainActor
final class LyricsPrefetcher {
    static let shared = LyricsPrefetcher()

    private var cancellables = Set<AnyCancellable>()
    private var activeKey = ""
    private var fetchTask: Task<Void, Never>?

    private init() {}

    func attach(monitor: PlayerMonitor) {
        guard cancellables.isEmpty else { return }
        monitor.$snapshot
            .combineLatest(EditHistoryService.shared.$rules)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawSnapshot, _ in
                self?.prefetch(rawSnapshot.map { EditHistoryService.shared.apply($0) })
            }
            .store(in: &cancellables)
    }

    private func prefetch(_ snapshot: NowPlayingSnapshot?) {
        guard let snapshot, let key = LyricsLookupIdentity.key(for: snapshot) else {
            activeKey = ""
            fetchTask?.cancel()
            fetchTask = nil
            return
        }
        guard key != activeKey else { return }
        activeKey = key
        fetchTask?.cancel()
        NSLog("[Lyrics] Prefetch started: source=%@ artist=%@ title=%@",
              snapshot.source.rawValue, snapshot.artist, snapshot.title)
        fetchTask = Task {
            let lines = await LyricsService.shared.lines(
                artist: snapshot.artist, title: snapshot.title, album: snapshot.album,
                duration: snapshot.duration, source: snapshot.source
            )
            guard !Task.isCancelled else { return }
            NSLog("[Lyrics] Prefetch finished: source=%@ lines=%ld",
                  snapshot.source.rawValue, lines.count)
        }
    }
}

enum TTMLCacheKey {
    static func make(artist: String, title: String, album: String, duration: Double) -> String {
        let identity = [artist, title, album, String(Int(duration.rounded()))]
            .joined(separator: "|")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let slug = "\(artist)-\(title)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character != "-" || result.last != "-" { result.append(character) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // FNV-1a is deliberately simple and stable across launches. Swift's
        // `hashValue` is randomized and would orphan every cached file on relaunch.
        let hash = identity.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return "\(String(slug.prefix(80)))-\(String(hash, radix: 16)).ttml"
    }
}

/// Raw TTML as Apple returned it, one file per track, so each song costs one
/// trip to the private endpoint per machine.
private actor TTMLDiskCache {
    static let shared = TTMLDiskCache()

    private let directory: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = support.appendingPathComponent("Musique/TTML", isDirectory: true)
    }

    func load(fileName: String) -> String? {
        let url = directory.appendingPathComponent(fileName)
        guard let ttml = try? String(contentsOf: url, encoding: .utf8), !ttml.isEmpty else { return nil }
        NSLog("[Lyrics] TTML local cache hit: %@", fileName)
        return ttml
    }

    func save(_ ttml: String, fileName: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(ttml.utf8).write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } catch {
            NSLog("[Lyrics] Unable to save local TTML cache: %@", error.localizedDescription)
        }
    }
}

/// Time-synced lyrics. Apple Music TTML is tried first through MusanovaKit's
/// private syllable-lyrics request for either supported player; LRCLIB remains
/// the fallback for denied Music access, missing matches, and private-API failures.
actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: [LyricLine]] = [:]

    func lines(artist: String, title: String, album: String, duration: Double,
               source: PlaybackSource = .appleMusic) async -> [LyricLine] {
        let key = "\(source.rawValue)|\(artist)|\(title)|\(album)|\(Int(duration))"
        if let hit = cache[key] {
            NSLog("[Lyrics] Parsed memory cache hit: source=%@ lines=%ld", source.rawValue, hit.count)
            return hit
        }
        NSLog("[Lyrics] Lookup started: source=%@ artist=%@ title=%@",
              source.rawValue, artist, title)
        let appleLines = AppleLyricsSourcePolicy.shouldAttemptTTML(for: source)
            ? await AppleMusicLyricsClient.shared.lines(artist: artist, title: title,
                                                        album: album, duration: duration)
            : []
        let lines = appleLines.isEmpty
            ? await fetch(artist: artist, title: title, album: album, duration: duration)
            : appleLines
        // Cached even when empty: a track with no synced lyrics would otherwise
        // hit the network again every time the fullscreen window opens.
        cache[key] = lines
        NSLog("[Lyrics] Lookup finished: source=%@ lines=%ld", source.rawValue, lines.count)
        return lines
    }

    private func fetch(artist: String, title: String,
                       album: String, duration: Double) async -> [LyricLine] {
        // The exact endpoint first: artist, track, album and duration all have to
        // agree, so a hit is certainly the right release.
        if let json = await json(path: "get", query: [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]) as? [String: Any] {
            return parse(json)
        }

        // …and search when it misses, which is most of the time: the album string a
        // player reports rarely matches LRCLIB's word for word ("The Star Chapter:
        // TOGETHER" against "The Star Chapter TOGETHER"), and /get 404s on any
        // difference including a duration more than a couple of seconds out.
        guard let results = await json(path: "search", query: [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]) as? [[String: Any]] else { return [] }

        // Closest duration among the entries that actually carry timings — the
        // candidates are different masters and edits of the same song, and length is
        // the only thing that tells them apart.
        let best = results
            .filter { $0["lyricsfile"] is String || $0["syncedLyrics"] is String }
            .min { a, b in
                let da = abs((a["duration"] as? Double ?? 0) - duration)
                let db = abs((b["duration"] as? Double ?? 0) - duration)
                return da < db
            }
        return best.map(parse) ?? []
    }

    private func json(path: String, query: [URLQueryItem]) async -> Any? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")
        components?.queryItems = query
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // LRCLIB asks clients to identify themselves rather than send the default
        // URLSession agent.
        request.setValue("Musique (macOS menu bar player)", forHTTPHeaderField: "User-Agent")

        // A miss is a 404, which is the common case for anything off the charts —
        // no logging, nothing to report, just no lyrics.
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// `lyricsfile` first: it carries an end time per line, which is what lets a
    /// finished line dim instead of hanging until the next one starts. Not every
    /// entry in the database has one, so LRC stays as the fallback.
    private func parse(_ json: [String: Any]) -> [LyricLine] {
        if let file = json["lyricsfile"] as? String {
            let lines = LyricsFile.parse(file)
            if !lines.isEmpty { return lines }
        }
        guard let synced = json["syncedLyrics"] as? String else { return [] }
        return LRC.parse(synced)
    }
}

/// Read-only client for Apple Music's undocumented `/syllable-lyrics` resource.
///
/// MusanovaKit deliberately accepts the developer token as an argument. Apple Music's
/// web player publishes an `AMPWebPlay` token in its versioned JavaScript bundle, so
/// this personal macOS companion resolves that short-lived token at runtime instead of
/// baking a credential into the app. `MusicDeveloperRequest` then uses MusicKit's
/// `MusicDataRequest`, which attaches the authorized subscriber's Music User Token.
private actor AppleMusicLyricsClient {
    static let shared = AppleMusicLyricsClient()

    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"
    private var token: String?
    private var tokenExpiry: Date?

    func lines(artist: String, title: String, album: String, duration: Double) async -> [LyricLine] {
        let cacheFile = TTMLCacheKey.make(artist: artist, title: title,
                                          album: album, duration: duration)
        if let cachedTTML = await TTMLDiskCache.shared.load(fileName: cacheFile) {
            let cachedLines = parsedLines(from: cachedTTML)
            if !cachedLines.isEmpty { return cachedLines }
        }

        let authorization: MusicAuthorization.Status
        switch MusicAuthorization.currentStatus {
        case .notDetermined:
            authorization = await MusicAuthorization.request()
        default:
            authorization = MusicAuthorization.currentStatus
        }
        guard authorization == .authorized else {
            NSLog("[Lyrics] MusicKit authorization status: %ld", authorization.rawValue)
            return []
        }
        guard let developerToken = await webPlaybackToken() else {
            NSLog("[Lyrics] Unable to resolve Apple Music web playback token")
            return []
        }
        var songID = await catalogSongID(token: developerToken, artist: artist,
                                         title: title, album: album, duration: duration)
        if songID == nil {
            songID = await iTunesSongID(artist: artist, title: title,
                                        album: album, duration: duration)
        }
        guard let songID else {
            NSLog("[Lyrics] No Apple Music catalog match for %@ — %@", artist, title)
            return []
        }

        do {
            let request = try MusicLyricsRequest(songID: MusicItemID(songID),
                                                 developerToken: developerToken)
            let response = try await request.response(countryCode: "th")
            guard let ttml = response.rawTTML else { return [] }
            let parsed = parsedLines(from: ttml)
            await TTMLDiskCache.shared.save(ttml, fileName: cacheFile)
            NSLog("[Lyrics] Apple Music TTML fetched: song=%@ lines=%ld bytes=%ld",
                  songID, parsed.count, ttml.utf8.count)
            return parsed
        } catch {
            NSLog("[Lyrics] Apple Music syllable lyrics failed: %@", error.localizedDescription)
            return []
        }
    }

    private func parsedLines(from ttml: String) -> [LyricLine] {
        LyricsParser().parse(ttml)
            .flatMap(\.lines)
            .compactMap { line in
                guard let first = line.segments.first else { return nil }
                let segments = line.segments.map {
                    TimedLyricSegment(text: $0.text,
                                      start: $0.startTime,
                                      end: $0.endTime)
                }
                return LyricLine(time: first.startTime,
                                 end: line.segments.last?.endTime,
                                 text: line.text,
                                 segments: segments)
            }
            .sorted { $0.time < $1.time }
    }

    private func webPlaybackToken() async -> String? {
        if let token, let tokenExpiry, tokenExpiry > Date().addingTimeInterval(60) {
            return token
        }

        guard let pageURL = URL(string: "https://music.apple.com/th/new"),
              let html = await text(at: pageURL),
              let scriptPath = firstMatch(#"/assets/index~[A-Za-z0-9]+\.js"#, in: html),
              let scriptURL = URL(string: scriptPath, relativeTo: pageURL),
              let script = await text(at: scriptURL.absoluteURL) else { return nil }

        let jwtPattern = #"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"#
        for candidate in matches(jwtPattern, in: script) {
            guard let claims = jwtClaims(candidate), claims.issuer == "AMPWebPlay",
                  claims.expiry > Date() else { continue }
            token = candidate
            tokenExpiry = claims.expiry
            return candidate
        }
        return nil
    }

    private func catalogSongID(token: String, artist: String, title: String,
                               album: String, duration: Double) async -> String? {
        // The AMPWebPlay token is issued for the web player's AMP host. Using the
        // public API hostname here can reject an otherwise valid privileged token.
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/th/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let songs = results["songs"] as? [String: Any],
              let candidates = songs["data"] as? [[String: Any]] else { return nil }

        let wantedTitle = normalized(title)
        let wantedAlbum = normalized(album)
        return candidates.compactMap { item -> (String, Int)? in
            guard let id = item["id"] as? String,
                  let attributes = item["attributes"] as? [String: Any],
                  attributes["hasLyrics"] as? Bool == true else { return nil }
            let candidateTitle = normalized(attributes["name"] as? String ?? "")
            let candidateAlbum = normalized(attributes["albumName"] as? String ?? "")
            guard candidateTitle == wantedTitle,
                  AppleMusicMetadataMatcher.artistsMatch(reported: artist,
                                                         catalog: attributes["artistName"] as? String ?? "")
            else { return nil }

            var score = candidateAlbum == wantedAlbum ? 1_000 : 0
            if let millis = attributes["durationInMillis"] as? Double {
                score -= Int(abs(millis / 1_000 - duration).rounded())
            }
            return (id, score)
        }
        .max { $0.1 < $1.1 }?.0
    }

    /// The storefront search endpoint occasionally declines AMPWebPlay tokens even
    /// though the privileged lyrics endpoint accepts them. The public iTunes
    /// Search API exposes the same numeric Adam IDs, so it is a safe lookup-only
    /// fallback; MusanovaKit still performs the authenticated lyrics request.
    private func iTunesSongID(artist: String, title: String, album: String,
                              duration: Double) async -> String? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "country", value: "th"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25"),
        ]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = root["results"] as? [[String: Any]] else { return nil }

        let wantedTitle = normalized(title)
        let wantedAlbum = normalized(album)
        return candidates.compactMap { item -> (String, Int)? in
            guard let id = item["trackId"] as? NSNumber,
                  normalized(item["trackName"] as? String ?? "") == wantedTitle,
                  AppleMusicMetadataMatcher.artistsMatch(
                    reported: artist,
                    catalog: item["artistName"] as? String ?? ""
                  ) else { return nil }
            var score = normalized(item["collectionName"] as? String ?? "") == wantedAlbum ? 1_000 : 0
            if let millis = item["trackTimeMillis"] as? Double {
                score -= Int(abs(millis / 1_000 - duration).rounded())
            }
            return (id.stringValue, score)
        }
        .max { $0.1 < $1.1 }?.0
    }

    private func text(at url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text).first
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private func jwtClaims(_ jwt: String) -> (issuer: String, expiry: Date)? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let issuer = json["iss"] as? String,
              let seconds = json["exp"] as? Double else { return nil }
        return (issuer, Date(timeIntervalSince1970: seconds))
    }
}

enum LRC {
    /// `[mm:ss.xx] text`, one entry per timestamp. A line can carry several
    /// timestamps when the same words repeat (a chorus), and metadata tags
    /// (`[ar:…]`, `[length:…]`) share the bracket syntax — those parse to no
    /// timestamp at all and drop out on their own.
    static func parse(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = raw.drop(while: { $0 == "\r" })
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                if let t = seconds(rest[rest.index(after: rest.startIndex)..<close]) {
                    stamps.append(t)
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            let line = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(contentsOf: stamps.map { LyricLine(time: $0, text: line) })
        }
        return out.sorted { $0.time < $1.time }
    }

    private static func seconds(_ body: Substring) -> Double? {
        let parts = body.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}

/// LRCLIB's `lyricsfile`: one YAML document holding metadata, a `lines:` list of
/// `text` / `start_ms` / `end_ms`, and a `plain:` block.
///
/// ponytail: only the `lines:` block is read, by hand, at the exact shape LRCLIB
/// emits — flat list, three known keys, one line each. Swift has no YAML parser
/// in the stdlib and a real one is a dependency for a schema this small. If the
/// field ever grows nested values or block scalars per line this gives up and the
/// caller falls back to LRC, which is the same outcome as an unparseable file.
enum LyricsFile {
    static func parse(_ yaml: String) -> [LyricLine] {
        var out: [LyricLine] = []
        var inLines = false
        var text: String?
        var start: Double?
        var end: Double?

        func flush() {
            if let text, let start { out.append(LyricLine(time: start, end: end, text: text)) }
            text = nil; start = nil; end = nil
        }

        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard inLines else {
                if trimmed == "lines:" { inLines = true }
                continue
            }
            // Any other top-level key (`plain:`) ends the list. Its own body is
            // indented, so only an unindented, undashed line can be one.
            if !line.hasPrefix(" ") && !line.hasPrefix("-") { break }
            if trimmed.hasPrefix("- ") { flush() }

            let body = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            guard let colon = body.firstIndex(of: ":") else { continue }
            // The first colon is always the key's: a bare YAML scalar can't contain
            // ": ", so anything that does comes back quoted.
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch body[body.startIndex..<colon] {
            case "text":     text = scalar(value)
            case "start_ms": start = Double(value).map { $0 / 1000 }
            case "end_ms":   end = Double(value).map { $0 / 1000 }
            default: break
            }
        }
        flush()
        return out
    }

    private static func scalar(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return value
    }
}
