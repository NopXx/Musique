# Musique — TODO

อ้างอิงแผนเต็มที่ `~/.claude/plans/desktop-app-fizzy-whale.md`

---

## ✅ เสร็จแล้ว

### Foundation
- [x] Xcode project skeleton (xcodegen) — 3 targets: app, widget, tests
- [x] App Group: `group.com.nopxx.musique`
- [x] Min target macOS 14, Bundle ID `com.nopxx.musique`
- [x] Entitlements: Apple Events, network client, app-sandbox = false

### Player integration
- [x] `PlayerMonitor` — event-driven via `com.apple.Music.playerInfo` notification + 1s polling fallback
- [x] `MusicAppController` — NSAppleScript wrapper สำหรับ playpause / next / prev / seek / snapshot
- [x] Snapshot script ใช้ `<<MMSEP>>` separator + escape `theState` (กัน reserved word)

### Menu bar
- [x] `NSStatusItem` + `NSPopover` host SwiftUI
- [x] Title อัปเดตชื่อเพลงปัจจุบัน (max 40 chars + ellipsis)

### Mini player (SwiftUI)
- [x] 3 layouts: Classic / Tall (auto for portrait video) / Immersive (opt-in)
- [x] `AnimatedArtworkView` — AVPlayer + AVPlayerLooper retained ใน Coordinator
- [x] ตำแหน่งของ Icon ในโหมด Classic Not Tall ของ Mini player (เลื่อนลงไปอยู่ที่ด้านล่างสุด) เหมือน Tall
- [x] Static artwork fallback ผ่าน `AsyncImage`
- [x] Blurred backdrop + dominant-color gradient
- [x] Progress bar + remaining time + scrobble percent indicator
- [x] Play/Pause/Next/Prev + footer (settings, notifications toggle, quit)

### Artwork
- [x] `ArtworkService` (actor) — เรียก `apple-music-artwork-search.vercel.app/api/search`
- [x] Best-match logic: track+artist+album → track+artist → first
- [x] In-memory cache by track key
- [x] `ColorExtractor` (actor) — sample saturated pixels เพื่อ accent + average สำหรับ gradient

### Settings
- [x] `SettingsStore` — JSON-backed file ที่ `~/Library/Application Support/Musique/settings.json`
- [x] Deep merge + defaults + public snapshot (กัน api_secret หลุด)
- [x] SwiftUI `SettingsView` — General / Last.fm / Scrobble / Notifications / Webhooks / Menu Bar / Mini Player / Lock Screen / Edit Rules / History
- [x] Live update mini player เมื่อแก้ settings

### Last.fm
- [x] `LastFMClient` — sign params (MD5 via CryptoKit) + call API
- [x] `ScrobblerService` — subscribe `PlayerMonitor.$snapshot`
- [x] `track.updateNowPlaying` ตอนเริ่มเพลง
- [x] `track.scrobble` เมื่อ played ≥ percent setting (default 50%) + duration > min_seconds
- [x] กัน scrobble ซ้ำต่อ track key (persistent ID)
- [x] Auth flow: `auth.getToken` → เปิด browser → poll `auth.getSession` ทุก 2.5s

### Now Playing
- [x] `NowPlayingService` — takeover mode (hardcoded, no mirror)
- [x] Silent AVPlayer looper → macOS recognises app as media source
- [x] `MPNowPlayingInfoCenter` publish artwork + metadata
- [x] `MPRemoteCommandCenter` forward play/pause/next/prev/seek → AppleScript
- [x] Periodic republish to reassert Now Playing ownership

### Lock Screen overlay
- [x] `LockScreenController` — observe `screenIsLocked` / `screenIsUnlocked` via DistributedNotificationCenter
- [x] `SkyLightOperator` — dlopen SkyLight, pin private space at `notificationCenterAtScreenLock` (level 400)
- [x] `LockScreenWindow` / `LockScreenBackgroundWindow` — borderless, `canBecomeVisibleWithoutLogin`, `Int32.max` level
- [x] `LockScreenPlayerView` — now-playing card + artwork backdrop
- [x] Raise loop (burst `orderFrontRegardless` for 3s after lock UI appears)
- [x] Multi-display support (`screens: main | all`)
- [x] Glass clock style picker
- [x] Static artwork → real desktop wallpaper (crossfade) + motion overlay
- [ ] Motion artwork as REAL video lock wallpaper — spike done, feasible but large RE build. See [docs/video-lock-wallpaper-spike.md](docs/video-lock-wallpaper-spike.md). Needs code signing + private `WallpaperExtensionKit` interface reconstruction + appex target.

