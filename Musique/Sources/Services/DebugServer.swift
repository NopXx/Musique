import Foundation
import Network

@MainActor
final class DebugServer {
    static let shared = DebugServer()

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private(set) var port: UInt16 = 0
    private weak var playerMonitor: PlayerMonitor?
    private var cachedRaw: [String: Any] = [:]
    private var cachedRawKey: String = ""

    func attach(monitor: PlayerMonitor) {
        self.playerMonitor = monitor
    }

    func start(port requested: UInt16 = 8765) {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback
            let nwPort = NWEndpoint.Port(rawValue: requested) ?? .any
            let l = try NWListener(using: params, on: nwPort)
            l.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.port = l.port?.rawValue ?? requested
                        NSLog("[DebugServer] ready on http://127.0.0.1:\(self.port)")
                    case .failed(let err):
                        NSLog("[DebugServer] failed: \(err)")
                        self.stop()
                    default: break
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            NSLog("[DebugServer] start error: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
        port = 0
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        connections[id] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let conn = conn else { return }
            Task { @MainActor in
                if case .cancelled = state { self?.connections.removeValue(forKey: ObjectIdentifier(conn)) }
                if case .failed = state { self?.connections.removeValue(forKey: ObjectIdentifier(conn)) }
            }
        }
        conn.start(queue: .main)
        receive(on: conn, buffer: Data())
    }

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isEOF, error in
            Task { @MainActor in
                guard let self = self else { return }
                if let error = error { NSLog("[DebugServer] recv error: \(error)"); conn.cancel(); return }
                var buf = buffer
                if let data = data { buf.append(data) }
                if let headerEnd = buf.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                    let head = buf.subdata(in: 0..<headerEnd.lowerBound)
                    self.handleRequest(head: head, on: conn)
                } else if isEOF {
                    conn.cancel()
                } else {
                    self.receive(on: conn, buffer: buf)
                }
            }
        }
    }

    private func handleRequest(head: Data, on conn: NWConnection) {
        guard let text = String(data: head, encoding: .utf8) else { send(status: 400, body: Data(), conn: conn); return }
        let firstLine = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { send(status: 400, body: Data(), conn: conn); return }
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        let query = target.dropFirst(path.count).hasPrefix("?") ? String(target.dropFirst(path.count + 1)) : ""
        let forceRefresh = query.contains("refresh=1")

        switch path {
        case "/", "/index.html":
            send(status: 200, contentType: "text/html; charset=utf-8", body: Self.indexHTML.data(using: .utf8) ?? Data(), conn: conn)
        case "/api/all":
            sendJSON(payload: collectAll(), conn: conn)
        case "/api/snapshot":
            sendJSON(payload: collectSnapshot(), conn: conn)
        case "/api/raw", "/api/raw/refresh":
            let force = forceRefresh || path == "/api/raw/refresh"
            sendJSON(payload: cachedOrFetchRaw(force: force), conn: conn)
        case "/api/pending":
            Task { @MainActor in
                let items = await HistoryStore.shared.loadPendingScrobbles(limit: 200)
                let payload: [String: Any] = ["count": items.count, "items": items.map(Self.encodePending)]
                self.sendJSON(payload: payload, conn: conn)
            }
        case "/api/settings":
            sendJSON(payload: SettingsStore.shared.publicSnapshot(), conn: conn)
        case "/api/audio":
            sendJSON(payload: collectAudio(), conn: conn)
        default:
            send(status: 404, body: Data("not found".utf8), conn: conn)
        }
    }

    private func collectSnapshot() -> [String: Any] {
        guard let s = playerMonitor?.snapshot else { return [:] }
        var out: [String: Any] = [
            "state": s.state,
            "title": s.title,
            "artist": s.artist,
            "album": s.album,
            "duration": s.duration,
            "position": s.position,
            "persistentID": s.persistentID,
            "isPlaying": s.isPlaying,
            "hasTrack": s.hasTrack,
        ]
        // What the player reports, before edit rules. Every UI surface — mini
        // player, menu bar, lock screen, widget — shows the rewritten values, so
        // carry those too when a rule changes something; otherwise the dashboard
        // and the app look like they disagree about the same track.
        let edited = EditHistoryService.shared.apply(s)
        if edited.title != s.title || edited.artist != s.artist || edited.album != s.album {
            out["edited"] = [
                "title": edited.title,
                "artist": edited.artist,
                "album": edited.album,
            ]
        }
        return out
    }

    private func collectAll() -> [String: Any] {
        [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "snapshot": collectSnapshot(),
            "audio": collectAudio(),
            "settings": SettingsStore.shared.publicSnapshot(),
            "rawCacheKey": cachedRawKey,
        ]
    }

    private func collectAudio() -> [String: Any] {
        let monitor = MusicAudioLevelMonitor.shared
        let snap = monitor.magnitudesSnapshot()
        let rate = snap.sampleRate
        let mags = snap.bins
        let fftSize = Float(MusicAudioLevelMonitor.fftSize)
        let binWidth = rate / fftSize

        let octaveCenters: [Float] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let octave = octaveCenters.map { center -> [String: Any] in
            let lo = center / sqrtf(2)
            let hi = center * sqrtf(2)
            let level = Self.aggregate(mags: mags, fromHz: lo, toHz: hi, binWidth: binWidth)
            return ["center": center, "lo": lo, "hi": hi, "level": level]
        }

        let log32 = Self.logBands(count: 32, minHz: 30, maxHz: min(rate / 2 * 0.9, 16000), mags: mags, binWidth: binWidth)

        let subBassRanges: [(String, Float, Float)] = [
            ("sub_low", 20, 40),
            ("sub_high", 40, 60),
            ("sub_full", 20, 60),
        ]
        let subBass = subBassRanges.reduce(into: [String: Any]()) { dict, item in
            dict[item.0] = ["lo": item.1, "hi": item.2,
                            "level": Self.aggregate(mags: mags, fromHz: item.1, toHz: item.2, binWidth: binWidth)]
        }

        let default10 = Self.logBands(count: 10, minHz: 60, maxHz: min(rate / 2 * 0.9, 14000), mags: mags, binWidth: binWidth)

        return [
            "bands": monitor.bands,                          // capped + boosted (matches UI)
            "bandsRaw": default10.map { $0["level"] ?? 0 },  // raw magnitudes
            "default10": default10,
            "sampleRate": rate,
            "binWidth": binWidth,
            "fftSize": Int(fftSize),
            "octave": octave,
            "log32": log32,
            "subBass": subBass,
        ]
    }

    private static func aggregate(mags: [Float], fromHz: Float, toHz: Float, binWidth: Float) -> Float {
        guard binWidth > 0, !mags.isEmpty else { return 0 }
        let b0 = max(1, Int(fromHz / binWidth))
        let b1 = max(b0 + 1, Int(toHz / binWidth))
        let end = min(mags.count, b1)
        guard end > b0 else { return 0 }
        var sum: Float = 0
        for i in b0..<end { sum += mags[i] }
        return sum / Float(end - b0)
    }

    private static func logBands(count: Int, minHz: Float, maxHz: Float, mags: [Float], binWidth: Float) -> [[String: Any]] {
        guard count > 0, maxHz > minHz else { return [] }
        let ratio = powf(maxHz / minHz, 1.0 / Float(count))
        var out: [[String: Any]] = []
        for i in 0..<count {
            let lo = minHz * powf(ratio, Float(i))
            let hi = minHz * powf(ratio, Float(i + 1))
            let level = aggregate(mags: mags, fromHz: lo, toHz: hi, binWidth: binWidth)
            out.append(["lo": lo, "hi": hi, "level": level])
        }
        return out
    }

    private func cachedOrFetchRaw(force: Bool) -> [String: Any] {
        let key = playerMonitor?.snapshot?.persistentID ?? ""
        if !force, !cachedRaw.isEmpty, key == cachedRawKey {
            return cachedRaw
        }
        let fresh = playerMonitor?.rawTrackInfo() ?? [:]
        cachedRaw = fresh
        cachedRawKey = key
        return fresh
    }

    private static func encodePending(_ p: PendingScrobble) -> [String: Any] {
        [
            "id": p.id,
            "artist": p.artist,
            "track": p.track,
            "album": p.album,
            "duration": p.duration,
            "timestamp": ISO8601DateFormatter().string(from: p.timestamp),
            "attempts": p.attempts,
            "lastError": p.lastError,
        ]
    }

    private func sendJSON(payload: Any, conn: NWConnection) {
        let safe = Self.sanitize(payload)
        let body: Data
        if JSONSerialization.isValidJSONObject(safe),
           let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]) {
            body = data
        } else {
            body = Data("{}".utf8)
        }
        send(status: 200, contentType: "application/json; charset=utf-8", body: body, conn: conn)
    }

    private static func sanitize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = sanitize(v) }
            return out
        }
        if let arr = value as? [Any] { return arr.map(sanitize) }
        if let f = value as? Float { return Double(f) }
        if JSONSerialization.isValidJSONObject([value]) { return value }
        return String(describing: value)
    }

    private func send(status: Int, contentType: String = "text/plain; charset=utf-8", body: Data, conn: NWConnection) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "OK"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static let indexHTML = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Musique Debug</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { font: 13px/1.45 ui-monospace, Menlo, monospace; margin: 0; padding: 16px; background: #0f1115; color: #e5e7eb; }
  h1 { font-size: 16px; margin: 0 0 12px; color: #fff; letter-spacing: 0.5px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .card { background: #1a1d24; border: 1px solid #262a33; border-radius: 8px; padding: 12px; min-width: 0; }
  .card h2 { font-size: 12px; text-transform: uppercase; margin: 0 0 8px; color: #94a3b8; letter-spacing: 1px; }
  .card h2 small { text-transform: none; letter-spacing: 0; color: #64748b; font-weight: 400; }
  pre { margin: 0; white-space: pre-wrap; word-break: break-word; font-size: 12px; color: #d1d5db; max-height: 360px; overflow: auto; }
  .topbar { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; flex-wrap: wrap; }
  .pill { background: #1a1d24; border: 1px solid #262a33; padding: 4px 8px; border-radius: 999px; color: #94a3b8; font-size: 11px; }
  .pill.live { color: #34d399; border-color: #134e3a; }
  button { background: #2563eb; color: #fff; border: 0; padding: 6px 12px; border-radius: 6px; cursor: pointer; font-family: inherit; font-size: 12px; }
  button:hover { background: #1d4ed8; }
  label { font-size: 12px; color: #94a3b8; }
  input[type=number] { width: 64px; background: #0f1115; color: #e5e7eb; border: 1px solid #262a33; padding: 4px 6px; border-radius: 4px; font: inherit; }
  .bands { display: flex; gap: 2px; align-items: flex-end; height: 80px; }
  .band { flex: 1; background: linear-gradient(180deg, #60a5fa, #2563eb); border-radius: 2px; will-change: height; transition: background 0.1s linear; }
  .band.clip { background: linear-gradient(180deg, #fca5a5, #ef4444); }
  .band.hot { background: linear-gradient(180deg, #fcd34d, #f59e0b); }
  .gain-label { font-size: 10px; color: #64748b; margin-left: 6px; }
</style>
</head>
<body>
  <div class="topbar">
    <h1>Musique Debug</h1>
    <span id="status" class="pill">init</span>
    <label>refresh <input id="ms" type="number" min="100" step="100" value="1000"> ms</label>
    <button id="toggle">pause</button>
    <button id="once">refresh</button>
  </div>
  <div class="grid">
    <div class="card"><h2>snapshot</h2><pre id="snapshot">—</pre></div>
    <div class="card"><h2>raw track <small>(cached — hit refresh to re-read)</small></h2><pre id="raw">—</pre></div>
    <div class="card">
      <h2>audio · default 10 (60Hz–14kHz log)</h2>
      <div class="bands" id="bands"></div>
      <pre id="bandsText" style="margin-top:8px"></pre>
    </div>
    <div class="card">
      <h2>audio · octave ISO (31.5Hz–16kHz)</h2>
      <div class="bands" id="octave"></div>
      <pre id="octaveText" style="margin-top:8px"></pre>
    </div>
    <div class="card" style="grid-column: 1/-1">
      <h2>audio · log32 (30Hz–16kHz)</h2>
      <div class="bands" id="log32" style="height:96px"></div>
      <pre id="log32Text" style="margin-top:8px;max-height:60px"></pre>
    </div>
    <div class="card">
      <h2>audio · sub-bass (20–60Hz)</h2>
      <pre id="subBass">—</pre>
    </div>
    <div class="card">
      <h2>audio · meta</h2>
      <pre id="audioMeta">—</pre>
    </div>
    <div class="card"><h2>pending scrobbles</h2><pre id="pending">—</pre></div>
    <div class="card" style="grid-column: 1/-1"><h2>settings</h2><pre id="settings">—</pre></div>
  </div>
<script>
const $ = id => document.getElementById(id);
function buildBars(parent, n) {
  parent.innerHTML = "";
  for (let i = 0; i < n; i++) {
    const b = document.createElement("div");
    b.className = "band"; b.style.height = "2%";
    parent.appendChild(b);
  }
}
buildBars($("bands"), 10);
buildBars($("octave"), 10);
buildBars($("log32"), 32);
const barState = new WeakMap();
function setTarget(parent, values, opts) {
  opts = opts || {};
  let s = barState.get(parent);
  if (!s || s.target.length !== values.length) {
    s = {
      target: new Float32Array(values.length),
      current: new Float32Array(values.length),
      peak: 0.01,
      autoGain: !!opts.autoGain,
    };
    barState.set(parent, s);
  }
  // running peak (decay slowly) for auto-gain normalization
  let maxV = 0;
  for (let i = 0; i < values.length; i++) {
    const v = Math.max(0, values[i] || 0);
    if (v > maxV) maxV = v;
  }
  s.peak = Math.max(s.peak * 0.992, maxV, 1e-4);
  const div = s.autoGain ? s.peak : 1;
  for (let i = 0; i < values.length; i++) {
    s.target[i] = Math.max(0, Math.min(1.2, (values[i] || 0) / div));
  }
}
function renderBars(parent, attack, decay) {
  const s = barState.get(parent);
  if (!s) return;
  const els = parent.children;
  for (let i = 0; i < els.length; i++) {
    const t = s.target[i] || 0;
    const c = s.current[i] || 0;
    const k = t > c ? attack : decay;
    const next = c + (t - c) * k;
    s.current[i] = next;
    const display = Math.min(1, next);
    els[i].style.height = (display * 100).toFixed(2) + "%";
    const cls = next >= 0.98 ? "band clip" : next >= 0.85 ? "band hot" : "band";
    if (els[i].className !== cls) els[i].className = cls;
  }
}
function gainText(parent) {
  const s = barState.get(parent);
  return s ? "peak=" + s.peak.toExponential(2) : "";
}
function fmtHz(hz) { return hz >= 1000 ? (hz/1000).toFixed(1) + "k" : Math.round(hz) + ""; }
let timer = null;
let running = true;
let lastRawKey = "";
let slowCounter = 0;

async function tickFast() {
  try {
    const all = await fetch("/api/all").then(r => r.json());
    $("snapshot").textContent = JSON.stringify(all.snapshot, null, 2);
    // audio handled by its own fast loop
    if (all.rawCacheKey !== lastRawKey) {
      lastRawKey = all.rawCacheKey;
      const raw = await fetch("/api/raw?refresh=1").then(r => r.json());
      $("raw").textContent = JSON.stringify(raw, null, 2);
    }
    slowCounter++;
    if (slowCounter >= 10) {
      slowCounter = 0;
      const [pending, settings] = await Promise.all([
        fetch("/api/pending").then(r => r.json()),
        fetch("/api/settings").then(r => r.json()),
      ]);
      $("pending").textContent = JSON.stringify(pending, null, 2);
      $("settings").textContent = JSON.stringify(settings, null, 2);
    }
    $("status").textContent = "live · " + new Date().toLocaleTimeString();
    $("status").className = "pill live";
  } catch (e) {
    $("status").textContent = "error: " + e.message;
    $("status").className = "pill";
  }
}

async function forceRefresh() {
  slowCounter = 10;
  lastRawKey = "__force__";
  await tickFast();
  const raw = await fetch("/api/raw?refresh=1").then(r => r.json());
  $("raw").textContent = JSON.stringify(raw, null, 2);
  lastRawKey = (raw && raw.track && raw.track.persistentID) || "";
}

function schedule() {
  if (timer) clearInterval(timer);
  const ms = Math.max(250, parseInt($("ms").value, 10) || 1000);
  if (running) timer = setInterval(tickFast, ms);
}

$("toggle").addEventListener("click", () => {
  running = !running;
  $("toggle").textContent = running ? "pause" : "resume";
  schedule();
});
$("once").addEventListener("click", forceRefresh);
$("ms").addEventListener("change", schedule);
forceRefresh(); schedule();

let audioTimer = null;
let audioMeta = {};
async function pollAudio() {
  try {
    const a = await fetch("/api/audio").then(r => r.json());
    // bands (capped+boosted by FFT processor) — no auto-gain, just show as-is
    setTarget($("bands"), a.bands || [], { autoGain: false });
    // octave / log32 use raw magnitudes — apply auto-gain to keep bars dynamic
    setTarget($("octave"), (a.octave || []).map(b => b.level), { autoGain: true });
    setTarget($("log32"), (a.log32 || []).map(b => b.level), { autoGain: true });
    $("bandsText").textContent = (a.bands || []).map(v => v.toFixed(3)).join("  ");
    $("octaveText").textContent = (a.octave || []).map(b => fmtHz(b.center) + ":" + b.level.toExponential(1)).join("  ") + "    " + gainText($("octave"));
    $("log32Text").textContent = (a.log32 || []).map(b => b.level.toExponential(1)).join(" ") + "    " + gainText($("log32"));
    $("subBass").textContent = JSON.stringify(a.subBass, null, 2);
    audioMeta = { sampleRate: a.sampleRate, binWidth: a.binWidth, fftSize: a.fftSize };
    $("audioMeta").textContent = JSON.stringify(audioMeta, null, 2);
  } catch (e) {}
}
audioTimer = setInterval(pollAudio, 50);
pollAudio();

const ATTACK = 0.55, DECAY = 0.12;
function frame() {
  renderBars($("bands"), ATTACK, DECAY);
  renderBars($("octave"), ATTACK, DECAY);
  renderBars($("log32"), ATTACK, DECAY);
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
</script>
</body>
</html>
"""#
}
