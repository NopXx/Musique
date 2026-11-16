# Musique

A native macOS menu bar companion for Apple Music, Spotify and browser players — Last.fm scrobbling, listening history, webhooks, edit-rules, notifications, time-synced lyrics, a polished mini player and a desktop player.

Written in Swift / SwiftUI. Talks to Music.app and Spotify via ScriptingBridge — event-driven and system-integrated.

## Features

- **Menu bar status item** — two styles:
  - *Text* — configurable display (icon, play state, track, artist, max length)
  - *Dynamic Island* — pill with album artwork thumbnail, play/pause icon (clickable), and a real-time audio waveform; pill tint follows the current track's accent color
- **Three playback sources** — Apple Music and Spotify (polled via ScriptingBridge), plus browser players through the [Web Scrobbler](https://web-scrobbler.com) extension's webhook; the active one is picked automatically or from the mini player
- **Mini player popover** — three layouts (Classic / Tall / Immersive), animated artwork, blurred backdrop, dominant-color gradient, scrubber, full-width audio waveform, and a lyrics toggle that morphs the cover into the corner
- **Desktop player** — a free-standing floating player in two designs, an *artwork card* and a *glass bar*, switched from the player itself; lyrics open beside the card (or below the bar) without moving it
- **Time-synced lyrics** — Apple Music TTML with word-by-word highlighting (letters rise on long held notes), falling back to LRCLIB; works for Spotify and browser tracks too, and picks up lyrics the Music app has already loaded on this Mac
- **Fullscreen artwork** — motion artwork mirrored into the margins or a card over a blurred backdrop, with lyrics and a Liquid Glass clock
- **Real-time audio waveform** — Core Audio Process Tap (macOS 14.2+) captures Music.app's output, FFT (Accelerate / vDSP) decomposes it into 10 log-spaced frequency bands rendered as bars in the menu bar, mini player, and lock screen card
- **Now Playing widget** — small / medium / large WidgetKit widgets sharing app-group data, with transport controls (play/pause/next/previous) via App Intents and live in-process progress bar
- **Last.fm scrobbling** — `track.updateNowPlaying` on play, `track.scrobble` once per play (configurable threshold), with auth flow and Keychain-style local config
- **Pending scrobble queue** — failed scrobbles are persisted to SQLite and retried on launch + every 5 minutes
- **Now Playing takeover** — `MPNowPlayingInfoCenter` with silent-audio looper so Musique owns the lock screen / Control Center slot, artwork included
- **Notifications** — banner with artwork on track change and scrobble success
- **Webhooks** — POST JSON payloads in Music-Scrobbler format with optional heartbeat
- **Listening history** — every play / pause / resume / scrobble event is recorded to SQLite; viewable in Settings
- **Edit rules** — automatically rewrite artist / track / album metadata before scrobbling, configurable inline from the mini player or in Settings
- **Import / export** — Edit-rule JSON can be backed up and restored from Settings
- **Lock screen overlay** — full-screen now-playing window rendered above the macOS login UI via SkyLight private API (space pinning at NotificationCenterAtScreenLock level)
- **Debug dashboard** — opt-in loopback web page with live state, listening history, artwork and lyrics lookups
- **Localization** — Thai and English; switchable in Settings → General

## Requirements

- macOS 26.0 or later — required for Liquid Glass UI (lock screen / mini player), and Core Audio Process Tap (real-time audio waveform)
- Xcode 26+
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```sh
xcodegen generate
xcodebuild -project Musique.xcodeproj -scheme Musique -configuration Debug build
```

Or open `Musique.xcodeproj` in Xcode and Run.

The generated `.xcodeproj` is not committed — regenerate it from `project.yml` whenever you pull.

## Architecture

```
PlayerMonitor          ──┐
  Apple Music + Spotify  │
  (ScriptingBridge)      │
  + Web Scrobbler push   │
  + DistributedNotif     ├─►  ScrobblerService  ──►  Last.fm
  + 1 Hz tick timer      │      └─► PendingScrobbleQueue (retry)
                         │
                         ├─►  NowPlayingService (Takeover)
                         │
                         ├─►  WebhookDispatcher
                         │
                         ├─►  NotificationService
                         │
                         ├─►  HistoryRecorder ──► HistoryStore (SQLite)
                         │
                         ├─►  WidgetDataManager  ──►  App Group JSON + WidgetCenter reload
                         │                            └─►  MusiqueWidget (WidgetKit + App Intents)
                         │
                         ├─►  MenuBarController + MiniPlayer (SwiftUI)
                         │
                         ├─►  DesktopMiniPlayerController (card / glass bar)
                         │
                         ├─►  LyricsService  ──►  Apple TTML (MusicKit) / LRCLIB
                         │
                         └─►  LockScreenController
                                └─► SkyLightOperator (private CGS space pinning)

MusicAudioLevelMonitor  ──►  CATapDescription + AudioHardwareCreateProcessTap (macOS 14.2+)
                             └─► vDSP FFT → 10 log-spaced bands → @Published
                                 └─► consumed by menu bar / miniplayer / lockscreen wave views

EditHistoryService  ──►  applies rules before scrobble / webhook / display
L10n                ──►  runtime i18n (Thai / English) via SettingsStore
```

- `PlayerMonitor` owns one ScriptingBridge object per player and listens to `com.apple.Music.playerInfo` / `com.spotify.client.PlaybackStateChanged` distributed notifications. A 1 Hz timer ticks position locally; full state resyncs fire on actual events. Web Scrobbler tracks are pushed to a loopback webhook instead.
- `MusicAppController` routes control commands (play / pause / next / prev / seek) to whichever player is active, through ScriptingBridge on a background queue.
- `HistoryStore` is an `actor` wrapping `sqlite3` directly — no third-party dependency.

## Settings

All user data lives under `~/Library/Application Support/Musique/`:

- `settings.json` — JSON-merged with defaults
- `history.db` — events, edit rules, pending scrobbles
- `TTML/` — raw lyrics cache
- `Videos/` — animated artwork cache

## Project layout

```
Musique/
  Sources/
    App.swift
    Player/                  PlayerMonitor, MusicAppController, NowPlayingService,
                             MusicAudioLevelMonitor (Core Audio Process Tap + FFT),
                             WebScrobblerReceiver, WidgetDataManager (App Group writer)
      Bridge/                Music.h (sdef-generated), Spotify.h, stubs
    Scrobbler/               LastFMClient, ScrobblerService, PendingScrobbleQueue
    Lyrics/                  LyricsService (Apple TTML, LRCLIB, parsers, prefetcher)
    Artwork/                 ArtworkService, ColorExtractor, CustomArtworkStore
    History/                 HistoryStore, HistoryRecorder, EditHistoryService
    Notifications/           NotificationService
    Webhooks/                WebhookDispatcher
    Services/                DebugServer, LaunchAtLoginService
    Helpers/                 L10n (i18n), TextShape
    Settings/                SettingsStore
    UI/                      MenuBarController, MenuBarDynamicIslandView,
                             MiniPlayer*, DesktopMiniPlayerController,
                             DesktopPlayerView, DesktopCompactPlayerView,
                             AnimationFullscreen*, FullscreenArtworkView,
                             AnimatedArtworkView, SettingsView, ...
      LockScreen/            LockScreenController, SkyLightOperator, LockScreenWindow,
                             LockScreenPlayerView (with real-time wave bars)
    Wallpaper/               MotionWallpaperController, MotionWallpaperStore (inactive)
  Musique-Bridging-Header.h
  Info.plist                 (NSAudioCaptureUsageDescription for Process Tap)
  Musique.entitlements
MusiqueWidget/               WidgetKit extension — small / medium / large + App Intents
MusiqueWallpaper/            wallpaper ExtensionKit appex
Shared/                      AppGroup identifier
MusiqueTests/
web/                         debug dashboard page
docs/                        design notes (Apple Music TTML pipeline)
project.yml                  (xcodegen)
```

## Permissions

The first time Musique sends a command to Music.app or Spotify, macOS will prompt for **Apple Events** automation permission (once per player). If you deny it, control buttons stop working — re-enable it under **System Settings → Privacy & Security → Automation → Musique → Music / Spotify**.

Apple Music lyrics ask for **Apple Music (MusicKit) access** and need a subscription; without it lyrics come from LRCLIB. The audio waveform asks for **audio capture** permission.

## Status

Most features described above are implemented and working. Outstanding:

- Last.fm session-key migration to Keychain
- Localization for non-Settings views (MiniPlayer, AnimationFullscreen)
- App icon, notarization and auto-update (releases are signed for development only)

See [TODO.md](TODO.md) for the live punch list.

## Acknowledgements

Artwork lookup uses [`apple-music-artwork-search`](https://apple-music-artwork.nopxx.site/).

## License

MIT
