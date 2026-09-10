import QtQuick
import qs.Ui
import qs.Commons

// Collapsible panel section: separator, chevron header, content slot.
// Expansion state lives with the caller (`expanded` + `onToggled`) so lazy
// loading and cross-close persistence stay in panel code.
Column {
  id: root

  property string title: ""
  property bool expanded: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal toggled()

  default property alias content: body.children

  PanelSeparator { foreground: root.foreground }

  Row {
    width: parent.width
    spacing: Style.space(8)

    Button {
      iconText: root.expanded ? "▾" : "▸"
      tooltipText: root.expanded ? "Collapse" : "Expand"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.toggled()
    }

    PanelSectionHeader {
      width: parent.width - 40
      anchors.verticalCenter: parent.verticalCenter
      text: root.title
      foreground: root.foreground
      fontFamily: root.fontFamily
    }
  }

  Column {
    id: body
    width: parent.width
    spacing: Style.space(8)
    visible: root.expanded
  }
}
