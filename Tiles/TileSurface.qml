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
  property bool reduceMotion: false

  // Edit mode state, held here rather than by each tile so that "this one is
  // hidden" is said once, the same way, on every kind of control.
  property bool editing: false
  property bool enabledInSettings: true
  property bool compact: false
  readonly property bool hiddenInEdit: editing && !enabledInSettings
  readonly property bool dimmed: hiddenInEdit
  property color foreground: Color.popups.text
  property color accent: Color.accent

  // What "on" is painted in.
  //
  // The shell's shared `selected` token is written by the theme template as
  // the theme's own foreground, for every theme, so following it leaves a card
  // whose entire job is showing what is on rendered in exactly one colour.
  // That token is about generic control chrome; this card is about state, and
  // Omarchy already spends the accent on state elsewhere: the mark under a bar
  // icon whose panel is open, and the border of this very card.
  //
  // So the accent marks what is on, when the theme has an accent worth
  // spending. Two ways it might not: a theme that never set one, where the
  // accent is the foreground; and a theme whose accent is a neutral, where an
  // "on" tile would come out a paler wash than the plain foreground gives.
  // Either way the shared token is the better answer.
  readonly property bool hasColourAccent: accent.hsvSaturation > 0.15
    && (Math.abs(accent.r - foreground.r) + Math.abs(accent.g - foreground.g)
      + Math.abs(accent.b - foreground.b) > 0.15)
  readonly property color stateColor: hasColourAccent
    ? accent
    : Style.selectedStateColor(foreground, accent)
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
  // The drag reports positions, never deltas. A delta measured in this item's
  // own coordinates is measured against a frame the drag itself is moving, so
  // it feeds back on the next event and the tile oscillates. The card
  // measures in the grid's coordinates, which the tile's transform cannot
  // touch, and needs the press point to do it.
  signal dragStarted(var item, real pressX, real pressY)
  signal dragMoved(var item, var mouse)
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
  color: active ? Util.alpha(stateColor, Style.selectedFillAlpha) : Style.normalFillFor(foreground, accent)
  borderSpec: dropTarget
    ? Border.flat(accent, Math.max(2, Style.space(2)))
    : (hasCursor
      ? Border.flat(Style.focusStateColor(foreground, accent), Math.max(1, Style.focusBorderWidth))
      : (active
        ? Border.flat(Util.alpha(stateColor, 0.5), Style.normalBorderWidth)
        : Border.controlSpec("normal", foreground, accent)))

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
      if (!dragging) {
        // Still the tile's own coordinates, but nothing has moved yet, so
        // they are the same as anyone else's.
        if (Math.abs(m.x - pressX) < root.dragThreshold && Math.abs(m.y - pressY) < root.dragThreshold) return
        dragging = true
        root.dragStarted(root, pressX, pressY)
      }
      root.dragMoved(root, m)
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
    // No wheel handler on purpose. A tile has nothing to do with a wheel, and
    // anything declared here would be accepted and stop there, which left the
    // grid scrolling only over the gaps between tiles.
  }

  PanelToolTip {
    visible: root.tooltip !== "" && mouse.containsMouse
    text: root.tooltip
    fontFamily: root.fontFamily
  }
}
