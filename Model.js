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

// --- vCard 2.1 quoted-printable ---
// Phones emit non-ASCII display names QP-encoded ("=44=61=76=C3=AD=64" =
// "Davíd", UTF-8 bytes as =XX pairs) and naive parsers store them verbatim
// (upstream kcd#38). Decode: split on '=', every group between '='s must be
// exactly two hex digits, else bail untouched (a literal "a=b" name must
// never be mangled). Byte-wise UTF-8 decode, no TextDecoder in QML's ES5.
function _qpHexToByte(s) {
  var v = parseInt(s, 16)
  return (s.length === 2 && /^[0-9a-fA-F]{2}$/.test(s) && isFinite(v)) ? v : -1
}

function _utf8Decode(bytes) {
  var out = ""
  var i = 0
  while (i < bytes.length) {
    var b = bytes[i]
    var cp
    if (b < 0x80) {
      cp = b
      i += 1
    } else if (b >= 0xC2 && b <= 0xDF && i + 1 < bytes.length) {
      cp = ((b & 0x1F) << 6) | (bytes[i + 1] & 0x3F)
      i += 2
    } else if (b >= 0xE0 && b <= 0xEF && i + 2 < bytes.length) {
      cp = ((b & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F)
      i += 3
    } else if (b >= 0xF0 && b <= 0xF4 && i + 3 < bytes.length) {
      cp = ((b & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) | ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F)
      i += 4
    } else {
      // Invalid sequence: drop one byte, never mis-sync the stream.
      i += 1
      continue
    }
    if (cp > 0xFFFF) {
      cp -= 0x10000
      out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF))
    } else if (cp === 0) {
      out += String.fromCharCode(0xFFFD)
    } else {
      out += String.fromCharCode(cp)
    }
  }
  return out
}

function decodeQuotedPrintable(s) {
  var text = String(s || "")
  var first = text.indexOf("=")
  if (first < 0) return text
  var bytes = []
  // Literal prefix before the first =XX group: tolerated, kept verbatim.
  for (var p = 0; p < first; p++) bytes.push(text.charCodeAt(p) & 0xFF)
  var i = first
  var pairs = 0
  while (i < text.length) {
    if (text.charAt(i) !== "=") {
      // Non '=' text inside a QP run is literal (rare in FN, legal in RFC).
      bytes.push(text.charCodeAt(i) & 0xFF)
      i += 1
      continue
    }
    var v = _qpHexToByte(text.substr(i + 1, 2))
    if (v < 0) {
      // Invalid token: a pure QP run ended mid-group (kcd truncates QP names
      // at 256 bytes, upstream kcd#38). With enough preceding pairs the run
      // was clearly QP — decode the valid prefix and drop the mangled tail.
      // A stray '=' in a plain name (under 3 pairs) keeps the original.
      return pairs >= 3 ? _utf8Decode(bytes) : text
    }
    bytes.push(v)
    pairs += 1
    i += 3
  }
  // Full run: one pair could be a literal ("A=B2"), two real QP groups
  // ("=C3=A9" → é) are unambiguous enough to decode.
  if (pairs < 2) return text
  var decoded = _utf8Decode(bytes)
  return decoded === "" ? text : decoded
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

// --- version gate (kcd >= 1.18 has `contacts list --json`) ---
// Status reports versions like "1.18.0", "v1.18.0", or "dev" for local
// builds. Unknown/dev shapes fail closed (false) so the panel keeps the
// pre-1.18 manual-number behaviour instead of probing a missing subcommand.
function parseVersion(raw) {
  var m = /(\d+)\.(\d+)(?:\.(\d+))?/.exec(String(raw || ""))
  if (!m) return null
  return {
    major: parseInt(m[1], 10),
    minor: parseInt(m[2], 10),
    patch: m[3] !== undefined ? parseInt(m[3], 10) : 0
  }
}

function versionAtLeast(raw, major, minor) {
  var v = parseVersion(raw)
  if (!v) return false
  if (v.major !== major) return v.major > major
  return v.minor >= minor
}

function supportsContacts(raw) {
  return versionAtLeast(raw, 1, 18)
}

// Definitive missing-subcommand answers: pre-1.18 daemons have no
// `contacts` tree, so urfave/cli reports "No help topic" (exit non-zero).
// Only these exact shapes mark the daemon as contacts-incapable; any other
// failure stays transient so a later Refresh can still succeed.
function isContactsUnsupportedError(stdoutText, stderrText) {
  var hay = (String(stdoutText || "") + "\n" + String(stderrText || "")).toLowerCase()
  return hay.indexOf("no help topic") >= 0
    || hay.indexOf("unknown command") >= 0
    || hay.indexOf("unknown subcommand") >= 0
}
// --- contacts (`kcd contacts list <id> --json`) ---
// Shape per ContactSummary: {uid, name, phones[], emails[], timestamp}.
// Empty stdout with the "No cached contacts" hint means zero contacts, not
// an error. Anything unparseable is an error so the panel can show it.
// Capped at 2000 entries; field widths bound retained strings.
function parseContactsJson(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: true, contacts: [] }
  if (text.indexOf("No cached contacts") === 0) return { ok: true, contacts: [], empty: true }
  var r = safeParseJson(raw, 64)
  if (r.empty) return { ok: true, contacts: [] }
  if (r.malformed) return { ok: false, error: "contacts: invalid JSON", contacts: [] }
  var parsed = r.value
  if (!parsed || typeof parsed.length !== "number") return { ok: false, error: "contacts: unexpected shape", contacts: [] }
  var contacts = []
  var n = Math.min(parsed.length, 2000)
  for (var i = 0; i < n; i++) {
    var c = parsed[i] || {}
    // Decode BEFORE clipping: quoted-printable names are ~3x longer, and a
    // pre-decode slice would cut mid-=pair and ruin the UTF-8 decode.
    var name = decodeQuotedPrintable(str(c, "name", "", 512)).trim().slice(0, 100)
    var uid = str(c, "uid", "", 128)
    var phones = []
    var rawPhones = c.phones
    if (rawPhones && typeof rawPhones.length === "number") {
      for (var p = 0; p < rawPhones.length && phones.length < 10; p++) {
        var ph = String(rawPhones[p] || "").trim().slice(0, 64)
        if (ph !== "") phones.push(ph)
      }
    }
    var emails = []
    var rawEmails = c.emails
    if (rawEmails && typeof rawEmails.length === "number") {
      for (var e = 0; e < rawEmails.length && emails.length < 10; e++) {
        var em = String(rawEmails[e] || "").trim().slice(0, 128)
        if (em !== "") emails.push(em)
      }
    }
    if (name === "" && phones.length === 0) continue
    contacts.push({
      uid: uid,
      name: name !== "" ? name : (phones.length > 0 ? phones[0] : "Unknown"),
      phones: phones,
      emails: emails
    })
  }
  return { ok: true, contacts: contacts }
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
