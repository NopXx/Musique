import SwiftUI
import AppKit

struct AnimationFullscreenView: View {
    @ObservedObject var viewModel: MiniPlayerViewModel
    /// The mini player's overlay is a glance you dismiss with a click anywhere.
    /// The desktop window owns a Space, so a stray click on a full screen of
    /// cover art must not end it — there the corner button and Esc are the way out.
    var dismissOnTap: Bool = false
    let onDismiss: () -> Void

    @State private var lyrics: [LyricLine] = []
    /// Holds the split layout up across a track change. Without it the fetch's own
    /// `lyrics = []` collapsed the screen back to the cover and the next line of
    /// JSON threw it open again — a full layout flip on every song.
    @State private var lyricsPending = false
    @State private var showLyrics = SettingsStore.shared.bool(["lockscreen", "lyrics"])

    private var animationURL: URL? {
        let s = viewModel.artwork.animationSquareUltraURL ?? viewModel.artwork.animationURL
        guard let s, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    private var artworkURL: URL? {
        guard let s = viewModel.artwork.artworkURL, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    // The clock and card share the lock screen's settings so there's one place to
    // configure them, read live rather than mirrored onto the view model — this
    // window is short-lived and rebuilt on every present.
    private var settings: SettingsStore { .shared }
    private var clockEnabled: Bool { settings.bool(["lockscreen", "clock"]) }
    private var clockFormat: String {
        let f = settings.string(["lockscreen", "clock_format"]); return f.isEmpty ? "system" : f
    }
    private var clockDateStyle: String {
        let s = settings.string(["lockscreen", "clock_date_style"]); return s.isEmpty ? "full" : s
    }
    private var showAlbum: Bool { settings.bool(["lockscreen", "show_album"]) }
    private var showProgress: Bool { settings.bool(["lockscreen", "show_progress"]) }
    private var padding: CGFloat { CGFloat(settings.int(["lockscreen", "padding"])) }
    private var clockSize: CGFloat {
        let pt = settings.int(["lockscreen", "clock_size"])
        return CGFloat(pt > 0 ? pt : 96)
    }

    private var trackKey: String {
        guard let snap = viewModel.snapshot else { return "" }
        return "\(snap.artist)|\(snap.title)|\(snap.album)"
    }

    /// Lyrics get a layout of their own rather than a panel over the cover: a
    /// column of text needs a column of screen, and floated over fullscreen
    /// artwork it fought the cover for the middle of the display. Artwork left,
    /// words right, the way every desktop player splits it.
    private var splitLayout: Bool { showLyrics && (!lyrics.isEmpty || lyricsPending) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if splitLayout {
                    lyricsLayout(geo)
                } else {
                    coverLayout(geo)
                }

                // Now-playing card at the bottom — reuses the lock screen card, so
                // the title/artist, progress and transport all come along. Outside
                // the layout switch on purpose: it holds the same place in both, so
                // turning lyrics on doesn't send the transport somewhere new. The
                // big artwork is already on screen, so its inline thumbnail is off.
                if let snap = viewModel.snapshot, snap.hasTrack {
                    NowPlayingCard(
                        snap: snap,
                        showAlbum: showAlbum,
                        showProgress: showProgress,
                        width: min(380, geo.size.width * 0.36),
                        artworkImage: nil,
                        animatedURL: nil,
                        animatedArtwork: false,
                        showInlineArtwork: false,
                        onArtworkTap: {}
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    // Lifted off the bottom edge — the lock screen's own padding
                    // sits the card lower than reads well on a full desktop.
                    .padding(.bottom, padding + 56)
                }

                // Window chrome, not track chrome: leaving fullscreen belongs to
                // the window, so it sits in its corner rather than inside the
                // now-playing card.
                VStack(alignment: .leading, spacing: 12) {
                    GlassPill {
                        FullscreenGlyph(systemName: "xmark", size: 15, action: onDismiss)
                    }
                    // Only offered when there is something to show — a dead toggle
                    // on every instrumental would read as the feature being broken.
                    if !lyrics.isEmpty {
                        GlassPill {
                            FullscreenGlyph(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble",
                                            size: 15) {
                                showLyrics.toggle()
                                SettingsStore.shared.merge(["lockscreen": ["lyrics": showLyrics]])
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if dismissOnTap {
                    Text("กดเพื่อปิด")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: splitLayout)
        }
        .contentShape(Rectangle())
        .onTapGesture { if dismissOnTap { onDismiss() } }
        // Space toggles playback, the way every fullscreen player on the platform
        // behaves. Needs focus to receive the key, and the ring would draw over the
        // artwork — both windows are borderless-looking, so there is nothing for a
        // ring to sit on anyway.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            MusicAppController.playPause()
            return .handled
        }
        // Esc goes through onKeyPress too, not onExitCommand: in a native-fullscreen
        // window AppKit takes cancelOperation: for its own "leave fullscreen", so the
        // SwiftUI hook never sees the key.
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onChange(of: viewModel.snapshot?.hasTrack ?? false) { _, hasTrack in
            if !hasTrack { onDismiss() }
        }
        // Keyed on the track, so a fetch is one per song and the previous song's
        // lines are dropped the moment the next one starts.
        .task(id: trackKey) {
            lyrics = []
            guard let snap = viewModel.snapshot, snap.hasTrack else { return }
            lyricsPending = true
            lyrics = await LyricsService.shared.lines(artist: snap.artist, title: snap.title,
                                                     album: snap.album, duration: snap.duration)
            lyricsPending = false
        }
    }

    /// The cover owning the whole screen — clock at the top, transport at the
    /// bottom, the same block the lock screen draws.
    @ViewBuilder
    private func coverLayout(_ geo: GeometryProxy) -> some View {
        // Same component the lock screen overlay draws, so the fullscreen
        // cover looks identical locked and unlocked.
        FullscreenArtworkView(artworkURL: artworkURL,
                              clipURL: animationURL,
                              palette: viewModel.palette,
                              backgroundBlur: settings.int(["lockscreen", "background_blur"]))

        // Clock + date pinned to the top, over the artwork — the same block
        // the lock screen draws. Gated on the same lockscreen.clock setting.
        if clockEnabled {
            LockScreenClockView(timeFormat: clockFormat, dateStyle: clockDateStyle,
                                size: clockSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, padding + 40)
                .allowsHitTesting(false)
        }

    }

    /// Artwork left, lyrics right. No clock here: the words want the top of the
    /// column they are in, and a clock across the middle of the split had nowhere
    /// to sit that wasn't over one half or the other.
    @ViewBuilder
    private func lyricsLayout(_ geo: GeometryProxy) -> some View {
        // A palette gradient rather than the blurred cover: the cover is on screen
        // beside it at card size, and a giant blurred copy of the same image behind
        // the lyrics made the text a second thing to read through.
        LinearGradient(colors: [Color(viewModel.palette.gradientStart),
                                Color(viewModel.palette.gradientMid),
                                Color(viewModel.palette.gradientEnd)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()

        HStack(spacing: 0) {
            artworkCard(side: min(geo.size.width * 0.30, geo.size.height * 0.52))
                .frame(width: geo.size.width * 0.45)

            if let snap = viewModel.snapshot {
                FullscreenLyricsView(lines: lyrics, position: snap.position)
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 56)
                    .allowsHitTesting(false)
            }
        }
        // Both columns sit above the transport card, which keeps the place it has
        // in the other layout rather than moving into the artwork's column.
        .padding(.bottom, padding + 150)
    }

    @ViewBuilder
    private func artworkCard(side: CGFloat) -> some View {
        Group {
            if let animationURL {
                AnimatedArtworkView(url: animationURL, contentMode: .fill, cornerRadius: 16)
            } else if let artworkURL {
                AsyncImage(url: artworkURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(viewModel.palette.gradientMid)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.45), radius: 30, x: 0, y: 14)
    }

}

/// The card's glass, reused for the corner control so the window chrome matches
/// the thing it frames.
private struct GlassPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.35))
                    .glassEffect(Glass.clear.tint(.white.opacity(0.05)), in: Capsule(style: .continuous))
                    .opacity(0.6)
            )
    }
}

/// `ControlGlyph` in LockScreenPlayerView is private to that file; this is the
/// same press behaviour for the chrome.
private struct FullscreenGlyph: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        let side = size * 1.6
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white.opacity(pressed ? 0.7 : 1))
            .frame(width: side, height: side)
            .background(Circle().fill(.white.opacity(pressed ? 0.18 : 0)))
            .scaleEffect(pressed ? 0.86 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.6), value: pressed)
            .contentShape(Circle())
            .gesture(
                // minimumDistance 0 so the press lands on mouse-down. Fires the
                // action itself rather than pairing with onTapGesture — a
                // zero-distance drag swallows the tap.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        guard CGRect(x: 0, y: 0, width: side, height: side)
                            .contains(value.location) else { return }
                        action()
                    }
            )
    }
}

