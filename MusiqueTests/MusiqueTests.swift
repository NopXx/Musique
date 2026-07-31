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
        XCTAssertFalse(MotionWallpaperStore.hasStuckDesktop(in: restored))
        XCTAssertTrue(MotionWallpaperStore.hasStuckDesktop(in: live))
    }

    /// A Desktop whose *file path* merely mentions our bundle id is not stuck —
    /// only its Provider decides. The staged clip lives under a path containing
    /// the extension's bundle id, so a raw byte scan of the store reported clean
    /// stores as stuck.
    func testStuckDetectionIgnoresFilePaths() {
        let staged = "file:///Users/x/Library/Containers/\(MotionWallpaperStore.extensionBundleID)/Data/Documents/videos/a.mov"
        let store: [String: Any] = [
            "Displays": [
                "d1": [
                    "Desktop": ["Content": ["Choices": [[
                        "Provider": "com.apple.wallpaper.choice.image",
                        "Files": [["relative": staged]],
                    ]]]],
                ],
            ],
        ]
        XCTAssertFalse(MotionWallpaperStore.hasStuckDesktop(in: store))
    }

    /// The AppKit restore needs the real image URL out of an image choice's
    /// Configuration blob, which is a nested binary plist.
    func testImageURLDecodesFromContent() throws {
        let inner: [String: Any] = ["type": "imageFile", "url": ["relative": "file:///Users/x/Pic/wall.jpg"]]
        let cfg = try PropertyListSerialization.data(fromPropertyList: inner, format: .binary, options: 0)
        let content: [String: Any] = ["Choices": [[
            "Provider": "com.apple.wallpaper.choice.image",
            "Configuration": cfg,
        ]]]
        XCTAssertEqual(MotionWallpaperStore.imageURL(fromContent: content),
                       URL(string: "file:///Users/x/Pic/wall.jpg"))
        // A motion choice carries no such image URL.
        let motion: [String: Any] = ["Choices": [["Provider": MotionWallpaperStore.extensionBundleID,
                                                   "Configuration": Data("musique-motion".utf8)]]]
        XCTAssertNil(MotionWallpaperStore.imageURL(fromContent: motion))
    }

    /// A desktop showing the lock-screen artwork still (written by
    /// `SystemWallpaperOperator`, not the user) must never be backed up as the
    /// wallpaper to restore — that is how the desktop gets stuck on a frozen
    /// artwork frame. It counts as stuck, so a restore repairs it instead.
    func testBackupSkipsOurOwnArtworkStill() throws {
        let still = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Musique/lockscreen-wallpaper-a.jpg")
        let userPic = URL(string: "file:///Users/x/Pictures/wall.jpg")!
        func imageContent(_ url: URL) throws -> [String: Any] {
            let cfg = try PropertyListSerialization.data(
                fromPropertyList: ["type": "imageFile", "url": ["relative": url.absoluteString]],
                format: .binary, options: 0)
            return ["Choices": [["Provider": "com.apple.wallpaper.choice.image", "Configuration": cfg]]]
        }
        let store: [String: Any] = [
            "Displays": [
                "ours": ["Desktop": ["Content": try imageContent(still)]],
                "real": ["Desktop": ["Content": try imageContent(userPic)]],
            ],
        ]
        let saved = MotionWallpaperStore.collectDesktopContents(in: store)
        XCTAssertEqual(Array(saved.keys), ["/Displays/real"])
        XCTAssertTrue(MotionWallpaperStore.hasStuckDesktop(in: store))
    }

    /// Each display must get its own wallpaper back, not one image sprayed over
    /// every screen — the display-level node wins, else the lowest per-Space node
    /// for that display, and a display the backup never saw gets nothing.
    func testSavedContentIsPickedPerDisplay() {
        let saved: [String: Any] = [
            "/Displays/D1": "d1-display",
            "/Spaces/S2/Displays/D1": "d1-space2",
            "/Spaces/S2/Displays/D2": "d2-space2",
            "/Spaces/S1/Displays/D2": "d2-space1",
            "/SystemDefault": "system",
        ]
        XCTAssertEqual(MotionWallpaperStore.savedContent(forDisplay: "D1", in: saved) as? String, "d1-display")
        XCTAssertEqual(MotionWallpaperStore.savedContent(forDisplay: "D2", in: saved) as? String, "d2-space1")
        XCTAssertNil(MotionWallpaperStore.savedContent(forDisplay: "D3", in: saved))
    }

    /// "Main display only": the rewrite must touch only Desktop nodes under the
    /// target display's `Displays/<uuid>` containers — the other display, the
    /// all-displays node, and Space defaults keep the user's wallpaper.
    func testRewriteCanTargetOneDisplay() {
        let image: [String: Any] = ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.image"]]]]
        let store: [String: Any] = [
            "AllSpacesAndDisplays": ["Desktop": image],
            "Displays": ["D1": ["Desktop": image], "D2": ["Desktop": image]],
            "Spaces": ["S1": [
                "Default": ["Desktop": image],
                "Displays": ["D1": ["Desktop": image], "D2": ["Desktop": image]],
            ]],
        ]
        let out = MotionWallpaperStore.rewriteDesktop(
            in: store, choiceID: "c", videoURL: URL(fileURLWithPath: "/tmp/x.mov"),
            onlyDisplayUUID: "D1")
        func provider(_ path: [String]) -> String? {
            var node: Any? = out
            for key in path { node = (node as? [String: Any])?[key] }
            let content = (node as? [String: Any])?["Content"] as? [String: Any]
            return (content?["Choices"] as? [[String: Any]])?.first?["Provider"] as? String
        }
        let ours = MotionWallpaperStore.extensionBundleID
        XCTAssertEqual(provider(["Displays", "D1", "Desktop"]), ours)
        XCTAssertEqual(provider(["Spaces", "S1", "Displays", "D1", "Desktop"]), ours)
        XCTAssertEqual(provider(["Displays", "D2", "Desktop"]), "com.apple.wallpaper.choice.image")
        XCTAssertEqual(provider(["Spaces", "S1", "Displays", "D2", "Desktop"]), "com.apple.wallpaper.choice.image")
        XCTAssertEqual(provider(["AllSpacesAndDisplays", "Desktop"]), "com.apple.wallpaper.choice.image")
        XCTAssertEqual(provider(["Spaces", "S1", "Default", "Desktop"]), "com.apple.wallpaper.choice.image")
    }
}
