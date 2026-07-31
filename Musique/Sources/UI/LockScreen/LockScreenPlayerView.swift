import SwiftUI
import AppKit

struct LockScreenPlayerView: View {
    @ObservedObject var viewModel: LockScreenViewModel

    var body: some View {
        GeometryReader { geo in
            let snap = viewModel.snapshot
            let animationURLString = viewModel.animatedArtwork
                ? (viewModel.artwork.animationURL ?? viewModel.artwork.animationTallURL)
                : nil
            let animURL = animationURLString.flatMap(URL.init(string:))

            let largeSize = min(geo.size.height * 0.40, geo.size.width * 0.38)
            let cardWidth = min(350, geo.size.width * 0.35)

            ZStack {
                // Crossfade layer: the outgoing desktop, shown instantly then
                // faded to nil to mask the un-animatable real-wallpaper swap.
                if let cf = viewModel.crossfadeImage {
                    Image(nsImage: cf)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                }

                let showLarge = viewModel.isLargeArtwork && !viewModel.fullscreenAnimationActive
                let showInline = !viewModel.isLargeArtwork && !viewModel.fullscreenAnimationActive
                // Only stand down once the real desktop is *actually* playing our
                // clip. Activation takes seconds and can fail (unwritable wallpaper
                // store, nothing restorable to back up); trusting the setting alone
                // left the lock screen showing no artwork at all in those cases.
                let motionActive = viewModel.motionWallpaperLive && animURL != nil

                // Motion artwork: fill the screen with the animation itself (no
                // blur) instead of setting a still as the wallpaper. Tap-to-shrink
                // is handled by the Color.clear layer above it.
                // In motion-wallpaper mode the REAL desktop already plays the video,
                // so don't draw a SkyLight copy on top — that would cover the native
                // lock-screen clock. Keep the background clear so the real video and
                // the native clock both show.
                if showLarge, let animURL, !motionActive {
                    AnimatedArtworkView(url: animURL, staticImage: viewModel.artworkImage,
                                        contentMode: .fill, cornerRadius: 0)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // Still artwork: cover the seconds WallpaperAgent takes to repaint
                // the desktop with our own blurred copy, then fade out and let the
                // real wallpaper (and the native clock over it) show.
                if showLarge, animURL == nil, !viewModel.staticWallpaperLive,
                   let image = viewModel.artworkImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: CGFloat(viewModel.backgroundBlur) / 3)
                        .clipped()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if showLarge {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { shrink() }
                }

                if let snap, snap.hasTrack {
                    VStack(spacing: 20) {
                        if showLarge && animURL == nil {
                            ArtworkLayer(
                                artworkImage: viewModel.artworkImage,
                                animatedURL: animURL,
                                size: largeSize
                            )
                            .onTapGesture { shrink() }
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                        }

                        NowPlayingCard(
                            snap: snap,
                            showAlbum: viewModel.showAlbum,
                            showProgress: viewModel.showProgress,
                            width: cardWidth,
                            artworkImage: viewModel.artworkImage,
                            animatedURL: animURL,
                            animatedArtwork: viewModel.animatedArtwork,
                            showInlineArtwork: showInline,
                            onArtworkTap: {
                                // Enlarge — the controller reacts to `isLargeArtwork`
                                // and turns on whichever real wallpaper (static or
                                // motion) its setting allows. Tap is the single
                                // activation signal for both.
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                                    viewModel.isLargeArtwork = true
                                }
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, CGFloat(viewModel.padding) + 160)
                    .padding(.horizontal, CGFloat(viewModel.padding))
                }

            }
            // Fade the stand-in copy out as the real wallpaper lands, rather than
            // cutting to it.
            .animation(.easeInOut(duration: 0.35), value: viewModel.staticWallpaperLive)
            .animation(.easeInOut(duration: 0.35), value: viewModel.motionWallpaperLive)
        }
        .ignoresSafeArea()
    }

    /// Exit large mode — the inverse of the thumbnail tap. The controller reacts
    /// to `isLargeArtwork` flipping false and restores the previous wallpaper.
    private func shrink() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            viewModel.isLargeArtwork = false
        }
    }

}

private struct ArtworkLayer: View {
    let artworkImage: NSImage?
    let animatedURL: URL?
    let size: CGFloat

    var body: some View {
        ZStack {
            if let animatedURL {
                AnimatedArtworkView(url: animatedURL, staticImage: artworkImage, contentMode: .fill, cornerRadius: 20)
            } else if let nsImage = artworkImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.05)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 36, x: 0, y: 22)
    }
}

private struct NowPlayingCard: View {
    let snap: NowPlayingSnapshot
    let showAlbum: Bool
    let showProgress: Bool
    let width: CGFloat
    let artworkImage: NSImage?
    let animatedURL: URL?
    let animatedArtwork: Bool
    let showInlineArtwork: Bool
    let onArtworkTap: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if showInlineArtwork {
                    artworkThumbnail
                        .onTapGesture { onArtworkTap() }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }

                VStack(alignment: showInlineArtwork ? .leading : .leading, spacing: 2) {
                    Text(snap.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: showInlineArtwork ? .leading : .leading)

                    Text(snap.artist)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: showInlineArtwork ? .leading : .leading)
                }

                if snap.isPlaying {
                    LockScreenWaveBars()
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
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.clear)
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
