import QtQuick
import qs.Commons
import qs.Ui

// A 1x1 tile: glyph top-left, chevron top-right, label and one line of
// subtitle at the bottom. Two lines of text at most.
TileSurface {
  id: root

  property string glyph: ""
  property string label: ""
  property string subtitle: ""
  property bool busy: false
  property bool urgent: false
  property bool chevron: false
  property string chevronTooltip: ""
  property string error: ""
  property bool editing: false
  property bool enabledInSettings: true

  signal chevronClicked()
  signal moveRequested(int delta)

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color glyphColor: urgent ? Color.urgent : (active ? Style.selectedStateColor(foreground, accent) : dim)
  readonly property int pad: Style.spacing.xl

  dimmed: editing && !enabledInSettings

  Text {
    id: glyphText
    x: root.borderLeft + root.pad
    y: root.borderTop + root.pad - Style.space(2)
    text: root.busy ? "󰑐" : root.glyph
    color: root.glyphColor
    font.family: root.fontFamily
    font.pixelSize: Style.font.iconLarge

    Behavior on color { enabled: !root.reduceMotion; ColorAnimation { duration: 100 } }

    RotationAnimation on rotation {
      from: 0; to: 360; duration: 900
      loops: Animation.Infinite
      running: root.busy && !root.reduceMotion
      onRunningChanged: if (!running) glyphText.rotation = 0
    }

    // Recording pulses so a live recorder is never mistaken for an idle one.
    SequentialAnimation on opacity {
      running: root.urgent && !root.reduceMotion
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { from: 1.0; to: 0.4; duration: 800; easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.4; to: 1.0; duration: 800; easing.type: Easing.InOutSine }
    }
  }

  // Edit mode replaces the chevron with reorder arrows; a disabled tile says
  // so in the same corner.
  Row {
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: root.borderRight + Style.spacing.sm
    anchors.topMargin: root.borderTop + Style.spacing.sm
    spacing: 0
    visible: root.editing

    PanelActionButton {
      iconText: "󰅁"
      tooltipText: "Move left"
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      onClicked: root.moveRequested(-1)
    }
    PanelActionButton {
      iconText: "󰅂"
      tooltipText: "Move right"
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      onClicked: root.moveRequested(1)
    }
  }

  PanelActionButton {
    visible: root.chevron && !root.editing
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: root.borderRight + Style.spacing.sm
    anchors.topMargin: root.borderTop + Style.spacing.sm
    iconText: "󰅂"
    tooltipText: root.chevronTooltip
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.body
    onClicked: root.chevronClicked()
  }

  Column {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.leftMargin: root.borderLeft + root.pad
    anchors.rightMargin: root.borderRight + Style.spacing.sm
    anchors.bottomMargin: root.borderBottom + root.pad - Style.space(2)
    spacing: Style.space(1)

    // A tile is one column of four, so the longest label ("Do Not Disturb")
    // is the one that decides the type size. Rather than pick a size that
    // suits the longest and leaves the rest small, each label shrinks by up
    // to one step to fit its own tile, and only elides if even that fails.
    Text {
      width: parent.width
      text: root.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      minimumPixelSize: Style.font.caption
      fontSizeMode: Text.HorizontalFit
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      text: root.error !== "" ? root.error : (root.editing && !root.enabledInSettings ? "Hidden" : root.subtitle)
      visible: text !== ""
      color: root.error !== "" ? Color.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
