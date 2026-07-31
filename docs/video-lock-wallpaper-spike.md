# Spike — motion artwork as REAL video lock-screen wallpaper (macOS 26)

Date: 2026-07-20. Goal: set the now-playing motion artwork as the actual macOS
lock-screen wallpaper (not the SkyLight overlay we already ship).

**Result: feasible, but a large + fragile reverse-engineering build. Not started.
The shipped motion-overlay is the sane interim.**

## Decision: ship our own `WallpaperExtension.appex` (path B). File-hacking (path A) is dead.

- **Path A (inject asset + drive selection) — DEAD.** Decoded every nested bplist
  `Configuration` in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`
  — all `imageFile`, zero aerial config anywhere (AllSpacesAndDisplays / SystemDefault /
  Spaces / Displays). Aerial *selection* never touches disk; it is pure XPC/extension
  state. On-disk edits cannot drive it. (`killall WallpaperAgent` + plist rewrite does not
  repaint.)
- **Path B (ship an appex) — feasible.** Extension point `com.apple.wallpaper` is **not
  entitlement-gated**: Apple's `WallpaperAerialsExtension.appex` has only `app-sandbox` +
  `network.client` + temp file exceptions — no private wallpaper entitlement. A notarized,
  sandboxed third-party appex can register at this point (this is how the closed-source
  `wallper-app` works — user then picks it in System Settings → Wallpaper).

## The video-wallpaper interface (class-dumped from the dyld shared cache)

Tool: `ipsw dyld macho <cache> <framework> --swift --demangle` (ipsw 3.1.704 prebuilt —
brew build-from-source needs Xcode 27, machine had 26.5). Cache at
`/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e`.

Frameworks the appex links (from `otool -L` on `WallpaperImageExtension`):
`WallpaperExtensionKit`, `WallpaperFoundation`, `WallpaperTypes`, `ExtensionFoundation`.

```
struct Video.Variant { url: URL; orientation: .landscape|.portrait?;
                        systemAppearance?; solar?; videoGravity: .resize|.resizeAspectFit }
struct Video { default: Variant; additionalVariants: [Variant] }
struct VideoWallpaperConfiguration: Codable { videos: [Video] }   // the config blob we vend
class  VideoWallpaper  init(request:host:configuration:shouldLoop:)
                       // fields: player: VideoPlayer, playerLayer, shouldLoop, videos: [Video]
enum   VideoWallpaperError { missingFile(URL); noFiles }

protocol WallpaperExtension { A: ExtensionFoundation.AppExtension ... }
protocol WallpaperExtensionConfiguration: ExtensionFoundation.AppExtensionConfiguration
```

Packaging: NSExtension/NSXPC under the hood (`_NSExtensionMain`,
`EXExtensionPointIdentifier=com.apple.wallpaper`, `LSMinimumSystemVersion 27.0`, sandboxed).
The config reaches the extension as a Codable `Data` blob
(`WallpaperCreationRequestXPC.CodableSubset { configuration: Data; destination;
presentationMode; activityState; systemAppearance; isPreview; ... }`).

## The real blocker (not the appex packaging)

`WallpaperExtensionKit` is a **private framework with no vended `.swiftmodule` /
`.swiftinterface`**, and every protocol-requirement witness name is `<stripped>` in the
release dump. So you cannot `import WallpaperExtensionKit` to declare
`@main struct: WallpaperExtension`. A native extension requires **reconstructing the module
interface by hand** (a `.swiftinterface` + `module.modulemap` matching the mangled symbols,
or an ObjC / `@_silgen_name` shim) — fragile, breaks on OS updates. This is the bulk of the
work and almost certainly what `wallper-app` did.

## To actually build it (dedicated session)

Prereqs, in order:
1. **Code signing + notarization** for Musique (already on the general TODO) — an unsigned
   dev appex will not register with `pluginkit`.
2. Reconstruct the `WallpaperExtensionKit` module interface.
3. New sandboxed appex target in `project.yml`
   (`EXExtensionPointIdentifier=com.apple.wallpaper`) vending
   `VideoWallpaperConfiguration{ videos: [Video(url: our .mov)] }`.
4. Transcode the cached motion artwork to **HEVC 10-bit `.mov`** before feeding it in.

Config keys / provider ids seen along the way: image provider =
`com.apple.wallpaper.choice.image`; aerials extension bundle id =
`com.apple.wallpaper.extension.aerials`; aerial config keys `AerialAssetID` /
`selectedAerialIDs` / `representativeAssetID` / `shotID`.
