import SwiftUI
import AppKit
import AVFoundation

/// The fullscreen cover, drawn the same way wherever it appears — the lock screen
/// overlay and the mini player's fullscreen window both use this, so the two can't
/// drift apart again.
///
/// Two layouts, the same split the iPad lock screen makes:
///
/// - **Motion clip** — fit to the screen at its own aspect so it owns the short edge,
///   sharp to its own edges, with soft mirrors of the same frames filling the margins.
///   Fit, not fill: filling crops ~17% off the top and bottom of a square cover on a
///   16:10 display, which eats whatever the scene put at its edges.
/// - **Still artwork** — a rounded card at half the screen's short edge over the
///   blurred field. A still sleeve blown up to fill a screen is just a big JPEG:
///   there is no movement to earn the size, and at that scale the upscaling shows.
struct FullscreenArtworkView: View {
    /// The cover, if the caller already has it decoded (the lock screen does — its
    /// view model downloads one for the card thumbnail).
    var artworkImage: NSImage?
    /// Loaded into `artworkImage`'s place when the caller has only a URL.
    var artworkURL: URL?
    /// The motion clip. `nil` picks the still card layout — that choice is the
    /// caller's, since only it knows whether animated artwork is switched on.
    var clipURL: URL?
    var palette: ArtworkPalette
    /// `lockscreen.background_blur`, in the setting's own units.
    var backgroundBlur: Int

    /// A still cover's card, as a fraction of the fit size — half the screen's short
    /// edge, which is what the iPad lock screen gives it. Big enough to be the thing
    /// you are looking at, small enough to leave the clock and the transport card
    /// their own space above and below.
    private let cardScale: CGFloat = 0.5

    /// How far the cover fades into the mirrors beside it — the two edges that have a
    /// mirror, not all four: the other two are the screen's own edges.
    private let feather: CGFloat = 48

    /// How soft the mirrored margins are. Enough to read as backdrop rather than as a
    /// second copy of the cover, not so much that the movement stops registering —
    /// which is the whole reason they are video and not a still.
    private let mirrorBlur: CGFloat = 40

    @State private var loadedImage: NSImage?

    private var cover: NSImage? { artworkImage ?? loadedImage }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop(geo.size)
                foreground(geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .allowsHitTesting(false)   // whoever presents this owns the click
        // Card mode has nothing to show at all without a still, so don't depend on the
        // caller having one: fetch it if it didn't come through.
        .task(id: artworkURL) {
            guard artworkImage == nil, let artworkURL,
                  let (data, _) = try? await URLSession.shared.data(from: artworkURL) else { return }
            loadedImage = NSImage(data: data)
        }
    }

    /// The card layout's background: the cover blurred into one colour field. Motion
    /// mode gets nothing here — its margins are mirrors of the clip, edge to edge, and
    /// every layer that used to sit under them (a blurred still, a palette gradient, a
    /// scrim) only showed up as a tint on the reflection.
    @ViewBuilder
    private func backdrop(_ size: CGSize) -> some View {
        if clipURL == nil {
            ZStack {
                // The artwork download hasn't landed yet, or the cover has transparent
                // corners. A palette gradient beats a black screen.
                LinearGradient(colors: [Color(palette.gradientStart),
                                        Color(palette.gradientMid),
                                        Color(palette.gradientEnd)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                if let cover,
                   let backdrop = ArtworkBackdrop.image(
                       for: cover, screen: size,
                       // Nothing has to line up with the cover's edge here and the
                       // background is meant to read as one colour field rather than as
                       // a smeared photograph — so blur it far past recognition.
                       blur: ArtworkBackdrop.blurRadius(setting: backgroundBlur) * 3) {
                    Image(nsImage: backdrop)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private func foreground(_ size: CGSize) -> some View {
        // Aspect from the still, which is always present; the clip we pick is the
        // square one, so it matches.
        let aspect = cover.map { $0.size.width / max($0.size.height, 1) } ?? 1
        let fit = min(size.height, size.width / max(aspect, 0.01))

        if let clipURL {
            // One view for the whole screen: the clip fit in the middle, mirrored
            // copies of the same frames filling the margins. Mirroring is what makes
            // the seam vanish; the feather only softens the hand-off. The movement is
            // the point: a still blurred backdrop sat there dead beside a playing cover
            // and read as a frame around a picture.
            AnimatedArtworkView(url: clipURL,
                                staticImage: cover,
                                contentMode: .fill,
                                cornerRadius: 0,
                                edgeFeather: feather,
                                mirrorCoverSize: CGSize(width: fit * aspect, height: fit),
                                mirrorBlur: mirrorBlur)
                .frame(width: size.width, height: size.height)
        } else {
            let height = fit * cardScale
            ZStack {
                // Lifts the card off a backdrop made of its own colours — without it
                // a cover whose edges match the blur behind them has no card shape.
                // Drawn as its own blurred shape, not `.shadow` on the artwork: that
                // is a SwiftUI render-graph filter and it does not reach the
                // AppKit-hosted layer inside AnimatedArtworkView.
                RoundedRectangle(cornerRadius: height * 0.045, style: .continuous)
                    .fill(Color.black.opacity(0.5))
                    .frame(width: height * aspect, height: height)
                    .blur(radius: height * 0.05)
                    .offset(y: height * 0.025)

                AnimatedArtworkView(url: nil,
                                    staticImage: cover,
                                    contentMode: .fill,
                                    cornerRadius: height * 0.045,
                                    edgeFeather: 0)
                    .frame(width: height * aspect, height: height)
            }
        }
    }
}
