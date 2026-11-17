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
        return LyricsLookupIdentity.key(for: snap) ?? ""
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
            defer { lyricsPending = false }
            lyrics = await LyricsService.shared.lines(artist: snap.artist, title: snap.title,
                                                     album: snap.album, duration: snap.duration,
                                                     source: snap.source)
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
                FullscreenLyricsView(lines: lyrics, playback: snap)
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
/// anchor — the whole column moves as one when the line changes. (A per-line
/// staggered ripple was tried and taken back out.)
struct FullscreenLyricsView: View {
    let lines: [LyricLine]
    /// The playing track. Its position is projected to every frame here, so the
    /// line changes when it's sung — not at the next once-a-second snapshot,
    /// which came up to a second late and had the first word gone already.
    let playback: NowPlayingSnapshot
    /// One size for every line, like Apple Music: the sung one is told apart by
    /// brightness, not by growing. Defaults are the fullscreen window's.
    var fontSize: CGFloat = 30
    var spacing: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let scrollLead = 0.3

    /// Where the sung line parks, as a fraction of the height — near
    /// the top, as Apple Music does (~13% on a capture), leaving room for one
    /// faded line of what's gone and the rest for what's coming. 0.5 centres it.
    var anchor: CGFloat = 0.14

    var body: some View {
        let all = displayed
        GeometryReader { geo in
            // Reduce Motion: still keeps time, just stops sweeping per frame.
            TimelineView(.animation(minimumInterval: tickInterval, paused: !playback.isPlaying)) { context in
                let position = playback.livePosition(at: context.date)
                // The frame only picks which line is sung; the column below is
                // Equatable, so it re-renders when that changes, not per frame.
                // Rebuilding every line, shadow and scroll layout 30 times a second
                // was ~23% of the main thread with the desktop card's panel open.
                LyricsColumn(lines: all,
                             current: all.lastIndex { $0.time <= position } ?? 0,
                             // The scroll spring takes ~0.5s to land; starting it on the
                             // line's own time put the line in place after its first
                             // words were sung. Scroll a beat early so it arrives as
                             // it's sung — the highlight still uses `current`.
                             target: all.lastIndex { $0.time <= position + Self.scrollLead } ?? 0,
                             height: geo.size.height, playback: playback, fontSize: fontSize,
                             spacing: spacing, anchor: anchor, tickInterval: tickInterval)
                    .equatable()
            }
        }
        // Lines leave through the top and bottom edges; fade them rather than
        // slicing them off mid-glyph.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                     .init(color: .white, location: 0.1),
                                     .init(color: .white, location: 0.82),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .clipped()
    }

    private var tickInterval: Double { reduceMotion ? 0.25 : 1.0 / 30.0 }

    /// `lines` with a dots marker dropped into every stretch of the song nobody
    /// sings through: the intro before the first line, and any instrumental in the
    /// middle. Without one the column sits on a line that finished half a minute
    /// ago, which reads as the sync having broken.
    ///
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

/// `FullscreenLyricsView`'s scrolling column, re-rendered only when the sung
/// line (or the track's clock) changes. The sung line runs its own timeline,
/// so the per-frame work is that one line's wipe.
private struct LyricsColumn: View, Equatable {
    let lines: [LyricLine]
    let current: Int
    let target: Int
    let height: CGFloat
    let playback: NowPlayingSnapshot
    let fontSize: CGFloat
    let spacing: CGFloat
    let anchor: CGFloat
    let tickInterval: Double

