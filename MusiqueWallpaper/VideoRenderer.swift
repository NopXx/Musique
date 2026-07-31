import AVFoundation
import CoreMedia
import QuartzCore

/// Plays a looping video into an `AVSampleBufferDisplayLayer`, driven by an
/// `AVAssetReader`. This layer type is required: a plain `CALayer.contents` or
/// `AVPlayerLayer` composites as solid black through a *remote* CAContext — only
/// the IOSurface-backed sample-buffer layer reaches WallpaperAgent's compositor.
///
/// All mutable state is confined to the serial `queue`; the public entry points
/// hop onto it, which is why `@unchecked Sendable` is sound here.
final class VideoRenderer: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private let queue = DispatchQueue(label: "com.nopxx.musique.wallpaper.render", qos: .userInitiated)

    private var asset: AVURLAsset
    private var track: AVAssetTrack
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var running = true
    private var paused = false

    // Gapless-loop bookkeeping: PTS/DTS of every sample is shifted forward by
    // `ptsOffset` so the timeline stays monotonic across loop boundaries.
    // ponytail: recreates one reader per loop (no preloaded next reader). Fine
    // for short artwork clips; add a preloaded reader if loop seams stutter.
    private var ptsOffset: CMTime = .zero
    private var lastEnd: CMTime = .zero

    /// Bumped on every swap request. A track load that finishes after a newer
    /// swap started is dropped, so two reloads in flight can't land out of order
    /// and leave the older clip on screen.
    private var swapGeneration: UInt64 = 0

    static func create(rootLayer: CALayer, videoURL: URL) async throws -> VideoRenderer {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.frame = rootLayer.bounds
        layer.contentsScale = rootLayer.contentsScale
        layer.isOpaque = true
        setDisallowsVideoLayerDisplayCompositing(layer, true)
        return VideoRenderer(rootLayer: rootLayer, layer: layer, asset: asset, track: track)
    }

    private init(rootLayer: CALayer, layer: AVSampleBufferDisplayLayer, asset: AVURLAsset, track: AVAssetTrack) {
        self.displayLayer = layer
        self.renderer = layer.sampleBufferRenderer
        self.asset = asset
        self.track = track

        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        self.timebase = tb!
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0.0)   // held until start()
        layer.controlTimebase = timebase

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(layer)
        CATransaction.commit()
        CATransaction.flush()   // push the tree to the render server for the remote context
    }

    /// Begin playback. `onFirstFrameReady` fires once the first frame is enqueued
    /// and flushed, so the acquire reply can be deferred until the context is
    /// actually showing video (no black flash on the host swap).
    func start(onFirstFrameReady: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, running else { onFirstFrameReady?(); return }
            ptsOffset = .zero
            lastEnd = .zero
            guard let out = startReading(asset: asset, track: track) else {
                extLog("start: could not read \(asset.url.lastPathComponent)")
                onFirstFrameReady?(); return
            }

            CMTimebaseSetTime(timebase, time: .zero)
            if let first = out.copyNextSampleBuffer() {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                renderer.enqueue(first)
                CATransaction.commit(); CATransaction.flush()
                noteEnd(of: first)
            }
            CMTimebaseSetRate(timebase, rate: 1.0)
            onFirstFrameReady?()
            feed()
        }
    }

    /// Swap to a different clip in place, reusing the hosted layer (a fresh layer
    /// added to an already-hosted context does not composite).
    func switchVideo(to url: URL) {
        queue.async { [weak self] in
            guard let self, running, asset.url != url else { return }
            self.loadTrackThenSwap(url: url)
        }
    }

    /// Load `url`'s video track, then hop back onto `queue` to swap the reader over.
    /// The load deliberately runs *off* the render queue: blocking `queue` on it
    /// meant a stalled or corrupt clip wedged the queue forever, which also
    /// deadlocked `stop()`'s `queue.sync` and with it the XPC invalidate path.
    /// Must be called on `queue`.
    private func loadTrackThenSwap(url: URL) {
        swapGeneration &+= 1
        let generation = swapGeneration
        let newAsset = AVURLAsset(url: url)
        newAsset.loadTracks(withMediaType: .video) { [weak self] tracks, error in
            guard let self else { return }
            guard let newTrack = tracks?.first else {
                extLog("swap: no video track in \(url.lastPathComponent) — \(error?.localizedDescription ?? "unknown"); keeping current clip")
                return
            }
            queue.async { [weak self] in
                guard let self, running, generation == swapGeneration else { return }
                swap(to: newAsset, track: newTrack)
            }
        }
    }

    /// Point the reader at a new asset. If it can't be read, the previous clip is
    /// kept playing rather than leaving the surface frozen on a stopped timebase.
    /// Must run on `queue`.
    private func swap(to newAsset: AVURLAsset, track newTrack: AVAssetTrack) {
        let previousAsset = asset
        let previousTrack = track

        renderer.stopRequestingMediaData()
        reader?.cancelReading()
        CMTimebaseSetRate(timebase, rate: 0.0)
        renderer.flush(removingDisplayedImage: false)   // keep last frame until first new one
        ptsOffset = .zero; lastEnd = .zero
        CMTimebaseSetTime(timebase, time: .zero)

        asset = newAsset
        track = newTrack
        guard let out = startReading(asset: newAsset, track: newTrack) else {
            extLog("swap: reader failed for \(newAsset.url.lastPathComponent) — resuming previous clip")
            asset = previousAsset
            track = previousTrack
            restartLoop()
            return
        }
        if let first = out.copyNextSampleBuffer() {
            setDisplayImmediately(first)
            renderer.enqueue(first)
            noteEnd(of: first)
        }
        CMTimebaseSetRate(timebase, rate: paused ? 0.0 : 1.0)
        feed()
    }

    /// Build and start a reader/output pair, storing them as the current ones.
    /// Returns nil if the asset can't be read right now — the host overwrites the
    /// staged clip in place, so this can fail transiently mid-replace.
    /// Must run on `queue`.
    @discardableResult
    private func startReading(asset: AVURLAsset, track: AVAssetTrack) -> AVAssetReaderTrackOutput? {
        guard let r = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return nil }
        r.add(out)
        guard r.startReading() else { return nil }
        reader = r
        output = out
        return out
    }

    func pause() { queue.async { [weak self] in guard let self, !paused else { return }; paused = true; CMTimebaseSetRate(timebase, rate: 0.0) } }
    func resume() { queue.async { [weak self] in guard let self, paused else { return }; paused = false; CMTimebaseSetRate(timebase, rate: 1.0) } }

    func stop() {
        queue.sync {
            running = false
            renderer.stopRequestingMediaData()
            reader?.cancelReading()
        }
        displayLayer.removeFromSuperlayer()
    }

    // MARK: - Feed loop

    private func feed() {
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self, running else { self?.renderer.stopRequestingMediaData(); return }
            if renderer.status == .failed {
                renderer.stopRequestingMediaData()
                queue.async { [weak self] in self?.restartLoop() }
                return
            }
            if renderer.requiresFlushToResumeDecoding { renderer.flush() }
            while renderer.isReadyForMoreMediaData {
                guard let sample = output?.copyNextSampleBuffer() else {
                    // Reader exhausted → loop from the top, continuing the timeline.
                    renderer.stopRequestingMediaData()
                    queue.async { [weak self] in self?.restartLoop() }
                    return
                }
                let shifted = offsetTiming(sample)
                noteEnd(of: shifted)
                renderer.enqueue(shifted)
            }
        }
    }

    /// Rebuild the reader for the next loop iteration, carrying `ptsOffset` forward
    /// so the display timeline never jumps backward.
    ///
    /// A reader can transiently fail to open while the host is replacing the staged
    /// clip, so retry a few times before giving up — bailing out on the first
    /// failure just stopped the feed loop and froze the wallpaper on its last frame
    /// with nothing to restart it.
    private func restartLoop(attempt: Int = 0) {
        guard running else { return }
        ptsOffset = lastEnd
        guard startReading(asset: asset, track: track) != nil else {
            guard attempt < 5 else {
                extLog("loop: gave up re-reading \(asset.url.lastPathComponent) after \(attempt) attempts")
                return
            }
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restartLoop(attempt: attempt + 1)
            }
            return
        }
        feed()
    }

    private func noteEnd(of sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }
        let dur = CMSampleBufferGetDuration(sample)
        let end = (dur.isValid && dur > .zero) ? CMTimeAdd(pts, dur) : CMTimeAdd(pts, CMTime(value: 1, timescale: 60))
        if end > lastEnd { lastEnd = end }
    }

    private func offsetTiming(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard ptsOffset > .zero else { return sample }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        var info = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: pts.isValid ? CMTimeAdd(pts, ptsOffset) : pts,
            decodeTimeStamp: dts.isValid ? CMTimeAdd(dts, ptsOffset) : .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &info, sampleBufferOut: &copy)
        return copy ?? sample
    }
}

/// Show a sample the instant it decodes, regardless of the control timebase —
/// used for the first frame of a switch so the swap is immediate.
private func setDisplayImmediately(_ sample: CMSampleBuffer) {
    guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return }
    for i in 0 ..< CFArrayGetCount(arr) {
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, i), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

/// Private AVSBDL setter Apple uses to stop the layer painting opaque black
/// before its first frame. Resolved dynamically; a no-op if it ever disappears.
private func setDisallowsVideoLayerDisplayCompositing(_ layer: CALayer, _ flag: Bool) {
    let sel = NSSelectorFromString("_setDisallowsVideoLayerDisplayCompositing:")
    guard layer.responds(to: sel), let imp = class_getMethodImplementation(type(of: layer), sel) else { return }
    typealias Fn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
    unsafeBitCast(imp, to: Fn.self)(layer, sel, ObjCBool(flag))
}
