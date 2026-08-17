import SwiftUI
import AVKit

struct AnimatedArtworkView: NSViewRepresentable {
    let url: URL?
    var staticImage: NSImage? = nil
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 0
    /// Soft-edge inset in points. Non-zero fades the artwork's own edges to
    /// transparent so it melts into whatever is behind it instead of ending on a
    /// hard rectangle — the lock screen's iPad-style edge blur.
    ///
    /// Done with CALayer masks rather than SwiftUI `.mask(Rectangle().blur())` on
    /// purpose: `.blur` is a render-graph filter SwiftUI can't push onto an
    /// AppKit-hosted AVPlayerLayer (it silently no-ops), `.mask` over a
    /// representable is undefined, and where it *does* land it costs a full-screen
    /// offscreen pass per video frame. A CALayer mask is what the video layer
    /// already honours — the same mechanism `cornerRadius` + `masksToBounds` uses.
    var edgeFeather: CGFloat = 0

    /// Non-nil switches the view into the fullscreen-artwork layout: it spans the
    /// whole screen, the clip plays at this size in the middle, and the margins are
    /// filled with soft mirrored copies of *the same frames* — one decode, so they
    /// cannot drift apart.
    ///
    /// Three separate players was the obvious way to do this and it doesn't work:
    /// they drift, and blurring one through `CALayer.filters` (the only filter path
    /// that reaches an AVPlayerLayer at all) pushed that copy onto a slow render
    /// path, dropped its frames, and left it seconds behind the cover beside it.
    var mirrorCoverSize: CGSize? = nil

    /// Softness of those margins, in points at screen scale.
    var mirrorBlur: CGFloat = 0

