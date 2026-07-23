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
            guard let self, running, let reader = try? AVAssetReader(asset: asset) else {
                onFirstFrameReady?(); return
            }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            reader.startReading()
            self.reader = reader
            self.output = out
            ptsOffset = .zero
            lastEnd = .zero

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
            self.loadAndSwap(url: url)
        }
    }

    /// Re-read the current clip *file* in place — the host overwrites it atomically
    /// (same path, new inode) and pings us, so we swap to the new content without
    /// forcing WallpaperAgent to reload the whole desktop.
    /// ponytail: relies on a fresh AVURLAsset re-reading the swapped inode; if a
    /// same-path clip ever fails to refresh, stage under versioned filenames instead.
    func reload() {
        queue.async { [weak self] in
            guard let self, running else { return }
            self.loadAndSwap(url: asset.url)
        }
    }

    /// Load `url`'s video track and swap the reader over to it. Must run on `queue`.
    private func loadAndSwap(url: URL) {
        let newAsset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var loaded: AVAssetTrack?
        newAsset.loadTracks(withMediaType: .video) { tracks, _ in loaded = tracks?.first; sem.signal() }
        sem.wait()
        guard let newTrack = loaded else { return }

        renderer.stopRequestingMediaData()
        reader?.cancelReading()
        asset = newAsset
        track = newTrack
        CMTimebaseSetRate(timebase, rate: 0.0)
        renderer.flush(removingDisplayedImage: false)   // keep last frame until first new one
        ptsOffset = .zero; lastEnd = .zero
        CMTimebaseSetTime(timebase, time: .zero)

        guard let r = try? AVAssetReader(asset: newAsset) else { return }
        let out = AVAssetReaderTrackOutput(track: newTrack, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        r.add(out); r.startReading()
        reader = r; output = out
        if let first = out.copyNextSampleBuffer() {
            setDisplayImmediately(first)
            renderer.enqueue(first)
            noteEnd(of: first)
        }
        CMTimebaseSetRate(timebase, rate: paused ? 0.0 : 1.0)
        feed()
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
    private func restartLoop() {
        guard running, let r = try? AVAssetReader(asset: asset) else { return }
        ptsOffset = lastEnd
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        r.add(out); r.startReading()
        reader = r; output = out
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
