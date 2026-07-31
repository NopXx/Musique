import AppKit
import os

/// Promotes an `NSWindow` above the macOS lock UI by attaching it to a
/// private SkyLight (CoreGraphicsServices) space pinned at an absolute level
/// that sits *above* the loginwindow's own ScreenLock space.
///
/// Approach and function signatures are based on Lakr233/SkyLightWindow
/// (https://github.com/Lakr233/SkyLightWindow), which is the only public
/// reference implementation that works on current macOS releases.
@MainActor
final class SkyLightOperator {
    static let shared = SkyLightOperator()

    /// Absolute SkyLight level the player space is pinned at. Other exported
    /// levels, for reference: 0 default, 100 setup assistant, 200 security agent,
    /// 300 screen lock, 500 boot progress, 600 VoiceOver — larger = on top.
    private static let notificationCenterAtScreenLock: Int32 = 400

    private let log = Logger(subsystem: "com.nopxx.musique", category: "SkyLight")

    // C function signatures (verified against SkyLightWindow):
    //   int  SLSMainConnectionID(void);
    //   int  SLSSpaceCreate(int cid, int one, int zero);
    //   CGError SLSSpaceSetAbsoluteLevel(int cid, int sid, int level);
    //   CGError SLSShowSpaces(int cid, CFArrayRef space_list);
    //   CGError SLSSpaceAddWindowsAndRemoveFromSpaces(int cid, int sid, CFArrayRef windows, int seven);
    private typealias FnMainConnectionID = @convention(c) () -> Int32
    private typealias FnSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias FnSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias FnShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias FnAddWindowsAndRemove = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let SLSMainConnectionID: FnMainConnectionID
    private let SLSSpaceCreate: FnSpaceCreate
    private let SLSSpaceSetAbsoluteLevel: FnSpaceSetAbsoluteLevel
    private let SLSShowSpaces: FnShowSpaces
    private let SLSSpaceAddWindowsAndRemoveFromSpaces: FnAddWindowsAndRemove

    private let connection: Int32
    /// Player card/clock/controls — fixed above the lock UI so they never vanish.
    /// The only space we keep; everything else on the lock screen is either the
    /// real wallpaper (motion/static) or drawn inside this same window.
    private let space: Int32
    let isAvailable: Bool

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        let handle = dlopen(path, RTLD_NOW)
        let logger = Logger(subsystem: "com.nopxx.musique", category: "SkyLight")

        func sym<T>(_ name: String, as: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else {
                logger.error("dlsym \(name, privacy: .public) failed")
                return nil
            }
            return unsafeBitCast(p, to: T.self)
        }

        guard let mainConn = sym("SLSMainConnectionID", as: FnMainConnectionID.self),
              let spcCreate = sym("SLSSpaceCreate", as: FnSpaceCreate.self),
              let spcSetLevel = sym("SLSSpaceSetAbsoluteLevel", as: FnSpaceSetAbsoluteLevel.self),
              let showSpc = sym("SLSShowSpaces", as: FnShowSpaces.self),
              let addRemove = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", as: FnAddWindowsAndRemove.self) else {
            // Populate stub closures so stored properties are initialised.
            SLSMainConnectionID = { 0 }
            SLSSpaceCreate = { _, _, _ in 0 }
            SLSSpaceSetAbsoluteLevel = { _, _, _ in 0 }
            SLSShowSpaces = { _, _ in 0 }
            SLSSpaceAddWindowsAndRemoveFromSpaces = { _, _, _, _ in 0 }
            connection = 0
            space = 0
            isAvailable = false
            logger.error("SkyLight unavailable — lock screen promotion disabled")
            return
        }

        SLSMainConnectionID = mainConn
        SLSSpaceCreate = spcCreate
        SLSSpaceSetAbsoluteLevel = spcSetLevel
        SLSShowSpaces = showSpc
        SLSSpaceAddWindowsAndRemoveFromSpaces = addRemove

        connection = mainConn()
        // (cid, one=1, zero=0) — magic values from WindowServer reverse-engineering
        space = spcCreate(connection, 1, 0)
        // Player space is pinned above macOS's NotificationCenterAtScreenLock
        // layer so the card/controls always composite over system widgets.
        _ = spcSetLevel(connection, space, Self.notificationCenterAtScreenLock)
        _ = showSpc(connection, [space] as CFArray)
        isAvailable = true
        logger.info("SkyLight init OK — connection:\(self.connection) space:\(self.space)")
    }

    /// Attach `window` to the player space (fixed above the lock UI). Idempotent.
    func promoteAboveLockScreen(_ window: NSWindow) { attach(window, to: space) }

    private func attach(_ window: NSWindow, to targetSpace: Int32) {
        guard isAvailable else { return }
        guard window.windowNumber > 0 else {
            log.error("Window has no CGWindowID — call after orderFront")
            return
        }
        // Last argument `7` is a fixed mask used by WindowServer's own
        // notification-center plumbing — copied verbatim from SkyLightWindow.
        _ = SLSSpaceAddWindowsAndRemoveFromSpaces(
            connection,
            targetSpace,
            [window.windowNumber] as CFArray,
            7
        )
    }
}
