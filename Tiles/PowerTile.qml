import QtQuick
import qs.Commons
import qs.Ui
import "../Model.js" as Model

// Battery on the left, the profile picker on the right. Either half can be
// absent: a desktop has profiles and no battery, a laptop without
// power-profiles-daemon has a battery and no profiles.
TileSurface {
  id: root

  property string batteryGlyph: ""
  property string batteryText: ""
  property bool batteryPresent: false
  property bool charging: false
  property var profiles: []
  property string activeProfile: ""
  property string pendingProfile: ""
  property int subCursor: -1
  property bool busy: false
  property string error: ""
  property bool chevron: false
  property string chevronTooltip: ""

  signal profileClicked(string profile)
  signal profileHovered(int index)
  signal chevronClicked()

  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property int pad: Style.spacing.xl
  readonly property string shownProfile: pendingProfile !== "" ? pendingProfile : activeProfile

  active: false

  Item {
    anchors.fill: parent
    anchors.leftMargin: root.borderLeft + root.pad
    anchors.rightMargin: root.borderRight + Style.spacing.md
    anchors.topMargin: root.borderTop
    anchors.bottomMargin: root.borderBottom

    Text {
      textFormat: Text.PlainText
      id: glyphText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      visible: root.batteryPresent
      text: root.batteryGlyph
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge

      SequentialAnimation on opacity {
        running: root.charging && !root.reduceMotion
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
        NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
      }
    }

    Column {
      id: labels
      anchors.left: root.batteryPresent ? glyphText.right : parent.left
      anchors.leftMargin: root.batteryPresent ? Style.spacing.lg : 0
      anchors.right: chips.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.batteryPresent ? "Battery" : "Power"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.error !== "" ? root.error : (root.batteryPresent ? root.batteryText : "Profile")
        visible: text !== ""
        color: root.error !== "" ? Color.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: chips
      anchors.right: trailing.left
      anchors.rightMargin: trailing.width > 0 ? Style.spacing.sm : 0
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.sm
      visible: !root.editing

      Repeater {
        model: root.profiles
        Button {
          required property var modelData
          required property int index
          iconText: root.busy && root.shownProfile === modelData ? "󰑐" : Model.profileGlyph(modelData)
          iconSpinning: root.busy && root.shownProfile === modelData && !root.reduceMotion
          iconSize: Style.font.body
          text: root.profiles.length <= 2 ? Model.profileLabel(modelData) : ""
          tooltipText: Model.profileLabel(modelData)
          fontSize: Style.font.caption
          foreground: root.shownProfile === modelData ? root.stateColor : root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          horizontalPadding: Style.spacing.lg
          verticalPadding: Style.spacing.sm
          bordered: true
          selected: root.shownProfile === modelData
          hasCursor: root.subCursor === index
          onClicked: root.profileClicked(modelData)
          onHovered: function(h) { if (h) root.profileHovered(index) }
        }
      }
    }

    Row {
      id: trailing
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      PanelActionButton {
        visible: root.chevron && !root.editing
        iconText: "󰅂"
        tooltipText: root.chevronTooltip
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.body
        onClicked: root.chevronClicked()
      }
    }
  }
}
