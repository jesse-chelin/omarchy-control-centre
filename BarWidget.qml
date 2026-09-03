import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The launcher in the bar. It behaves like a stock bar panel rather than like
// a separate overlay that happens to have a button: the card opens under this
// icon, the icon takes the accent open-panel mark while it is up, and opening
// it closes whichever bar panel was open before (and vice versa), because it
// claims the bar's single popout the same way the stock panels do.
//
// The overlay owns the settings; this reads them through the shell's panel
// loader so there is one copy of the answer to "is the pill shown".
BarWidget {
  id: root
  moduleName: "io.github.jesse-chelin.control-centre"

  readonly property var overlay: {
    var loaders = bar && bar.shell ? bar.shell.panelLoaders : null
    var loader = loaders ? loaders[root.moduleName] : null
    return loader && loader.item ? loader.item : null
  }
  // On by default, but not until the overlay has read the settings file:
  // painting the pill and then taking it away again is worse for someone who
  // turned it off than showing it a beat after the rest of the bar.
  readonly property bool shown: overlay && overlay.settingsLoaded
    ? overlay.settings.barWidget === true : false
  readonly property bool overlayOpen: overlay ? overlay.opened === true : false

  // The bar coordinator closes the previous owner by calling one of these,
  // which is how clicking another bar icon puts this card away.
  readonly property bool opened: overlayOpen
  function close() {
    if (bar && bar.shell && typeof bar.shell.hide === "function") bar.shell.hide(root.moduleName)
  }
  function closeForPopoutSwitch() { root.close() }
  function open() { root.summon() }
  function toggle() { root.overlayOpen ? root.close() : root.summon() }

  // Where the card should point. On a horizontal bar the widget's position
  // inside the bar's content item maps straight to screen x, because the bar
  // spans the screen on that axis; on a vertical bar the same holds for y.
  function anchorPayload() {
    var window = root.QsWindow.window
    if (!window || !window.contentItem) return "{}"
    var point = root.mapToItem(window.contentItem, 0, 0)
    var centre = root.vertical ? point.y + root.height / 2 : point.x + root.width / 2
    return JSON.stringify({
      anchor: Math.round(centre),
      screen: window.screen ? String(window.screen.name) : ""
    })
  }

  function summon() {
    if (!bar || !bar.shell || typeof bar.shell.summon !== "function") return
    bar.shell.summon(root.moduleName, root.anchorPayload())
  }

  // Claim the bar's popout while the card is up, so this icon gets the
  // open-panel mark and any other open panel steps aside.
  onOverlayOpenChanged: {
    if (!bar) return
    if (overlayOpen) bar.requestPopout(root)
    else if (bar.activePopout === root) bar.releasePopout(root)
  }

  Component.onDestruction: if (bar && bar.activePopout === root) bar.releasePopout(root)

  visible: shown
  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: shown ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰘮"
    tooltipText: "Control Centre"
    onPressed: function() { root.toggle() }
  }
}
