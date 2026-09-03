import QtQuick
import qs.Commons
import qs.Ui

// One settings row in edit mode: a label, a description, and either a
// switch or a pair of choice chips on the right. Enter on the row activates
// it: flips the switch, or cycles the choice.
TileSurface {
  id: root

  property string label: ""
  property string description: ""
  property bool isChoice: false
  property var choices: []      // [{ value, label }]
  property string value: ""
  property bool checked: false

  // A row that captures a key rather than holding a value: it shows what is
  // set, and while it is armed it says so instead.
  property bool isCapture: false
  property bool capturing: false
  property string captureValue: ""

  signal activated()
  signal choiceClicked(string value)

  readonly property color dim: Qt.darker(foreground, 1.5)

  active: false

  Item {
    anchors.fill: parent
    anchors.leftMargin: root.borderLeft + Style.spacing.xl
    anchors.rightMargin: root.borderRight + Style.spacing.md
    anchors.topMargin: root.borderTop
    anchors.bottomMargin: root.borderBottom

    Column {
      anchors.left: parent.left
      anchors.right: control.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

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
        text: root.description
        visible: text !== ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Item {
      id: control
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: root.isCapture ? capture.implicitWidth
        : (root.isChoice ? group.implicitWidth : toggle.implicitWidth)
      height: root.isCapture ? capture.implicitHeight
        : (root.isChoice ? group.implicitHeight : toggle.implicitHeight)

      // The shortcut itself, in the shape a shortcut is written.
      BorderSurface {
        id: capture
        visible: root.isCapture
        implicitWidth: captureText.implicitWidth + Style.spacing.xxl
        implicitHeight: captureText.implicitHeight + Style.spacing.md
        radius: Style.cornerRadius
        color: root.capturing
          ? Style.selectedFillFor(root.accent, root.accent)
          : Style.normalFillFor(root.foreground, root.accent)
        borderSpec: root.capturing
          ? Border.flat(root.accent, Math.max(1, Style.focusBorderWidth))
          : Border.controlSpec("normal", root.foreground, root.accent)

        Text {
          id: captureText
          anchors.centerIn: parent
          text: root.capturing ? "Press a combination"
            : (root.captureValue !== "" ? root.captureValue : "Not set")
          color: root.capturing ? root.accent
            : (root.captureValue !== "" ? root.foreground : root.dim)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ButtonGroup {
        id: group
        visible: root.isChoice
        options: root.choices
        value: root.value
        focusable: false
        foreground: root.foreground
        background: Color.popups.background
        accent: root.accent
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onChanged: function(v) { root.choiceClicked(v) }
      }

      ToggleSwitch {
        id: toggle
        visible: !root.isChoice && !root.isCapture
        checked: root.checked
        foreground: root.foreground
        accent: root.accent
        cursorRing: false
        onToggled: root.activated()
      }
    }
  }
}
