# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Musique — native macOS menu bar companion for Apple Music **and Spotify** (Last.fm scrobbling, history, webhooks, mini player, lock screen overlay, real-time audio waveform). Swift / SwiftUI, talks to each player via ScriptingBridge + distributed notifications (`com.apple.Music.playerInfo`, `com.spotify.client.PlaybackStateChanged`).

The folder is named `MusicMate` (legacy); the app and all targets were renamed to `Musique` (see commit `47bdcf7`).

## Build & Run

The `.xcodeproj` is generated, not committed. Regenerate after any pull or change to `project.yml`:

```sh
xcodegen generate
xcodebuild -project Musique.xcodeproj -scheme Musique -configuration Debug build
```

Or open `Musique.xcodeproj` in Xcode and Run. `postGenCommand` (`scripts/fix-icon-filetype.sh`) runs automatically after `xcodegen`.

**Never build with `CODE_SIGNING_ALLOWED=NO` into the shared DerivedData.** The
products end up ad-hoc linker-signed with the wrong bundle identifiers and no
entitlements: the wallpaper appex stops being registered (`pluginkit -mAvvv |
grep musique` goes empty, so the motion wallpaper can't work at all) and the
changed signature revokes the app's TCC grants. Signing needs an Apple account
that only Xcode has — a plain `xcodebuild` from a terminal fails with
`No Accounts`. So: build/run in Xcode, and if a command-line build is needed for
a compile check or tests, point it somewhere harmless with
`-derivedDataPath /tmp/<something>`.

Tests:
```sh
xcodebuild -project Musique.xcodeproj -scheme Musique -destination 'platform=macOS' test
# single test
xcodebuild -project Musique.xcodeproj -scheme Musique -destination 'platform=macOS' test -only-testing:MusiqueTests/<ClassName>/<testMethod>
```

Other scripts: `scripts/build-dmg.sh`, `scripts/clean-builds.sh`, `scripts/wipe-user-data.sh` (clears `~/Library/Application Support/Musique/`).

## Secrets / config

`Secrets.xcconfig` (gitignored) supplies `LASTFM_API_KEY` and `LASTFM_API_SECRET`, injected into `Info.plist` at build time. Copy from `Secrets.xcconfig.example`.

## Requirements

- macOS 26.0+ (deployment target — Liquid Glass UI + Core Audio Process Tap)
- Xcode 26+
- `xcodegen` (`brew install xcodegen`)
- Swift 5.9, `SWIFT_STRICT_CONCURRENCY=minimal`
- App is **not sandboxed** (`ENABLE_APP_SANDBOX=false`); widget extension is sandboxed.

## Targets

Four targets defined in [project.yml](project.yml):

- **Musique** — main app. `LSUIElement=true` (menu bar agent). Entitlements: apple-events, network.client, app-group `AppGroup.id` (team-ID prefixed — a non-sandboxed macOS process gets no container for the plain `group.` form), disable-library-validation (for SkyLight dlopen).
- **MusiqueWidget** — WidgetKit app extension. Sandboxed. Shares app-group JSON.
- **MusiqueWallpaper** — `com.apple.wallpaper` ExtensionKit appex, embedded in `Contents/Extensions`. Sandboxed; plays the staged motion-artwork clip as the real desktop wallpaper. Talks to WallpaperAgent over NSXPC using hand-declared protocols, with `WallpaperExtensionKit` (private, no Swift module) `dlopen`ed at launch so its ObjC wire classes resolve by name.
- **MusiqueTests** — unit test bundle.

The app group is the *only* shared filesystem between them — same identifier
string in all three entitlements. It's what carries `nowPlaying.json` for the
widget and the staged `videos/` for the wallpaper appex.

`MusiqueSaverExtension/` exists on disk but is not yet wired into `project.yml`.

## Architecture (big picture)

Central hub is `PlayerMonitor` — polls **both** Apple Music and Spotify via ScriptingBridge (driven by each app's distributed notification + a 1 Hz tick timer), normalises each into a `NowPlayingSnapshot`, and publishes one chosen snapshot plus a per-source `sourceSnapshots` map. Other services subscribe to its `@Published snapshot`:

```
PlayerMonitor ──► ScrobblerService ──► Last.fm
              │      └─► PendingScrobbleQueue (SQLite retry, 5 min)
              ├─► NowPlayingService (takeover via MPNowPlayingInfoCenter + silent AVPlayer looper)
              ├─► WebhookDispatcher
              ├─► NotificationService
              ├─► HistoryRecorder ──► HistoryStore (SQLite actor)
              ├─► WidgetDataManager ──► App Group JSON + WidgetCenter reload
              ├─► MenuBarController + MiniPlayer (SwiftUI)
              └─► LockScreenController ──► SkyLightOperator (private CGS space pinning)

MusicAudioLevelMonitor ──► CATapDescription + AudioHardwareCreateProcessTap
                           └─► vDSP FFT → 10 log-spaced bands → @Published
                              └─► consumed by menu bar / mini player / lock screen wave views
```

### Key invariants

- **Multi-source playback** — `PlayerMonitor` owns one `MusicApplication` and one `SpotifyApplication`; events trigger full resync, the 1 Hz timer only ticks local position. Each source toggled via `settings.bool(["sources", "<apple_music|spotify>_enabled"])`. `pickSnapshot` chooses the active source: explicit `selectedSource` (mini player picker) wins while it has a track; otherwise a *playing* source beats a paused one, ties broken by configured priority then `lastActiveSource`. `MusicAppController.activeSource` (static) tracks the current source so control commands route to the right app.
- **Spotify duration is in milliseconds** (`SpotifyTrack.duration`), while `MusicTrack.duration` is in seconds — `spotifySnapshot()` converts. Spotify control commands go through `SpotifyController`, Apple Music through `AppleMusicController`; both run on their own background ScriptingBridge queue, dispatched by `MusicAppController` based on `activeSource`. Bridge headers are hand-written/sdef-generated and imported via `Musique-Bridging-Header.h`.
- **`HistoryStore` is an `actor`** wrapping `sqlite3` directly — no third-party SQL dependency. Schema: `events`, `edit_rules`, `pending_scrobbles`.
- **`EditHistoryService` rewrites metadata *before*** scrobble / webhook / display — anything user-visible downstream of it sees rewritten artist/track/album.
- **Now Playing takeover** requires the silent AVPlayer looper running, otherwise macOS won't recognise Musique as a media source.
- **Lock screen overlay** uses SkyLight private API (`dlopen`) to pin a borderless window at level `notificationCenterAtScreenLock` (400), above the loginwindow. Multi-display supported via `screens: main | all` setting. It draws **everything** the lock screen shows: the now-playing card, and — once the user taps the thumbnail (`isLargeArtwork`) — the fullscreen artwork, its blurred edge-blur backdrop, and our own clock/date.
  - **Fullscreen artwork** lives in `FullscreenArtworkView`, shared by the lock screen overlay and the mini player's fullscreen window so the two can't drift. Two layouts, the same split the iPad lock screen makes:
    - **Motion clip** — the cover fit to the screen's short edge, and the margins are the *clip itself, mirrored* and butted against its edges. Mirroring is what makes the seam vanish: the column either side of the join is the same column of the same frame, so no feather is needed and none is used. Nothing is drawn under or over them — a blurred still, a palette gradient, a scrim all read as a tint on the reflection. The blur has to be **strong enough that the margin stops being a picture** (`FullscreenArtworkView.mirrorBlur`, 120pt): softer than that and the reflection is still legible as forms, reads as a second copy of the cover, and the eye finds the join through it. Dimmed ~0.78 in the same CoreImage pass — margins at full brightness compete with the cover beside them. A flat dim, not a vignette: under this much blur the gradient is invisible and costs another filter pass.
    - The mirrors come from **one decode**: `AnimatedArtworkView.mirrorCoverSize` makes the view span the screen, plays the clip in an `AVPlayerLayer` at the cover rect, and feeds `CALayer`s either side from an `AVPlayerItemVideoOutput` on the same item (downscaled to 320pt and blurred through CoreImage, since the margins are magnified blur anyway). The output has to follow `currentItem` — `AVPlayerLooper` cycles between copies of the item, so an output pinned to the first one freezes after one loop. **Three separate players does not work**: they drift, and blurring one through `CALayer.filters` (the only filter path that reaches an `AVPlayerLayer` at all) puts that copy on a slow render path, drops its frames and leaves it seconds behind the cover beside it.
    - **Still artwork** — a rounded card at half the fit size over `ArtworkBackdrop`, which is the cover blurred far past recognition. A still sleeve blown up to fill a screen is just a big JPEG.
  - `ArtworkBackdrop` pre-renders that field with CoreImage at 480pt tall and caches one entry. **Edge-clamp, not a scaled-up copy**: `clampedToExtent()` stretches the cover's own edge pixels outward at the *same* scale as the sharp cover, so the margin colour is the colour the cover ends on. A second copy scaled to fill puts the sleeve's forms at a different size and position, and the eye finds that seam through any amount of blur.
  - Effects that must reach the video go on the layer, never through SwiftUI: `AnimatedArtworkView.edgeFeather` is **CALayer gradient masks inside `PlayerView`** and a blur would have to be `CALayer.filters`. SwiftUI render-graph filters (`.blur`, `.mask`, `.shadow`) don't reach an AppKit-hosted `AVPlayerLayer` — they silently no-op — and where one does land it costs an offscreen pass per video frame.
  - **The clock** (`LockScreenClockView`, shared with the desktop fullscreen window) pours Liquid Glass into the *glyph outlines*, not into a box behind them — the iOS 26 look of the artwork seen through the numerals. `.glassEffect(_:in:)` takes a `Shape` and `Text` is not one, which is the entire reason `Helpers/TextShape.swift` exists: Core Text glyph outlines as a SwiftUI `Shape`. Size is `lockscreen.clock_size` (96pt default, 48–220 in Settings) and the date is tied to a fifth of it, so one slider scales the block. Weight tops out at `.bold` — heavier and the rim meets itself, the numeral flattens to solid white and nothing shows through.
    - **Glass does not render the same in the two windows and can't be made to.** `SkyLightOperator.promoteAboveLockScreen` moves the overlay out of every normal space into a private WindowServer one, where glass has no backdrop to sample and falls back to a flat pale frost — the whole window, transport card included. The desktop fullscreen window gets a real refraction. Drawing the numerals with a fill and a stroke does match both, but trades away the good window's glass, so it isn't done. Window opacity, `backgroundColor`, level, `collectionBehavior` and `canBecomeVisibleWithoutLogin` were each ruled out as the cause. `.environment(\.colorScheme, .light)` on the clock closes the separate `NSAppearance` half of the gap and stays.
    - **Never wrap the card in a `GlassEffectContainer`.** A container hoists the glass its children declare into its own layer; `NowPlayingCard` declares glass inside `.background(...)`, so hoisted it lands *over* the title, artist and transport and the card renders as a grey blank. Nothing would merge anyway — the clock is half a screen away.
  - Covering the screen also covers loginwindow's password field, so the overlay fades (`lockUIVisible`) on **`com.apple.screensaver.didstop`** and comes back on `didstart` — the saver stopping is the only "the user just touched this machine" signal available while locked. **`com.apple.screenLockUIIsShown` is NOT that signal**: it fires ~1s after every lock and its `…IsHidden` partner only at unlock, so it means "the lock screen is up". Driving the fade from it blanked the artwork and left the window click-through for the whole lock session.
  - While faded *and* enlarged the controller sets `window.ignoresMouseEvents = true` — the only thing that lets a click through, since AppKit hit-tests a window by frame, not pixel alpha (`allowsHitTesting(false)` would swallow it instead). Never set when nothing is enlarged, or the card's own taps die. Keyboard needs nothing: a borderless window can't become key, which is also the escape hatch (type the password blind). Clicking anywhere shrinks.
- **Audio waveform** needs `NSAudioCaptureUsageDescription` and Core Audio Process Tap (macOS 14.2+).
- **DebugServer** — opt-in loopback HTTP server (`Network.framework`, default port 8765, `127.0.0.1` only), toggled in Settings. Serves an HTML dashboard + JSON endpoints: `/api/all`, `/api/snapshot`, `/api/raw` (`?refresh=1` / `/api/raw/refresh` forces a fresh ScriptingBridge read), `/api/pending`, `/api/settings`, `/api/audio`. `@MainActor`, attached to `PlayerMonitor` at launch in `App.swift`.
- **Desktop-wallpaper takeover is OFF** — `LockScreenController.wallpaperTakeoverEnabled = false` gates `syncWallpaper`, `syncMotionWallpaper` and `prewarmWallpaper`. The overlay above draws the artwork itself, so hijacking the real desktop bought nothing and cost a WallpaperAgent bounce, an `Index.plist` rewrite and a class of stuck-wallpaper bugs. The code below is kept, inert, so re-enabling is a one-word edit; `lockscreen.set_system_wallpaper` still exists in settings but has no UI row.
  - **Recovery stays unconditional** and must not be moved behind the flag: `MotionWallpaperStore.healIfStuck()` and `SystemWallpaperOperator.recoverIfNeeded()` at init, plus the `willTerminate` restore. An older build may have left a desktop hijacked and only these hand it back.
- **Motion wallpaper** (`MotionWallpaperController` + `MotionWallpaperStore`, disabled — see above; it was gated on `lockscreen.set_system_wallpaper` and live only while locked *and* the artwork was enlarged) makes the animated artwork the real desktop wallpaper: stage the clip into `<app group>/videos`, rewrite every `Desktop` node in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` to our provider, reload WallpaperAgent. Later tracks only overwrite the staged clip + post a Darwin notification (`…wallpaper.switch`) so the appex swaps on the live surface — no reload flash.
  - Stage through the **app group**, never the appex's own container: writing into another app's container needs the user's "access data from other apps" grant, which macOS revokes on every signature change.
  - `pointsAtUs` counts *any* file Musique wrote (artwork stills, staged clips) as ours, not just our provider. Backing one up as the "original" is how the desktop gets stuck on a frozen artwork frame forever.
  - Restore must go through **AppKit** (`setDesktopImageURL`) as well as the plist — WallpaperAgent re-projects its own state over a file-only rewrite. AppKit reaches only the current Space per screen; other Spaces come back via the plist rewrite and `healIfStuck()` at next launch. Per-display: each screen gets its own backed-up image, matched by display UUID (`savedContent(forDisplay:)`).
  - `viewModel.motionWallpaperLive`/`staticWallpaperLive` said whether the desktop really was carrying ours — activation took seconds and could fail. Nothing reads them for display any more.
- **Artwork and its palette are published in the same hop** — `MiniPlayerViewModel` and `LockScreenViewModel` both fetch the `ColorExtractor` palette *before* committing the new `ArtworkResult`, then assign both together. Published apart, the new sleeve sits on the previous track's colours for as long as the palette download takes; the mini player's bottom fade tints its lowest 320pt with `gradientStart`, so a blue cover came up over a brown gradient. `ColorExtractor` caches per URL, so holding both costs nothing on a repeat.
- **Animated artwork** is cached to disk by `AnimatedArtworkCache` (`~/Library/Application Support/Musique/Videos/`, keyed by CryptoKit hash of the remote URL). `localURLIfCached` returns synchronously; misses download in the background — this is the workaround for the `-12860` decode error (see Known issues).

### Source layout

```
Musique/Sources/
  App.swift
  Player/          PlayerMonitor, MusicAppController, NowPlayingService,
                   MusicAudioLevelMonitor, WidgetDataManager
    Bridge/        Music.h (sdef-generated) + MusicStubs.m,
                   Spotify.h (hand-written) + SpotifyStubs.m
  Scrobbler/       LastFMClient, ScrobblerService, PendingScrobbleQueue
  Artwork/         ArtworkService (actor, hits apple-music-artwork-search.vercel.app),
                   ColorExtractor (accent + gradient)
  History/         HistoryStore, HistoryRecorder, EditHistoryService
  Notifications/   NotificationService
  Webhooks/        WebhookDispatcher
  Helpers/         L10n (runtime i18n via SettingsStore["language"]),
                   TextShape (Core Text glyph outlines as a SwiftUI Shape)
  Settings/        SettingsStore (JSON deep-merged with defaults; public snapshot
                   strips api_secret)
  Services/        DebugServer (loopback HTTP debug dashboard)
  UI/              MenuBarController, MenuBarDynamicIslandView, MiniPlayer*,
                   SettingsView, AnimatedArtworkView, AnimatedArtworkCache,
                   AnimationFullscreen*, FullscreenArtworkView +
                   ArtworkBackdrop (shared by the lock screen and the mini
                   player's fullscreen window)
    LockScreen/    LockScreenController, SkyLightOperator, LockScreenWindow,
                   LockScreenPlayerView, SystemWallpaperOperator (lock-only
                   static artwork wallpaper)
  Wallpaper/       MotionWallpaperController, MotionWallpaperStore

MusiqueWallpaper/  the appex — MusiqueWallpaperExtension (@main),
                   WallpaperXPCHandler, VideoRenderer, WallpaperState,
                   WallpaperPaths (must match MotionWallpaperStore's paths)

Shared/            AppGroup — the group identifier, compiled into all three
                   targets (entitlements repeat it via a YAML anchor)
```

## User data

All under `~/Library/Application Support/Musique/`:
- `settings.json` — deep-merged with defaults on load
- `history.db` — events, edit rules, pending scrobbles

`scripts/wipe-user-data.sh` clears it.

## Localization

`L10n` reads `SettingsStore["language"]` at runtime (Thai / English). SettingsView is fully translated (~70 strings); MiniPlayer + AnimationFullscreen Thai strings still pending (see [TODO.md](TODO.md)).

## Permissions

First control command triggers a macOS Apple Events prompt (one per target app — Music and/or Spotify). If denied: **System Settings → Privacy & Security → Automation → Musique → Music / Spotify**.

Grants are keyed to the app's code signature, so an ad-hoc/unsigned build silently
loses all of them; `tccutil reset All com.nopxx.musique` re-prompts for everything.

Reading the app's own logs: `log` is a **zsh builtin**, so `log show …` in this
shell errors with `too many arguments` and prints nothing useful — use
`/usr/bin/log show --predicate 'subsystem == "com.nopxx.musique"' --last 15m --info`
(without `--info` the `Logger.info` lines are missing).

## Known issues

- AVPlayer animated mp4 error `-12860` on some unsigned dev builds (mvod.itunes.apple.com decode fails); worked around by `AnimatedArtworkCache` downloading to a local file URL before playback. Likely also resolved by a code-signed build.

See [TODO.md](TODO.md) for outstanding work (widget timeline reload, MiniPlayer i18n, code signing / notarization, Sparkle, Keychain migration for Last.fm session key).
