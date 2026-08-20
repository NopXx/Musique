import SwiftUI
import AppKit

struct LockScreenPlayerView: View {
    @ObservedObject var viewModel: LockScreenViewModel

    var body: some View {
        GeometryReader { geo in
            let snap = viewModel.snapshot
            // The 52pt thumbnail keeps the standard-res clip — it doesn't need the
            // ultra one and shouldn't pay for the extra download.
            let thumbURL = (viewModel.animatedArtwork
                ? (viewModel.artwork.animationURL ?? viewModel.artwork.animationTallURL)
                : nil).flatMap(URL.init(string:))

            let cardWidth = min(350, geo.size.width * 0.35)

            ZStack {
                let showLarge = viewModel.isLargeArtwork && !viewModel.fullscreenAnimationActive
                let showInline = !viewModel.isLargeArtwork && !viewModel.fullscreenAnimationActive

                if showLarge {
                    Group {
                        FullscreenArtworkView(artworkImage: viewModel.artworkImage,
                                              // Fallback for when the view model's own
                                              // download came back empty — the backdrop
                                              // needs a still even if the card's
                                              // thumbnail went without one.
                                              artworkURL: stillURL,
                                              clipURL: fullscreenAnimationURL,
                                              palette: viewModel.palette,
                                              backgroundBlur: viewModel.backgroundBlur)

                        if viewModel.clock {
                            LockScreenClockView(timeFormat: viewModel.clockFormat,
                                                dateStyle: viewModel.clockDateStyle,
                                                size: CGFloat(viewModel.clockSize))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                .padding(.top, CGFloat(viewModel.padding) + 56)
                                .allowsHitTesting(false)
                        }

                        // Click anywhere to shrink. Above the artwork so the whole
                        // screen is the target, below the card so the transport
                        // buttons still win their own hits.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { shrink() }
                    }
                    // ponytail: opacity, not `if` — removing the subtree tears down
                    // the AVPlayer and restarts the clip from frame 0 every time the
                    // password panel blinks. Ceiling: swap to conditional removal if
                    // a hidden decoding video ever shows up in powermetrics.
                    .opacity(viewModel.lockUIVisible ? 0 : 1)
                    .allowsHitTesting(!viewModel.lockUIVisible)
                    .transition(.opacity)
                }

                if let snap, snap.hasTrack {
                    NowPlayingCard(
                        snap: snap,
                        showAlbum: viewModel.showAlbum,
                        showProgress: viewModel.showProgress,
                        width: cardWidth,
                        artworkImage: viewModel.artworkImage,
                        animatedURL: thumbURL,
                        animatedArtwork: viewModel.animatedArtwork,
                        showInlineArtwork: showInline,
                        onArtworkTap: {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                viewModel.isLargeArtwork = true
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    // 160pt of clearance for loginwindow's avatar and password
                    // field — only meaningful while that UI is actually on screen.
                    // The fullscreen artwork covers it, so the card drops to the
                    // real padding while it's up, and gives the room back the
                    // moment we fade for the password panel.
                    .padding(.bottom, CGFloat(viewModel.padding)
                             + (showLarge && !viewModel.lockUIVisible ? 0 : 160))
                    .padding(.horizontal, CGFloat(viewModel.padding))
                }
            }
            // A filled cover is taller than the screen and a ZStack doesn't clip:
            // without this the overflow lands outside the hosting view and the
            // desktop shows through at the corners.
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .animation(.easeInOut(duration: 0.28), value: viewModel.lockUIVisible)
        }
        .ignoresSafeArea()
    }

    /// Highest-resolution *square* clip first: this layer is screen-height now, not
    /// a 350pt card, so the standard-res one visibly softens. The tall (3:4)
    /// variant is deliberately not in the chain — the frame is built from the
    /// still's aspect, so a tall clip would only get cropped.
    private var stillURL: URL? {
        (viewModel.artwork.artworkUltraURL ?? viewModel.artwork.artworkURL)
            .flatMap(URL.init(string:))
    }

    private var fullscreenAnimationURL: URL? {
        guard viewModel.animatedArtwork else { return nil }
        return (viewModel.artwork.animationSquareUltraURL ?? viewModel.artwork.animationURL)
            .flatMap(URL.init(string:))
    }

    /// Exit large mode — the inverse of the thumbnail tap.
    private func shrink() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            viewModel.isLargeArtwork = false
        }
    }

}

