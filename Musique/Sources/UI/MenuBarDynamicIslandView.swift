import AppKit
import Combine

@MainActor
final class MenuBarDynamicIslandModel: ObservableObject {
    @Published var snapshot: NowPlayingSnapshot?
    @Published var artwork: NSImage?
    @Published var accent: NSColor?
    /// The wave bars, at 20 Hz (the monitor runs 30) and only when a bar would
    /// actually move: every change costs AppKit a re-snapshot of the status item
    /// per display, whether or not a pixel differs. That snapshot is AppKit's
    /// cost, not ours, so the rate is the only lever left on it.
    @Published var bands: [Float] = []

    private let monitor: PlayerMonitor
    private var cancellables = Set<AnyCancellable>()
    private var artworkTask: Task<Void, Never>?
    private var paletteTask: Task<Void, Never>?
    private var lastArtworkKey: String = ""

    init(monitor: PlayerMonitor) {
        self.monitor = monitor
        monitor.$snapshot
            .combineLatest(EditHistoryService.shared.$rules)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] raw, _ in
                guard let self else { return }
                let edited = raw.map { EditHistoryService.shared.apply($0) }
                self.snapshot = edited
                self.refreshArtwork(for: edited)
            }
            .store(in: &cancellables)

        MusicAudioLevelMonitor.shared.$bands
            .map(MenuBarIslandRenderer.quantized)
            .removeDuplicates()
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.bands = $0 }
            .store(in: &cancellables)

        // The user can change a track's custom artwork while it's already
        // playing; our key (title|artist|album) is unchanged, so force a
        // re-resolve when that happens.
        NotificationCenter.default.publisher(for: CustomArtworkStore.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.lastArtworkKey = ""
                self.refreshArtwork(for: self.snapshot)
            }
            .store(in: &cancellables)
    }

    private func refreshArtwork(for snap: NowPlayingSnapshot?) {
        guard let snap, snap.hasTrack else {
            artworkTask?.cancel()
            paletteTask?.cancel()
            artwork = nil
            accent = nil
            lastArtworkKey = ""
            return
        }
        let key = "\(snap.title)|\(snap.artist)|\(snap.album)"
        if key == lastArtworkKey { return }
        lastArtworkKey = key
        artworkTask?.cancel()
        paletteTask?.cancel()

        // User-chosen artwork wins over the looked-up cover.
        if let customURL = CustomArtworkStore.shared.localURL(for: snap) {
            applyCustomArtwork(customURL, key: key)
            return
        }

        let title = snap.title
        let artist = snap.artist
        let album = snap.album
        artworkTask = Task { [weak self] in
            let result = await ArtworkService.shared.lookup(title: title, artist: artist, album: album)
            guard !Task.isCancelled else { return }
            guard let urlString = result.artworkURL, let url = URL(string: urlString) else {
                await MainActor.run {
                    self?.artwork = nil
                    self?.accent = nil
                }
                return
            }
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let image = Self.thumbnail(data) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if self?.lastArtworkKey == key {
                        self?.artwork = image
                    }
                }
            }
            let palette = await ColorExtractor.shared.palette(for: urlString)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.lastArtworkKey == key {
                    self?.accent = palette.accent
                }
            }
        }
    }

    /// The pill shows the cover at 18pt, but AppKit re-renders the status item
    /// on every wave-bar tick (30 Hz) — a full-size JPEG was re-decoded each time
    /// and starved the main thread. Decode once, at the size actually drawn.
    nonisolated static func thumbnail(_ data: Data) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func applyCustomArtwork(_ url: URL, key: String) {
        let urlString = url.absoluteString
        artworkTask = Task { [weak self] in
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let image = Self.thumbnail(data) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if self?.lastArtworkKey == key { self?.artwork = image }
                }
            }
            let palette = await ColorExtractor.shared.palette(for: urlString)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.lastArtworkKey == key { self?.accent = palette.accent }
            }
        }
    }
}

/// The dynamic-island pill, drawn with AppKit into the status button's image.
///
/// It used to be a SwiftUI view hosted in the button. AppKit snapshots a status
/// item once per menu bar (per display) on every change, setting that bar's
/// appearance first — which re-ran SwiftUI's environment, graph and layout each
/// time. With the wave bars ticking that was ~45 ms a tick and half the main
/// thread; every animation in the app dropped frames. A drawing handler costs
/// one small CoreGraphics pass, and resolves `labelColor` per bar on its own.
@MainActor
enum MenuBarIslandRenderer {
    static let height: CGFloat = 22
    private static let outer: CGFloat = 3
    private static let inner: CGFloat = 12
    private static let gap: CGFloat = 14
    private static let art: CGFloat = 18
    private static let barCount = 7
    /// How far a bar grows at full level, in points.
    private static let barTravel: CGFloat = 7.5

    /// The levels the bars can show: the drawn ones only, snapped to half-point
    /// steps of bar height (a pixel on Retina). Ticks that round to the same
    /// bars are dropped before they reach the status item.
    nonisolated static func quantized(_ bands: [Float]) -> [Float] {
        let steps = Float(barTravel * 2)
        return bands.prefix(barCount).map { (min(1, max(0, $0)) * steps).rounded() / steps }
    }
    private static let barW: CGFloat = 2
    private static let barGap: CGFloat = 1.5
    private static var wavesW: CGFloat { CGFloat(barCount) * barW + CGFloat(barCount - 1) * barGap }

