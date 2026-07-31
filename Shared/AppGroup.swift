import Foundation

/// The app group all three targets share — the only filesystem the app, the
/// widget and the wallpaper extension can all reach.
///
/// Team-ID prefixed on purpose: macOS resolves a group container for a
/// *non-sandboxed* process (the app itself) only in that form, and with the
/// plain `group.` form every write silently landed in a temp dir the sandboxed
/// targets can't read.
///
/// Compiled into all three targets so the string exists once in Swift; the
/// entitlements repeat it in `project.yml` through one YAML anchor. Changing it
/// means changing both.
enum AppGroup {
    static let id = "H4M5HWBU2K.group.com.nopxx.musique"

    /// The shared container, or nil when the entitlement isn't in force (an
    /// unsigned build, a test host).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }
}
