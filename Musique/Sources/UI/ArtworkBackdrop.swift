import AppKit
import CoreImage

/// The blurred fill behind a fullscreen cover.
///
/// The cover is drawn *fit* — on a wide display that leaves a margin either side,
/// and what goes in the margin decides whether the screen reads as one image or as
/// a framed picture. Scaling a second copy up to fill and blurring it (the obvious
/// move) puts the sleeve's forms at a different size and position than the sharp
/// copy in front, so the two disagree along the cover's edge and the eye finds the
/// seam no matter how heavy the blur.
///
/// So: same scale, same position, edge pixels *stretched* outward (`clampedToExtent`)
/// and then blurred. The margin colour is literally the colour the cover ends on, so
/// there is no seam to hide — which is what the iPad lock screen does with the same
/// artwork.
enum ArtworkBackdrop {

    /// Blur radius in *screen* points for a given `lockscreen.background_blur`
    /// setting. Floored well above the setting's default: the stretch has to smear
    /// into unrecognisable colour, or the streaks read as a smudge instead of a
    /// glow.
    static func blurRadius(setting: Int) -> CGFloat { max(140, CGFloat(setting) * 2) }

    /// Built at this height regardless of the screen's — it is a 140pt+ blur, so
    /// there is nothing in it that survives to full resolution anyway, and the
    /// aspect (hence the alignment with the sharp cover) is preserved.
    private static let workHeight: CGFloat = 480

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static var cacheKey = ""
    private static var cached: NSImage?

    /// A SwiftUI body runs far more often than the track changes, so this has to be
    /// cached — one entry is enough, nothing ever asks for two screens at once
    /// within a frame.
    static func image(for artwork: NSImage, screen: CGSize, blur: CGFloat) -> NSImage? {
        guard screen.width > 0, screen.height > 0 else { return nil }
        let key = "\(ObjectIdentifier(artwork))-\(Int(screen.width))x\(Int(screen.height))-\(Int(blur))"
        if key == cacheKey, let cached { return cached }
        guard let made = render(artwork, screen: screen, blur: blur) else { return nil }
        cacheKey = key
        cached = made
        return made
    }

    private static func render(_ artwork: NSImage, screen: CGSize, blur: CGFloat) -> NSImage? {
        guard let tiff = artwork.tiffRepresentation, let source = CIImage(data: tiff) else { return nil }

        let downscale = workHeight / screen.height
        let canvas = CGRect(x: 0, y: 0, width: (screen.width * downscale).rounded(), height: workHeight)

        // Fit, centred — the same frame the sharp cover in front gets.
        let e = source.extent
        let fit = min(canvas.width / e.width, canvas.height / e.height)
        var img = source.transformed(by: .init(scaleX: fit, y: fit))
        img = img.transformed(by: .init(translationX: canvas.midX - img.extent.midX,
                                        y: canvas.midY - img.extent.midY))

        img = img.clampedToExtent()
            // CI takes a sigma, SwiftUI's `.blur(radius:)` is roughly twice that.
            .applyingGaussianBlur(sigma: Double(blur * downscale / 2))
            .cropped(to: canvas)

        guard let cg = ciContext.createCGImage(img, from: canvas) else { return nil }
        return NSImage(cgImage: cg, size: canvas.size)
    }
}
