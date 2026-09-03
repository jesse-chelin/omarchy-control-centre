import QtQuick
import qs.Commons
import qs.Ui

// How a control that is not on the card appears in edit mode: its glyph, its
// name, and the word Hidden. Nothing live.
//
// The alternative was to draw the real control and mark it, which is what this
// replaces. A hidden control is a catalogue entry rather than something in
// use, so a working slider sitting at 100% for something the user has taken
// off their card is noise, and the mark had nowhere to go that did not land on
// top of the control's own trailing content.
TileSurface {
  id: root

  property string glyph: ""
  property string label: ""
  property bool wide: false

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property int pad: Style.spacing.xl

  active: false
  tooltip: "Enter shows this control"

  // Stacked in a square, side by side in a row: the same anatomy the real
  // control has at that shape, so nothing jumps when it is switched on.
  Item {
    anchors.fill: parent
    anchors.leftMargin: root.borderLeft + root.pad
    anchors.rightMargin: root.borderRight + Style.spacing.md
    anchors.topMargin: root.borderTop + (root.wide ? 0 : root.pad - Style.space(2))
    anchors.bottomMargin: root.borderBottom + (root.wide ? 0 : root.pad - Style.space(2))

    Text {
      id: glyphText
      text: root.glyph
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: root.wide ? Style.font.icon : Style.font.iconLarge
      anchors.left: parent.left
      anchors.top: root.wide ? undefined : parent.top
      anchors.verticalCenter: root.wide ? parent.verticalCenter : undefined
    }

    Text {
      text: root.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
      anchors.left: root.wide ? glyphText.right : parent.left
      anchors.leftMargin: root.wide ? Style.spacing.lg : 0
      // On a square the mark sits above the name, so the name gets the whole
      // width; only in a row do the two share a line.
      anchors.right: root.wide ? hiddenMark.left : parent.right
      anchors.rightMargin: root.wide ? Style.spacing.md : 0
      anchors.bottom: root.wide ? undefined : parent.bottom
      anchors.verticalCenter: root.wide ? parent.verticalCenter : undefined
    }

    Text {
      id: hiddenMark
      text: "Hidden"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      anchors.right: parent.right
      anchors.verticalCenter: root.wide ? parent.verticalCenter : undefined
      anchors.top: root.wide ? undefined : parent.top
    }
  }
}
