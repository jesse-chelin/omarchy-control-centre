import QtQuick
import qs.Commons
import qs.Ui

// A group heading in edit mode. It is a cell in the same grid so it scrolls
// and wraps with everything else, but it holds no state and the cursor steps
// straight over it.
Item {
  id: root

  property string label: ""
  property color foreground: Color.popups.text
  property string fontFamily: Style.font.family

  PanelSectionHeader {
    textFormat: Text.PlainText
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.spacing.xxs
    text: root.label.toUpperCase()
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Rectangle {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: Math.max(1, Style.spacing.hairline)
    color: Util.alpha(root.foreground, 0.12)
  }
}