/// The lock screen's own clock, drawn only while the fullscreen artwork is up —
/// it covers loginwindow's clock edge to edge, and losing the time is not an
/// acceptable price for a bigger cover.
// Not private: the unlocked fullscreen animation window (AnimationFullscreenView)
// draws the same clock and now-playing card over the artwork.
struct LockScreenClockView: View {
    let timeFormat: String   // system | 24h | 12h
    let dateStyle: String    // full | short | off
    let size: CGFloat        // point size of the time

    var body: some View {
        // Minute granularity: no seconds are shown, so one wake a minute is the
        // entire redraw budget this needs.
        TimelineView(.everyMinute) { ctx in
            VStack(spacing: 2) {
                // Glass in the glyph outlines, not in a box behind them — the iOS 26
                // lock screen clock is the artwork seen *through* the numerals. Needs
                // a real Shape, which is all TextShape is for; a Text can only ever
                // carry glass as a frosted rectangle around itself.
                //
                // Known: this clock does not look the same in both of its windows.
                // SkyLightOperator moves the lock screen overlay out of every normal
                // space into a private WindowServer one, and glass there has no
                // backdrop to sample — it falls back to a flat pale frost, while the
                // desktop fullscreen window gets a real refraction. The whole overlay
                // is affected, the transport card included, so it is not worth trading
                // the good window's glass away to match the bad one. Everything else
                // was ruled out by testing: window opacity, background colour, level,
                // collectionBehavior and canBecomeVisibleWithoutLogin all render the
                // same.
                let digits = TextShape(string: Self.timeString(ctx.date, timeFormat),
                                       font: TextShape.clockFont(size: size, weight: .bold))
                Color.clear
                    .frame(width: digits.size.width, height: digits.size.height)
                    // Tinted, not bare .clear: over a bright sleeve clear glass has
                    // nothing to separate it from, and the time disappears.
                    .glassEffect(Glass.clear.tint(.white.opacity(0.12)), in: digits)
                    .padding(.bottom, 6)

                if dateStyle != "off" {
                    Text(Self.dateString(ctx.date, dateStyle))
                        // Tied to the time's size rather than fixed, so one setting
                        // scales the whole block the way the iOS clock does.
                        .font(.system(size: size * 0.2, weight: .medium, design: .rounded))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            // The artwork underneath can be any brightness — a drop shadow is
            // cheaper than a scrim and doesn't dull the cover.
            .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 4)
            // Glass also takes its brightness from the host window's NSAppearance,
            // and the two windows don't resolve the same one — that made the lock
            // screen's numerals flat grey against the desktop's warm ones, on top of
            // the sampling difference above. Pinned here rather than on either
            // window, so nothing else in them is affected.
            .environment(\.colorScheme, .light)
        }
    }

    // ponytail: a DateFormatter per tick, on purpose — this runs once a minute, so
    // caching costs more code than it saves, and a cached one would miss the user
    // flipping the app's language or the system 24-hour switch underneath us.
    private static func timeString(_ date: Date, _ mode: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        switch mode {
        case "24h": f.dateFormat = "HH:mm"
        // No AM/PM, like the iOS lock screen. "system" keeps it, because that's
        // what following the system means.
        case "12h": f.dateFormat = "h:mm"
        default:
            f.dateStyle = .none
            f.timeStyle = .short
        }
        return f.string(from: date)
    }

    private static func dateString(_ date: Date, _ style: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(style == "short" ? "EEEdMMM" : "EEEEdMMMM")
        return f.string(from: date)
    }

    /// Follow the app's own language switch rather than the system's — every other
    /// string on this overlay comes from `L10n`, which reads that setting.
    private static var locale: Locale {
        Locale(identifier: L10n.lang == "en" ? "en_US" : "th_TH")
    }
}

struct NowPlayingCard: View {
    let snap: NowPlayingSnapshot
    let showAlbum: Bool
    let showProgress: Bool
    let width: CGFloat
    let artworkImage: NSImage?
    let animatedURL: URL?
    let animatedArtwork: Bool
    let showInlineArtwork: Bool
    let onArtworkTap: () -> Void
    /// Set only by the fullscreen views — the lock screen has nothing to collapse.
    var onCollapse: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if showInlineArtwork {
                    artworkThumbnail
                        .onTapGesture { onArtworkTap() }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(snap.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(snap.artist)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if snap.isPlaying {
                    LockScreenWaveBars()
                }

                if let onCollapse {
                    ControlGlyph(systemName: "arrow.down.right.and.arrow.up.left", size: 15)
                        .onTapGesture { onCollapse() }
                }
            }

            if showProgress && snap.duration > 0 {
                ProgressBar(elapsed: snap.position, duration: snap.duration)
            }

            HStack(spacing: 44) {
                ControlGlyph(systemName: "backward.fill", size: 22)
                    .onTapGesture { MusicAppController.previous() }
                ControlGlyph(systemName: snap.isPlaying ? "pause.fill" : "play.fill", size: 28)
                    .onTapGesture { MusicAppController.playPause() }
                ControlGlyph(systemName: "forward.fill", size: 22)
                    .onTapGesture { MusicAppController.next() }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: width)
        // Not inside a GlassEffectContainer, deliberately. A container hoists the
        // glass its children declare into its own layer, and this card declares glass
        // inside `.background(...)` — hoisted, it lands *over* the title, artist and
        // transport instead of behind them, and the card renders as a grey blank.
        // Nothing here would merge anyway: the only other glass on screen is the
        // clock, half a screen away.
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                // Not .clear: the card's text and glyphs are all white, and clear
                // glass over a white sleeve leaves them unreadable.
                .fill(.black.opacity(0.35))
                .glassEffect(
                    Glass.clear.tint(.white.opacity(0.05)),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .opacity(0.6)
        )
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        ZStack {
            if animatedArtwork, let animatedURL {
                AnimatedArtworkView(url: animatedURL, staticImage: artworkImage, contentMode: .fill, cornerRadius: 8)
            } else if let nsImage = artworkImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct LockScreenWaveBars: View {
    @ObservedObject private var audio = MusicAudioLevelMonitor.shared
    private let count = 10
    private let bandStride = 1

    private let barW: CGFloat = 2.5
    private let spacing: CGFloat = 2

    // ponytail: single Canvas instead of 10 Capsules with per-bar implicit animation.
    // EMA in the publisher already smooths; redraw is one pass, not 10 view diffs.
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 0
            for i in 0..<count {
                let h = barHeight(i)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                ctx.fill(Capsule().path(in: rect), with: .color(.white.opacity(0.75)))
                x += barW + spacing
            }
        }
        .frame(width: CGFloat(count) * barW + CGFloat(count - 1) * spacing, height: 18)
        .onAppear { MusicAudioLevelMonitor.shared.start() }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let bands = audio.bands
        let base: CGFloat = 4
        guard i < bands.count else { return base }
        let v = CGFloat(min(1, max(0, bands[i])))
        return base + v * 18
    }
}

private struct EqualizerIcon: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 3, height: animate ? barHeight(i) : 4)
            }
        }
        .frame(width: 16, height: 16)
        .onAppear { animate = true }
        .animation(
            .easeInOut(duration: 0.5)
                .repeatForever(autoreverses: true)
                .delay(Double.random(in: 0...0.2)),
            value: animate
        )
    }

    private func barHeight(_ index: Int) -> CGFloat {
        switch index {
        case 0: return 10
        case 1: return 14
        default: return 8
        }
    }
}

private struct ControlGlyph: View {
    let systemName: String
    let size: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size * 1.6, height: size * 1.6)
    }
}

private struct ProgressBar: View {
    let elapsed: Double
    let duration: Double

    var body: some View {
        let progress = duration > 0 ? min(1, max(0, elapsed / duration)) : 0
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 3)

            HStack {
                Text(format(elapsed))
                Spacer()
                Text(format(duration))
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .monospacedDigit()
        }
    }

    private func format(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
