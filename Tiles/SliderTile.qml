import QtQuick
import qs.Commons
import qs.Ui

// A full-width slider row: glyph button, label, an optional chip naming the
// device, the percentage, and the slider underneath. The glyph is the
// secondary action (mute); the chip cycles the device.
TileSurface {
  id: root

  property string glyph: ""
  property string label: ""
  property string chip: ""
  property string chipTooltip: ""
  property string glyphTooltip: ""
  property real value: 0
  property real minimum: 0
  property real step: 0.05
  property bool muted: false
  property bool chevron: false
  property string chevronTooltip: ""
  property bool editing: false
  property bool enabledInSettings: true
  // What the number on the right says. Percent suits volume and brightness;
  // warmth wants Kelvin, which is not a percentage of anything.
  property string valueText: Math.round((slider.dragging ? slider.liveValue : root.value) * 100) + "%"
  readonly property alias dragging: slider.dragging
  readonly property real liveValue: slider.liveValue

  signal glyphClicked()
  signal chipClicked()
  signal chevronClicked()
  signal moved(real value)
  signal released(real value)

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property int pad: Style.spacing.xl

  active: false
  dimmed: editing && !enabledInSettings

  Item {
    anchors.fill: parent
    anchors.leftMargin: root.borderLeft + root.pad
    anchors.rightMargin: root.borderRight + root.pad
    anchors.topMargin: root.borderTop + Style.spacing.md
    anchors.bottomMargin: root.borderBottom + Style.spacing.sm

    PanelActionButton {
      id: glyphButton
      anchors.left: parent.left
      anchors.top: parent.top
      iconText: root.glyph
      tooltipText: root.glyphTooltip
      foreground: root.muted ? root.dim : root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.icon
      onClicked: root.glyphClicked()
    }

    Text {
      id: labelText
      anchors.left: glyphButton.right
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: glyphButton.verticalCenter
      text: root.editing && !root.enabledInSettings ? root.label + "  ·  Hidden" : root.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    BorderSurface {
      id: chipPill
      visible: root.chip !== "" && !root.editing
      anchors.left: labelText.right
      anchors.leftMargin: Style.spacing.lg
      anchors.verticalCenter: glyphButton.verticalCenter
      width: Math.min(chipText.implicitWidth + Style.spacing.lg, parent.width - labelText.x - labelText.width - percentText.width - Style.space(40))
      height: chipText.implicitHeight + Style.spacing.sm
      radius: Style.cornerRadius
      color: chipMouse.containsMouse ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
      borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

      Text {
        id: chipText
        anchors.centerIn: parent
        width: parent.width - Style.spacing.lg
        text: root.chip
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignHCenter
      }

      MouseArea {
        id: chipMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.chipClicked()
      }

      PanelToolTip {
        visible: root.chipTooltip !== "" && chipMouse.containsMouse
        text: root.chipTooltip
        fontFamily: root.fontFamily
      }
    }

    Text {
      id: percentText
      anchors.right: chevronButton.visible ? chevronButton.left : parent.right
      anchors.rightMargin: chevronButton.visible ? Style.spacing.sm : 0
      anchors.verticalCenter: glyphButton.verticalCenter
      text: root.valueText
      color: root.muted ? root.dim : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }


    PanelActionButton {
      id: chevronButton
      visible: root.chevron && !root.editing
      anchors.right: parent.right
      anchors.verticalCenter: glyphButton.verticalCenter
      iconText: "󰅂"
      tooltipText: root.chevronTooltip
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.body
      onClicked: root.chevronClicked()
    }

    PanelSlider {
      id: slider
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.spacing.xs
      anchors.rightMargin: Style.spacing.xs
      height: Style.space(22)
      value: root.value
      minimum: root.minimum
      maximum: 1
      step: root.step
      enabled: !root.editing
      opacity: root.muted ? 0.5 : 1
      trackColor: Style.selectedFillFor(root.foreground, root.accent)
      fillColor: root.foreground
      knobColor: root.foreground
      tickColor: Color.popups.background
      onMoved: function(v) { root.moved(v) }
      onReleased: function(v) { root.released(v) }
      onRightClicked: root.glyphClicked()
    }
  }
}
