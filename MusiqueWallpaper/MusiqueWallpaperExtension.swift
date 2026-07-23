import ExtensionFoundation
import Foundation

/// Entry point for Musique's motion-artwork wallpaper provider.
///
/// The public extension point `com.apple.wallpaper` is driven by ExtensionKit's
/// `AppExtension` + `AppExtensionConfiguration` machinery (both public API). The
/// wallpaper-specific rendering contract lives in the *private* framework
/// `WallpaperExtensionKit`, which ships no Swift module — so instead of importing
/// it, we `dlopen` it at launch to make its ObjC XPC wire classes
/// (`WallpaperCreationRequestXPC`, `WallpaperRemoteContextXPC`, …) resolvable by
/// name, and speak to WallpaperAgent over NSXPC using hand-declared protocols
/// (see the bridging header). No private Swift protocol conformance is required.
@main
final class MusiqueWallpaperExtension: NSObject, AppExtension {
    override required init() {
        super.init()

        // Keep the handle for the process lifetime — the C function pointers and
        // ObjC classes it exposes must stay mapped for every XPC callback.
        let path = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"
        if dlopen(path, RTLD_LAZY) != nil {
            extLog("launched (pid \(ProcessInfo.processInfo.processIdentifier)) — WallpaperExtensionKit loaded")
        } else {
            let err = dlerror().map { String(cString: $0) } ?? "unknown"
            extLog("launched but dlopen(WallpaperExtensionKit) FAILED: \(err)")
        }

        // Host overwrites the staged clip then posts this Darwin notification; swap
        // it in on the live surface instead of forcing a desktop reload per song.
        // Name must match MotionWallpaperStore.switchNotification in the host app.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in WallpaperState.shared.eachRenderer { $0.reload() } },
            "com.nopxx.musique.wallpaper.switch" as CFString,
            nil, .deliverImmediately)
    }

    var configuration: some AppExtensionConfiguration {
        MusiqueWallpaperConfiguration()
    }
}
