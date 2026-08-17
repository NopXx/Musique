import ExtensionFoundation
import Foundation

/// XPC entry configuration. WallpaperAgent opens an `NSXPCConnection` here each
/// time it needs our wallpaper hosted. We publish the two hand-declared protocols
/// (see the bridging header) and, because NSXPC uses secure coding, pre-approve
/// every WallpaperExtensionKit wire class per argument slot.
struct MusiqueWallpaperConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        extLog("XPC accept from pid \(connection.processIdentifier)")

        let exported = NSXPCInterface(with: WallpaperHostedXPC.self)

        // WallpaperExtensionKit's wire types arrive over the connection; each must
        // be whitelisted for secure coding or the message is rejected.
        let wireTypes = [
            "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC", "WallpaperDebugRequestXPC",
            "WallpaperDebugResponseXPC", "WallpaperMigrationVersionXPC",
            "WallpaperSettingsViewModelsXPC", "AuditTokenXPC",
        ]
        let classes = NSMutableSet()
        for name in wireTypes where objc_getClass(name) != nil {
            classes.add(objc_getClass(name) as! AnyClass)
        }
        for t in [NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self, NSError.self] as [AnyClass] {
            classes.add(t)
        }
        let classSet = classes as! Set<AnyHashable>

        // Approve the class set for every argument (and reply) slot that carries a
        // wire object. Selector, arg index, is-reply.
        let slots: [(Selector, Int, Bool)] = [
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.invalidate(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            // WallpaperAgent hands this a `WallpaperContentTypeSetXPC`; without the
            // allowlist NSXPC drops the message with a secure-coding exception, the
            // provider never finishes setting up, and the desktop shows the user's
            // own wallpaper even though our appex is alive and rendering frames.
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
        ]
        for (sel, idx, isReply) in slots {
            exported.setClasses(classSet, for: sel, argumentIndex: idx, ofReply: isReply)
        }

        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: WallpaperProxyXPC.self)

        let handler = WallpaperXPCHandler()
        handler.connectionPID = connection.processIdentifier
        connection.exportedObject = handler

        connection.interruptionHandler = { extLog("XPC interrupted") }
        connection.invalidationHandler = { extLog("XPC invalidated (kept \(WallpaperState.shared.surfaceCount) surface(s))") }
        connection.resume()
        return true
    }
}
