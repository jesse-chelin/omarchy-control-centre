import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// Album art, what is playing, and the transport. The row is laid out like the
// slider rows above it: the same inset from the card edge, the same inset for
// its trailing controls, so the three wide rows line up down the card rather
// than each finding its own margins.
TileSurface {
  id: root

  property string title: ""
  property string artist: ""
  property string artUrl: ""
  property bool playing: false
  property bool canGoPrevious: false
  property bool canGoNext: false
  property int subCursor: 1

  signal transport(string action)
  signal controlHovered(int index)

  readonly property color dim: Qt.darker(foreground, 1.5)
  // The same inset every other tile uses, so the art starts where the glyphs
  // above it start.
  readonly property int pad: Style.spacing.xl
  readonly property int artSize: height - (borderTop + borderBottom) - Style.spacing.md * 2
  readonly property string artSource: Model.artSource(artUrl)
  // One size for all three, so the gaps between them are equal. A play button
  // drawn larger than its neighbours moved them apart by different amounts.
  readonly property int controlSize: Style.space(28)

  Item {
    anchors.fill: parent
    anchors.leftMargin: root.borderLeft + root.pad
    anchors.rightMargin: root.borderRight + root.pad
    anchors.topMargin: root.borderTop + Style.spacing.md
    anchors.bottomMargin: root.borderBottom + Style.spacing.md

    Rectangle {
      id: artFrame
      width: root.artSize
      height: root.artSize
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.foreground, root.accent)
      clip: true

      Image {
        id: art
        anchors.fill: parent
        source: root.artSource
        visible: status === Image.Ready
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        // Decoded to the size it is drawn at, so a player pointing at a
        // print-resolution image costs a thumbnail rather than a bitmap the
        // size of the screen.
        sourceSize.width: root.artSize * 2
        sourceSize.height: root.artSize * 2
        cache: false
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: art.status !== Image.Ready
        text: "󰝚"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
      }
    }

    Column {
      anchors.left: artFrame.right
      anchors.leftMargin: root.pad
      anchors.right: controls.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.title !== "" ? root.title : "Nothing playing"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.artist
        visible: text !== ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: controls
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs

      PanelActionButton {
        visible: !root.editing
        iconText: "󰒮"
        tooltipText: "Previous"
        enabled: root.canGoPrevious
        hasCursor: root.subCursor === 0
        size: root.controlSize
        fontSize: Style.font.icon
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.transport("previous")
        onHovered: function(h) { if (h) root.controlHovered(0) }
      }
      PanelActionButton {
        visible: !root.editing
        iconText: root.playing ? "󰏤" : "󰐊"
        tooltipText: root.playing ? "Pause" : "Play"
        hasCursor: root.subCursor === 1
        size: root.controlSize
        fontSize: Style.font.icon
        // The one control whose state is worth seeing from across the card.
        foreground: root.playing ? root.stateColor : root.foreground
        fontFamily: root.fontFamily
        onClicked: root.transport("playPause")
        onHovered: function(h) { if (h) root.controlHovered(1) }
      }
      PanelActionButton {
        visible: !root.editing
        iconText: "󰒭"
        tooltipText: "Next"
        enabled: root.canGoNext
        hasCursor: root.subCursor === 2
        size: root.controlSize
        fontSize: Style.font.icon
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.transport("next")
        onHovered: function(h) { if (h) root.controlHovered(2) }
      }
    }
  }
}
