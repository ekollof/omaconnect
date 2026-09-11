// Pure parsing / formatting helpers for the kcd backend.
// No Qt imports: every function takes primitives and returns primitives,
// so rows moving between lists never carry backend objects.

// JSON.parse has no depth limit, and a deeply nested payload could exhaust
// the QML engine stack before parsing even returns. Our wire shapes never
// nest deeper than 3 (envelope → payload → fields), so reject anything past
// 64 first. The string-aware scan fails closed on malformed input, which the
// parsers below already handle as graceful {ok:false} paths.
function nestingOk(text, limit) {
  var depth = 0
  var inStr = false
  var esc = false
  for (var i = 0; i < text.length; i++) {
    var c = text.charAt(i)
    if (inStr) {
      if (esc) esc = false
      else if (c === "\\") esc = true
      else if (c === '"') inStr = false
      continue
    }
    if (c === '"') inStr = true
    else if (c === "[" || c === "{") {
      depth++
      if (depth > limit) return false
    } else if (c === "]" || c === "}") {
      depth--
      if (depth < 0) return false
    }
  }
  return !inStr && depth === 0
}

function safeParseJson(raw, limit) {
  var text = String(raw || "").trim()
  if (text === "") return { empty: true }
  if (!nestingOk(text, limit || 64)) return { malformed: true }
  try {
    return { value: JSON.parse(text) }
  } catch (e) {
    return { malformed: true }
  }
}
// --- devices (`kcd devices --json`) ---
// Actual keys are lowercase: {id, name, type, state, cert_fp, last_seen, connected}
// Device registries are tiny; a hard cap keeps a malformed backend from
// inflating the model. Field widths bound retained strings.
// Device IDs double as JS object keys downstream (pendingPairs, batteries,
// live lookups). The protocol constrains them to [A-Za-z0-9_-]{32,38};
// anything else is rejected so crafted IDs can neither pollute prototypes
// nor escalate into unexpected keys.
function isDeviceId(id) {
  return /^[A-Za-z0-9_-]{32,38}$/.test(String(id || ""))
}
function parseDevicesJson(raw) {
  var r = safeParseJson(raw, 64)
  if (r.empty) return { ok: true, devices: [] }
  if (r.malformed) return { ok: false, error: "devices: invalid JSON", devices: [] }
  var parsed = r.value
  if (!parsed || typeof parsed.length !== "number") return { ok: true, devices: [] }
  var devices = []
  var n = Math.min(parsed.length, 256)
  for (var i = 0; i < n; i++) {
    var d = parsed[i] || {}
    var id = str(d, "id", "", 64)
    if (!isDeviceId(id)) continue
    devices.push({
      id: id,
      name: str(d, "name", "Unknown device", 100),
      type: str(d, "type", "phone", 20),
      state: str(d, "state", "UNKNOWN", 32),
      connected: d.connected === true
    })
  }
  return { ok: true, devices: devices }
}

function isPaired(device) {  return !!device && String(device.state || "").toLowerCase() === "paired"
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
  var r = safeParseJson(raw, 64)
  if (r.empty) return { ok: false, error: "empty status output" }
  if (r.malformed) return { ok: false, error: "status: invalid JSON" }
  var parsed = r.value
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
  var raw = String(line || "").trim()
  if (raw === "") return null
  var r = safeParseJson(raw, 64)
  if (r.malformed || r.empty) return { malformed: true }
  var parsed = r.value
  if (!parsed || typeof parsed.type !== "string") return { malformed: true }
  return {
    type: parsed.type,
    timestamp: String(parsed.timestamp || ""),
    deviceId: String(parsed.deviceId || ""),
    payload: (parsed.payload && typeof parsed.payload === "object") ? parsed.payload : {}
  }
}

function str(payload, key, fallback, max) {
  var v = payload ? payload[key] : undefined
  var s = (v === undefined || v === null) ? (fallback || "") : String(v)
  if (max && s.length > max) return s.slice(0, max)
  return s
}

function num(payload, key, fallback) {
  var v = payload ? Number(payload[key]) : NaN
  return isFinite(v) ? v : (fallback || 0)
}

// --- mpris (`kcd mpris status --json`) ---
// Array of player states; first entry carrying a title wins, else null.
function parseMprisStatus(raw) {
  var r = safeParseJson(raw, 64)
  if (r.empty || r.malformed) return null
  var parsed = r.value
  if (!parsed || typeof parsed.length !== "number") return null
  for (var i = 0; i < parsed.length; i++) {
    var p = parsed[i] || {}
    var title = str(p, "title", "", 300)
    if (title === "") continue
    return {
      player: str(p, "player", "", 100),
      title: title,
      artist: str(p, "artist", "", 300),
      album: str(p, "album", "", 300),
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

// --- sftp (`kcd sftp mount` prints "Mounted at: <path>") ---
function parseMountPoint(output) {
  var text = String(output || "")
  var m = /Mounted at:\s*(\S+)/.exec(text)
  return m ? m[1] : ""
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

// --- contacts (learned from call/SMS events; kcd has no phonebook API) ---
// Extract a dialable number from free text (digits, +, spaces, dashes,
// parens). Returns "" when nothing dialable is present.
function dialable(value) {
  var s = String(value || "")
  var digits = s.replace(/[^0-9+]/g, "")
  if (digits.replace(/[^0-9]/g, "").length < 3) return ""
  return s.trim().slice(0, 100)
}

// Live completion over learned contacts: substring match on name or number,
// most-recent first, capped. Empty query returns the head of the list.
function matchContacts(contacts, query, limit) {
  var list = contacts || []
  var q = String(query || "").trim().toLowerCase()
  var out = []
  var max = limit || 6
  for (var i = 0; i < list.length && out.length < max; i++) {
    var c = list[i] || {}
    var name = String(c.name || "")
    var number = String(c.number || "")
    if (q !== "" && name.toLowerCase().indexOf(q) < 0
        && number.toLowerCase().indexOf(q) < 0) continue
    out.push({ name: name, number: number })
  }
  return out
}
