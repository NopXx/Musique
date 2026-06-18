import SwiftUI
import AVKit

struct AnimatedArtworkView: NSViewRepresentable {
    let url: URL?
    var staticImage: NSImage? = nil
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 0

    enum ContentMode { case fill, fit }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        view.cornerRadius = cornerRadius
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
            didSet { layer?.cornerRadius = cornerRadius }
        }
        var gravity: AVLayerVideoGravity = .resizeAspectFill {
            didSet {
                playerLayer?.videoGravity = gravity
                imageLayer?.contentsGravity = gravity == .resizeAspectFill ? .resizeAspectFill : .resizeAspect
            }
        }
        private var playerLayer: AVPlayerLayer?
        private var imageLayer: CALayer?
        private var readyObservation: NSKeyValueObservation?
        private var lastURL: URL?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.masksToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            playerLayer?.frame = bounds
            imageLayer?.frame = bounds
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
                layer?.insertSublayer(il, at: 0)
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
                resolved = url
                AnimatedArtworkCache.shared.resolve(remote: url) { [weak self] _ in
                    // Cache populated for next playback; no live swap to avoid disrupting loop.
                    _ = self
                }
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
            pl.frame = bounds
            pl.videoGravity = gravity
            pl.opacity = 0
            layer?.addSublayer(pl)
            playerLayer = pl

            readyObservation = pl.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                guard let self, layer.isReadyForDisplay else { return }
                DispatchQueue.main.async { self.revealPlayer() }
            }

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
