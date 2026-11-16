import SwiftUI

/// Fetches the synced lines for the playing track while lyrics are on, one
/// lookup per track. Shared by every player view that shows lyrics.
private struct LyricsLookup: ViewModifier {
    let enabled: Bool
    let snapshot: NowPlayingSnapshot?
    @Binding var lines: [LyricLine]
    /// A lookup is running: views show a spinner, then the lines — or, when it
    /// comes back empty, `LyricsStatusView`'s "no lyrics found".
    @Binding var loading: Bool

    private var key: String {
        guard enabled, let snapshot else { return "" }
        return LyricsLookupIdentity.key(for: snapshot) ?? ""
    }

    func body(content: Content) -> some View {
        content
            // In the same update as the switch, not when the task gets round to
            // running — or "no lyrics" flashes for a frame before every lookup.
            .onChange(of: key, initial: true) { _, k in
                lines = []
                loading = !k.isEmpty
            }
            .task(id: key) {
                lines = []
                guard !key.isEmpty, let snap = snapshot else {
                    loading = false
                    return
                }
                loading = true
                let found = await LyricsService.shared.lines(artist: snap.artist, title: snap.title,
                                                             album: snap.album, duration: snap.duration,
                                                             source: snap.source)
                // A newer task (next track, lyrics off) owns the state now.
                guard !Task.isCancelled else { return }
                lines = found
                loading = false
            }
    }
}

/// What a lyrics area shows when it has no lines: a spinner while the lookup
/// runs, then that there are none — rather than silently closing again.
struct LyricsStatusView: View {
    let loading: Bool
    var fontSize: CGFloat = 13

    var body: some View {
        if loading {
            ProgressView()
                .controlSize(.small)
                .environment(\.colorScheme, .dark)
        } else {
            Text(L10n.tr("ไม่พบเนื้อเพลง", "No lyrics found"))
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

extension View {
    func lyricsLookup(enabled: Bool, snapshot: NowPlayingSnapshot?,
                      lines: Binding<[LyricLine]>, loading: Binding<Bool>) -> some View {
        modifier(LyricsLookup(enabled: enabled, snapshot: snapshot, lines: lines, loading: loading))
    }
}
