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

  // Edit mode drags a tile to where it should sit. The press has to stay a
  // click until the pointer has actually travelled, or every attempt to
  // switch a tile off would start a drag instead.
  property bool draggable: false
  property bool dropTarget: false
  readonly property int dragThreshold: Style.space(6)

  signal clicked()
  signal rightClicked()
  signal pointerMoved(var mouse)
  signal dragStarted()
  signal dragMoved(real dx, real dy, var item, var mouse)
  signal dragEnded()

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
  borderSpec: dropTarget
    ? Border.flat(accent, Math.max(2, Style.space(2)))
    : (hasCursor
      ? Border.flat(Style.focusStateColor(foreground, accent), Math.max(1, Style.focusBorderWidth))
      : (active ? Border.controlSpec("selected", foreground, accent) : Border.controlSpec("normal", foreground, accent)))

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
    cursorShape: root.draggable ? (dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    // The grid scrolls, and a Flickable takes the grab off a child as soon as
    // the pointer has travelled far enough. Without this a drag turns into a
    // scroll halfway through, every time.
    preventStealing: root.draggable

    property bool dragging: false
    property real pressX: 0
    property real pressY: 0

    onPressed: function(m) {
      dragging = false
      pressX = m.x
      pressY = m.y
    }
    onPositionChanged: function(m) {
      if (!root.draggable || !(m.buttons & Qt.LeftButton)) {
        root.pointerMoved(m)
        return
      }
      var dx = m.x - pressX
      var dy = m.y - pressY
      if (!dragging) {
        if (Math.abs(dx) < root.dragThreshold && Math.abs(dy) < root.dragThreshold) return
        dragging = true
        root.dragStarted()
      }
      root.dragMoved(dx, dy, root, m)
    }
    onReleased: function(m) {
      if (!dragging) return
      dragging = false
      root.dragEnded()
    }
    onCanceled: {
      if (!dragging) return
      dragging = false
      root.dragEnded()
    }
    onClicked: function(m) {
      // A press that turned into a drag has already done its work.
      if (dragging) return
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
