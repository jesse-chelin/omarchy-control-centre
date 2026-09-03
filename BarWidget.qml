import QtQuick
import qs.Commons
import qs.Ui

// A single-glyph launcher for the mouse. Off by default: it renders only
// when the overlay's "Bar pill" setting is on, and the overlay is the single
// source of that setting, reached through the shell's panel loader so no
// second copy of the settings file is ever read.
BarWidget {
  id: root
  moduleName: "io.github.jesse-chelin.control-centre"

  readonly property var overlay: {
    var loaders = bar && bar.shell ? bar.shell.panelLoaders : null
    var loader = loaders ? loaders[root.moduleName] : null
    return loader && loader.item ? loader.item : null
  }
  readonly property bool shown: overlay && overlay.settings ? overlay.settings.barWidget === true : false
  readonly property bool overlayOpen: overlay ? overlay.opened === true : false

  visible: shown
  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: shown ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰘮"
    active: root.overlayOpen
    tooltipText: "Control Centre"
    onPressed: function() {
      if (root.bar && root.bar.shell && typeof root.bar.shell.toggle === "function")
        root.bar.shell.toggle(root.moduleName, "{}")
    }
  }
}
