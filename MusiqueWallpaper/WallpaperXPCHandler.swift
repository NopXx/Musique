import AVFoundation
import Foundation
import QuartzCore

/// Serves the wallpaper lifecycle over XPC. WallpaperAgent calls `acquire` to get
/// a hosted surface, `update` on presentation-mode changes (desktop ↔ lock),
/// `invalidate` when a surface goes away. Everything is funnelled through one
/// serial queue so an invalidate can't interleave with the two halves of an
/// acquire.
final class WallpaperXPCHandler: NSObject, WallpaperHostedXPC {
    static let queue = DispatchQueue(label: "com.nopxx.musique.wallpaper.lifecycle")
    var connectionPID: Int32 = -1

    // MARK: Lifecycle

    func acquire(withId id: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        nonisolated(unsafe) let uid = id, ureq = request
        Self.queue.async { [weak self] in self?.acquireBody(id: uid, request: ureq, reply: reply) }
    }

    private func acquireBody(id: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        var destSize = CGSize(width: 2560, height: 1440)
        var scale: CGFloat = 2.0
        var displayID: UInt32 = 0
        if let size = mirrorFind("size", in: request as Any) as? CGSize { destSize = size }
        if let sf = mirrorFind("scaleFactor", in: request as Any) as? CGFloat { scale = sf }
        if let did = mirrorFind("directDisplayID", in: request as Any) as? UInt32 { displayID = did }

        let choice = (mirrorFind("configuration", in: request as Any) as? Data).flatMap { String(data: $0, encoding: .utf8) }
        let files = mirrorFind("files", in: request as Any) as? [URL] ?? []
        let videoURL = files.first(where: { $0.pathExtension == "mov" || $0.pathExtension == "mp4" })
            ?? WallpaperPaths.videoURL(forChoice: choice)

        let surfaceUUID = extractUUID(from: id) ?? deterministicUUID(displayID)
        let key = SurfaceKey(displayID: displayID, surfaceUUID: surfaceUUID)
        extLog("acquire pid=\(connectionPID) display=\(displayID) choice=\(choice ?? "nil") video=\(videoURL?.lastPathComponent ?? "nil")")

        // Reuse the surface's persistent context so the host never drops its host
        // (no gray gap); only swap the clip if the choice actually changed.
        if let existing = WallpaperState.shared.surface(for: key) {
            reply(makeRemoteContextXPC(contextId: existing.contextId), nil)
            guard let videoURL, existing.videoID != choice else { return }
            if let renderer = existing.renderer {
                renderer.switchVideo(to: videoURL)
                existing.videoID = choice
            } else {
                createRenderer(for: existing, url: videoURL, choice: choice, key: key, onReady: nil)
            }
            return
        }

        // First acquire for this surface: mint a remote context.
        guard let ctxRaw = CAContext.remoteContext() as? CAContext, ctxRaw.contextId != 0 else {
            reply(nil, NSError(domain: "MusiqueWallpaper", code: 1))
            return
        }
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: destSize)
        rootLayer.contentsScale = scale
        rootLayer.contentsGravity = .resizeAspectFill
        ctxRaw.layer = rootLayer
        CATransaction.flush()

        let surface = Surface(context: ctxRaw, contextId: ctxRaw.contextId, rootLayer: rootLayer)
        surface.videoID = choice
        WallpaperState.shared.install(surface, for: key)