    enum ContentMode { case fill, fit }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.cornerRadius = cornerRadius
        view.edgeFeather = edgeFeather
        view.mirrorBlur = mirrorBlur
        view.coverSize = mirrorCoverSize
        view.gravity = (contentMode == .fill) ? .resizeAspectFill : .resizeAspect
        view.coordinator = context.coordinator
        view.setStaticImage(staticImage)
        view.load(url: url)
    }

    static func dismantleNSView(_ view: PlayerView, coordinator: Coordinator) {
        view.cleanup()
        coordinator.looper = nil
        coordinator.queuePlayer?.pause()
        coordinator.queuePlayer = nil
    }

    final class Coordinator {
        var queuePlayer: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }

    final class PlayerView: NSView {
        var coordinator: Coordinator?
        var cornerRadius: CGFloat = 0 {
            // On `contentLayer`, which is the one that clips — the root layer is the
            // whole screen when this view is drawing mirrored margins.
            didSet { contentLayer.cornerRadius = cornerRadius }
        }
        var gravity: AVLayerVideoGravity = .resizeAspectFill {
            didSet {
                playerLayer?.videoGravity = gravity
                imageLayer?.contentsGravity = gravity == .resizeAspectFill ? .resizeAspectFill : .resizeAspect
            }
        }
        var edgeFeather: CGFloat = 0 {
            // Also re-laid out: the mirrors overlap the cover by exactly this much.
            didSet { if edgeFeather != oldValue { updateGeometry() } }
        }
        var mirrorBlur: CGFloat = 0
        var coverSize: CGSize? {
            didSet {
                guard coverSize != oldValue else { return }
                // Opaque floor while this view owns the whole screen: anything the
                // mirrors don't reach would otherwise be a hole through to the desktop.
                layer?.backgroundColor = coverSize == nil ? nil : NSColor.black.cgColor
                updateGeometry()
            }
        }
        private var playerLayer: AVPlayerLayer?
        private var imageLayer: CALayer?
        private var mirrorLayers: [CALayer] = []
        private var videoOutput: AVPlayerItemVideoOutput?
        private var outputItem: AVPlayerItem?
        private var itemObservation: NSKeyValueObservation?
        private var displayLink: CADisplayLink?
        private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        private var readyObservation: NSKeyValueObservation?
        private var lastURL: URL?

        /// `coverHost` is the cover rect; `contentLayer` inside it holds the image +
        /// video layers. Two levels because the two feather ramps have to nest: a
        /// layer takes exactly one mask, and a soft-edged rectangle factors into a
        /// vertical ramp times a horizontal one — the host masks vertically, this
        /// masks horizontally, and the corners fall out as the product for free.
        ///
        /// The feather lives here rather than on the view's root layer so the mirrored
        /// margins, which are siblings of `coverHost`, don't fade at the screen edge
        /// along with the cover.
        private let coverHost = CALayer()
        private let contentLayer = CALayer()
        private let vMask = CAGradientLayer()
        private let hMask = CAGradientLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.masksToBounds = true
            coverHost.frame = bounds
            layer?.addSublayer(coverHost)
            contentLayer.frame = coverHost.bounds
            contentLayer.masksToBounds = true
            coverHost.addSublayer(contentLayer)

            for ramp in [vMask, hMask] {
                // White-with-zero-alpha, not `.clear`: only alpha matters to a mask,
                // and `.clear` can arrive in a different colour space and ramp
                // through grey on the way out.
                ramp.colors = [NSColor.white.withAlphaComponent(0).cgColor,
                               NSColor.white.cgColor,
                               NSColor.white.cgColor,
                               NSColor.white.withAlphaComponent(0).cgColor]
                // Without this the implicit animation on these properties wipes the
                // ramp across the artwork on every layout pass.
                ramp.actions = ["locations": NSNull(), "position": NSNull(), "bounds": NSNull()]
            }
            vMask.startPoint = CGPoint(x: 0.5, y: 0)
            vMask.endPoint = CGPoint(x: 0.5, y: 1)
            hMask.startPoint = CGPoint(x: 0, y: 0.5)
            hMask.endPoint = CGPoint(x: 1, y: 0.5)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// Where the clip itself sits: the whole view, or the centred cover rect when
        /// this view is also drawing mirrored margins around it.
        private var coverRect: CGRect {
            guard let coverSize else { return bounds }
            return CGRect(x: ((bounds.width - coverSize.width) / 2).rounded(),
                          y: ((bounds.height - coverSize.height) / 2).rounded(),
                          width: coverSize.width, height: coverSize.height)
        }

        override func layout() {
            super.layout()
            updateGeometry()
        }

        /// Called straight from the setters as well as from `layout()`. Waiting for a
        /// layout pass left the mirrors on the *previous* track's cover geometry — the
        /// player layer is re-framed inside `load()` and gets the new rect immediately,
        /// so the two disagreed and the margin the stale mirror no longer reached went
        /// black.
        private func updateGeometry() {
            let cover = coverRect
            coverHost.frame = cover
            contentLayer.frame = coverHost.bounds
            playerLayer?.frame = contentLayer.bounds
            imageLayer?.frame = contentLayer.bounds
            layoutMirrors(around: cover)
            applyFeather()
        }

        // MARK: Mirrored margins

        /// Two copies of the cover rect, butted against the edges on whichever axis
        /// has room left, each flipped across that axis — so the column (or row) next
        /// to the join is the same one the cover ends on and the seam has nothing to
        /// give away. The far copy runs off-screen and is clipped.
        ///
        /// They reach `edgeFeather` *under* the cover rather than stopping at it: the
        /// cover's feathered edge fades to transparent, and this is what it fades into.
        /// Moving the reflection axis inward by the feather width puts the mirror's
        /// content out by at most twice that at the far end of the band — invisible
        /// under a blur several times wider.
        private func layoutMirrors(around cover: CGRect) {
            guard coverSize != nil else {
                mirrorLayers.forEach { $0.removeFromSuperlayer() }
                mirrorLayers = []
                return
            }
            let horizontal = cover.width < bounds.width
            let overlap = min(edgeFeather, horizontal ? cover.width / 2 : cover.height / 2)
            let step = horizontal ? cover.width - overlap : cover.height - overlap
            let offsets: [CGPoint] = horizontal
                ? [CGPoint(x: -step, y: 0), CGPoint(x: step, y: 0)]
                : [CGPoint(x: 0, y: -step), CGPoint(x: 0, y: step)]

            while mirrorLayers.count < offsets.count {
                let m = CALayer()
                m.contentsGravity = .resizeAspectFill
                m.masksToBounds = true
                // Below the cover — they only ever show where it doesn't reach or has
                // faded out.
                layer?.insertSublayer(m, below: coverHost)
                mirrorLayers.append(m)
            }
            while mirrorLayers.count > offsets.count {
                mirrorLayers.removeLast().removeFromSuperlayer()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (m, offset) in zip(mirrorLayers, offsets) {
                let rect = cover.offsetBy(dx: offset.x, dy: offset.y)
                // bounds + position, never `frame`: a layer's frame is derived from
                // those *through* its transform, so assigning it while the transform
                // is a -1 flip lands the layer somewhere else and the margin ends up
                // part transparent — which on the lock screen shows the desktop.
                m.bounds = CGRect(origin: .zero, size: rect.size)
                m.position = CGPoint(x: rect.midX, y: rect.midY)
                m.transform = CATransform3DMakeScale(horizontal ? -1 : 1, horizontal ? 1 : -1, 1)
            }
            CATransaction.commit()
        }

        /// AVPlayerLooper cycles through copies of the item, so the output has to
        /// follow `currentItem` or the margins freeze after the first loop.
        private func startMirrorFeed(on player: AVQueuePlayer) {
            guard coverSize != nil else { return }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            videoOutput = output
            itemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
                guard let self, let item = player.currentItem, item !== self.outputItem else { return }
                self.outputItem?.remove(output)
                item.add(output)
                self.outputItem = item
            }
            let link = displayLink(target: self, selector: #selector(pullMirrorFrame))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        /// One frame, downscaled hard before the gaussian — the margins are magnified
        /// blur, so full-resolution pixels would be thrown away twice over.
        @objc private func pullMirrorFrame() {
            guard let output = videoOutput, !mirrorLayers.isEmpty else { return }
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: time),
                  let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
            else { return }

            var image = CIImage(cvPixelBuffer: buffer)
            let scale = Self.mirrorWorkWidth / max(image.extent.width, 1)
            image = image.transformed(by: .init(scaleX: scale, y: scale))
            if mirrorBlur > 0 {
                let frame = image.extent
                image = image.clampedToExtent()
                    .applyingGaussianBlur(sigma: Double(mirrorBlur * scale / 2))
                    .cropped(to: frame)
            }
            guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
            // Actions off: `contents` has a default cross-fade, and at display rate
            // that smears every frame into the last one.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for m in mirrorLayers { m.contents = cg }
            CATransaction.commit()
        }

        private static let mirrorWorkWidth: CGFloat = 320

        private func stopMirrorFeed() {
            displayLink?.invalidate()
            displayLink = nil
            itemObservation?.invalidate()
            itemObservation = nil
            if let videoOutput { outputItem?.remove(videoOutput) }
            outputItem = nil
            videoOutput = nil
            // The last frame stays until the next clip's first one replaces it. Clearing
            // leaves the margins transparent for as long as the new clip takes to
            // start, and on the lock screen transparent means the desktop shows.
        }

        /// Only the edges that have a mirror beside them get feathered. With mirrors,
        /// the other two sides are up against the screen, and fading them there just
        /// bleeds the cover into black — which is what feathering all four looked like.
        /// Without mirrors (a thumbnail, the still card) all four fade, as before.
        private func applyFeather() {
            let cover = coverHost.bounds
            let mirrored = coverSize != nil
            let horizontal = cover.width < bounds.width
            let featherY = !mirrored || !horizontal
            let featherX = !mirrored || horizontal

            guard edgeFeather > 0, cover.width > 1, cover.height > 1 else {
                coverHost.mask = nil
                contentLayer.mask = nil
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            vMask.frame = cover
            hMask.frame = cover
            let fy = min(0.5, Double(edgeFeather / cover.height))
            let fx = min(0.5, Double(edgeFeather / cover.width))
            vMask.locations = [0, NSNumber(value: fy), NSNumber(value: 1 - fy), 1]
            hMask.locations = [0, NSNumber(value: fx), NSNumber(value: 1 - fx), 1]
            coverHost.mask = featherY ? vMask : nil
            contentLayer.mask = featherX ? hMask : nil
            CATransaction.commit()
        }

        func setStaticImage(_ image: NSImage?) {
            guard let image else {
                imageLayer?.removeFromSuperlayer()
                imageLayer = nil
                return
            }
            if imageLayer == nil {
                let il = CALayer()
                il.frame = bounds
                il.contentsGravity = gravity == .resizeAspectFill ? .resizeAspectFill : .resizeAspect
                il.masksToBounds = true
                contentLayer.insertSublayer(il, at: 0)
                imageLayer = il
            }
            imageLayer?.contents = image
        }

        func load(url: URL?) {
            guard url != lastURL else { return }
            lastURL = url
            cleanupPlayer()
            guard let url else { return }

            let resolved: URL
            if url.isFileURL {
                resolved = url
            } else if let cached = AnimatedArtworkCache.shared.localURLIfCached(for: url) {
                resolved = cached
            } else {
                // Not cached yet. Playing the remote mzstatic URL directly has no
                // directly-playable video track, so AVFoundation just spams
                // -12864/-12860 forever and never shows a frame (see Known issues).
                // Stay on the static image and play once the local file lands.
                AnimatedArtworkCache.shared.resolve(remote: url) { [weak self] localURL in
                    // resolve fires on the main queue, and only once the file is on disk.
                    guard let self, self.lastURL == url else { return }
                    self.lastURL = nil                // let load() proceed past its dedup guard
                    self.load(url: localURL)
                }
                return
            }

            let item = AVPlayerItem(url: resolved)
            let queue = AVQueuePlayer(playerItem: item)
            queue.isMuted = true
            queue.actionAtItemEnd = .none
            queue.automaticallyWaitsToMinimizeStalling = false
            let template = AVPlayerItem(url: resolved)
            let looper = AVPlayerLooper(player: queue, templateItem: template)
            coordinator?.queuePlayer = queue
            coordinator?.looper = looper

            let pl = AVPlayerLayer(player: queue)
            pl.frame = coverRect
            pl.videoGravity = gravity
            pl.opacity = 0
            contentLayer.addSublayer(pl)
            playerLayer = pl

            readyObservation = pl.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard let self, layer.isReadyForDisplay else { return }
                DispatchQueue.main.async { self.revealPlayer() }
            }

            startMirrorFeed(on: queue)
            updateGeometry()
            queue.play()
        }

        private func revealPlayer() {
            guard let pl = playerLayer, pl.opacity != 1 else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            pl.opacity = 1
            CATransaction.commit()

            if imageLayer != nil {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.25)
                CATransaction.setCompletionBlock { [weak self] in
                    self?.imageLayer?.removeFromSuperlayer()
                    self?.imageLayer = nil
                }
                imageLayer?.opacity = 0
                CATransaction.commit()
            }
        }

        private func cleanupPlayer() {
            stopMirrorFeed()
            readyObservation?.invalidate()
            readyObservation = nil
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            coordinator?.looper = nil
            coordinator?.queuePlayer?.pause()
            coordinator?.queuePlayer = nil
        }

        func cleanup() {
            cleanupPlayer()
            imageLayer?.removeFromSuperlayer()
            imageLayer = nil
        }
    }
}
