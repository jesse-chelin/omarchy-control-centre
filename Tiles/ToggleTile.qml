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

  signal chevronClicked()

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color glyphColor: urgent ? Color.urgent : (active ? root.stateColor : dim)
  readonly property int pad: Style.spacing.xl


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
    fontSize: Style.font.icon
    size: Style.space(28)
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

    // One size for every label on the card. Shrinking each one to fit its own
    // tile was kinder to the longest label and unkind to the row it sits in:
    // neighbouring labels came out at two different sizes, which reads as a
    // mistake rather than as a system. The card is sized instead so that the
    // longest label in the catalogue fits at this size.
    Text {
      width: parent.width
      text: root.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      text: root.error !== "" ? root.error : root.subtitle
      // An error is worth the room at any density; the state line is not,
      // and the tile's fill says on or off without it.
      visible: text !== "" && (!root.compact || root.error !== "")
      color: root.error !== "" ? Color.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
