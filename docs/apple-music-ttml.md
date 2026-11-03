# Apple Music TTML lyrics — implementation and agent handoff

Last updated: 2026-11-03

This document is the source of truth for Musique's time-synced lyrics work. It
describes what is implemented, why it is built this way, and how to diagnose
it.

> Status: Apple Music private TTML fetching, parsing, LRCLIB fallback and
> per-syllable fullscreen rendering are implemented. Tracks from every source
> (Apple Music, Spotify, Web Scrobbler) are eligible for Apple catalog matching
> and TTML retrieval. Successful TTML responses are prefetched on every
> selected-track change and cached on disk; fullscreen is only a consumer.

## Goal and scope

For a track playing in Music.app or Spotify, Musique should:

1. Read the current track metadata and playback position.
2. Resolve the corresponding Apple Music catalog song ID.
3. Fetch Apple's undocumented `syllable-lyrics` resource.
4. Retain line and syllable timing from the returned TTML.
5. Render karaoke-style progress in the fullscreen lyrics UI.
6. Fall back to LRCLIB when Apple lyrics are unavailable.
7. Persist the original TTML locally for reuse.

The implementation uses [MusanovaKit](https://github.com/rryam/MusanovaKit),
currently resolved to version `4.0.0` (revision
`17793dc4ecfb3e8cacd6a117fcbcc273b78501e2`). MusanovaKit wraps Apple Music's
privileged request and supplies the TTML parser. This remains a private,
undocumented Apple endpoint and can change without notice.

## Files

| File | Responsibility |
| --- | --- |
| `project.yml` | Adds MusanovaKit `from: 4.0.0` and links it to the main app target. |
| `Musique/Sources/Lyrics/LyricsService.swift` | Apple TTML client, catalog matching, token discovery, TTML-to-local-model mapping, LRCLIB fallback, prefetcher, and local TTML cache. |
| `Musique/Sources/App.swift` | Attaches `LyricsPrefetcher` before `PlayerMonitor.start()`. |
| `Musique/Sources/UI/AnimationFullscreenView.swift` | Loads lyrics for the active source and renders timed syllable highlighting at up to 30 fps. |
| `MusiqueTests/MusiqueTests.swift` | Tests segment highlighting, artist matching, Spotify eligibility, stable TTML cache keys, and the lookup identity. |

Because `Musique.xcodeproj` is generated, edit `project.yml`, then run
`xcodegen generate`. Do not make lasting dependency changes only in the
generated Xcode project.

## End-to-end data flow

```text
Music.app
  │ ScriptingBridge + distributed player notification
  ▼
PlayerMonitor.snapshot: NowPlayingSnapshot
  │ artist, title, album, duration, position, source, persistentID
  ├─ LyricsPrefetcher (application lifetime, once per track identity)
  └─ AnimationFullscreenView.task(id: stable lyrics identity)
  ▼
LyricsService.lines(..., source: snapshot.source)
  ├─ any source (Apple Music, Spotify, Web Scrobbler)
  │    ▼
  │  AppleMusicLyricsClient.lines(...)
  │    1. Local TTML cache lookup
  │    2. MusicKit subscriber authorization
  │    3. AMPWebPlay developer-token discovery
  │    4. Apple catalog search, then iTunes ID lookup fallback
  │    5. MusanovaKit MusicLyricsRequest → /syllable-lyrics
  │    6. Save locally, parse line + syllable timings
  │
  └─ Apple authorization, match, fetch, or parse failure
       ▼
     LRCLIB exact lookup → search fallback → LyricsFile/LRC parser

LyricLine[]
  ▼
FullscreenLyricsView → KaraokeLyricText for the current timed line
```

`PlayerMonitor` publishes position once per second. `KaraokeLyricText`
extrapolates the position between snapshots using an animation timeline, so
short syllables do not advance in one-second jumps.

`LyricsPrefetcher` is attached in `AppDelegate` before `PlayerMonitor.start()`.
It observes the edited selected snapshot, ignores position/state-only updates,
cancels obsolete work when the selected track changes, and requests lyrics as
soon as a valid artist/title is available. Therefore the local TTML cache no
longer depends on opening fullscreen.

## Local lyrics model

`LyricsService.swift` defines two local value types:

```swift
struct TimedLyricSegment: Equatable {
    let text: String
    let start: Double
    let end: Double
}

struct LyricLine: Equatable {
    let time: Double
    var end: Double?
    let text: String
    var segments: [TimedLyricSegment]
}
```

Times are seconds relative to the start of the track.

- Apple TTML normally yields multiple `segments` per line.
- LRCLIB `lyricsfile` provides line start/end but no syllable segments.
- Plain LRC provides line start only; its effective end is the next line.
- `highlightOpacity(at:)` returns `0.28` before a segment, interpolates from
  `0.35` to `1.0` while it is sung, and returns `1.0` afterward.

Do not collapse TTML to only line text/timestamps: preserving `segments` is what
makes karaoke highlighting possible.

## Apple Music private request flow

### 1. MusicKit subscriber authorization

`AppleMusicLyricsClient.lines` checks `MusicAuthorization.currentStatus` and
calls `MusicAuthorization.request()` when the status is `.notDetermined`.
Anything other than `.authorized` produces no Apple lyrics and allows the
caller to use LRCLIB.

The app declares `NSAppleMusicUsageDescription`. Do **not** add a made-up
`com.apple.developer.musickit` entitlement: MusicKit access is configured as an
App Service/capability, and the current signed app builds and fetches without
that entitlement.

### 2. Resolve a short-lived AMPWebPlay token

MusanovaKit's privileged request requires a developer token. Musique does not
embed a long-lived secret. It currently:

1. GETs `https://music.apple.com/th/new`;
2. extracts the first versioned script matching
   `/assets/index~[A-Za-z0-9]+.js`;
3. scans the script for JWT-shaped strings;
4. base64url-decodes each JWT payload without treating that as signature
   verification;
5. selects a non-expired token whose `iss` claim is `AMPWebPlay`; and
6. caches it until 60 seconds before its `exp` time.

The token is only an input to Apple requests. Never log it, persist it, return
it from the debug server, or put it in a test fixture.

This scraper is deliberately isolated in `webPlaybackToken()`, because the web
page/script naming or token placement is the most likely part to break.

### 3. Resolve the catalog song ID

Primary lookup:

```text
GET https://amp-api.music.apple.com/v1/catalog/th/search
    ?term={title artist}&types=songs&limit=10
Authorization: Bearer {AMPWebPlay JWT}
```

Candidates must have `hasLyrics == true`, an exactly normalized title, and a
matching artist credit. Album equality adds 1,000 points; duration difference
in seconds is subtracted. The highest-scoring candidate wins.

The hostname matters: the AMPWebPlay token is issued for the AMP web-player
host. Using the normal public API hostname can reject a token which works for
the privileged endpoint.

Fallback lookup:

```text
GET https://itunes.apple.com/search
    ?term={title artist}&country=th&entity=song&limit=25
```

The public iTunes search result's numeric `trackId` is the same Adam ID used by
Apple Music. This endpoint is lookup-only; MusanovaKit still performs the
authenticated lyrics request.

### Artist matching and the Supernova Love regression

Music.app can expose only a primary artist while the catalog exposes every
credit. The concrete failure was:

```text
Music.app:  IVE — Supernova Love
Catalog:    IVE & David Guetta — Supernova Love
Song ID:    1776623957
```

Exact flattened artist equality therefore rejected the correct song.
`AppleMusicMetadataMatcher.artistsMatch` now splits credits on `&`, comma, `/`,
`;`, `×`, `x`, `feat.`, `featuring`, and `with`, then case/diacritic-folds and
removes non-alphanumeric characters. A non-empty intersection counts as a
match. This also allows reordered credits such as `IVE & Saweetie` versus
`Saweetie, IVE`.

The matcher is intentionally permissive once the title is exact. If false
positives appear for generic artist names, improve candidate scoring rather
than returning to exact display-string equality.

### 4. Fetch the syllable-lyrics resource

After resolving the ID, the app executes:

```swift
let request = try MusicLyricsRequest(
    songID: MusicItemID(songID),
    developerToken: developerToken
)
let response = try await request.response(countryCode: "th")
let ttml = response.rawTTML
```

MusanovaKit constructs the privileged Apple Music path:

```text
catalog/th/songs/{songID}/syllable-lyrics
```

Its `MusicPrivilegedDataRequest` uses MusicKit's request machinery so the
authorized subscriber's Music User Token is attached. Do not replace this with
a plain `URLSession` request containing only the developer token; that loses the
subscriber authorization required by the endpoint.

### 5. Parse and map TTML

`LyricsParser().parse(ttml)` produces paragraphs, lines, and timed segments.
Musique flattens paragraphs in document order and maps each parsed line to the
local `LyricLine`:

- `time` = first segment start;
- `end` = last segment end;
- `text` = MusanovaKit's reconstructed line text;
- `segments` = every parsed segment's text/start/end.

Lines without a first segment are dropped, and the result is sorted by line
start time. The parsed API still returns only `LyricLine` values, but the
original `rawTTML` is retained in the local cache.

## Local TTML cache

Raw TTML is kept on disk so each song costs one trip to the private endpoint per
machine:

```text
~/Library/Application Support/Musique/TTML/{artist-title-hash}.ttml
```

`TTMLCacheKey` creates a readable, filesystem-safe prefix and a stable FNV-1a
hash from normalized artist, title, album, and rounded duration. It does not use
Swift `hashValue`, because that value changes between launches.

On a memory-cache miss, `AppleMusicLyricsClient` checks the disk cache
(`TTMLDiskCache`) before going to Apple. After a new Apple fetch it atomically
writes the file. A failed write is logged and otherwise ignored; the parsed
lyrics are still returned. `scripts/wipe-user-data.sh` clears the cache along
with the rest of `~/Library/Application Support/Musique/`.

## LRCLIB fallback

`LyricsService.lines` uses `AppleLyricsSourcePolicy` to decide whether the
current player source can attempt Apple TTML. Every source — `.appleMusic`,
`.spotify` and `.webScrobbler` — is allowed. A Spotify or browser snapshot
supplies title, artist, album, and duration to the same Apple catalog matcher;
no Spotify Web API or Spotify OAuth is required. After an Apple authorization,
token, catalog-match, privileged-request, or TTML-parsing failure, every source
falls back to LRCLIB.

Keep the playback source in the cache key even though every source can
resolve Apple TTML. Music.app, Spotify and the browser may report different album strings,
artist credits, durations, or editions for what appears to be the same track.

The LRCLIB sequence is:

1. `/api/get` with artist, track, album, and rounded duration;
2. `/api/search` with artist and track if the exact query misses;
3. choose the timed result with the nearest duration;
4. prefer the YAML `lyricsfile` parser because it includes line end times;
5. fall back to `syncedLyrics` LRC.

The cache key is:

```text
{source}|{artist}|{title}|{album}|{integer duration}
```

Empty arrays are cached as well. This avoids repeated network calls, but it
also means granting Music access or recovering from a temporary private-API
failure will not retry that track until the process restarts. A future cache
revision should distinguish stable “no lyrics” from transient/auth failures and
add explicit invalidation or a TTL.

## Fullscreen rendering

`AnimationFullscreenView` starts one async load per `trackKey` via
`.task(id:)`. It clears the old song immediately but keeps the split layout up
with `lyricsPending` to prevent a full-screen layout flash during track changes.
The key comes from `LyricsLookupIdentity`, shared with the prefetcher, and does
not include playback position or playing/paused state. In the normal path this
call is an immediate hit in `LyricsService`'s parsed memory cache.

`FullscreenLyricsView`:

- determines the current line from `line.time <= position`;
- scrolls that line to an anchor at 42% of the viewport height;
- inserts `• • •` for instrumental gaps longer than five seconds when reliable
  line-end timing exists; and
- uses `KaraokeLyricText` only for the current line when it has timed segments.

`KaraokeLyricText` runs at a maximum of 30 fps while playing. It anchors the
latest snapshot position to `Date()` and advances locally until the next player
snapshot arrives. Only the current line is placed on this animation clock, so
the entire lyrics column is not needlessly recomputed at 30 fps.

MusanovaKit segment text omits whitespace separators. The renderer locates each
segment sequentially inside the complete `line.text`, appends intervening
literal whitespace, and builds one concatenated SwiftUI `Text`; this preserves
normal line wrapping. If segment-to-line matching fails, it safely renders the
whole line in white.

When Reduce Motion is enabled, or playback is paused, the timeline pauses and
uses the snapshot position directly.

## Logging and diagnosis

Relevant log messages all start with `[Lyrics]`:

| Log | Interpretation |
| --- | --- |
| `Prefetch started: source=... artist=... title=...` | A selected-track change triggered eager loading without fullscreen. |
| `Lookup started: ...` / `Lookup finished: ...` | The shared lyrics pipeline ran and reports its final parsed-line count. |
| `Parsed memory cache hit: ...` | Fullscreen reused the eager result without another network request. |
| `MusicKit authorization status: N` | Subscriber access is not authorized. |
| `Unable to resolve Apple Music web playback token` | Apple changed the web bundle/token, the network failed, or no valid AMPWebPlay JWT was found. |
| `No Apple Music catalog match for ARTIST — TITLE` | Both AMP catalog and iTunes lookups failed candidate matching. |
| `Apple Music TTML fetched: song=ID lines=N bytes=N` | Private fetch and parse succeeded. |
| `Apple Music syllable lyrics failed: ...` | MusanovaKit request/decoding failed. |

Use `/usr/bin/log`, because `log` is a zsh builtin in this environment:

```sh
/usr/bin/log show --last 15m --info --debug \
  --predicate 'process == "Musique" AND (composedMessage CONTAINS "[Lyrics]" OR composedMessage CONTAINS "TTML" OR composedMessage CONTAINS "syllable")'
```

For a live failure, record all of these before changing matching logic:

- source (`apple_music`, `spotify` or `web_scrobbler`);
- Music.app title, artist, album, duration, and persistent ID;
- candidate catalog title, artist, album, duration, `hasLyrics`, and Adam ID;
- Music authorization status;
- exact `[Lyrics]` log line; and
- whether LRCLIB supplied the visible lyrics instead.

The existing debug server's `/api/snapshot` and `/api/raw?refresh=1` endpoints
help compare normalized UI metadata with Music.app's raw ScriptingBridge data.

## Verified behavior

Live signed-app smoke tests have successfully fetched and parsed Apple TTML.
Recorded examples include:

| Track / ID | Observed result |
| --- | --- |
| `All Night` — IVE & Saweetie, `1725388355` | 56 parsed lines, 26,398 TTML bytes. |
| Song `1709569706` | 55 lines, 6,852 bytes. |
| Song `1685789441` | 74 lines, 22,717 bytes. |
| Song `1680047366` | 49 lines, 16,905 bytes. |
| Song `1680047542` | 67 lines, 23,429 bytes. |

The full suite last passed with 23 tests and 0 failures (2026-11-03, isolated
DerivedData).

## Build and test procedure

Regenerate after dependency/project changes:

```sh
xcodegen generate
```

Preferred verification is a signed Run from Xcode. The repository-wide signing
warning in `CLAUDE.md` is important: never build with
`CODE_SIGNING_ALLOWED=NO` into shared DerivedData. For a command-line compile or
test check, use an isolated temporary DerivedData path:

```sh
xcodebuild \
  -project Musique.xcodeproj \
  -scheme Musique \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/musique-ttml-derived \
  test
```

Focused tests:

```sh
xcodebuild \
  -project Musique.xcodeproj \
  -scheme Musique \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/musique-ttml-derived \
  test \
  -only-testing:MusiqueTests/MusiqueTests/testTTMLSegmentHighlightProgress

xcodebuild \
  -project Musique.xcodeproj \
  -scheme Musique \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/musique-ttml-derived \
  test \
  -only-testing:MusiqueTests/MusiqueTests/testAppleMusicArtistMatcherAcceptsCatalogCollaborators
```

The test host may take unusually long to start because the app initializes its
audio-tap and other lifecycle services. A slow first test is not by itself a
TTML failure.

Manual acceptance test:

1. Run a correctly signed app from Xcode.
2. Ensure Music.app is signed in and play a catalog track known to have synced
   lyrics.
3. Grant the Music/Media permission prompt if shown.
4. Open Musique's fullscreen player and enable lyrics.
5. Confirm the log reports `Apple Music TTML fetched` rather than only showing
   LRCLIB output.
6. Confirm the current line advances by syllable, remains in sync after
   pause/resume and seek, and stops animating under Reduce Motion.
7. Test `IVE — Supernova Love`; it should resolve catalog ID `1776623957`
   despite the catalog credit `IVE & David Guetta`.
8. Play a Spotify track which also exists in Apple Music and confirm the log
   reports `Apple Music TTML fetched`; if matching or authorization fails, the
   UI must still fall back to LRCLIB.

## Known fragility and follow-up improvements

- The Apple endpoint and MusanovaKit behavior are undocumented and may break.
- The storefront is hard-coded to `th` in web token discovery, search, iTunes
  lookup, and lyrics response. Centralize it before supporting other regions.
- The web bundle regex assumes one `index~HASH.js` path. Add diagnostics and a
  more tolerant script discovery strategy if Apple changes its asset graph.
- A cached AMP token is not invalidated and retried immediately after an
  authentication failure. Retry once with a freshly discovered token.
- Catalog lookup error paths currently become `nil`, losing HTTP status and
  response details. Typed internal errors will make API responses and logs much
  more useful.
- Artist-credit intersection may be too permissive for ambiguous titles. Album,
  duration, ISRC, and catalog relationship data can strengthen scoring.
- `LyricsParser.parse` returns an empty array for malformed TTML. Use
  `parseValidating` where the API needs to distinguish malformed data from an
  empty lyrics resource.
- The in-memory parsed-lyrics cache has no TTL or explicit invalidation and
  caches transient misses. Successful raw TTML disk entries are durable.
- There is no fixture-based TTML mapping test in Musique yet. Add a small,
  synthetic TTML fixture; do not commit full commercial song lyrics.
- The code logs only a localized error string. Log a sanitized error category
  and upstream status, but never tokens or full TTML.

## Agent continuation checklist

Before making further changes:

1. Read `CLAUDE.md` and this file completely.
2. Confirm MusanovaKit still resolves to 4.0.0 after `xcodegen generate`.
3. Inspect `LyricsService.swift`, `AnimationFullscreenView.swift`, and the
   TTML-related tests.
4. Do not remove the LRCLIB fallback.
5. If another component (e.g. a debug endpoint) needs lyrics, reuse the
   `LyricsService` actor; do not duplicate the Apple request.
6. Never expose or log the AMPWebPlay token, Music User Token, cookies, or
   request authorization headers.
7. Regenerate the project after `project.yml` changes.
8. Test in isolated DerivedData, then do a signed Xcode Run for the live private
   request.
9. Update this document when behavior changes.
