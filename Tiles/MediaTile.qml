import QtQuick
import qs.Commons
import qs.Ui

// Album art on the left, title and artist in the middle, transport on the
// right. Art is only loaded from a local file: an MPRIS player that hands
// out an http URL gets the note glyph instead, because this plugin never
// touches the network.
TileSurface {
  id: root

  property string title: ""
  property string artist: ""
  property string artUrl: ""
  property bool playing: false
  property bool canGoPrevious: false
  property bool canGoNext: false
  property int subCursor: 1
  property bool editing: false
  property bool enabledInSettings: true

  signal transport(string action)
  signal controlHovered(int index)
  signal moveRequested(int delta)

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property int pad: Style.spacing.xl
  readonly property bool localArt: artUrl.indexOf("file://") === 0
  readonly property int artSize: height - (borderTop + borderBottom) - Style.spacing.md * 2

  active: playing
  dimmed: editing && !enabledInSettings

  Item {
    anchors.fill: parent
    anchors.leftMargin: root.borderLeft + Style.spacing.md
    anchors.rightMargin: root.borderRight + Style.spacing.md
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
        anchors.fill: parent
        source: root.localArt ? root.artUrl : ""
        visible: status === Image.Ready
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize.width: root.artSize * 2
        sourceSize.height: root.artSize * 2
        cache: false
      }

      Text {
        anchors.centerIn: parent
        visible: !root.localArt
        text: "󰝚"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
      }
    }

    Column {
      anchors.left: artFrame.right
      anchors.leftMargin: Style.spacing.xl
      anchors.right: controls.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        text: root.title !== "" ? root.title : "Nothing playing"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
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
        visible: root.editing
        iconText: "󰅁"; tooltipText: "Move up"; fontSize: Style.font.body
        foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: root.moveRequested(-1)
      }
      PanelActionButton {
        visible: root.editing
        iconText: "󰅂"; tooltipText: "Move down"; fontSize: Style.font.body
        foreground: root.foreground; fontFamily: root.fontFamily
        onClicked: root.moveRequested(1)
      }
      PanelActionButton {
        visible: !root.editing
        iconText: "󰒮"
        tooltipText: "Previous"
        enabled: root.canGoPrevious
        hasCursor: root.subCursor === 0
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
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.iconLarge
        onClicked: root.transport("playPause")
        onHovered: function(h) { if (h) root.controlHovered(1) }
      }
      PanelActionButton {
        visible: !root.editing
        iconText: "󰒭"
        tooltipText: "Next"
        enabled: root.canGoNext
        hasCursor: root.subCursor === 2
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.transport("next")
        onHovered: function(h) { if (h) root.controlHovered(2) }
      }
    }
  }
}
