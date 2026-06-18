# Musique

A native macOS menu bar companion for Apple Music — Last.fm scrobbling, listening history, webhooks, edit-rules, notifications, and a polished mini player.

Written in Swift / SwiftUI. Talks to Music.app via ScriptingBridge — event-driven and system-integrated.

## Features

- **Menu bar status item** — two styles:
  - *Text* — configurable display (icon, play state, track, artist, max length)
  - *Dynamic Island* — pill with album artwork thumbnail, play/pause icon (clickable), and a real-time audio waveform; pill tint follows the current track's accent color
- **Mini player popover** — three layouts (Classic / Tall / Immersive), animated artwork, blurred backdrop, dominant-color gradient, scrubber, full-width audio waveform
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
  ScriptingBridge        │
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
                         └─►  LockScreenController
                                └─► SkyLightOperator (private CGS space pinning)

MusicAudioLevelMonitor  ──►  CATapDescription + AudioHardwareCreateProcessTap (macOS 14.2+)
                             └─► vDSP FFT → 10 log-spaced bands → @Published
                                 └─► consumed by menu bar / miniplayer / lockscreen wave views

EditHistoryService  ──►  applies rules before scrobble / webhook / display
L10n                ──►  runtime i18n (Thai / English) via SettingsStore
```

- `PlayerMonitor` owns a single `MusicApplication` ScriptingBridge object and listens to `com.apple.Music.playerInfo` distributed notifications. A 1 Hz timer ticks position locally; full state resyncs only fire on actual events.
- `MusicAppController` issues control commands (play / pause / next / prev / seek) through ScriptingBridge on a background queue.
- `HistoryStore` is an `actor` wrapping `sqlite3` directly — no third-party dependency.

## Settings

All user data lives under `~/Library/Application Support/Musique/`:

- `settings.json` — JSON-merged with defaults
- `history.db` — events, edit rules, pending scrobbles

## Project layout

```
Musique/
  Sources/
    App.swift
    Player/                  PlayerMonitor, MusicAppController, NowPlayingService,
                             MusicAudioLevelMonitor (Core Audio Process Tap + FFT),
                             WidgetDataManager (App Group writer)
      Bridge/                Music.h (sdef-generated), MusicStubs.m
    Scrobbler/               LastFMClient, ScrobblerService, PendingScrobbleQueue
    Artwork/                 ArtworkService, ColorExtractor
    History/                 HistoryStore, HistoryRecorder, EditHistoryService
    Notifications/           NotificationService
    Webhooks/                WebhookDispatcher
    Helpers/                 L10n (i18n), TextToShape
    Settings/                SettingsStore
    UI/                      MenuBarController, MenuBarDynamicIslandView,
                             MiniPlayer*, SettingsView, SettingsWindowController,
                             AnimatedArtworkView, AnimationFullscreen*
      LockScreen/            LockScreenController, SkyLightOperator, LockScreenWindow,
                             LockScreenPlayerView (with real-time wave bars)
  Musique-Bridging-Header.h
  Info.plist                 (NSAudioCaptureUsageDescription for Process Tap)
  Musique.entitlements
MusiqueWidget/             WidgetKit extension — small / medium / large + App Intents
MusiqueTests/
project.yml                  (xcodegen)
```

## Permissions

The first time Musique sends a command to Music.app, macOS will prompt for **Apple Events** automation permission. If you deny it, control buttons stop working — re-enable it under **System Settings → Privacy & Security → Automation → Musique → Music**.

## Status

Most features described above are implemented and working. Outstanding:

- Last.fm session-key migration to Keychain
- Localization for non-Settings views (MiniPlayer, AnimationFullscreen)
- App icon, code signing, notarization, auto-update

See [TODO.md](TODO.md) for the live punch list.

## Acknowledgements

Artwork lookup uses [`apple-music-artwork-search`](https://apple-music-artwork.nopxx.site/).

## License

MIT
