import Foundation

/// Build a `WallpaperRemoteContextXPC` carrying a remote CAContext id, to hand
/// back from `acquire`. The class lives in WallpaperExtensionKit and exposes no
/// Swift-callable initializer, so we allocate a bare instance and write the
/// 32-bit context id into its backing ivar directly. The ivar is named `box`
/// (a small struct wrapping the id); if that lookup ever fails we fall back to
/// the historically-stable offset just past the isa pointer.
func makeRemoteContextXPC(contextId: UInt32) -> AnyObject? {
    guard let cls = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
          let raw = class_createInstance(cls, 0) else {
        extLog("makeRemoteContextXPC: WallpaperRemoteContextXPC unavailable")
        return nil
    }
    let obj = raw as AnyObject
    let base = Unmanaged.passUnretained(obj).toOpaque()
    let offset: Int
    if let ivar = class_getInstanceVariable(cls, "box") {
        offset = ivar_getOffset(ivar)
    } else {
        offset = MemoryLayout<UInt>.size // just past isa
    }
    base.advanced(by: offset).storeBytes(of: contextId, as: UInt32.self)
    return obj
}