### Notifications
- [x] `NotificationService` — `UNUserNotificationCenter` wrapper
- [x] On track change: banner + artwork thumbnail
- [x] On scrobble success: optional banner
- [x] เคารพ settings: enabled / on_play / on_scrobble

### Webhooks
- [x] `WebhookDispatcher` — async URLSession fan-out
- [x] Payload shape เทียบ Music-Scrobbler
- [x] Settings UI สำหรับ webhook URLs (add / remove / heartbeat)

### History & Edit Rules
- [x] `HistoryStore` (actor) — SQLite via `sqlite3` directly (no third-party)
- [x] Schema: events, edit_rules, pending_scrobbles
- [x] `EditHistoryService` — apply rules ก่อน scrobble / webhook
- [x] Settings UI: เพิ่ม/ลบ rules + Import/Export JSON
- [x] Settings tab "ประวัติ" — table view with event history

### Pending scrobble queue
- [x] เก็บ scrobble ที่ส่งไม่ผ่านลง SQLite `pending_scrobbles`
- [x] Retry ตอน launch + ทุก 5 นาที

### Localization
- [x] `L10n` helper — runtime i18n via SettingsStore `["language"]`
- [x] Thai + English สำหรับ SettingsView ทั้งหมด (~70 strings)
- [x] Language picker ใน Settings → General

---

## 🚧 ยังไม่ทำ

### Widget extension
- [ ] `WidgetCenter.shared.reloadAllTimelines()` ทุกครั้งที่เพลงเปลี่ยน
- [ ] Widget UI: small / medium ใช้ artwork + title + artist
- [ ] Progress timeline (entries ห่าง 30s ถึงปลายเพลง)

### Localization (remaining views)
- [ ] MiniPlayerView — Thai strings (`ยังไม่ได้เล่นเพลง`, `เพลงสั้นเกินไป`, `แก้ข้อมูลเพลง`, etc.)
- [ ] AnimationFullscreenView — `กดเพื่อปิด`

### Polish
- [ ] App icon + Dock icon (LSUIElement = NO ตอน first-run welcome?)
- [ ] Code signing + notarization สำหรับ release
- [ ] Auto-update mechanism (Sparkle หรือ GitHub releases)
- [ ] Last.fm session_key migration to Keychain

### ScriptingBridge upgrade (optional — performance)
- [ ] Generate `Music.h` จาก `sdef`/`sdp`
- [ ] แทน NSAppleScript polling → typed Swift API
- [ ] Lower CPU เพราะไม่ต้อง parse string ทุกวินาที

---

## 🐞 Known issues

- **AVPlayer animated mp4 error -12860** — ใน unsigned dev build บางเครื่อง mp4 จาก `mvod.itunes.apple.com` decode ไม่ผ่าน
  - Workaround: download mp4 → cache ใน `/tmp` → play จาก file URL
  - Likely fix: code-signed build จะดีขึ้น
- **Sandbox subprocess noise** — WebContent process logs สิ่งที่ไม่เกี่ยวกับ feature เรา; ignore ได้

---

## 📋 Verification matrix

| Feature | Test |
|---|---|
| Menu bar | Title อัปเดตภายใน 1s |
| Mini player Classic | Artwork 272×272 ตรงกลาง + blurred backdrop |
| Mini player Tall | Portrait mp4 full-bleed + content overlay |
| Mini player Immersive | Full-bleed ทุกเพลง |
| Scrobbling | Last.fm/user/X เห็นรายการภายใน 30s |
| Now Playing (takeover) | Lockscreen แสดง artwork + transport |
| Lock Screen overlay | SkyLight window โผล่เหนือ loginwindow |
| Control Center | App เราโผล่ใน Now Playing tile |
| Widget | Refresh ภายใน 2s เมื่อเปลี่ยนเพลง |
| Webhooks | Payload ส่งครบทุก event |
| Edit history | Rule "A → B" → scrobble โชว์ B |
| Notifications | Banner ตอนเปลี่ยนเพลง + artwork |
| Localization | สลับ TH ↔ EN ใน Settings → General ทุก label เปลี่ยน |
