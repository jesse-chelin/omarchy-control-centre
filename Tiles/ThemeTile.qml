import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// A row of theme chips. The list wraps rather than scrolls, because a machine
// with more themes than fit on one line should show them all rather than hide
// some behind a gesture nobody will find.
TileSurface {
  id: root

  property var themes: []
  property string current: ""
  property string pendingTheme: ""
  property int subCursor: -1
  property bool busy: false
  property string error: ""
  property bool editing: false
  property bool enabledInSettings: true

  signal themeClicked(string name)
  signal themeHovered(int index)

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string shown: pendingTheme !== "" ? pendingTheme : current

  active: false
  dimmed: editing && !enabledInSettings

  // "matte-black" reads as a directory; "Matte Black" reads as a theme.
  function pretty(name) {
    var parts = String(name || "").split("-")
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].length > 0) parts[i] = parts[i].charAt(0).toUpperCase() + parts[i].slice(1)
    }
    return parts.join(" ")
  }

  Item {
    anchors.fill: parent
    anchors.leftMargin: root.borderLeft + Style.spacing.xl
    anchors.rightMargin: root.borderRight + Style.spacing.md
    anchors.topMargin: root.borderTop + Style.spacing.md
    anchors.bottomMargin: root.borderBottom + Style.spacing.md

    Text {
      id: glyphText
      anchors.left: parent.left
      anchors.top: parent.top
      text: Model.glyphOf("theme")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    Text {
      visible: root.editing
      anchors.left: labelText.right
      anchors.leftMargin: Style.spacing.lg
      anchors.verticalCenter: labelText.verticalCenter
      text: root.enabledInSettings ? root.pretty(root.current) : "Hidden"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      id: labelText
      anchors.left: glyphText.right
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: glyphText.verticalCenter
      text: root.error !== "" ? root.error : "Theme"
      color: root.error !== "" ? Color.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }


    Flow {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: glyphText.bottom
      anchors.topMargin: Style.spacing.md
      spacing: Style.spacing.sm
      visible: !root.editing

      Repeater {
        model: root.themes
        Button {
          required property var modelData
          required property int index
          text: root.pretty(modelData)
          fontSize: Style.font.caption
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          horizontalPadding: Style.spacing.lg
          verticalPadding: Style.spacing.xs
          bordered: true
          selected: root.shown === modelData
          iconText: root.busy && root.shown === modelData ? "󰑐" : ""
          iconSpinning: root.busy && root.shown === modelData && !root.reduceMotion
          iconSize: Style.font.caption
          hasCursor: root.subCursor === index
          onClicked: root.themeClicked(modelData)
          onHovered: function(h) { if (h) root.themeHovered(index) }
        }
      }
    }
  }
}
