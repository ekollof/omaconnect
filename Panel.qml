import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "ekollof.omaconnect"
  ipcTarget: "ekollof.omaconnect"
  // Own the single IpcHandler this target permits, so refresh() is exposed
  // alongside the standard open/close/toggle lifecycle.
  manageIpc: false

  // Lazy-load the share browser on first open; navigation state persists
  // across closes within the shell lifetime.
  onOpenedChanged: {
    if (opened && root.shareExpanded && kcd.primaryDevice && (kcd.browseEntries || []).length === 0 && !kcd.browseBusy) {
      kcd.browseHome()
    }
  }

  Kcd {
    id: kcd
    settings: root.settings
  }

  // Bar pill: phone glyph + primary battery, dimmed when nothing is connected.
  readonly property string pillText: {
    if (kcd.daemonState === "checking") return "󰄜 …"
    if (kcd.daemonState !== "up") return "󰄜"
    var dev = kcd.primaryDevice
    if (!dev) return "󰄜"
    var bat = kcd.primaryBattery
    if (!bat) return Model.typeIcon(dev.type)
    return Model.batteryIcon(bat.charge, bat.charging) + " " + Math.round(Number(bat.charge) || 0) + "%"
  }

  readonly property string heroMeta: {
    switch (kcd.daemonState) {
    case "checking": return "CHECKING DAEMON"
    case "missing": return "KCD NOT INSTALLED"
    case "down": return "DAEMON STOPPED"
    default:
      if (kcd.connectedCount > 0) return String(kcd.connectedCount) + " CONNECTED"
      return kcd.deviceCount > 0 ? "NO ACTIVE LINK" : "NO DEVICES"
    }
  }

  property string sharePath: ""
  property bool shareExpanded: false
  property string smsNumber: ""
  property string smsMessage: ""
  property bool smsExpanded: false
  property var replyDrafts: ({})

  function setReplyDraft(replyId, text) {
    var next = Object.assign({}, replyDrafts)
    next[String(replyId)] = text
    replyDrafts = next
  }

  function sendReply(entry) {
    if (!entry) return
    kcd.replyTo(entry.deviceId, entry.replyId, replyDrafts[String(entry.replyId)] || "")
    setReplyDraft(entry.replyId, "")
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "ekollof.omaconnect"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function refresh(): string { kcd.refresh(); return "ok" }
    function version(): string { return "omaconnect-picker-1" }
    function debugState(): string {
      return kcd.debugSnapshot(String(root.sharePath || ""))
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pillText
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Outer scroll: the card height is clamped to the screen by
      // fittedContentHeight, so without this anything below the fold
      // (expanded browser + SMS + media) would be silently clipped.
      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

      Column {
        id: column
        width: scroll.width
        spacing: Style.space(14)

        PanelHero {
          title: "OMAConnect"
          meta: root.heroMeta
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          iconComponent: Text {
            textFormat: Text.PlainText
            text: "󰄜"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
          }
        }

        // ---------- daemon health ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: kcd.daemonState !== "up"

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: kcd.daemonState === "missing"
              ? "Install the kcd backend first: yay -S kcd-bin"
              : kcd.daemonState === "checking"
                ? "Probing for the kcd daemon…"
                : "The kcd daemon is not running. Start it to discover and pair phones."
          }

          Button {
            visible: kcd.daemonState === "down"
            text: "Start kcd daemon"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: kcd.enableDaemon()
          }
        }

        // ---------- devices ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: kcd.daemonState === "up"

          PanelSectionHeader {
            text: "DEVICES"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            visible: (kcd.devices || []).length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            text: "No phones seen yet. Open KDE Connect on your phone on the same network."
          }

          Repeater {
            model: kcd.devices || []
            delegate: Column {
              required property var modelData
              required property int index
              readonly property var dev: modelData
              readonly property bool paired: Model.isPaired(dev)
              readonly property bool peerAsked: Model.pairRequestedByPeer(dev)
              readonly property bool pending: !!kcd.pendingPairs[String(dev.id)]
              readonly property var bat: (kcd.batteries || {})[String(dev.id)] || null
              width: parent.width
              spacing: Style.space(6)

              Row {
                width: parent.width
                spacing: Style.space(10)

                Text {
                  textFormat: Text.PlainText
                  text: Model.typeIcon(dev.type)
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.heading
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  width: parent.width - 120
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)
                  Text {
                    textFormat: Text.PlainText
                    text: dev.name
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    width: parent.width
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: (pending ? "Pair requested…" : Model.stateLabel(dev))
                      + (bat ? " · " + Model.batteryLabel(bat.charge, bat.charging) : "")
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  visible: !paired
                  text: peerAsked ? "Accept pair" : "Pair"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: kcd.pairDevice(dev.id)
                }
                Button {
                  visible: paired
                  text: "Unpair"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: kcd.unpairDevice(dev.id)
                }
                Button {
                  visible: paired && dev.connected
                  text: "Ping"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: kcd.pingDevice(dev.id)
                }
                Button {
                  visible: paired && dev.connected
                  text: "Find"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: kcd.findPhone(dev.id)
                }
                Button {
                  visible: paired && dev.connected
                  text: "Clip"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: kcd.pushClipboard(dev.id)
                }
              }
            }
          }
        }

        // ---------- replies ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: kcd.daemonState === "up" && (kcd.replyable || []).length > 0

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: "REPLY FROM DESKTOP"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: kcd.replyable || []
            delegate: Column {
              required property var modelData
              required property int index
              readonly property var entry: modelData
              width: parent.width
              spacing: Style.space(4)

              Text {
                width: parent.width
                elide: Text.ElideRight
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
                text: entry.appName + (entry.title !== "" ? " · " + entry.title : "")
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
                text: entry.text
              }
              Row {
                width: parent.width
                spacing: Style.space(8)
                TextField {
                  id: replyField
                  width: parent.width - 76
                  foreground: root.bar.foreground
                  font.family: root.bar.fontFamily
                  placeholderText: "Reply…"
                  text: root.replyDrafts[String(entry.replyId)] || ""
                  onTextChanged: root.setReplyDraft(entry.replyId, text)
                  onAccepted: root.sendReply(entry)
                }
                Button {
                  text: "Send"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  onClicked: root.sendReply(entry)
                }
              }
            }
          }
        }

        // ---------- share: in-panel file browser ----------
        // Collapsed by default to keep the panel compact; expanding a fresh
        // browser also triggers its first directory load.
        CollapsibleSection {
          width: parent.width
          title: "SHARE FILE"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          visible: kcd.daemonState === "up" && kcd.primaryDevice !== null
          expanded: root.shareExpanded
          onToggled: {
            root.shareExpanded = !root.shareExpanded
            if (root.shareExpanded && kcd.primaryDevice
                && (kcd.browseEntries || []).length === 0 && !kcd.browseBusy) {
              kcd.browseHome()
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: "Up"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: kcd.browseUp()
            }
            Text {
              width: parent.width - 120
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideMiddle
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
              text: kcd.browseBusy ? "Loading…" : String(kcd.browseDir || "")
            }
            Button {
              text: "Send"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: {
                if (kcd.primaryDevice) kcd.shareFile(kcd.primaryDevice.id, root.sharePath)
              }
            }
          }

          ListView {
            width: parent.width
            height: Math.min(contentHeight, Style.space(240))
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            spacing: Style.space(4)
            model: kcd.browseEntries || []

            delegate: Button {
              required property var modelData
              width: ListView.view.width
              leftAlign: true
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              iconText: modelData && modelData.isDir ? "" : ""
              text: modelData ? modelData.name : ""
              selected: modelData && !modelData.isDir && root.sharePath === modelData.path
              onClicked: {
                if (!modelData) return
                if (modelData.isDir) kcd.browse(modelData.path)
                else root.sharePath = modelData.path
              }
            }
          }

          Text {
            visible: root.sharePath !== ""
            width: parent.width
            elide: Text.ElideMiddle
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            text: "Selected: " + root.sharePath
          }
          Text {
            visible: kcd.primaryDevice !== null
            width: parent.width
            elide: Text.ElideRight
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            text: "To " + (kcd.primaryDevice ? kcd.primaryDevice.name : "")
          }
        }

        // ---------- phone files (SFTP) ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: kcd.daemonState === "up" && kcd.primaryDevice !== null

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: "PHONE FILES"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            visible: kcd.doctorSummary.indexOf("sshfs") >= 0
            width: parent.width
            wrapMode: Text.WordWrap
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            text: "Install sshfs for phone file browsing."
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: kcd.doctorSummary.indexOf("sshfs") < 0

            Button {
              text: "Volumes"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: {
                if (kcd.primaryDevice) kcd.sftpVolumes(kcd.primaryDevice.id)
              }
            }
            Button {
              text: "Mount"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: {
                if (kcd.primaryDevice) kcd.sftpMount(kcd.primaryDevice.id)
              }
            }
            Button {
              text: "Unmount"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: {
                if (kcd.primaryDevice) kcd.sftpUnmount(kcd.primaryDevice.id)
              }
            }
          }
          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            text: "Mount opens the phone storage in your file manager."
          }
        }

        // ---------- SMS ----------
        CollapsibleSection {
          width: parent.width
          title: "SMS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          visible: kcd.daemonState === "up" && kcd.primaryDevice !== null
          expanded: root.smsExpanded
          onToggled: root.smsExpanded = !root.smsExpanded

          TextField {
            width: parent.width
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily
            placeholderText: "Phone number"
            text: root.smsNumber
            onTextChanged: root.smsNumber = text
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            TextField {
              width: parent.width - 84
              foreground: root.bar.foreground
              font.family: root.bar.fontFamily
              placeholderText: "Message…"
              text: root.smsMessage
              onTextChanged: root.smsMessage = text
              onAccepted: {
                if (kcd.primaryDevice) kcd.smsSend(kcd.primaryDevice.id, root.smsNumber, root.smsMessage)
              }
            }
            Button {
              text: "Send"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: {
                if (kcd.primaryDevice) kcd.smsSend(kcd.primaryDevice.id, root.smsNumber, root.smsMessage)
              }
            }
          }

          Repeater {
            model: kcd.smsList || []
            delegate: Column {
              required property var modelData
              width: parent.width
              spacing: Style.space(1)
              Text {
                width: parent.width
                elide: Text.ElideRight
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
                text: (modelData.sender || "Unknown") + (modelData.date !== "" ? " · " + modelData.date : "")
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
                text: modelData.body || ""
              }
            }
          }

          Button {
            text: "Load conversations"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            onClicked: {
              if (kcd.primaryDevice) kcd.smsRefresh(kcd.primaryDevice.id)
            }
          }
        }

        // ---------- phone media (MPRIS) ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: kcd.daemonState === "up" && kcd.primaryDevice !== null

          PanelSeparator { foreground: root.bar.foreground }

          PanelSectionHeader {
            text: "PHONE MEDIA"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Text {
            width: parent.width
            elide: Text.ElideRight
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            text: Model.nowPlayingLabel(kcd.nowPlaying)
          }
          Text {
            visible: kcd.nowPlaying !== null && kcd.nowPlaying.player !== ""
            width: parent.width
            elide: Text.ElideRight
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            // Guarded twice: `visible` doesn't stop the binding below from
            // evaluating when nowPlaying is null.
            text: (kcd.nowPlaying ? kcd.nowPlaying.player : "")
              + ((kcd.nowPlaying && kcd.nowPlaying.isPlaying) ? " · playing" : " · paused")
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: "Prev"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: {
                if (kcd.primaryDevice) kcd.mprisAction(kcd.primaryDevice.id, "previous")
              }
            }
            Button {
              text: kcd.nowPlaying !== null && kcd.nowPlaying.isPlaying ? "Pause" : "Play"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: {
                if (kcd.primaryDevice) kcd.mprisAction(kcd.primaryDevice.id, "toggle")
              }
            }
            Button {
              text: "Next"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: {
                if (kcd.primaryDevice) kcd.mprisAction(kcd.primaryDevice.id, "next")
              }
            }
          }
        }

        // ---------- status / errors ----------
        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            visible: kcd.actionStatus !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            text: kcd.actionStatus
          }
          Text {
            visible: kcd.lastError !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            color: "#e06c75"
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            text: kcd.lastError
          }
          Text {
            visible: kcd.doctorSummary !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            text: kcd.doctorSummary
          }
        }
      } // end scrollable column
      } // end scroll Flickable
    }
  }
}
