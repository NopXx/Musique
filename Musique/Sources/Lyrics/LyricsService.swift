import Foundation

struct LyricLine: Equatable {
    let time: Double
    /// When the line stops being sung. Only LRCLIB's `lyricsfile` carries it — LRC
    /// gives a start and nothing else, so a line there runs until the next one.
    var end: Double? = nil
    let text: String
}

/// Time-synced lyrics from LRCLIB (lrclib.net) — free, no key, no account, and
/// the one public source that hands back LRC. Apple Music's own `lyrics`
/// property is plain text and only filled in for library tracks, so it can't
/// drive a synced view; Spotify's bridge exposes nothing at all.
actor LyricsService {
    static let shared = LyricsService()

    private var cache: [String: [LyricLine]] = [:]

    func lines(artist: String, title: String, album: String, duration: Double) async -> [LyricLine] {
        let key = "\(artist)|\(title)|\(album)|\(Int(duration))"
        if let hit = cache[key] { return hit }
        let lines = await fetch(artist: artist, title: title, album: album, duration: duration)
        // Cached even when empty: a track with no synced lyrics would otherwise
        // hit the network again every time the fullscreen window opens.
        cache[key] = lines
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
