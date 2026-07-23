import XCTest
@testable import Musique

final class MusiqueTests: XCTestCase {
    func testSnapshotPlayingFlag() {
        let snap = NowPlayingSnapshot(
            state: "playing", title: "Song", artist: "Artist", album: "Album",
            duration: 200, position: 30, persistentID: "abc"
        )
        XCTAssertTrue(snap.isPlaying)
        XCTAssertTrue(snap.hasTrack)
    }

    /// The wallpaper-store rewrite must re-point every Desktop node at our
    /// extension while leaving Idle (screen-saver) nodes untouched.
    func testWallpaperRewriteTargetsDesktopOnly() {
        let store: [String: Any] = [
            "AllSpacesAndDisplays": [
                "Desktop": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.image"]]]],
                "Idle": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.image"]]]],
            ],
        ]
        let url = URL(fileURLWithPath: "/tmp/x.mov")
        let out = MotionWallpaperStore.rewriteDesktop(in: store, choiceID: "deadbeef", videoURL: url)

        let group = out["AllSpacesAndDisplays"] as! [String: Any]
        let desktop = (group["Desktop"] as! [String: Any])["Content"] as! [String: Any]
        let choice = (desktop["Choices"] as! [[String: Any]]).first!
        XCTAssertEqual(choice["Provider"] as? String, MotionWallpaperStore.extensionBundleID)
        XCTAssertEqual(choice["Configuration"] as? Data, Data("deadbeef".utf8))

        // Idle stays on the original provider.
        let idle = (group["Idle"] as! [String: Any])["Content"] as! [String: Any]
        let idleChoice = (idle["Choices"] as! [[String: Any]]).first!
        XCTAssertEqual(idleChoice["Provider"] as? String, "com.apple.wallpaper.choice.image")
    }

    /// Restore must leave no Desktop node on our provider — including a Space that
    /// macOS created *after* we activated, which the backup never captured. Such a
    /// node falls back to the saved system-default desktop, not to its Idle
    /// sibling (Idle is the lock-screen image, which can be a different picture).
    /// Regression test for restoring by overwriting the whole store with a stale
    /// snapshot, which dropped those nodes instead of restoring them.
    func testRestoreCoversDesktopsMissingFromBackup() {
        func node(_ image: String) -> [String: Any] {
            ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.image",
                                      "Files": [["relative": image]]]]]]
        }
        // Desktop and lock screen deliberately show different pictures.
        let original: [String: Any] = [
            "SystemDefault": ["Desktop": node("default.heic"), "Idle": node("lock.heic")],
            "Spaces": [
                "space-1": ["Desktop": node("beach.heic"), "Idle": node("lock.heic")],
            ],
        ]
        let saved = MotionWallpaperStore.collectDesktopContents(in: original)
        XCTAssertEqual(saved.count, 2)

        // A second Space appears while we are active; every Desktop gets rewritten.
        var live = original
        var spaces = live["Spaces"] as! [String: Any]
        spaces["space-2"] = ["Desktop": node("whatever.heic"), "Idle": node("lock.heic")]
        live["Spaces"] = spaces
        live = MotionWallpaperStore.rewriteDesktop(in: live,
                                                   choiceID: "musique-motion",
                                                   videoURL: URL(fileURLWithPath: "/tmp/x.mov"))

        let restored = MotionWallpaperStore.restoreDesktops(in: live, saved: saved)

        func desktopImage(_ container: [String: Any]) -> String? {
            let content = (container["Desktop"] as! [String: Any])["Content"] as! [String: Any]
            let choice = (content["Choices"] as! [[String: Any]]).first!
            XCTAssertNotEqual(choice["Provider"] as? String, MotionWallpaperStore.extensionBundleID)
            return ((choice["Files"] as? [[String: String]])?.first)?["relative"]
        }
        let restoredSpaces = restored["Spaces"] as! [String: Any]
        XCTAssertEqual(desktopImage(restored["SystemDefault"] as! [String: Any]), "default.heic")
        XCTAssertEqual(desktopImage(restoredSpaces["space-1"] as! [String: Any]), "beach.heic")
        // Not in the backup → the system-default desktop, NOT the lock screen.
        XCTAssertEqual(desktopImage(restoredSpaces["space-2"] as! [String: Any]), "default.heic")
    }
}