    /// The pill, plus where the play/pause glyph sits in it (top-left origin,
    /// image coordinates) so the controller can hit-test clicks on it.
    static func render(snapshot: NowPlayingSnapshot?, artwork: NSImage?, accent: NSColor?,
                       bands: [Float], showState: Bool) -> (image: NSImage, playRect: CGRect) {
        let hasTrack = snapshot?.hasTrack == true
        let isPlaying = snapshot?.isPlaying == true
        let glyph = hasTrack && showState ? stateGlyph(playing: isPlaying) : nil
        let label = hasTrack ? nil : NSAttributedString(string: "Musique", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])

        var x = outer + inner + art + gap
        var playRect = CGRect.zero
        if let glyph {
            playRect = CGRect(x: x, y: (height - glyph.size.height) / 2,
                              width: glyph.size.width, height: glyph.size.height)
            x += glyph.size.width + gap
        }
        x += label.map { ceil($0.size().width) } ?? (hasTrack ? wavesW : 0)
        let size = NSSize(width: x + inner + outer, height: height)

        // Everything but the bars only changes with the track, so it's drawn
        // once per appearance and kept as a bitmap; a wave tick then costs one
        // image blit and seven rects. AppKit runs this handler for the button and
        // again for every menu bar's replicant, 30 times a second.
        let key = "\(size)|\(hasTrack)|\(isPlaying)|\(showState)|\(accent?.description ?? "-")|"
            + "\(artwork.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-")"
        if backgroundKey != key { backgroundKey = key; backgrounds = [:] }

        let image = NSImage(size: size, flipped: true) { rect in
            let appearance = NSAppearance.currentDrawing().name
            let background = backgrounds[appearance] ?? rasterize(size: size) {
                let pill = NSRect(x: outer, y: 0, width: size.width - outer * 2, height: height)
                let tint = accent ?? .labelColor
                tint.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
                let rim = NSBezierPath(roundedRect: pill.insetBy(dx: 0.4, dy: 0.4), xRadius: 10.6, yRadius: 10.6)
                rim.lineWidth = 0.8
                tint.withAlphaComponent(0.55).setStroke()
                rim.stroke()

                drawArtwork(artwork, in: NSRect(x: outer + inner, y: (height - art) / 2, width: art, height: art))
                glyph?.draw(in: playRect, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
                if let label {
                    let h = label.size().height
                    label.draw(at: NSPoint(x: outer + inner + art + gap, y: (height - h) / 2))
                }
            }
            backgrounds[appearance] = background
            background.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
            if label == nil, hasTrack {
                drawWaves(bands: bands, playing: isPlaying, originX: size.width - outer - inner - wavesW)
            }
            return true
        }
        return (image, playRect)
    }

    private static var backgroundKey = ""
    private static var backgrounds: [NSAppearance.Name: NSImage] = [:]

    /// Draws `body` (flipped, in points) into a 2x bitmap under the current
    /// drawing appearance, so dynamic colours resolve for this menu bar.
    private static func rasterize(size: NSSize, _ body: () -> Void) -> NSImage {
        let scale: CGFloat = 2
        guard let cg = CGContext(data: nil, width: Int(ceil(size.width * scale)),
                                 height: Int(ceil(size.height * scale)), bitsPerComponent: 8,
                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: size) }
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
        guard let made = cg.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: made, size: size)
    }

    private static let playGlyph = makeStateGlyph(playing: true)
    private static let pauseGlyph = makeStateGlyph(playing: false)
    private static func stateGlyph(playing: Bool) -> NSImage? { playing ? playGlyph : pauseGlyph }

    private static func makeStateGlyph(playing: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(.init(paletteColors: [.labelColor]))
        return NSImage(systemSymbolName: playing ? "play.fill" : "pause.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private static func drawArtwork(_ image: NSImage?, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).addClip()
        if let image, image.size.width > 0, image.size.height > 0 {
            // Aspect fill.
            let scale = max(rect.width / image.size.width, rect.height / image.size.height)
            let w = image.size.width * scale, h = image.size.height * scale
            image.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h),
                       from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium.rawValue])
        } else {
            NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
            rect.fill()
            let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
                    .applying(.init(paletteColors: [.secondaryLabelColor])))
            if let note {
                note.draw(in: NSRect(x: rect.midX - note.size.width / 2, y: rect.midY - note.size.height / 2,
                                     width: note.size.width, height: note.size.height),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawWaves(bands: [Float], playing: Bool, originX: CGFloat) {
        NSColor.labelColor.setFill()
        var x = originX
        for i in 0..<barCount {
            var h: CGFloat = 2.5
            if playing, i < bands.count { h += CGFloat(min(1, max(0, bands[i]))) * barTravel }
            NSBezierPath(roundedRect: NSRect(x: x, y: (height - h) / 2, width: barW, height: h),
                         xRadius: barW / 2, yRadius: barW / 2).fill()
            x += barW + barGap
        }
    }
}
