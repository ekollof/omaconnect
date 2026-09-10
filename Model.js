// Pure parsing / formatting helpers for the kcd backend.
// No Qt imports: every function takes primitives and returns primitives,
// so rows moving between lists never carry backend objects.

// --- devices (`kcd devices --json`) ---
// Actual keys are lowercase: {id, name, type, state, cert_fp, last_seen, connected}
function parseDevicesJson(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: true, devices: [] }
  var parsed = null
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "devices: invalid JSON", devices: [] }
  }
  if (!parsed || typeof parsed.length !== "number") return { ok: true, devices: [] }
  var devices = []
  for (var i = 0; i < parsed.length; i++) {
    var d = parsed[i] || {}
    devices.push({
      id: String(d.id || ""),
      name: String(d.name || "Unknown device"),
      type: String(d.type || "phone"),
      state: String(d.state || "UNKNOWN"),
      connected: d.connected === true
    })
  }
  return { ok: true, devices: devices }
}

function isPaired(device) {
  return !!device && String(device.state || "").toLowerCase() === "paired"
}

function pairRequestedByPeer(device) {
  return !!device && String(device.state || "").toLowerCase() === "pairrequestedbypeer"
}

function stateLabel(device) {
  if (!device) return "Unknown"
  if (device.connected !== true) return "Offline"
  var s = String(device.state || "UNKNOWN").toLowerCase()
  if (s === "paired") return "Paired"
  if (s === "pairrequested") return "Pair requested…"
  if (s === "pairrequestedbypeer") return "Wants to pair"
  return "Unpaired"
}

function typeIcon(type) {
  var t = String(type || "").toLowerCase()
  if (t === "tablet") return "󰓶"
  if (t === "laptop" || t === "desktop") return "󰌽"
  if (t === "tv") return "󰑛"
  return "󰄜" // phone
}

// --- status (`kcd status --json`) ---
function parseStatusJson(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, error: "empty status output" }
  var parsed = null
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "status: invalid JSON" }
  }
  return {
    ok: true,
    version: String(parsed.version || ""),
    uptimeHuman: String(parsed.uptimeHuman || ""),
    deviceCount: Number(parsed.deviceCount || 0),
    connectedCount: Number(parsed.connectedCount || 0)
  }
}

// --- doctor (`kcd doctor`) ---
// Doctor prints a coloured pass/fail table; parse the plain-text outcome per line.
function parseDoctorLine(line) {
  var text = String(line || "").replace(/\x1b\[[0-9;]*m/g, "").trim()
  var m = /^(✗|✓|×|x|v)\s+(.+?)(?:\s+[—–-]\s+(.*))?$/.exec(text)
  if (!m) return null
  return { ok: m[1] === "✓" || m[1] === "v", name: m[2].trim(), detail: (m[3] || "").trim() }
}

// --- watch (`kcd watch --json`) ---
// Envelope: {type, timestamp, deviceId, payload}. Returns null for blank lines;
// {malformed:true} for unparseable lines so the caller can ignore them safely.
function parseWatchLine(line) {
  var text = String(line || "").trim()
  if (text === "") return null
  var parsed = null
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return { malformed: true }
  }
  if (!parsed || typeof parsed.type !== "string") return { malformed: true }
  return {
    type: parsed.type,
    timestamp: String(parsed.timestamp || ""),
    deviceId: String(parsed.deviceId || ""),
    payload: (parsed.payload && typeof parsed.payload === "object") ? parsed.payload : {}
  }
}

function str(payload, key, fallback) {
  var v = payload ? payload[key] : undefined
  return (v === undefined || v === null) ? (fallback || "") : String(v)
}

function num(payload, key, fallback) {
  var v = payload ? Number(payload[key]) : NaN
  return isFinite(v) ? v : (fallback || 0)
}

// --- mpris (`kcd mpris status --json`) ---
// Array of player states; first entry carrying a title wins, else null.
function parseMprisStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null
  var parsed = null
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed.length !== "number") return null
  for (var i = 0; i < parsed.length; i++) {
    var p = parsed[i] || {}
    var title = String(p.title || "")
    if (title === "") continue
    return {
      player: String(p.player || ""),
      title: title,
      artist: String(p.artist || ""),
      album: String(p.album || ""),
      isPlaying: p.isPlaying === true
    }
  }
  return null
}

function nowPlayingLabel(nowPlaying) {
  if (!nowPlaying) return "No media playing"
  var t = String(nowPlaying.title || "Unknown title")
  var a = String(nowPlaying.artist || "")
  return a !== "" ? t + " — " + a : t
}

// --- battery pill ---
function batteryIcon(charge, charging) {
  if (charging === true) return "󰂄"
  var c = Number(charge)
  if (!isFinite(c)) return "󰂑"
  if (c >= 95) return "󰁹"
  if (c >= 80) return "󰂂"
  if (c >= 60) return "󰁿"
  if (c >= 40) return "󰁽"
  if (c >= 20) return "󰁻"
  return "󰂎"
}

function batteryLabel(charge, charging) {
  var c = Number(charge)
  var text = isFinite(c) ? Math.round(c) + "%" : "—"
  return charging === true ? text + " 󰂄" : text
}