/// The whole song in one column, scrolled so the line being sung sits at a fixed
/// anchor — what Spotify and YouTube Music both do. The five fixed slots this
/// replaces had to blank the middle one to swap its text, which read as the line
/// vanishing; a column that moves never has to.
private struct FullscreenLyricsView: View {
    let lines: [LyricLine]
    let position: Double

    /// Where the sung line parks. Slightly above centre, so what is coming gets
    /// more room than what has gone.
    private let anchor = UnitPoint(x: 0, y: 0.42)

    var body: some View {
        let all = displayed
        let current = all.lastIndex { $0.time <= position } ?? 0
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(all.indices, id: \.self) { n in
                        line(all[n], distance: abs(n - current)).id(n)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Air at both ends, or the first and last lines could never reach
                // the anchor and the column would jerk at the edges of the song.
                .padding(.vertical, 260)
                .animation(.spring(response: 0.34, dampingFraction: 0.78), value: current)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .onChange(of: current, initial: true) { _, n in
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    proxy.scrollTo(n, anchor: anchor)
                }
            }
        }
        // The column is as tall as the screen, so it has to fade out at both ends
        // — otherwise lines are sliced off mid-glyph by the window edge.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                     .init(color: .white, location: 0.18),
                                     .init(color: .white, location: 0.82),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        // Same reasoning as the clock: the background can be any brightness, and a
        // shadow is cheaper than a scrim.
        .shadow(color: .black.opacity(0.6), radius: 16, x: 0, y: 3)
    }

    @ViewBuilder
    private func line(_ l: LyricLine, distance: Int) -> some View {
        Text(l.text.isEmpty ? " " : l.text)
            .font(.system(size: distance == 0 ? 32 : 26,
                          weight: distance == 0 ? .bold : .semibold,
                          design: .rounded))
            // Falls off with distance rather than one dim value for everything
            // else: it's what gives the column a reading position. Sung and unsung
            // dim the same amount — both players do that, and telling them apart
            // only invited the eye to read backwards.
            .foregroundStyle(.white.opacity(distance == 0 ? 1
                                            : distance == 1 ? 0.4
                                            : distance == 2 ? 0.2 : 0.12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// `lines` with a dots marker dropped into every stretch of the song nobody
    /// sings through: the intro before the first line, and any instrumental in the
    /// middle. Without one the column sits on a line that finished half a minute
    /// ago, which reads as the sync having broken.
    ///
    /// ponytail: rebuilt on every tick rather than cached — it's a walk over a few
    /// dozen lines next to a layout pass. Cache it in the parent if a song ever
    /// ships thousands.
    private var displayed: [LyricLine] {
        var out: [LyricLine] = []
        if let first = lines.first, first.time > gap {
            out.append(LyricLine(time: 0, end: first.time, text: dots))
        }
        for (i, l) in lines.enumerated() {
            out.append(l)
            // Only where `end_ms` says when the line actually stopped. LRC gives a
            // start and nothing else, so a long stretch there could as easily be a
            // slow line as an instrumental — no marker rather than a wrong one.
            guard let end = l.end, i + 1 < lines.count,
                  lines[i + 1].time - end > gap else { continue }
            out.append(LyricLine(time: end, end: lines[i + 1].time, text: dots))
        }
        return out
    }

    /// Long enough that the pause is deliberate rather than a singer drawing breath.
    private let gap = 5.0
    private let dots = "• • •"
}