        guard let videoURL else {
            reply(makeRemoteContextXPC(contextId: ctxRaw.contextId), nil)
            return
        }
        // Defer the reply until the renderer has a frame up, so the host swap lands
        // on live video rather than a black layer.
        let ctxId = ctxRaw.contextId
        createRenderer(for: surface, url: videoURL, choice: choice, key: key) {
            reply(makeRemoteContextXPC(contextId: ctxId), nil)
        }
    }

    private func createRenderer(for surface: Surface, url: URL, choice: String?, key: SurfaceKey, onReady: (@Sendable () -> Void)?) {
        let box = SendableBox(surface.rootLayer)
        Task {
            let renderer: VideoRenderer
            do { renderer = try await VideoRenderer.create(rootLayer: box.value, videoURL: url) }
            catch { extLog("renderer create failed: \(error)"); onReady?(); return }
            surface.renderer = renderer
            surface.videoID = choice
            renderer.start(onFirstFrameReady: onReady)
            if WallpaperState.shared.presentationMode != "locked" { /* desktop: keep playing */ }
        }
    }

    func update(withId _: Any?, request: Any?, reply: @escaping (Error?) -> Void) {
        nonisolated(unsafe) let ureq = request
        Self.queue.async {
            let mode = (mirrorFind("presentationMode", in: ureq as Any)).map(enumCaseName) ?? "default"
            WallpaperState.shared.presentationMode = mode
            reply(nil)
        }
    }

    func invalidate(withId id: Any?, reply: @escaping (Error?) -> Void) {
        nonisolated(unsafe) let uid = id
        Self.queue.async {
            guard let uuid = extractUUID(from: uid) else { reply(nil); return }
            // Tear down after a short grace so a display sleep/wake or a quick
            // re-acquire of the same surface doesn't drop it.
            Self.queue.asyncAfter(deadline: .now() + 12) {
                // Only tear down if nobody re-installed this exact surface meanwhile.
                for did in UInt32(0)...UInt32(8) {
                    let key = SurfaceKey(displayID: did, surfaceUUID: uuid)
                    if let s = WallpaperState.shared.surface(for: key) {
                        WallpaperState.shared.removeSurface(for: key)?.renderer?.stop()
                        _ = s
                    }
                }
            }
            reply(nil)
        }
    }

    func snapshot(withId _: Any?, reply: @escaping (Any?, Error?) -> Void) {
        // No IOSurface snapshot for the Settings preview — we drive selection
        // ourselves via the wallpaper store, so the picker path is unused.
        reply(nil, nil)
    }

    // MARK: Settings / choices / downloads / migration / shuffle — no-ops

    func provideSettingsViewModels(withContentTypes _: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil, nil) }
    func addChoiceRequest(withChoiceRequest _: Any?, onBehalfOfProcess _: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil, nil) }
    func removeChoiceRequest(withChoiceRequest _: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func selectedChoicesDidChange(for _: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func invokeContextMenuAction(withMenuItemID _: Any?, groupItemID _: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func isChoiceDownloaded(with _: Any?, reply: @escaping (Bool, Error?) -> Void) { reply(true, nil) }
    func pauseDownload(for _: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func cancelDownload(for _: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func resumeDownload(for _: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeDownload(for _: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func migrateSelectedChoice(for _: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil, nil) }
    func migrate(from _: Any?, to _: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func skipShuffledContent(withId _: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func canSkipShuffledContent(withId _: Any?, reply: @escaping (Bool, Error?) -> Void) { reply(false, nil) }
    func handleDebugRequest(for _: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil, nil) }
    func handleNotification(withNamed _: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
}

// MARK: - Reflection helpers

struct SendableBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

/// Recursively search a value's Mirror for a stored property named `label`.
/// Robust to the XPC wrapper nesting, unlike scanning a stringified description.
func mirrorFind(_ label: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 8 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == label { return child.value }
        if let found = mirrorFind(label, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// Find the first `UUID` anywhere in a value's Mirror tree (the WallpaperID).
func extractUUID(from value: Any?, depth: Int = 0) -> UUID? {
    guard let value, depth < 8 else { return nil }
    if let uuid = value as? UUID { return uuid }
    for child in Mirror(reflecting: value).children {
        if let found = extractUUID(from: child.value, depth: depth + 1) { return found }
    }
    return nil
}

/// Stable per-display UUID for an acquire that carries no WallpaperID.
func deterministicUUID(_ displayID: UInt32) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", displayID)) ?? UUID()
}

/// `.locked` → "locked", `.suspended(x)` → "suspended".
func enumCaseName(_ value: Any) -> String {
    let m = Mirror(reflecting: value)
    if m.displayStyle == .enum, let label = m.children.first?.label { return label }
    return String(describing: value)
}
