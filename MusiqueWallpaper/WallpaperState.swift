import QuartzCore
import Foundation

/// Identifies one hosted wallpaper surface. WallpaperAgent hosts several against
/// the same display (the live desktop, the lock screen, a Settings preview), each
/// with its own WallpaperID; giving each its own CAContext stops one surface from
/// stealing another's and blacking it out. Falls back to display id when an
/// acquire carries no WallpaperID.
struct SurfaceKey: Hashable {
    let displayID: UInt32
    let surfaceUUID: UUID
}

/// One live wallpaper surface: its remote context plus the renderer feeding it.
final class Surface {
    let context: AnyObject          // CAContext
    let contextId: UInt32
    let rootLayer: CALayer
    var renderer: VideoRenderer?
    var videoID: String?

    init(context: AnyObject, contextId: UInt32, rootLayer: CALayer) {
        self.context = context
        self.contextId = contextId
        self.rootLayer = rootLayer
    }
}

/// Process-wide, lock-guarded. Touched from the XPC lifecycle queue and the
/// renderer/update paths.
///
/// ponytail: one `VideoRenderer` — and so one AVAssetReader and one decode — per
/// surface, even though every surface plays the identical clip. With several
/// displays that is N hardware decodes of the same file. Suspended surfaces are
/// paused, which caps the waste at the number of *visible* displays. Sharing a
/// single reader that fans its sample buffers out to each layer would remove the
/// rest, at the cost of per-sink backpressure and timebase syncing; do that only
/// if the duplicate decodes ever show up in a profile.
final class WallpaperState: @unchecked Sendable {
    static let shared = WallpaperState()
    private init() {}

    private let lock = NSLock()
    private var surfaces: [SurfaceKey: Surface] = [:]

    /// Last presentation mode WallpaperAgent reported ("default", "locked", …).
    var presentationMode = "default"

    /// The mode WallpaperAgent reports for a surface that isn't on screen — a
    /// sleeping display, a covered surface. Decoding through it burns CPU for
    /// nothing. Deliberately *not* "locked": this wallpaper exists to be visible
    /// behind the lock screen.
    static let suspendedMode = "suspended"

    func surface(for key: SurfaceKey) -> Surface? {
        lock.lock(); defer { lock.unlock() }
        return surfaces[key]
    }

    func install(_ surface: Surface, for key: SurfaceKey) {
        lock.lock(); defer { lock.unlock() }
        surfaces[key] = surface
    }

    func removeSurface(for key: SurfaceKey) -> Surface? {
        lock.lock(); defer { lock.unlock() }
        return surfaces.removeValue(forKey: key)
    }

    func eachRenderer(_ body: (VideoRenderer) -> Void) {
        lock.lock()
        let renderers = surfaces.values.compactMap(\.renderer)
        lock.unlock()
        renderers.forEach(body)
    }

    var surfaceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return surfaces.count
    }
}
