import QtQuick
import qs.Commons
import qs.Ui

// Lock, Sleep, Screensaver as a row of three bordered buttons. Sleep wants a
// second press within two seconds; the button says so while it is armed.
TileSurface {
  id: root

  property var actions: []   // [{ id, glyph, label, armed }]
  property int subCursor: 0

  signal activated(string id)
  signal actionHovered(int index)

  active: false

  Row {
    id: row
    anchors.fill: parent
    anchors.leftMargin: root.borderLeft + Style.spacing.md
    anchors.rightMargin: root.borderRight + Style.spacing.md
    anchors.topMargin: root.borderTop + Style.spacing.sm
    anchors.bottomMargin: root.borderBottom + Style.spacing.sm
    spacing: Style.spacing.sm

    readonly property int count: root.actions.length
    readonly property real cellWidth: count > 0 ? (width - spacing * (count - 1)) / count : 0

    Repeater {
      model: root.actions
      Button {
        required property var modelData
        required property int index
        width: row.cellWidth
        height: row.height
        iconText: modelData.glyph
        iconSize: Style.font.body
        text: modelData.armed ? "Press again" : modelData.label
        fontSize: Style.font.caption
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        bordered: true
        selected: modelData.armed === true
        hasCursor: root.subCursor === index && !root.editing
        enabled: !root.editing
        onClicked: root.activated(modelData.id)
        onHovered: function(h) { if (h) root.actionHovered(index) }
      }
    }

  }
}
