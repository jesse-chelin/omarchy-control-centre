import QtQuick
import qs.Commons
import qs.Ui

// The one surface every tile draws on. Fill and border follow the shared
// control tokens so a tile reads like every other Omarchy control: normal
// fill at rest, selected fill when the thing it stands for is on, the
// hover-cursor ring when the keyboard cursor or the pointer is on it. Accent
// marks state only; there are no readout colours.
//
// Hover is reported through `pointerMoved(mouse)` from a position change
// rather than from `entered`, because a tile that appears under a stationary
// pointer fires `entered` with a made-up position, and the card's
// PointerMoveGate needs a real one to decide whether the cursor should follow.
BorderSurface {
  id: root

  property bool active: false
  property bool hasCursor: false
  property bool dimmed: false
  property bool reduceMotion: false
  property color foreground: Color.popups.text
  property color accent: Color.accent
  property string tooltip: ""
  property string fontFamily: Style.font.family

  signal clicked()
  signal rightClicked()
  signal pointerMoved(var mouse)

  readonly property alias containsMouse: mouse.containsMouse

  radius: Style.cornerRadius
  opacity: dimmed ? 0.45 : 1

  // Fill says what the tile's state is; the cursor is drawn on top of that
  // rather than instead of it. A tile that is both on and under the cursor
  // has to show both, and the shared hover-cursor tokens cannot do it alone:
  // themes give normal chrome a stronger border (0.4) than hover-cursor
  // (0.25), so a bordered tile would go *fainter* under the cursor, and the
  // hover fill is dimmer than the selected fill it would be replacing.
  color: active ? Style.selectedFillFor(foreground, accent) : Style.normalFillFor(foreground, accent)
  borderSpec: hasCursor
    ? Border.flat(Style.focusStateColor(foreground, accent), Math.max(1, Style.focusBorderWidth))
    : (active ? Border.controlSpec("selected", foreground, accent) : Border.controlSpec("normal", foreground, accent))

  Behavior on color { enabled: !root.reduceMotion; ColorAnimation { duration: 100 } }

  // The cursor's own wash, stacked over whichever fill the state chose.
  Rectangle {
    anchors.fill: parent
    radius: root.radius
    color: Style.hoverFillFor(root.foreground, root.accent)
    opacity: root.hasCursor ? 1 : 0
    Behavior on opacity { enabled: !root.reduceMotion; NumberAnimation { duration: 100 } }
  }
  Behavior on opacity { enabled: !root.reduceMotion; NumberAnimation { duration: 100 } }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPositionChanged: function(m) { root.pointerMoved(m) }
    onClicked: function(m) {
      if (m.button === Qt.RightButton) root.rightClicked()
      else root.clicked()
    }
    // A toggle tile swallows the wheel on purpose: scrolling over a switch
    // must never flip it, and the slider tiles own their own wheel handling.
    onWheel: function(w) { w.accepted = true }
  }

  PanelToolTip {
    visible: root.tooltip !== "" && mouse.containsMouse
    text: root.tooltip
    fontFamily: root.fontFamily
  }
}
