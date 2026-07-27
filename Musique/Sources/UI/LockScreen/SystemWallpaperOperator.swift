import AppKit
import CoreImage
import os

/// Swaps the macOS desktop wallpaper to the now-playing artwork while the
/// screen is locked, then restores the user's original on unlock. The lock
/// screen renders the desktop wallpaper, so changing it is what shows the
/// artwork behind the lock UI.
///
/// Uses the supported `NSWorkspace.setDesktopImageURL(_:for:)` API — it forces
/// an immediate repaint, unlike rewriting the private wallpaper store + bouncing
/// `WallpaperAgent`, which writes the file but never re-renders.
///
/// `apply` must only ever run *while locked* (the caller enforces this) and
/// `restore` before the desktop is visible again, otherwise the artwork would
/// show on the user's real desktop. The original per-display URLs are backed up
/// to disk so a crash mid-lock is recovered on next launch instead of leaving
/// the artwork stuck as the wallpaper.
@MainActor
final class SystemWallpaperOperator {
    static let shared = SystemWallpaperOperator()

    private let log = Logger(subsystem: "com.nopxx.musique", category: "Wallpaper")
    private let fm = FileManager.default
    private let backupURL: URL
    /// Two artwork files we alternate between. `setDesktopImageURL` caches by
    /// URL and won't re-read a path it already shows, so each apply must hand it
    /// a *different* URL — hence A/B ping-pong instead of one fixed filename.
    private let artworkA: URL
    private let artworkB: URL
    private var useA = false
    /// Blur + jpeg encode run here so a large artwork doesn't stall main.
    private let renderQueue = DispatchQueue(label: "com.nopxx.musique.wallpaper")

    /// Original desktop image URL per display, captured before the first swap.
    /// Mirrored to `backupURL` on disk for crash recovery.
    private var savedURLs: [CGDirectDisplayID: URL] = [:]

    /// Last pre-rendered wallpaper file + the key it was rendered for. Lets
    /// `apply` skip the (slow) blur+encode when the artwork is already prepared.
    private var readyURL: URL?
    private var readyKey: String?

    private init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("Musique", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        backupURL = dir.appendingPathComponent("wallpaper-backup.plist")
        artworkA = dir.appendingPathComponent("lockscreen-wallpaper-a.jpg")
        artworkB = dir.appendingPathComponent("lockscreen-wallpaper-b.jpg")
    }

    /// A backup left on disk means a previous session swapped the wallpaper but
    /// never restored it (crash / force-quit while locked). Call once at launch.
    func recoverIfNeeded() {
        guard savedURLs.isEmpty else { return }
        if let disk = loadBackup() {
            log.info("Stale wallpaper backup found — restoring user's wallpaper")
            savedURLs = disk
            restore()
            return
        }
        // No backup, but a session that died mid-swap can still have left our
        // artwork on the desktop with no record of what it replaced. Fall back to
        // the image macOS's own wallpaper store holds, so the desktop isn't
        // stranded on a blurred still forever.
        let stranded = NSScreen.screens.filter { screen in
            NSWorkspace.shared.desktopImageURL(for: screen).map(isOurArtwork) == true
        }
        guard !stranded.isEmpty else { return }
        guard let real = MotionWallpaperStore.realImageFromStore() else {
            log.error("Desktop stranded on our artwork and no backup or store image to recover from")
            return
        }
        log.info("Desktop stranded on our artwork — recovering \(stranded.count) screen(s) from the wallpaper store")
        for screen in stranded { setDesktop(real, for: screen) }
    }

    /// Pre-render the wallpaper file for `key` in the background so a later
    /// `apply(key:)` is instant. Cheap no-op if already prepared for `key`.
    /// Call while locked as the artwork lands, before the user taps.
    func prepare(image: NSImage, blurRadius: Double = 0, key: String) {
        guard key != readyKey else { return }
        render(image, blurRadius: blurRadius, key: key)
    }

    /// Set the desktop wallpaper of every screen to `image` (optionally blurred).
    /// Uses the pre-rendered file when `key` matches `prepare`, so the swap lands
    /// with the enlarge animation instead of after a blur+encode delay.
    func apply(image: NSImage, blurRadius: Double = 0, key: String) {
        // Never replace the wallpaper unless the real one is recorded — otherwise
        // a restore would have nothing to put back and the user's picture is gone.
        guard captureOriginalsIfNeeded() else {
            log.error("apply — no restorable wallpaper captured; leaving the desktop alone")
            return
        }
        if key == readyKey, let url = readyURL {
            setAll(to: url)
        } else {
            render(image, blurRadius: blurRadius, key: key) { [weak self] url in
                self?.setAll(to: url)
            }
        }
    }