    static func == (a: Self, b: Self) -> Bool {
        a.current == b.current && a.target == b.target && a.height == b.height
            && a.fontSize == b.fontSize && a.spacing == b.spacing && a.anchor == b.anchor
            && a.tickInterval == b.tickInterval && a.lines == b.lines
            // What the sung line's clock projects from.
            && a.playback.isPlaying == b.playback.isPlaying
            && a.playback.position == b.playback.position
            && a.playback.positionDate == b.playback.positionDate
            && a.playback.duration == b.playback.duration
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(lines.indices, id: \.self) { n in
                        line(lines[n], distance: abs(n - current)).id(n)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Air at both ends, or the first and last lines could never reach
                // the anchor and the column would jerk at the edges of the song.
                .padding(.vertical, height)
                // Quick, so the new line brightens on its first word, not after it.
                .animation(.easeOut(duration: 0.12), value: current)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .onChange(of: target, initial: true) { _, n in
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    proxy.scrollTo(n, anchor: UnitPoint(x: 0, y: anchor))
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ l: LyricLine, distance: Int) -> some View {
        Group {
            if distance == 0, !l.segments.isEmpty {
                // The wipe rebuilds its Text every frame; as a plain child that
                // re-measured the line and, through the VStack, the whole scroll
                // column. A hidden copy holds the layout and the wipe draws as an
                // overlay, whose size never feeds back up.
                Text(l.text.isEmpty ? " " : l.text)
                    .hidden()
                    .overlay(alignment: .topLeading) {
                        KaraokeLyricText(line: l, playback: playback, tickInterval: tickInterval)
                    }
            } else {
                Text(l.text.isEmpty ? " " : l.text)
                    .foregroundStyle(.white.opacity(distance == 0 ? 1 : distance <= 2 ? 0.34 : 0.22))
            }
        }
            .font(.system(size: fontSize, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(l.text)
            // The background can be any brightness, and a shadow is cheaper than a
            // scrim. Per line, not on the column: on the scroll view it cast the
            // shadow of a box, which showed as grey blocks on a light cover.
            .shadow(color: .black.opacity(0.45), radius: fontSize * 0.35, x: 0, y: 1)
    }
}

/// The sung line: every syllable drawn grey, then white over it up to how far
/// it's been sung — a soft-edged wipe through the word, not a whole syllable
/// brightening at once. `position` arrives already projected to the frame.
private struct KaraokeLyricText: View {
    let line: LyricLine
    let playback: NowPlayingSnapshot
    let tickInterval: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Built once per line, outside the timeline: only the renderer's
        // position changes per frame, so SwiftUI redraws the runs without
        // resolving and measuring the Text again (which it did for every frame
        // while the progress lived in the Text's attributes).
        let text = Self.text(for: line)
        let lift: CGFloat = reduceMotion ? 0 : 1.5
        TimelineView(.animation(minimumInterval: tickInterval, paused: !playback.isPlaying)) { context in
            text.textRenderer(SungWordRenderer(position: playback.livePosition(at: context.date), lift: lift))
        }
    }

    /// Builds one wrapping SwiftUI Text while retaining the literal whitespace in
    /// the complete TTML line. MusanovaKit's segment text omits those separators,
    /// so each segment is located sequentially inside the original line.
    private static func text(for line: LyricLine) -> Text {
        let content = line.text.isEmpty ? " " : line.text
        guard !line.segments.isEmpty else { return Text(content).foregroundColor(.white) }

        var result = Text("")
        var cursor = content.startIndex
        var matchedAny = false

        for segment in line.segments {
            guard cursor < content.endIndex,
                  let range = content.range(of: segment.text,
                                            range: cursor..<content.endIndex) else { continue }
            let timing = SungTiming(start: segment.start, end: segment.end)
            if cursor < range.lowerBound {
                result = result + styled(String(content[cursor..<range.lowerBound]), timing)
            }
            var syllable = timing
            syllable.held = segment.end - segment.start >= heldNote
            result = result + styled(String(content[range]), syllable)
            cursor = range.upperBound
            matchedAny = true
        }

        guard matchedAny else { return Text(content).foregroundColor(.white) }
        if cursor < content.endIndex {
            // The tail follows the last syllable (segments is non-empty here).
            let timing = line.segments.last.map { SungTiming(start: $0.start, end: $0.end) }
                ?? SungTiming(start: 0, end: 0)
            result = result + styled(String(content[cursor...]), timing)
        }
        return result
    }

    private static func styled(_ text: String, _ timing: SungTiming) -> Text {
        Text(text)
            .foregroundColor(.white)
            .customAttribute(timing)
    }

    /// A syllable sung at least this long is a held note and gets the wave.
    private static let heldNote = 1.0
}

/// When a run of the sung line is sung. The renderer turns it into progress
/// against the frame's position, so the Text itself never changes per frame.
private struct SungTiming: TextAttribute {
    var start: Double
    var end: Double
    /// A held note: drawn letter by letter, rising as the colour reaches each.
    var held = false

    /// 0 before the syllable, 1 once it's sung, linear in between — the wipe
    /// should track the voice, not ease around it.
    func progress(at position: Double) -> Double {
        min(max((position - start) / max(end - start, 0.01), 0), 1)
    }
}

/// Draws the sung line: each run grey underneath, white on top masked by a
/// gradient whose soft edge sits at the run's progress, so the colour sweeps
/// through the letters. A syllable being sung also glows, and lifts a hair and
/// stays up. A renderer because the line is one `Text` built from many pieces;
/// nothing else can paint part of one word.
private struct SungWordRenderer: TextRenderer {
    /// Playback position for this frame, projected.
    var position: Double
    var lift: CGFloat
    /// Grey of the not-yet-sung part of the sung line — brighter than the lines
    /// around it, so the line still reads as the current one before it's sung.
    var unsung: Double = 0.45

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let timing = run[SungTiming.self] else {
                    context.draw(run)
                    continue
                }
                let sung = timing.progress(at: position)
                let rise = lift * sung * sung * (3 - 2 * sung)
                if timing.held, sung > 0, sung < 1, lift > 0 {
                    drawHeld(run, sung: sung, baseRise: rise, in: context)
                    continue
                }
                var ctx = context
                ctx.translateBy(x: 0, y: -rise)
                // A held note that's done keeps the pose its wave ended on, rather
                // than dropping back the moment the next syllable starts.
                if timing.held, sung >= 1, lift > 0 {
                    let box = run.typographicBounds.rect
                    ctx.translateBy(x: box.midX, y: box.midY - 3)
                    ctx.scaleBy(x: 1.06, y: 1.06)
                    ctx.translateBy(x: -box.midX, y: -box.midY)
                }

                var grey = ctx
                grey.opacity = unsung
                grey.draw(run)
                guard sung > 0 else { continue }

                if sung < 1 {
                    // Glow under the syllable being sung, peaking mid-syllable. Its own
                    // pass: a shadow on the clipped layer below outlined the clip box.
                    var glow = ctx
                    glow.opacity = 0.35 * sin(sung * .pi)
                    glow.addFilter(.blur(radius: 6))
                    glow.draw(run)
                }

                var lit = ctx
                if sung < 1 {
                    let rect = run.typographicBounds.rect
                    // A few points of feather, whatever the word's width.
                    let feather = min(0.5, 8 / max(rect.width, 1))
                    let edge = sung * (1 + feather)
                    lit.clipToLayer { layer in
                        layer.fill(Path(rect), with: .linearGradient(
                            Gradient(stops: [.init(color: .white, location: max(0, edge - feather)),
                                             .init(color: .clear, location: min(1, edge))]),
                            startPoint: CGPoint(x: rect.minX, y: rect.midY),
                            endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
                    }
                }
                lit.draw(run)
            }
        }
    }

    /// A held note while it's being sung: a glow that builds over the note, and
    /// the letters lit one by one, each rising a few points (and the word swelling
    /// a touch) as the colour reaches it — Apple Music's long-vowel wave. Letter
    /// by letter because a run only moves as a whole.
    private func drawHeld(_ run: Text.Layout.Run, sung: Double, baseRise: CGFloat,
                          in context: GraphicsContext) {
        let swell = sin(min(1, sung * 1.2) * .pi / 2)

        var glow = context
        glow.translateBy(x: 0, y: -baseRise)
        glow.opacity = 0.5 * swell
        glow.addFilter(.blur(radius: 6 + 6 * swell))
        glow.draw(run)

        let slices = Array(run)
        let count = Double(slices.count)
        let scale = 1 + 0.06 * swell
        for (i, slice) in slices.enumerated() {
            let reached = sung * count - Double(i)
            let lit = min(max(reached + 0.5, 0), 1)
            let t = min(max(reached, 0), 1)
            let rise = baseRise + 3 * CGFloat(t * t * (3 - 2 * t))
            let box = slice.typographicBounds.rect
            var ctx = context
            ctx.translateBy(x: box.midX, y: box.midY - rise)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.midX, y: -box.midY)

            var grey = ctx
            grey.opacity = unsung
            grey.draw(slice)
            guard lit > 0 else { continue }
            var white = ctx
            white.opacity = lit
            white.draw(slice)
        }
    }
}
