import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Backend bridge to the kcd daemon (AUR kcd-bin).
// One-shot state goes through short-lived `kcd … --json` processes;
// liveness comes from one long-lived `kcd watch --json` stream parsed
// line-by-line. All parsing lives in Model.js; this object only owns
// processes, timers, and plain-data properties for the panel.
Item {
  id: root

  property var settings: ({})

  // Daemon health: "checking" | "up" | "down" | "missing".
  property string daemonState: "checking"
  property bool kcdInstalled: true
  property string daemonVersion: ""
  property string daemonUptime: ""
  property int deviceCount: 0
  property int connectedCount: 0

  // Plain-data device rows: {id, name, type, state, connected}.
  property var devices: []
  // deviceId -> {charge, charging}.
  property var batteries: ({})
  // Replyable phone notifications, newest first (capped): {deviceId, replyId, appName, title, text, timestamp}.
  property var replyable: []
  // Pending outbound pair requests we initiated (deviceId -> true) so the
  // panel can show "Pair requested…" instead of flipping back to Unpaired.
  property var pendingPairs: ({})

  property bool refreshing: false
  property string actionStatus: ""
  property string lastError: ""
  property string doctorSummary: ""

  readonly property bool busy: statusProc.running || devicesProc.running || actionProc.running || doctorProc.running
  readonly property int refreshIntervalSec: {
    var n = parseInt(String(settings && settings.refreshIntervalSec !== undefined ? settings.refreshIntervalSec : 30), 10)
    if (!isFinite(n)) n = 30
    return Math.min(3600, Math.max(5, n))
  }
  readonly property int replyableLimit: 5

  // ---------- in-panel file browser (outbound share) ----------
  // Native Qt dialogs are out: instantiating the GTK platform file chooser
  // inside the shell process crashes quickshell (gvfs abort in the crash
  // log). Listing via `ls` and rendering rows in the panel instead.

  property string browseDir: ""
  property var browseEntries: [] // {name, isDir, path}
  property bool browseBusy: false

  function browseHome() {
    browse(Quickshell.env("HOME") || "/home")
  }

  function browseUp() {
    var dir = String(browseDir || "")
    if (dir === "" || dir === "/") {
      browse("/")
      return
    }
    var trimmed = dir.charAt(dir.length - 1) === "/" ? dir.slice(0, -1) : dir
    var slash = trimmed.lastIndexOf("/")
    browse(slash <= 0 ? "/" : trimmed.slice(0, slash))
  }

  function joinPath(dir, name) {
    var d = String(dir || "")
    var n = String(name || "")
    if (d === "" || d === "/") return "/" + n
    return d.charAt(d.length - 1) === "/" ? d + n : d + "/" + n
  }

  function browse(path) {
    var dir = String(path || "").trim()
    if (dir === "" || browseProc.running) return
    browseBusy = true
    browseProc.command = ["ls", "-1A", "-p", "--group-directories-first", "--", dir]
    browseProc.running = true
  }

  // First connected+paired device, or first connected device — the pill and
  // most actions target this one.
  readonly property var primaryDevice: {
    var list = devices || []
    for (var i = 0; i < list.length; i++)
      if (list[i] && list[i].connected && Model.isPaired(list[i])) return list[i]
    for (var j = 0; j < list.length; j++)
      if (list[j] && list[j].connected) return list[j]
    return null
  }

  readonly property var primaryBattery: {
    if (!primaryDevice) return null
    return batteries[primaryDevice.id] || null
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function deviceById(id) {
    var list = devices || []
    for (var i = 0; i < list.length; i++)
      if (list[i] && String(list[i].id) === String(id)) return list[i]
    return null
  }

  function deviceName(id) {
    var dev = deviceById(id)
    return dev ? dev.name : String(id || "Unknown device")
  }

  // ---------- polling ----------

  function refresh() {
    if (!statusProc.running) {
      refreshing = true
      statusProc.running = true
    }
  }

  function refreshDevices() {
    if (daemonState !== "up" || devicesProc.running) return
    devicesProc.running = true
  }

  // ---------- actions (all detached one-shots through actionProc) ----------

  property string _pendingAction: ""
  property string _pendingDeviceId: ""
  property string _actionOutput: ""

  function runAction(tag, deviceId, args) {
    if (actionProc.running) {
      lastError = "Another action is still running"
      return
    }
    _pendingAction = tag
    _pendingDeviceId = String(deviceId || "")
    _actionOutput = ""
    lastError = ""
    actionStatus = ""
    actionProc.command = ["kcd"].concat(args)
    actionProc.running = true
  }

  function pairDevice(id) {
    pendingPairs = Object.assign({}, pendingPairs, { [String(id)]: true })
    runAction("pair", id, ["pair", String(id)])
  }

  function unpairDevice(id) {
    runAction("unpair", id, ["unpair", String(id)])
  }

  function pingDevice(id) {
    runAction("ping", id, ["ping", String(id)])
  }

  function findPhone(id) {
    runAction("findmyphone", id, ["findmyphone", String(id)])
  }

  function muteCall(id) {
    runAction("mute", id, ["call", "mute", String(id)])
  }

  function shareFile(id, path) {
    var p = String(path || "").trim()
    if (p === "") {
      lastError = "Enter a file path to share"
      return
    }
    runAction("share", id, ["share", String(id), p])
  }

  function replyTo(deviceId, replyId, message) {
    var msg = String(message || "").trim()
    if (msg === "") {
      lastError = "Reply is empty"
      return
    }
    runAction("reply", deviceId, ["reply", String(deviceId), String(replyId), msg])
  }

  function enableDaemon() {
    // Explicit user gesture only — the plugin never enables the service itself.
    lastError = ""
    actionStatus = "Starting kcd…"
    Quickshell.execDetached(["systemctl", "--user", "enable", "--now", "kcd"])
    enableWait.restart()
  }

  // One-line JSON snapshot of backend state for `debugState` IPC probing.
  function debugSnapshot(sharePath) {
    var devs = []
    var list = devices || []
    for (var i = 0; i < list.length; i++) {
      devs.push({ id: String(list[i].id), name: list[i].name, state: list[i].state,
        connected: list[i].connected === true })
    }
    var bats = {}
    for (var id in batteries) {
      bats[id] = { charge: batteries[id].charge, charging: batteries[id].charging === true }
    }
    return JSON.stringify({
      daemon: daemonState, installed: kcdInstalled,
      devices: devs, batteries: bats,
      primary: primaryDevice ? String(primaryDevice.id) : null,
      browseDir: browseDir, browseCount: (browseEntries || []).length,
      browseBusy: browseBusy, replyable: (replyable || []).length,
      sharePath: String(sharePath || ""),
      action: actionStatus, error: lastError, doctor: doctorSummary
    })
  }

  function notify(title, body) {
    var t = String(title || "OMAConnect")
    var b = String(body || "")
    if (b === "") Quickshell.execDetached(["notify-send", t])
    else Quickshell.execDetached(["notify-send", t, b])
  }

  function dismissToastBySummary(summary) {
    var needle = String(summary || "")
    if (needle === "") return
    Quickshell.execDetached(["qs", "-c", "omarchy", "ipc", "call", "notifications", "dismiss", needle])
  }

  // ---------- watch stream ----------

  function handleWatchLine(line) {
    var event = Model.parseWatchLine(line)
    if (!event || event.malformed) return
    var payload = event.payload || {}
    switch (event.type) {
    case "device.added":
    case "device.connected":
    case "device.disconnected":
    case "device.removed":
    case "pair.accepted":
    case "pair.rejected":
      if (event.type === "pair.accepted" || event.type === "pair.rejected") {
        var next = {}
        for (var k in pendingPairs)
          if (k !== String(event.deviceId)) next[k] = true
        pendingPairs = next
      }
      refreshDevices()
      break
    case "pair.requested":
      notify("Pairing request", deviceName(event.deviceId) + " wants to pair — open OMAConnect to accept")
      refreshDevices()
      break
    case "battery.update":
      var all = Object.assign({}, batteries)
      all[String(event.deviceId)] = {
        charge: Model.num(payload, "charge", 0),
        charging: payload.charging === true
      }
      batteries = all
      break
    case "notification": {
      var replyId = Model.str(payload, "requestReplyId", "")
      if (replyId !== "") {
        var entry = {
          deviceId: String(event.deviceId),
          replyId: replyId,
          appName: Model.str(payload, "appName", "Phone"),
          title: Model.str(payload, "title", ""),
          text: Model.str(payload, "text", ""),
          timestamp: event.timestamp
        }
        var list = ([entry]).concat(replyable || [])
        replyable = list.slice(0, replyableLimit)
      }
      break
    }
    case "notification.canceled":
      // Phone dismissed it — nothing to keep offering a reply for.
      removeReplyable(Model.str(payload, "id", ""))
      break
    case "share.complete":
      notify("File received", Model.str(payload, "file", "A file") + " saved to phone downloads")
      break
    case "share.url":
      notify("Link shared", Model.str(payload, "url", ""))
      break
    case "share.text":
      notify("Text shared", Model.str(payload, "text", "").slice(0, 120))
      break
    case "telephony.ringing": {
      var who = Model.str(payload, "contactName", "") || Model.str(payload, "phoneNumber", "Unknown caller")
      notify("Incoming call", who + " — open OMAConnect to mute")
      break
    }
    case "telephony.missed": {
      var missed = Model.str(payload, "contactName", "") || Model.str(payload, "phoneNumber", "Unknown caller")
      notify("Missed call", missed)
      break
    }
    default:
      break
    }
  }

  function removeReplyable(replyId) {
    if (!replyId) return
    var kept = []
    var list = replyable || []
    for (var i = 0; i < list.length; i++)
      if (String(list[i].replyId) !== String(replyId)) kept.push(list[i])
    replyable = kept
  }

  // ---------- processes ----------

  Process {
    id: statusProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStatusJson(text)
        if (parsed.ok) {
          root.daemonState = "up"
          root.kcdInstalled = true
          root.daemonVersion = parsed.version
          root.daemonUptime = parsed.uptimeHuman
          root.deviceCount = parsed.deviceCount
          root.connectedCount = parsed.connectedCount
          root.refreshDevices()
          if (!watchProc.running) watchProc.running = true
        } else {
          root.daemonState = "down"
        }
        root.refreshing = false
      }
    }
    onExited: function(code) {
      // Nonzero exit (or empty output handled above) means the daemon socket
      // is unreachable. Exit 127-class failures mean kcd itself is gone.
      if (code !== 0 && root.daemonState === "checking") {
        root.daemonState = "down"
        root.refreshing = false
      } else if (code !== 0) {
        root.daemonState = "down"
        root.refreshing = false
      }
    }
    Component.onCompleted: {
      // Probe the binary first so "not installed" and "daemon stopped" get
      // different, actionable messages.
      whichProc.running = true
    }
  }

  Process {
    id: whichProc
    command: ["bash", "-c", "command -v kcd"]
    running: false
    onExited: function(code) {
      if (code !== 0) {
        root.kcdInstalled = false
        root.daemonState = "missing"
        root.refreshing = false
        return
      }
      root.kcdInstalled = true
      statusProc.command = ["kcd", "status", "--json"]
      statusProc.running = true
    }
  }

  Process {
    id: devicesProc
    command: ["kcd", "devices", "--json"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseDevicesJson(text)
        if (parsed.ok) {
          root.devices = parsed.devices
          root.lastError = ""
        } else {
          root.lastError = parsed.error
        }
      }
    }
    onExited: function(code) {
      if (code !== 0) root.daemonState = "down"
    }
  }

  Process {
    id: watchProc
    // Filtered to the events the panel actually consumes; kcd reconnects by
    // itself if the daemon restarts, with backoff up to 30s.
    command: ["kcd", "watch", "--json", "--events",
      "device.added,device.connected,device.disconnected,device.removed," +
      "pair.requested,pair.accepted,pair.rejected," +
      "battery.update,notification,notification.canceled," +
      "share.complete,share.url,share.text,telephony.ringing,telephony.missed"]
    running: false
    stdout: SplitParser {
      onRead: function(data) { root.handleWatchLine(data) }
    }
    onExited: function(code) {
      // Daemon went away mid-stream: fall back to polling until it is back.
      if (root.daemonState === "up") root.daemonState = "down"
      if (root.daemonState !== "missing") watchRetry.restart()
    }
  }

  Process {
    id: actionProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._actionOutput = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.lastError = err.split("\n")[0]
      }
    }
    onExited: function(code) {
      var tag = root._pendingAction
      var devId = root._pendingDeviceId
      root._pendingAction = ""
      root._pendingDeviceId = ""
      if (code === 0) {
        root.lastError = ""
        if (tag === "pair") root.actionStatus = "Pair request sent — accept on " + root.deviceName(devId)
        else if (tag === "unpair") root.actionStatus = "Unpaired " + root.deviceName(devId)
        else if (tag === "ping") root.actionStatus = "Ping sent"
        else if (tag === "findmyphone") root.actionStatus = "Phone is ringing"
        else if (tag === "mute") root.actionStatus = "Call muted"
        else if (tag === "share") root.actionStatus = "File sent"
        else if (tag === "reply") {
          root.actionStatus = "Reply sent"
          // The reply went out; drop matching entries so the list only holds
          // notifications still awaiting an answer.
          var kept = []
          var list = root.replyable || []
          for (var i = 0; i < list.length; i++)
            if (String(list[i].deviceId) !== String(devId)) kept.push(list[i])
          root.replyable = kept
        }
        root.refreshDevices()
      } else {
        if (!root.lastError) root.lastError = "Action failed (exit " + code + ")"
        if (tag === "pair") {
          var next = {}
          for (var k in root.pendingPairs)
            if (k !== String(devId)) next[k] = true
          root.pendingPairs = next
        }
      }
    }
  }

  // `ls -p` marks directories with a trailing slash; that is the whole
  // protocol. Newline-containing file names won't round-trip — accepted
  // v1 limitation, shared with most shell listings.
  Process {
    id: browseProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dir = String((browseProc.command || []).slice(-1)[0] || "")
        var entries = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i]
          if (line === "") continue
          var isDir = line.charAt(line.length - 1) === "/"
          var name = isDir ? line.slice(0, -1) : line
          if (name === "") continue
          entries.push({ name: name, isDir: isDir, path: root.joinPath(dir, name) })
        }
        root.browseDir = dir
        root.browseEntries = entries
        root.browseBusy = false
        root.lastError = ""
      }
    }
    onExited: function(code) {
      root.browseBusy = false
      if (code !== 0) {
        root.lastError = "Cannot list " + String((browseProc.command || []).slice(-1)[0] || "")
      }
    }
  }

  Process {
    id: doctorProc
    command: ["kcd", "doctor"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var missing = []
        for (var i = 0; i < lines.length; i++) {
          var row = Model.parseDoctorLine(lines[i])
          if (row && !row.ok && row.name.toLowerCase().indexOf("daemon") !== 0
              && row.name.toLowerCase().indexOf("config") !== 0
              && row.name.toLowerCase().indexOf("cert") !== 0) missing.push(row.name)
        }
        root.doctorSummary = missing.length > 0 ? ("Missing: " + missing.join(", ")) : ""
      }
    }
  }

  Timer {
    id: enableWait
    interval: 4000
    repeat: false
    onTriggered: {
      root.actionStatus = ""
      root.refresh()
    }
  }

  Timer {
    id: watchRetry
    interval: 15000
    repeat: false
    onTriggered: {
      if (root.daemonState !== "missing" && !watchProc.running) {
        root.refresh()
      }
    }
  }

  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: statusClear
    interval: 8000
    repeat: false
    onTriggered: {
      root.actionStatus = ""
    }
  }

  onActionStatusChanged: if (actionStatus !== "") statusClear.restart()

  Component.onCompleted: doctorProc.running = true
}
