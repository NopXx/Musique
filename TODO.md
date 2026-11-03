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
- [~] Motion artwork as REAL video wallpaper (macOS 26 `com.apple.wallpaper` extension). Feasibility re-confirmed HIGH; blockers from the spike overturned (no WEK Swift-protocol reconstruction needed — conform public `AppExtension` + ObjC/XPC bridge; ad-hoc/dev signing registers, notarization only for distribution; selection = rewrite `com.apple.wallpaper/Store/Index.plist` + `killall WallpaperAgent`). See docs + memory `macos26-video-lock-wallpaper`.
  - [x] **Scaffold** — `MusiqueWallpaper` appex target (sandboxed, app-group, `EXExtensionPointIdentifier=com.apple.wallpaper`), `@main AppExtension` + dlopen(WallpaperExtensionKit) + `AppExtensionConfiguration`. Builds + embeds + dev-signed + **registers** (`pluginkit` lists `com.nopxx.musique.wallpaper`).
  - [x] Bridging header (`MusiqueWallpaper-Bridging-Header.h`: ObjC `WallpaperHostedXPC`/`WallpaperProxyXPC` + private `CAContext`/CGS) — original
  - [x] `WallpaperXPCHandler` — acquire/update/invalidate real (Mirror-parse request, remote `CAContext`, `WallpaperRemoteContextXPC` ivar poke); snapshot nil; choice/download/migrate/shuffle/settings stubbed
  - [x] `VideoRenderer` — `AVSampleBufferDisplayLayer` fed by `AVAssetReader` → remote `CAContext`, gapless loop (ptsOffset), `_setDisallowsVideoLayerDisplayCompositing`
  - [x] Host `MotionWallpaperStore` — stage clip into app-group container, rewrite Index.plist Desktop nodes, `killall WallpaperAgent`, backup/restore, prune (ponytail: no HEVC transcode — extension decodes source directly)
  - [x] Host `MotionWallpaperController` — observes artwork/snapshot via LockScreenController, auto-swap per track, dedup by choiceID, revert on disable/quit
  - [x] Settings toggle `lockscreen.desktop_animated_wallpaper` (Lock Screen tab, L10n th/en) + revert-on-stop
  - [x] Unit test: `testWallpaperRewriteTargetsDesktopOnly` (Desktop rewritten, Idle untouched) — passes
  - [x] **On-device: WORKING** — desktop becomes the now-playing motion artwork video, live. Mirror field names + `WallpaperRemoteContextXPC` ivar offset + no-`EncodedOptionValues` all turned out fine. Key fix: non-sandboxed host can't write the app-group Group Container (EPERM even when entitled) → stage the video into the extension's OWN container Documents (`~/Library/Containers/com.nopxx.musique.wallpaper/Data/Documents/videos/`), backup kept in host `~/Library/Application Support/Musique/`.
  - [x] **No `killall` per song** — stable choiceID `musique-motion` + fixed staged file (atomic overwrite) + Darwin notify `com.nopxx.musique.wallpaper.switch` → `VideoRenderer.reload()` swaps clips on the live surface. Plist rewrite + `killall` now only on first activate / deactivate.
  - [x] **Restore hardening** — backup is now per-Desktop-node (`path → Content`) instead of a whole-file copy of `Index.plist`, and `deactivate()` merges into the *live* store. Fixes desktops not restoring: a Space/display macOS created while we were active was absent from the snapshot and got dropped from the plist entirely. Fallback order per node: saved Content → saved `/SystemDefault` (real desktop image) → sibling Idle (lock-screen image, last resort). `activate()` refuses to rewrite unless the backup persisted, and only then reports itself active.
  - [x] **Restore actually sticks now (the real fix)** — Index.plist is NOT WallpaperAgent's source of truth; it keeps its selection in its own state and re-projects it over the file on every respawn, so a file-only deactivate reverted to our provider on the next agent restart. `deactivate()` now restores through `NSWorkspace.setDesktopImageURL` per screen (the authoritative WallpaperManager path — survives a respawn), then rewrites Index.plist best-effort. Public API reaches only the current Space per screen; other Spaces fall to the rewrite + `healIfStuck()` on next launch. Verified 0/113 stuck across repeated agent kills. The prior per-node / ordering / respawn-race fixes were correct but orthogonal — they made the file right; the file was never the authority.
  - [x] **Playback hardening** — renderer no longer blocks its own queue loading a track (that could wedge it forever and deadlock `stop()`'s `queue.sync`, and with it the XPC invalidate path); reader failures retry instead of freezing the surface; a swap that can't open its clip resumes the previous one. Each track is staged under its own filename with a `current` pointer file, so a swap is always a new URL rather than a replaced inode. Artwork downloads that land after the track changed are dropped. Renderers pause while WallpaperAgent reports the surface `suspended` (never while merely `locked` — the wallpaper is meant to show behind the lock screen). Staged clips are pruned per track and cleared on deactivate.
  - [ ] Polish (optional): `EncodedOptionValues` crop/color if placement needs tuning; multi-display context options.
  - [ ] Perf (optional): one decode per surface — several visible displays each decode the same clip. Would need a shared reader fanning sample buffers to every layer (see `ponytail:` note in `WallpaperState`). Only worth it if it shows up in a profile.
  - Note: reference repos (Mural/geneva) UNLICENSED — studied only, all code original. Feature invasive (replaces real desktop wallpaper, `killall WallpaperAgent` per song) + fragile (≈8 private APIs, breaks on OS updates). Notarize only needed to distribute to other machines.

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

### Desktop mini player
- [ ] Mini player เป็นหน้าต่างลอยบน desktop (แยกจาก menu bar `NSPopover`) — reuse `MiniPlayerView` เดิมใน borderless `NSPanel`
- [ ] Toggle เปิด/ปิด จาก menu bar + setting `miniplayer.desktop_enabled`
- [ ] Window level ให้เลือก: ลอยเหนือทุกหน้าต่าง (`.floating`) / ติด desktop (`kCGDesktopIconWindowLevel`) / ปกติ
- [ ] ลากย้ายได้ (`isMovableByWindowBackground`) + จำตำแหน่งต่อจอ (`setFrameAutosaveName`)
- [ ] `collectionBehavior` `.canJoinAllSpaces` + `.stationary` — โผล่ทุก Space, ไม่หายตอน Mission Control
- [ ] ระวัง: ห้ามใช้ SwiftUI `.popover` ซ้อนข้างใน (ดู memory `no-nested-popover-miniplayer`) — ใช้ overlay หรือ NSWindow แยก
- [ ] ซ่อนอัตโนมัติตอน fullscreen app / ตอนไม่มีเพลง (optional)

### Web Scrobbler ingest (รับ webhook จาก [web-scrobbler](https://github.com/web-scrobbler/web-scrobbler))
เป้าหมาย: เพลงที่เล่นในเว็บ (YouTube, SoundCloud, Bandcamp ฯลฯ) ผ่าน extension web-scrobbler ส่งเข้า Musique เป็น source ที่สาม ถัดจาก Apple Music / Spotify
**Payload จริง** (verified จาก `src/core/scrobbler/webhook-scrobbler.ts` + `src/core/object/song.ts`, branch `master`):
- `POST <userApiUrl>`, `Content-Type: application/json`, ไม่มี auth header, timeout 15s
- **ต้องตอบ status `200` เป๊ะ** — `204`/`201` นับเป็น error (`response.status !== 200`)
- Body: `{ eventName, time /* ms epoch */, data: { song, songs?, isLoved?, currentlyPlaying? } }`

| `eventName` | `data` | ยิงตอน |
|---|---|---|
| `nowplaying` | `{ song }` | เริ่มเพลง |
| `paused` | `{ song }` | pause |
| `resumedplaying` | `{ song }` | เล่นต่อ |
| `scrobble` | `{ song /* = songs[0] */, songs, currentlyPlaying }` | ถึงเกณฑ์ scrobble (อาจมาเป็น batch) |
| `loved` | `{ song, isLoved }` | **ไม่เคยยิงจริง** — ดูข้างล่าง |

- `song` = `JSON.stringify` ของ class `Song` → ได้แค่ field ไม่ได้ getter:
  - `parsed`: `track, artist, album, albumArtist, duration, trackArt, uniqueID, originUrl, isPodcast, isPlaying, currentTime, scrobblingDisallowedReason` (ทุกตัว optional/nullable)
  - `processed`: `track, artist, album, albumArtist, duration` (หลังผ่าน regex/edit/Last.fm correction)
  - `noRegex`, `flags` (`isScrobbled, isCorrectedByUser, isSkipped, isReplaying, …`), `metadata` (`label, startTimestamp, trackArtUrl, trackUrl, userloved, …`), `connector` (`label, …`)
- ทำตาม getter ของ `BaseSong`: text = `processed.X ?? parsed.X`; duration = `parsed.duration ?? processed.duration` (**วินาที**); artwork = `parsed.trackArt ?? metadata.trackArtUrl`; ไม่มี artist หรือ track = song ว่าง → ข้าม
- **ไม่มี event position/heartbeat และไม่มี "stopped"** — `currentTime` เป็นค่า ณ `time` ของ event; ปิด tab แล้วเงียบไปเลย
- หลาย URL ได้ — ส่งพร้อมกันทุกอัน (`Promise.all`); อันไหนไม่ตอบ 200 (เช่น Musique ปิดอยู่) extension ขึ้น error ทั้ง call แต่อันอื่นยังได้รับปกติ
- **ทดสอบจริงแล้ว (YouTube, listener บน `127.0.0.1:8766`):**
  - ไม่มี CORS preflight — POST ตรงมาเลย, header `Origin: chrome-extension://<id>`
  - `processed` override `parsed` จริง (user แก้ artist `i-dle` → `MIYEON`) → อ่าน `processed` ก่อนถูกแล้ว
  - YouTube ให้ `parsed.trackArt = null`, album null — artwork ได้จาก `metadata.trackArtUrl` (Last.fm 300×300) เท่านั้น; ArtworkService ของเราค้นใหม่ได้ดีกว่า
  - `metadata.startTimestamp` = unix **วินาที** (ต่างจาก `time` ที่เป็น ms); `uniqueID` = YouTube video id
  - **`nowplaying` ซ้ำ 2 ครั้งห่าง ~0.5s** สำหรับเพลงเดียวกัน → dedupe ด้วย `uniqueID` + `startTimestamp`; เล่นซ้ำเพลงเดิม = `startTimestamp` ใหม่
  - `scrobble` มาตอนเล่นถึง ~60% (`currentTime` 103/171) และ `flags.isScrobbled` ยังเป็น `false` ใน payload
  - มี field ที่ไม่อยู่ใน type: `song.controllerTabId` → decoder ต้อง ignore unknown
  - `paused` → `parsed.isPlaying=false`, `currentTime` ณ ตอน pause (96); `resumedplaying` → `isPlaying=true`, `currentTime` = ค่าเดียวกับตอน pause (96); `startTimestamp` เดิมทั้งคู่ → position ตอน resume ใช้ `currentTime` ได้ตรง
  - `scrobble` ยิงหลัง resume ตามเวลาเล่นสะสม (ไม่นับช่วง pause) — ไม่ต้องสนใจตอนคำนวณ position
  - ตาม `controller.ts`: pause/resume ส่งเฉพาะเพลงที่ `isValid()` + ผ่าน `shouldScrobble()` (เพลงที่ถูก blocklist / ไม่รู้จัก ไม่มี event)
  - **`loved` ไม่มีวันมา**: `scrobble-service.toggleLove` กรองด้วย `scrobbler.canLoveSong()` และ `WebhookScrobbler` ไม่ override (default `false` ใน `base-scrobbler.ts`) — กดหัวใจใน popup แล้วก็ไม่ส่ง (ทดสอบแล้ว). สถานะ love ที่มีคือ `metadata.userloved` (ค่า Last.fm ตอน fetch) ใน event อื่น — ไม่ update ตามการกด
- Setup ฝั่ง extension (เห็นใน UI จริงแล้ว): Options → Webhook → Properties ใส่ "Application name" + "API URL" → Add Webhook; **หรือ** เปิด `https://webscrobbler.com/webhook?applicationName=Musique&userApiUrl=<encoded url>` → extension inject script ให้ user กด accept → เพิ่ม URL ให้เอง (one-click)

Tasks:
- [x] Endpoint `POST /api/webscrobbler` — ต่อกับ `DebugServer` ที่มีอยู่ (loopback `127.0.0.1` เท่านั้น) หรือแยก listener ถ้าไม่อยากให้ผูกกับ debug toggle; ตอบ `200` เสมอเมื่อ decode ผ่าน
- [x] Auth: secret token ใน query (`?token=`) เพราะ extension ส่ง header เองไม่ได้ — กันเว็บอื่นยิง localhost
- [x] Decoder `Codable` แบบ lenient (ทุก field optional, ignore unknown) → `NowPlayingSnapshot` source ใหม่ `.webScrobbler`
- [x] State machine: `nowplaying`/`resumedplaying` → playing, `paused` → paused, `scrobble` → ไม่เปลี่ยนสถานะ (แค่ mark scrobbled); `loved` decode ไว้เผื่อ upstream แก้ แต่ไม่ต้องทำ UI
- [x] Position: `currentTime + (now − time/1000)` ขณะ playing, เดินด้วย 1 Hz tick เดิม; ถ้า `currentTime` เป็น null นับจาก `time` ของ `nowplaying`
- [x] Expire: playing เกิน `duration` + grace (เช่น 30s) โดยไม่มี event ใหม่ หรือ paused นาน (เช่น 10 นาที) → ถือว่าหยุด/ล้าง source (ไม่มี stopped event)
- [x] `pickSnapshot` priority + setting `sources.web_scrobbler_enabled`
- [x] Control commands (play/pause/next/seek) ใช้ไม่ได้ — disable ปุ่มใน mini player / lock screen / `MPRemoteCommandCenter` เมื่อ active source นี้
- [x] กัน scrobble ซ้ำ: web-scrobbler scrobble Last.fm เองอยู่แล้ว → setting ว่า Musique scrobble ซ้ำไหม (default: ไม่); ถ้าเปิด ให้ใช้ event `scrobble` เป็นตัวสั่งแทนนับ % เอง
- [~] History / webhook dispatcher / widget ได้ข้อมูลจาก source นี้ (ผ่าน `snapshot` ตามปกติ — ยังไม่ได้ลอง end-to-end); ยังไม่ได้เก็บ `connector.label` (เช่น "YouTube") + `originUrl` ไว้แสดง
- [x] Settings UI: แสดง URL พร้อม token ให้ copy + ปุ่ม "เชื่อมต่อ web-scrobbler" เปิด approval link ข้างบน
- [x] Unit test: decode payload ตัวอย่างทุก `eventName` (รวม `scrobble` แบบ batch + song ที่ field เป็น null) → snapshot ถูกต้อง
- [x] **Implemented** — `Player/WebScrobblerReceiver.swift` (`WebScrobblerEvent` decoder, `WebScrobblerState` reducer, loopback `NWListener` port 8766 + `?token=`), source `.webScrobbler` ใน `PlaybackSource`, `PlayerMonitor.pickSnapshot` รองรับ N source, tests `MusiqueTests/WebScrobblerTests.swift`
- [x] ลองกับ extension จริงผ่าน app build (Xcode) — nowplaying/paused/resumedplaying เข้า, position ถูก, lyrics TTML ได้ (33 บรรทัด); `nowplaying` มาถึง 4 ครั้งติดกัน dedupe ด้วย persistentID ได้
- [ ] Waveform (`MusicAudioLevelMonitor`) ไม่ tap browser — เพลงจากเว็บไม่มี wave (ต้อง tap Chrome/Safari process; optional)

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
