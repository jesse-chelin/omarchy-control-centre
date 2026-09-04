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

  // A slider takes the wheel and changes its value, which is the right thing
  // on a card that fits. On a card long enough to scroll it is not: someone
  // scrolling past the volume row would turn the volume up instead. When the
  // grid can scroll, the wheel scrolls.
  property bool wheelScrolls: false
  // What the number on the right says. Percent suits volume and brightness;
  // warmth wants Kelvin, which is not a percentage of anything.
  property string valueText: Math.round((slider.dragging ? slider.liveValue : root.value) * 100) + "%"
  readonly property alias dragging: slider.dragging
  readonly property real liveValue: slider.liveValue

  signal glyphClicked()
  signal chipClicked()
  signal chevronClicked()
  signal scrollRequested(int delta)
  signal moved(real value)
  signal released(real value)

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property int pad: Style.spacing.xl

  active: false

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
      textFormat: Text.PlainText
      id: labelText
      anchors.left: glyphButton.right
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: glyphButton.verticalCenter
      text: root.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    // The device name, not a field to type in. A bordered pill beside a label
    // is input chrome on this desktop, so it read as editable; it is a quiet
    // label that brightens under the pointer, with a chevron to say it leads
    // somewhere.
    Item {
      id: chipPill
      visible: root.chip !== "" && !root.editing
      anchors.left: labelText.right
      anchors.leftMargin: Style.spacing.lg
      anchors.verticalCenter: glyphButton.verticalCenter
      // Measured against the percentage on the right, which does not depend
      // on this: sizing it from its own contents and then sizing its contents
      // from it is a loop, and QML settles a loop by leaving something at
      // zero, which is how the chevron disappeared.
      readonly property real room: Math.max(0, percentText.x - x - Style.space(14))
      width: Math.min(chipText.implicitWidth + chipChevron.implicitWidth + Style.spacing.xxs, room)
      height: chipText.implicitHeight + Style.spacing.sm

      Text {
        textFormat: Text.PlainText
        id: chipText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, Math.min(implicitWidth,
          chipPill.room - chipChevron.implicitWidth - Style.spacing.xxs))
        text: root.chip
        color: chipMouse.containsMouse ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        id: chipChevron
        anchors.left: chipText.right
        anchors.leftMargin: Style.spacing.xxs
        anchors.verticalCenter: chipText.verticalCenter
        text: "󰅀"
        color: chipText.color
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
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
      textFormat: Text.PlainText
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
      fillColor: root.muted ? Qt.darker(root.foreground, 1.6) : root.stateColor
      knobColor: root.foreground
      tickColor: Color.popups.background
      onMoved: function(v) { root.moved(v) }
      onReleased: function(v) { root.released(v) }
      onRightClicked: root.glyphClicked()

      // Buttons pass straight through, so dragging the slider still works;
      // only the wheel is taken, and only while the grid can use it.
      MouseArea {
        anchors.fill: parent
        enabled: root.wheelScrolls
        acceptedButtons: Qt.NoButton
        onWheel: function(wheel) { root.scrollRequested(wheel.angleDelta.y) }
      }
    }
  }
}
