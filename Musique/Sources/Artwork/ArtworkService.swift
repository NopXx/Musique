import Foundation

struct ArtworkResult {
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
}

actor ArtworkService {
    static let shared = ArtworkService()

    private let endpoint = URL(string: "https://apple-music-artwork.nopxx.site/api/search")!
    private var cache: [String: ArtworkResult] = [:]

    func lookup(title: String, artist: String, album: String) async -> ArtworkResult {
        let key = "\(title.lowercased())|\(artist.lowercased())|\(album.lowercased())"
        if let hit = cache[key] { return hit }

        let term = title.isEmpty ? artist : "\(title) \(artist)"
        guard !term.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ArtworkResult()
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "animation", value: "1"),
        ]
        guard let url = components.url else { return ArtworkResult() }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            let pick = pickBest(results: decoded.results, title: title, artist: artist, album: album)
            let result = ArtworkResult(
                artworkURL: pick?.artworkHi ?? pick?.artwork,
                artworkUltraURL: pick?.artworkUltra ?? pick?.artworkHi,
                animationURL: pick?.animation?.best,
                animationTallURL: pick?.animation?.bestTall,
                animationSquareUltraURL: pick?.animation?.square?["2160p"] ?? pick?.animation?.square?["1920p"] ?? pick?.animation?.best
            )
            cache[key] = result
            return result
        } catch {
            NSLog("[Artwork] api error: \(error.localizedDescription)")
            return ArtworkResult()
        }
    }

    /// Free-form search returning every candidate, for the artwork picker UI.
    func search(term: String) async -> [ArtworkChoice] {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "limit", value: "24"),
            URLQueryItem(name: "animation", value: "1"),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            return decoded.results.enumerated().compactMap { offset, item in
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
                                     hasAnimation: hasAnim)
            }
        } catch {
            NSLog("[Artwork] search error: \(error.localizedDescription)")
            return []
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
