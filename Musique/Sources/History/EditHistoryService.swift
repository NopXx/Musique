import Foundation
import Combine

@MainActor
final class EditHistoryService: ObservableObject {
    static let shared = EditHistoryService()

    @Published private(set) var rules: [EditRule] = []

    private init() {
        Task { await reload() }
    }

    func reload() async {
        let loaded = await HistoryStore.shared.loadEditRules()
        self.rules = loaded
    }

    func add(artistMatch: String, trackMatch: String, albumMatch: String,
             artistTo: String, trackTo: String, albumTo: String) async {
        let trimmedArtist = artistMatch.trimmingCharacters(in: .whitespaces)
        guard !trimmedArtist.isEmpty else { return }
        let rule = EditRule(id: 0,
                            artistMatch: trimmedArtist,
                            trackMatch: trackMatch.trimmingCharacters(in: .whitespaces),
                            albumMatch: albumMatch.trimmingCharacters(in: .whitespaces),
                            artistTo: artistTo.trimmingCharacters(in: .whitespaces),
                            trackTo: trackTo.trimmingCharacters(in: .whitespaces),
                            albumTo: albumTo.trimmingCharacters(in: .whitespaces))
        // Replace, don't stack: rules are applied oldest-first, so an earlier
        // rule for the same track would shadow this one and every edit after the
        // first would look like it didn't save.
        await HistoryStore.shared.deleteEditRules(artistMatch: rule.artistMatch,
                                                  trackMatch: rule.trackMatch,
                                                  albumMatch: rule.albumMatch)
        // Nothing left to rewrite — the user put the player's own metadata back,
        // so the rule is gone rather than replaced by one that changes nothing.
        if !rule.isNoOp {
            _ = await HistoryStore.shared.addEditRule(rule)
        }
        await reload()
    }

    func delete(id: Int64) async {
        await HistoryStore.shared.deleteEditRule(id: id)
        await reload()
    }

    /// Apply the first matching rule to a snapshot. Match is case-insensitive
    /// on artistMatch (required); trackMatch / albumMatch only matched if non-empty.
    /// Replacement fields only override when non-empty.
    func apply(_ snap: NowPlayingSnapshot) -> NowPlayingSnapshot {
        guard !rules.isEmpty else { return snap }
        let snapArtist = snap.artist.lowercased()
        let snapTrack = snap.title.lowercased()
        let snapAlbum = snap.album.lowercased()
        for rule in rules {
            let aMatch = rule.artistMatch.lowercased()
            guard aMatch == snapArtist else { continue }
            if !rule.trackMatch.isEmpty, rule.trackMatch.lowercased() != snapTrack { continue }
            if !rule.albumMatch.isEmpty, rule.albumMatch.lowercased() != snapAlbum { continue }
            var out = snap
            if !rule.artistTo.isEmpty { out.artist = rule.artistTo }
            if !rule.trackTo.isEmpty  { out.title = rule.trackTo }
            if !rule.albumTo.isEmpty  { out.album = rule.albumTo }
            return out
        }
        return snap
    }
}
