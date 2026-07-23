import Foundation
import os

/// Lightweight logger for the wallpaper extension. WallpaperAgent hosts this
/// process, so `print` goes nowhere useful — everything routes through the
/// unified log under the `wallpaper` category. Read live with:
///   log stream --predicate 'subsystem == "com.nopxx.musique.wallpaper"'
enum Ext {
    static let log = Logger(subsystem: "com.nopxx.musique.wallpaper", category: "wallpaper")
}

@inline(__always)
func extLog(_ message: String) {
    Ext.log.log("\(message, privacy: .public)")
}
