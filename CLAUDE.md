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

Three targets defined in [project.yml](project.yml):

- **Musique** — main app. `LSUIElement=true` (menu bar agent). Entitlements: apple-events, network.client, app-group `H4M5HWBU2K.group.com.nopxx.musique` (team-ID prefixed — a non-sandboxed macOS process gets no container for the plain `group.` form), disable-library-validation (for SkyLight dlopen).
- **MusiqueWidget** — WidgetKit app extension. Sandboxed. Shares app-group JSON.
- **MusiqueTests** — unit test bundle.

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
- **Lock screen overlay** uses SkyLight private API (`dlopen`) to pin a borderless window at level `notificationCenterAtScreenLock` (400), above the loginwindow. Multi-display supported via `screens: main | all` setting.
- **Audio waveform** needs `NSAudioCaptureUsageDescription` and Core Audio Process Tap (macOS 14.2+).
- **DebugServer** — opt-in loopback HTTP server (`Network.framework`, default port 8765, `127.0.0.1` only), toggled in Settings. Serves an HTML dashboard + JSON endpoints: `/api/all`, `/api/snapshot`, `/api/raw` (`?refresh=1` / `/api/raw/refresh` forces a fresh ScriptingBridge read), `/api/pending`, `/api/settings`, `/api/audio`. `@MainActor`, attached to `PlayerMonitor` at launch in `App.swift`.
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
  Helpers/         L10n (runtime i18n via SettingsStore["language"]), TextToShape
  Settings/        SettingsStore (JSON deep-merged with defaults; public snapshot
                   strips api_secret)
  Services/        DebugServer (loopback HTTP debug dashboard)
  UI/              MenuBarController, MenuBarDynamicIslandView, MiniPlayer*,
                   SettingsView, AnimatedArtworkView, AnimatedArtworkCache,
                   AnimationFullscreen*
    LockScreen/    LockScreenController, SkyLightOperator, LockScreenWindow,
                   LockScreenPlayerView
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

## Known issues

- AVPlayer animated mp4 error `-12860` on some unsigned dev builds (mvod.itunes.apple.com decode fails); worked around by `AnimatedArtworkCache` downloading to a local file URL before playback. Likely also resolved by a code-signed build.

See [TODO.md](TODO.md) for outstanding work (widget timeline reload, MiniPlayer i18n, code signing / notarization, Sparkle, Keychain migration for Last.fm session key).