    /// Blur + jpeg-encode `image` to the next A/B file off-main, then cache it as
    /// `readyURL`/`readyKey`. `setDesktopImageURL` caches by URL and won't re-read
    /// a path it already shows, so we alternate two filenames per render.
    private func render(_ image: NSImage, blurRadius: Double, key: String,
                        completion: ((URL) -> Void)? = nil) {
        useA.toggle()
        let dest = useA ? artworkA : artworkB
        renderQueue.async { [weak self] in
            guard let self else { return }
            let rendered = blurRadius > 0 ? (image.blurred(radius: blurRadius) ?? image) : image
            guard let jpg = rendered.jpegData() else {
                self.log.error("render — could not encode artwork to jpeg")
                return
            }
            do { try jpg.write(to: dest) } catch {
                self.log.error("render — jpeg write failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            DispatchQueue.main.async {
                self.readyURL = dest
                self.readyKey = key
                completion?(dest)
            }
        }
    }

    /// Put every display's original wallpaper back, if we changed it.
    func restore() {
        guard !savedURLs.isEmpty else { return }
        for screen in NSScreen.screens {
            guard let id = displayID(screen), let url = savedURLs[id] else { continue }
            setDesktop(url, for: screen)
        }
        savedURLs.removeAll()
        try? fm.removeItem(at: backupURL)
        log.info("Wallpaper restored")
    }

    // MARK: - Internals

    /// Record each display's real wallpaper before the first swap. Returns false if
    /// nothing restorable was found, in which case the caller must not swap.
    ///
    /// Screens already showing one of *our* artwork files are skipped: a session
    /// that died without restoring leaves them there, and capturing that as the
    /// "original" is how the user's real picture gets lost for good — restore then
    /// puts our own blurred artwork back forever.
    @discardableResult
    private func captureOriginalsIfNeeded() -> Bool {
        guard savedURLs.isEmpty else { return true }
        var captured: [CGDirectDisplayID: URL] = [:]
        for screen in NSScreen.screens {
            guard let id = displayID(screen),
                  let url = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            guard !isOurArtwork(url) else {
                log.error("capture — display \(id) already shows our artwork; a prior session never restored it")
                continue
            }
            captured[id] = url
        }
        guard !captured.isEmpty else { return false }
        savedURLs = captured
        writeBackup(savedURLs)
        return true
    }

    /// True if `url` is a file Musique wrote (an artwork still, a staged motion
    /// clip) rather than a real user wallpaper. Whole-directory rather than just
    /// the A/B pair, so a still left by an older build — or the motion wallpaper —
    /// can't be captured as the "original" either.
    private func isOurArtwork(_ url: URL) -> Bool {
        MotionWallpaperStore.isMusiqueFile(url)
    }

    private func setAll(to url: URL) {
        for screen in NSScreen.screens { setDesktop(url, for: screen) }
    }

    private func setDesktop(_ url: URL, for screen: NSScreen) {
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        } catch {
            log.error("setDesktopImageURL failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    // Backup is a plain [displayID: fileURLString] plist.
    private func writeBackup(_ map: [CGDirectDisplayID: URL]) {
        let plain = Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value.absoluteString) })
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plain, format: .binary, options: 0) else { return }
        try? data.write(to: backupURL)
    }

    private func loadBackup() -> [CGDirectDisplayID: URL]? {
        guard let data = try? Data(contentsOf: backupURL),
              let plain = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: String] else { return nil }
        var map: [CGDirectDisplayID: URL] = [:]
        for (k, v) in plain {
            if let id = CGDirectDisplayID(k), let url = URL(string: v) { map[id] = url }
        }
        return map.isEmpty ? nil : map
    }
}

private extension NSImage {
    func jpegData(compression: CGFloat = 0.9) -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }

    /// Gaussian-blurred copy. Clamps first so edges don't fade to transparent,
    /// then crops back to the original extent.
    func blurred(radius: Double) -> NSImage? {
        guard let tiff = tiffRepresentation,
              let ci = CIImage(data: tiff) else { return nil }
        let extent = ci.extent
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        blur.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(output, from: extent) else { return nil }
        return NSImage(cgImage: cg, size: extent.size)
    }
}
