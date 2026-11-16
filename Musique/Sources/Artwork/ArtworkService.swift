import Foundation

struct ArtworkResult: Encodable {
    var artworkURL: String?
    var artworkUltraURL: String?
    var animationURL: String?
    var animationTallURL: String?
    var animationSquareUltraURL: String?
}

/// One artwork candidate from a search, for the picker UI.
struct ArtworkChoice: Identifiable, Sendable {
    let id: String
    let track: String?
    let artist: String?
    let album: String?
    let thumbURL: String
    let fullURL: String
    let hasAnimation: Bool
    let animationURL: String?
    let animationTallURL: String?
}

actor ArtworkService {
    static let shared = ArtworkService()

    private let endpoint = URL(string: "https://apple-music-artwork.nopxx.site/api/search")!
    private var cache: [String: ArtworkResult] = [:]
    private var inflight: [String: Task<ArtworkResult, Never>] = [:]

    /// Every track change fans out to several view models — lock screen, mini player,
    /// menu bar, widget — and they all ask for the same artwork at the same moment.
    /// One shared request per key, held in an unstructured `Task` so it belongs to the
    /// service and not to whichever caller happened to start it: racing callers used to
    /// cancel each other's URLSession task (`[Artwork] api error: cancelled`), and the
    /// loser then committed an empty result over a perfectly good cover.
    func lookup(title: String, artist: String, album: String) async -> ArtworkResult {
        let key = "\(title.lowercased())|\(artist.lowercased())|\(album.lowercased())"
        if let hit = cache[key] { return hit }
        if let running = inflight[key] { return await running.value }

        let task = Task { await self.fetch(key: key, title: title, artist: artist, album: album) }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    private func fetch(key: String, title: String, artist: String, album: String) async -> ArtworkResult {
        let text = title.isEmpty ? artist : "\(title) \(artist)"
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ArtworkResult()
        }

        // The track's own Apple Music URL when one can be found: the API answers
        // a URL with exactly that release, where a text search hands back ten
        // look-alikes and a guess. Text search stays the fallback.
        var results: [SearchItem]?
        if let musicURL = await appleMusicURL(title: title, artist: artist, album: album) {
            results = await query(term: musicURL, limit: 1)
            NSLog("[Artwork] by URL %@ → %ld", musicURL, results?.count ?? -1)
        }
        if results?.isEmpty ?? true {
            results = await query(term: text, limit: 10)
        }
        guard let results else { return ArtworkResult() }

        let pick = pickBest(results: results, title: title, artist: artist, album: album)
        let result = ArtworkResult(
            artworkURL: pick?.artworkHi ?? pick?.artwork,
            artworkUltraURL: pick?.artworkUltra ?? pick?.artworkHi,
            animationURL: pick?.animation?.best,
            animationTallURL: pick?.animation?.bestTall,
            animationSquareUltraURL: pick?.animation?.square?["2160p"] ?? pick?.animation?.square?["1920p"] ?? pick?.animation?.best
        )
        cache[key] = result
        return result
    }

    /// One call to the artwork API. Nil on a network or decode failure, so the
    /// caller can tell "nothing found" from "couldn't ask".
    private func query(term: String, limit: Int) async -> [SearchItem]? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "animation", value: "1"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return try JSONDecoder().decode(SearchResponse.self, from: data).results
        } catch {
            NSLog("[Artwork] api error: \(error.localizedDescription)")
            return nil
        }
    }

    /// The track's `music.apple.com` album URL (with `?i=` for the track), from
    /// the public iTunes Search API — no token, and the same storefront the
    /// lyrics lookup uses. Only a result whose title and artist really match;
    /// a near miss would pin the wrong release, worse than a text search.
    private func appleMusicURL(title: String, artist: String, album: String) async -> String? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
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

        func norm(_ v: String) -> String {
            v.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        }
        let wantedTitle = norm(title), wantedAlbum = norm(album)
        let matches = candidates.filter {
            norm($0["trackName"] as? String ?? "") == wantedTitle
                && AppleMusicMetadataMatcher.artistsMatch(reported: artist,
                                                          catalog: $0["artistName"] as? String ?? "")
        }
        // Same album first, when the player told us one.
        let best = matches.first { norm($0["collectionName"] as? String ?? "") == wantedAlbum }
            ?? matches.first
        return (best?["collectionViewUrl"] ?? best?["trackViewUrl"]) as? String
    }

    /// Free-form search returning every candidate, for the artwork picker UI.
    func search(term: String) async -> [ArtworkChoice] {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        guard let results = await query(term: trimmed, limit: 24) else { return [] }
        return results.enumerated().compactMap { offset, item in
            let thumb = item.artworkHi ?? item.artwork
            let full = item.artworkUltra ?? item.artworkHi ?? item.artwork
            guard let full, let thumb else { return nil }
            let hasAnim = (item.animation?.best?.isEmpty == false)
                || (item.animation?.bestTall?.isEmpty == false)
                || (item.animation?.square?.isEmpty == false)
            // Two results can share the same artwork URL (different versions
            // of one album), so prefix with the index to keep ForEach ids
            // unique — duplicate ids leave blank cells in the grid.
            return ArtworkChoice(id: "\(offset)|\(full)", track: item.track, artist: item.artist,
                                 album: item.album, thumbURL: thumb, fullURL: full,
                                 hasAnimation: hasAnim,
                                 animationURL: item.animation?.best,
                                 animationTallURL: item.animation?.bestTall)
        }
    }

    private func pickBest(results: [SearchItem], title: String, artist: String, album: String) -> SearchItem? {
        guard !results.isEmpty else { return nil }
        let t = title.lowercased()
        let a = artist.lowercased()
        let al = album.lowercased()
        if !al.isEmpty {
            if let m = results.first(where: { ($0.track ?? "").lowercased() == t
                && ($0.artist ?? "").lowercased() == a
                && ($0.album ?? "").lowercased().contains(al) }) {
                return m
            }
        }
        if let m = results.first(where: { ($0.track ?? "").lowercased() == t
            && ($0.artist ?? "").lowercased() == a }) {
            return m
        }
        return results.first
    }
}

private struct SearchResponse: Decodable {
    var results: [SearchItem]
}

private struct SearchItem: Decodable {
    var track: String?
    var artist: String?
    var album: String?
    var artwork: String?
    var artworkHi: String?
    var artworkUltra: String?
    var animation: AnimationObject?
}

private struct AnimationObject: Decodable {
    var best: String?
    var bestTall: String?
    var square: [String: String]?
}
