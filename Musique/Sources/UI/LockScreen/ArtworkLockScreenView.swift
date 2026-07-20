import SwiftUI
import AppKit

struct ArtworkLockScreenView: View {
    @ObservedObject var viewModel: LockScreenViewModel
    private var animationURL: URL? {
        guard viewModel.animatedArtwork else { return nil }
        let s = viewModel.artwork.animationSquareUltraURL ?? viewModel.artwork.animationURL ?? viewModel.artwork.animationTallURL
        guard let s, !s.isEmpty else { return nil }
        return URL(string: s)
    }
    var body: some View {
        ZStack {
            if let url = animationURL {
                AnimatedArtworkView(url: url, staticImage: viewModel.artworkImage, contentMode: .fill, cornerRadius: 0)

                LinearGradient(
                    colors: [
                        .black.opacity(0.15),
                        .black.opacity(0.0),
                        .black.opacity(0.55),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                BlurredArtworkBackground(palette: viewModel.palette, artworkImage: viewModel.artworkImage, blur: viewModel.backgroundBlur)
            }
        }
        .opacity(shouldShow ? 1 : 0)
        .animation(.easeInOut(duration: 0.4), value: viewModel.isLargeArtwork)
        .animation(.easeInOut(duration: 0.4), value: viewModel.fullscreenAnimationActive)
        .animation(.easeInOut(duration: 0.4), value: viewModel.liqoriaStyle)
        .animation(.easeInOut(duration: 0.4), value: viewModel.setSystemWallpaper)
        .ignoresSafeArea()
    }

    private var shouldShow: Bool {
        // In system-wallpaper mode the real desktop *is* the artwork — don't
        // cover it with our own background (the crossfade overlay handles the
        // transition instead).
        if viewModel.setSystemWallpaper { return false }
        // Large motion artwork is drawn full-screen by the player view itself —
        // don't double the animation here.
        if animationURL != nil, !viewModel.liqoriaStyle,
           viewModel.isLargeArtwork, !viewModel.fullscreenAnimationActive { return false }
        if viewModel.liqoriaStyle { return !viewModel.fullscreenAnimationActive }
        return viewModel.isLargeArtwork && !viewModel.fullscreenAnimationActive
    }
}

// MARK: - Blurred Artwork (original)

private struct BlurredArtworkBackground: View {
    let palette: ArtworkPalette
    let artworkImage: NSImage?
    let blur: Int

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(palette.gradientStart),
                    Color(palette.gradientMid),
                    Color(palette.gradientEnd),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let nsImage = artworkImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: CGFloat(blur))
                    .saturation(2.4)
                    .brightness(-0.15)
                    .opacity(0.78)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

