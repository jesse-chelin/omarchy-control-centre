import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Networking
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Tiles"

// A macOS-style Control Centre for the Omarchy shell: one card with every
// daily toggle and slider, each backed by the same source the stock bar
// panel uses, with a chevron into that panel for anything deeper.
//
// State comes from three places, in order of preference: Quickshell's own
// service modules (Pipewire, UPower, Networking, Bluetooth), the shell's
// first-party services (notifications, night light, idle, media), and a
// handful of subprocess probes that only run while the card is open.
//
// One key catcher owns every keystroke. Tiles never take focus: a focused
// child that appears and vanishes hands Qt's focus somewhere useless and the
// card stops answering the keyboard.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "io.github.jesse-chelin.control-centre"
  readonly property string pluginDir: (manifest && manifest.__sourceDir)
    || (Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.jesse-chelin.control-centre")
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/control-centre.json"

  // ------------------------------------------------------------- lifecycle

  property bool opened: false
  property bool editing: false
  property int cursor: 0
  property int subCursor: 0
  property string status: ""
  property string screenName: ""
  property bool hintVisible: false

  property var settings: Model.defaultSettings()
  property bool settingsLoaded: false
  property string settingsRejected: ""
  readonly property bool reduceMotion: settings.reduceMotion === true
  readonly property bool compact: settings.density === "compact"

  // Where the card points when it was opened from the bar pill: the centre of
  // that icon, along the bar. -1 means it was summoned by key, and the
  // position setting decides instead.
  property int anchorCentre: -1

  // The payload is written by this plugin's own bar widget, but it arrives
  // through shell IPC where anyone can send one, so both fields are checked
  // rather than trusted.
  function applyPayload(payloadJson) {
    var payload = null
    var text = String(payloadJson || "")
    if (text.length > 0 && text.length < 4096) {
      try { payload = JSON.parse(text) } catch (e) { payload = null }
    }
    var anchor = payload && typeof payload.anchor === "number" && isFinite(payload.anchor)
      ? Math.round(payload.anchor) : -1
    root.anchorCentre = anchor >= 0 ? anchor : -1

    var named = payload && typeof payload.screen === "string" ? payload.screen : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && String(screens[i].name) === named) {
        root.screenName = named
        return
      }
    }
    root.screenName = root.focusedScreenName()
  }

  function open(payloadJson) {
    root.bindServices()
    root.editing = false
    root.status = ""
    root.armedId = ""
    root.tileErrors = ({})
    root.applyPayload(payloadJson)
    root.holdAvailability()
    // Re-read on every open, not only at load, so a settings file edited or
    // removed by hand takes effect at the next summon rather than at the next
    // shell restart. Skipped while a write is in flight, because reading then
    // would race our own writer and load the older document back.
    if (!stateWriter.running && !root.settingsWriteQueued) root.refreshSettings()
    root.opened = true
    root.hintVisible = root.settingsLoaded && root.settings.hintSeen !== true
    root.cursor = Model.firstIndexOfKind(root.gridIds, "toggle")
    root.resetSubCursor()
    pointerGate.reset()
    root.refreshAll()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (root.hintVisible) root.dismissHint()
    root.opened = false
    root.editing = false
    root.armedId = ""
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function flash(text) {
    root.status = String(text || "")
    statusTimer.restart()
  }

  function focusedScreenName() {
    var monitor = Hyprland.focusedMonitor
    return monitor ? String(monitor.name || "") : ""
  }

  readonly property var targetScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && String(screens[i].name) === root.screenName) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  // Every child runs with this and nothing else. A cleared environment is
  // what closes BASH_ENV and the loader hooks. The names passed through are
  // the ones the Omarchy scripts genuinely need: hyprctl wants the Hyprland
  // socket, omarchy-shell wants the runtime dir, the scripts locate their
  // siblings through OMARCHY_PATH.
  readonly property var childEnvironment: {
    var bin = root.omarchyPath ? root.omarchyPath + "/bin:" : ""
    var env = { "PATH": bin + "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8" }
    var names = ["HOME", "XDG_RUNTIME_DIR", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "WAYLAND_DISPLAY",
                 "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS", "OMARCHY_PATH"]
    for (var i = 0; i < names.length; i++) {
      var value = Quickshell.env(names[i])
      if (value) env[names[i]] = value
    }
    return env
  }

  // A child that never exits would pin a collector open inside a process
  // that lives as long as the session. TERM first, KILL if it will not go.
  component Watchdog: Timer {
    property var proc: null
    property bool escalated: false

    repeat: false
    interval: 3000
    onTriggered: {
      if (!proc || !proc.running) return
      if (escalated) {
        proc.signal(9)
        return
      }
      escalated = true
      interval = 1000
      restart()
    }

    function arm() {
      escalated = false
      interval = 3000
      restart()
    }
  }

  // Every subprocess in this file is one of these: fixed argv, cleared
  // environment, watchdog.
  component Child: Process {
    id: child
    clearEnvironment: true
    environment: root.childEnvironment
    onRunningChanged: {
      if (running) dog.arm()
      else dog.stop()
    }
    readonly property Watchdog dog: Watchdog { proc: child }
  }

  // Fire-and-forget system actions (lock, sleep, screensaver, the capture
  // menu) outlive the card, so they detach rather than run under a collector.
  function runDetached(argv) {
    Quickshell.execDetached({ command: argv, environment: root.childEnvironment, clearEnvironment: true })
  }

  // ------------------------------------------------------------- services

  property var notificationService: null
  property var nightlightService: null
  property var idleService: null
  property var mediaService: null
  property bool servicesReported: false

  function bindServices() {
    if (!root.shell || typeof root.shell.firstPartyServiceFor !== "function") return
    root.notificationService = root.shell.firstPartyServiceFor("omarchy.notifications")
    root.nightlightService = root.shell.firstPartyServiceFor("omarchy.nightlight")
    root.idleService = root.shell.firstPartyServiceFor("omarchy.idle")
    root.mediaService = root.shell.firstPartyServiceFor("omarchy.media")
    if (root.servicesReported) return
    root.servicesReported = true
    var missing = []
    if (!root.notificationService) missing.push("omarchy.notifications")
    if (!root.nightlightService) missing.push("omarchy.nightlight")
    if (!root.idleService) missing.push("omarchy.idle")
    if (!root.mediaService) missing.push("omarchy.media")
    if (missing.length > 0)
      console.warn("control-centre: shell services missing, their tiles are hidden: " + missing.join(", "))
  }

  onShellChanged: root.bindServices()
  Component.onCompleted: {
    root.bindServices()
    root.refreshSettings()
  }

  readonly property bool dnd: notificationService ? notificationService.doNotDisturb === true : false
  readonly property bool nightlight: nightlightService ? nightlightService.enabled === true : false
  readonly property bool stayAwake: idleService ? idleService.stayAwake === true : false
  readonly property var mediaPlayer: mediaService ? mediaService.activePlayer : null
  readonly property bool hasMedia: mediaService ? mediaService.hasMedia === true : false

  // ---------------------------------------------------------------- network

  readonly property bool networkManagerAvailable: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var networkDevices: Networking.devices ? Networking.devices.values : []
  readonly property var wifiDevice: findDevice(DeviceType.Wifi)
  readonly property var wiredDevice: findDevice(DeviceType.Wired)
  readonly property var wifiNetworkObjects: wifiDevice && wifiDevice.networks ? wifiDevice.networks.values : []
  readonly property var connectedWifiNetwork: findConnectedWifiNetwork()
  readonly property bool wifiEnabled: Networking.wifiEnabled === true
  readonly property bool wiredConnected: !!(wiredDevice && wiredDevice.connected)
  readonly property int wifiSignal: connectedWifiNetwork ? Math.round((connectedWifiNetwork.signalStrength || 0) * 100) : -1

  function findDevice(type) {
    var devices = root.networkDevices || []
    var fallback = null
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (!device || device.type !== type) continue
      if (device.connected) return device
      if (!fallback) fallback = device
    }
    return fallback
  }

  function findConnectedWifiNetwork() {
    var networks = root.wifiNetworkObjects || []
    for (var i = 0; i < networks.length; i++) {
      if (networks[i] && networks[i].connected) return networks[i]
    }
    return null
  }

  // Same call the stock network panel makes. NetworkManager answers the
  // desktop user without a prompt; the Quickshell binding takes care of it.
  function toggleWifi() {
    if (!root.networkManagerAvailable || !root.wifiDevice) return
    Networking.wifiEnabled = !Networking.wifiEnabled
  }

  // -------------------------------------------------------------- bluetooth

  readonly property var adapter: Bluetooth.defaultAdapter
  readonly property var bluetoothDevices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property bool bluetoothOn: !!(adapter && adapter.enabled)
  readonly property var connectedDeviceNames: {
    var names = []
    for (var i = 0; i < bluetoothDevices.length; i++) {
      var d = bluetoothDevices[i]
      if (d && d.connected) names.push(String(d.deviceName || d.name || "").trim())
    }
    return names
  }

  // Not adapter.enabled: that writes BlueZ's Powered, which nothing persists.
  // omarchy-bluetooth-power moves the rfkill block, which survives a reboot.
  function toggleBluetooth() {
    if (!root.adapter || bluetoothProc.running) return
    var want = !root.bluetoothOn
    root.beginPending("bluetooth", want, "Bluetooth adapter unavailable")
    bluetoothProc.command = ["omarchy-bluetooth-power", want ? "on" : "off"]
    bluetoothProc.running = true
  }

  Child {
    id: bluetoothProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.failPending("bluetooth", "Bluetooth adapter unavailable")
    }
  }

  // ------------------------------------------------------------------ audio

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  property string volumeSinkName: ""
  property var sinkAvailability: ({})

  // A DSP sink can be the selected output without being where loudness lives.
  // omarchy-audio-output-sink resolves through it to the physical sink, the
  // same way the volume keys and the stock panel do.
  readonly property var volumeSink: {
    if (volumeSinkName === "" || !sink) return sink
    if (volumeSinkName === String(sink.name)) return sink
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === volumeSinkName && n.audio) return n
    }
    return sink
  }

  readonly property var candidateSinks: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isSink || n.isStream) continue
      if (String(n.name || "").indexOf("omarchy_speaker_tuning") === 0) continue
      if (sinkAvailability[String(n.name)] === false) continue
      list.push(n)
    }
    return list
  }

  readonly property var captureStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isStream && n.isSink === false) list.push(n)
    }
    return list
  }

  readonly property real outputVolume: volumeSink && volumeSink.audio ? volumeSink.audio.volume : 0
  readonly property bool outputMuted: volumeSink && volumeSink.audio ? volumeSink.audio.muted : false
  readonly property bool inputMuted: source && source.audio ? source.audio.muted : true
  readonly property real inputVolume: source && source.audio ? source.audio.volume : 0
  readonly property bool micInUse: {
    if (root.inputMuted) return false
    for (var i = 0; i < captureStreams.length; i++) {
      var n = captureStreams[i]
      if (n && n.audio && !n.audio.muted) return true
    }
    return false
  }

  PwObjectTracker { objects: root.candidateSinks }
  PwObjectTracker { objects: root.source ? [root.source] : [] }
  PwObjectTracker { objects: root.captureStreams }

  function isHeadphones(node) {
    if (!node) return false
    var p = node.ready && node.properties ? node.properties : {}
    var blob = String([node.name, node.description, node.nickname,
      p["device.icon-name"] || "", p["device.product.name"] || "",
      p["node.description"] || "", p["node.nick"] || ""].join(" ")).toLowerCase()
    return blob.indexOf("headphone") !== -1 || blob.indexOf("headset") !== -1
      || blob.indexOf("earbud") !== -1 || blob.indexOf("earphone") !== -1 || blob.indexOf("airpod") !== -1
  }

  function nodeLabel(node) {
    if (!node) return ""
    var p = node.ready && node.properties ? node.properties : {}
    var label = String(node.nickname || node.nick || p["node.nick"] || p["device.profile.description"]
      || node.description || p["node.description"] || node.name || "").trim()
    label = label.replace(/^sof-soundwire\s+/i, "").replace(/^built-?in audio\s+/i, "")
      .replace(/\s+Output$/i, "").replace(/\s+Input$/i, "")
    return label
  }

  function setOutputVolume(v) {
    if (!root.volumeSink || !root.volumeSink.audio) return
    root.volumeSink.audio.volume = Math.max(0, Math.min(1, v))
  }

  function toggleOutputMute() {
    if (root.volumeSink && root.volumeSink.audio) root.volumeSink.audio.muted = !root.volumeSink.audio.muted
  }

  function toggleInputMute() {
    if (root.source && root.source.audio) root.source.audio.muted = !root.source.audio.muted
  }

  // Next output in the stock panel's order, set the way the stock panel sets
  // it: the Pipewire preference plus the Omarchy script that remembers it.
  function cycleSink() {
    var list = root.candidateSinks
    if (list.length < 2 || sinkProc.running) return
    var index = -1
    for (var i = 0; i < list.length; i++) if (root.sink && list[i].id === root.sink.id) index = i
    var next = list[(index + 1) % list.length]
    if (!next || !Model.isNodeId(next.id) || !Model.isNodeName(next.name)) return
    Pipewire.preferredDefaultAudioSink = next
    sinkProc.command = ["omarchy-audio-output-set-default", String(next.id), String(next.name)]
    sinkProc.running = true
  }

  Child {
    id: sinkProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: root.resolveVolumeSink()
  }

  function resolveVolumeSink() {
    if (!sinkNameProbe.running) sinkNameProbe.running = true
  }

  Child {
    id: sinkNameProbe
    command: ["omarchy-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var name = String(text || "").trim()
        root.volumeSinkName = Model.isNodeName(name) ? name : ""
      }
    }
  }

  Child {
    id: sinkAvailabilityProbe
    command: ["omarchy-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = {}
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length && i < 64; i++) {
          var parts = lines[i].trim().split("\t")
          if (parts.length >= 2 && Model.isNodeName(parts[0])) next[parts[0]] = parts[1] !== "0"
        }
        root.sinkAvailability = next
      }
    }
  }

  // ------------------------------------------------- flags, hardware, themes

  // Everything QML cannot read for itself, gathered by one child rather than
  // a dozen. `flags` is re-read on the open timer; `hardware` and the theme
  // list are read once per card, since a desktop does not grow a touchscreen
  // while the card is up.
  property var flags: ({})
  property var hardware: ({})
  property var themes: []
  property string currentTheme: ""
  property bool hardwareLoaded: false

  function parseProbe(raw, limit) {
    var out = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length && i < limit; i++) {
      var idx = lines[i].indexOf("\t")
      if (idx <= 0) continue
      var key = lines[i].substring(0, idx)
      if (!/^[a-z][a-z0-9._-]{0,48}$/.test(key)) continue
      out[key] = lines[i].substring(idx + 1).trim().slice(0, 64)
    }
    return out
  }

  Child {
    id: stateProbe
    command: [root.pluginDir + "/probe.sh", "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = root.parseProbe(text, 64)
        root.flags = next
        root.currentTheme = /^[a-z0-9][a-z0-9-]{0,63}$/.test(next["theme.current"] || "")
          ? next["theme.current"] : ""
        root.reconcileFlags()
        if (root.pending.theme !== undefined && root.pending.theme === root.currentTheme) root.clearPending("theme")
      }
    }
  }

  Child {
    id: staticProbe
    command: [root.pluginDir + "/probe.sh", "static"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var hw = {}
        var list = []
        for (var i = 0; i < lines.length && i < 80; i++) {
          var idx = lines[i].indexOf("\t")
          if (idx <= 0) continue
          var key = lines[i].substring(0, idx)
          var value = lines[i].substring(idx + 1).trim().slice(0, 64)
          if (key === "theme.available") {
            if (/^[a-z0-9][a-z0-9-]{0,63}$/.test(value) && list.length < 40) list.push(value)
          } else if (/^(hw|has)\.[a-z0-9.-]{1,48}$/.test(key)) {
            hw[key] = value
          }
        }
        root.hardware = hw
        root.themes = list
        root.hardwareLoaded = true
      }
    }
  }

  // The tiles below are all "a flag file exists or it does not". The flag
  // names carry the sense the file has (`bar-off`), which is the opposite of
  // the sense the tile shows, so the inversion lives here in one place.
  function flagOn(name) { return root.flags["flag." + name] === "on" }
  function hyprFlagOn(name) { return root.flags["hypr." + name] === "on" }
  // Core Omarchy commands are assumed present until the probe says otherwise,
  // so the usual case never shows a card that grows a beat after it opens.
  // Hardware is the other way round: claiming a touchscreen that is not there
  // is worse than showing its tile a moment late.
  function hasTool(name) {
    if (!root.hardwareLoaded) return true
    return root.hardware["has." + name] === "yes"
  }
  function hasPart(name) { return root.hardware["hw." + name] === "yes" }

  // Someone running their own emoji picker or clipboard should get theirs
  // from this tile, not the built-in one they replaced. A third-party plugin
  // whose name says what it is wins; the first-party one is the fallback.
  function preferredPlugin(word, fallbackId) {
    var registry = root.shell ? root.shell.pluginRegistry : null
    var plugins = registry && registry.installedPlugins ? registry.installedPlugins : null
    if (!plugins) return fallbackId
    var needle = String(word).toLowerCase()
    for (var id in plugins) {
      var manifest = plugins[id]
      if (!manifest || manifest.__isFirstParty) continue
      if (!Array.isArray(manifest.kinds) || manifest.kinds.indexOf("overlay") === -1) continue
      if (!registry.isEnabled(id)) continue
      var haystack = (String(id) + " " + String(manifest.name || "")).toLowerCase()
      if (haystack.indexOf(needle) !== -1) return id
    }
    return fallbackId
  }

  function pluginFor(tileId) {
    var fallback = Model.actionSummon(tileId)
    if (!fallback) return ""
    if (tileId === "emoji") return root.preferredPlugin("emoji", fallback)
    if (tileId === "clipboard") return root.preferredPlugin("clipboard", fallback)
    return fallback
  }

  function pluginAvailable(id) {
    var registry = root.shell ? root.shell.pluginRegistry : null
    if (!registry || !registry.installedPlugins) return false
    return !!registry.installedPlugins[id] && registry.isEnabled(id)
  }

  readonly property bool barShown: !root.flagOn("bar-off")
  readonly property bool screensaverEnabled: !root.flagOn("screensaver-off")
  readonly property bool crashCaptureEnabled: !root.flagOn("crash-capture-off")
  readonly property bool gapsOn: !root.hyprFlagOn("window-no-gaps")
  readonly property bool squareRatioOn: root.hyprFlagOn("single-window-aspect-ratio")
  readonly property bool touchpadOn: root.flags["input.touchpad"] !== "off"
  readonly property bool touchscreenOn: root.flags["input.touchscreen"] !== "off"
  readonly property bool scrollingLayout: root.flags["workspace.layout"] === "scrolling"

  // Each of these is what its tile shows, so reconciliation is one table.
  function flagState(id) {
    if (id === "bar") return root.barShown
    if (id === "screensaver") return root.screensaverEnabled
    if (id === "crashcapture") return root.crashCaptureEnabled
    if (id === "gaps") return root.gapsOn
    if (id === "ratio") return root.squareRatioOn
    if (id === "touchpad") return root.touchpadOn
    if (id === "touchscreen") return root.touchscreenOn
    if (id === "layout") return root.scrollingLayout
    if (id === "laptopdisplay") return root.internalEnabled
    if (id === "mirror") return root.mirrorEnabled
    return false
  }

  readonly property var flagTiles: ["bar", "screensaver", "crashcapture", "gaps", "ratio",
                                    "touchpad", "touchscreen", "layout", "laptopdisplay", "mirror"]

  function reconcileFlags() {
    for (var i = 0; i < root.flagTiles.length; i++) {
      var id = root.flagTiles[i]
      if (root.pending[id] !== undefined && root.pending[id] === root.flagState(id)) root.clearPending(id)
    }
  }

  // One command per flag tile, each a fixed vector.
  function flagCommand(id) {
    if (id === "bar") return ["omarchy-toggle-bar"]
    if (id === "screensaver") return ["omarchy-toggle-screensaver"]
    if (id === "crashcapture") return ["omarchy-toggle-crash-capture"]
    if (id === "gaps") return ["omarchy-hyprland-window-gaps-toggle"]
    if (id === "ratio") return ["omarchy-hyprland-window-single-square-aspect-toggle"]
    if (id === "layout") return ["omarchy-hyprland-workspace-layout-toggle"]
    if (id === "touchpad") return ["omarchy-toggle-touchpad"]
    if (id === "touchscreen") return ["omarchy-toggle-touchscreen"]
    if (id === "laptopdisplay") return ["omarchy-hyprland-monitor-internal", "toggle"]
    if (id === "mirror") return ["omarchy-hyprland-monitor-internal-mirror", "toggle"]
    return null
  }

  function toggleFlag(id) {
    var argv = root.flagCommand(id)
    if (!argv || flagProc.running) return
    root.beginPending(id, !root.flagState(id), "That switch did not take")
    flagProc.command = argv
    flagProc.running = true
  }

  Child {
    id: flagProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        for (var i = 0; i < root.flagTiles.length; i++) {
          var id = root.flagTiles[i]
          if (root.pending[id] !== undefined) root.failPending(id, "That switch did not take")
        }
      }
      if (!stateProbe.running) stateProbe.running = true
      if (!monitorProbe.running) monitorProbe.running = true
    }
  }

  // --------------------------------------------------------------- warmth

  // The night light service owns the temperature; this tile is a second way
  // to set it, alongside the on/off the indicator gives. Warmer to the right,
  // which is the direction the word points.
  readonly property int warmthCoolest: 6500
  readonly property int warmthWarmest: 2500
  readonly property int warmthTemperature: {
    var t = root.nightlightService ? Number(root.nightlightService.temperature) : NaN
    if (!isFinite(t) || t <= 0) return root.warmthCoolest
    return Math.max(root.warmthWarmest, Math.min(root.warmthCoolest, Math.round(t)))
  }
  property int warmthPreview: 0
  readonly property int warmthShown: root.warmthPreview > 0 ? root.warmthPreview : root.warmthTemperature
  readonly property real warmthValue: (root.warmthCoolest - root.warmthShown) / (root.warmthCoolest - root.warmthWarmest)

  function warmthFromValue(v) {
    var span = root.warmthCoolest - root.warmthWarmest
    return Math.max(root.warmthWarmest, Math.min(root.warmthCoolest,
      Math.round(root.warmthCoolest - Math.max(0, Math.min(1, v)) * span)))
  }

  function previewWarmth(v) {
    root.warmthPreview = root.warmthFromValue(v)
    warmthDebounce.restart()
  }

  function commitWarmth() {
    if (!root.nightlightService || root.warmthPreview <= 0) return
    root.nightlightService.applyTemperature(root.warmthPreview)
  }

  Timer {
    id: warmthDebounce
    interval: 180
    repeat: false
    onTriggered: root.commitWarmth()
  }

  // ---------------------------------------------------------------- themes

  function setTheme(name) {
    if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(String(name)) || root.themes.indexOf(name) < 0) return
    if (themeProc.running) return
    // A theme change rewrites config across the system and asks the shell to
    // reload; it is not a switch that answers in a moment.
    root.beginPending("theme", name, "Could not switch theme", 20000)
    themeProc.command = ["omarchy-theme-set", String(name)]
    themeProc.running = true
  }

  Child {
    id: themeProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.failPending("theme", "Could not switch theme")
      if (!stateProbe.running) stateProbe.running = true
    }
  }

  // ------------------------------------------------------------ brightness

  property bool brightnessAvailable: false
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property string focusedMonitor: ""
  property string internalMonitorName: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false

  Child {
    id: monitorProbe
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        var available = brightness !== "unavailable" && /^\d{1,3}$/.test(brightness)
        root.internalMonitorName = String(lines[1] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() !== "" && String(lines[2] || "").trim() !== ""
        var monitor = String(lines[5] || "").trim()
        root.focusedMonitor = Model.isMonitorName(monitor) ? monitor : ""
        root.brightnessAvailable = available && root.focusedMonitor !== ""
        root.monitorProbed = true
        // While a write is in flight the local value is authoritative;
        // re-reading races the driver and bounces the slider.
        if (root.brightnessAvailable && !setBrightnessProc.running && !brightnessDebounce.running)
          root.brightnessPercent = Model.clampPercent(parseInt(brightness, 10), 1)
      }
    }
  }

  function setBrightness(value) {
    var percent = Model.clampPercent(value, 1)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent
    if (!root.brightnessAvailable || !Model.isMonitorName(root.focusedMonitor)) return
    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }
    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampPercent(value, 1)
    brightnessDebounce.restart()
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Child {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) root.setBrightness(root.pendingBrightnessPercent)
    }
  }

  // ------------------------------------------------------------------ power

  property var profiles: []
  property string activeProfile: ""
  property var batteryInfo: ({})
  property bool suspendHidden: false

  readonly property var batteryDevice: UPower.displayDevice
  readonly property bool batteryPresent: !!(batteryDevice && batteryDevice.isPresent)
  readonly property bool onBattery: batteryPresent && UPower.onBattery === true
  readonly property real batteryFraction: batteryPresent ? Math.max(0, Math.min(1, batteryDevice.percentage)) : 0
  readonly property bool fullyCharged: batteryPresent && batteryDevice.state === UPowerDeviceState.FullyCharged
  readonly property bool charging: batteryPresent && !onBattery && !fullyCharged

  Child {
    id: profilesProbe
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseProfiles(text)
        root.profiles = parsed.profiles
        root.activeProfile = parsed.active
        if (root.pending.power !== undefined && root.pending.power === parsed.active) root.clearPending("power")
      }
    }
  }

  Child {
    id: batteryProbe
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseKeyValue(text)
        if (Object.keys(next).length > 0) root.batteryInfo = next
      }
    }
  }

  function setProfile(profile) {
    if (!Model.isProfile(profile) || profileProc.running) return
    root.beginPending("power", profile, "Could not set power profile")
    profileProc.command = ["omarchy-powerprofiles-set", root.onBattery ? "battery" : "ac", profile]
    profileProc.running = true
  }

  Child {
    id: profileProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.failPending("power", "Could not set power profile")
      if (!profilesProbe.running) profilesProbe.running = true
    }
  }

  Child {
    id: suspendProbe
    command: ["omarchy-toggle-enabled", "suspend-off"]
    onExited: function(exitCode) { root.suspendHidden = exitCode === 0 }
  }

  // -------------------------------------------------------------- recording

  property bool recording: false
  property string recordingPid: ""
  property int recordingElapsed: -1

  Child {
    id: recordingProbe
    command: ["pgrep", "-f", "^gpu-screen-recorder"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.recordingPid = Model.parsePid(text)
    }
    onExited: function(exitCode) {
      var live = exitCode === 0
      root.recording = live
      if (root.pending.recording !== undefined && root.pending.recording === live) root.clearPending("recording")
      if (live && root.recordingPid !== "" && !elapsedProbe.running) {
        elapsedProbe.command = ["ps", "-o", "etimes=", "-p", root.recordingPid]
        elapsedProbe.running = true
      } else if (!live) {
        root.recordingElapsed = -1
      }
    }
  }

  Child {
    id: elapsedProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.recordingElapsed = Model.parseElapsed(text)
    }
  }

  function toggleRecording() {
    if (root.recording) {
      if (stopRecordingProc.running) return
      root.beginPending("recording", false, "Could not stop the recording")
      stopRecordingProc.command = ["omarchy-capture-screenrecording", "--stop-recording"]
      stopRecordingProc.running = true
      return
    }
    // Starting goes through the stock capture menu so the user picks audio
    // and webcam options there; the card gets out of its way first.
    root.dismiss()
    root.runDetached(["omarchy-menu", "toggle", "trigger.capture.screenrecord"])
  }

  Child {
    id: stopRecordingProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.failPending("recording", "Could not stop the recording")
      if (!recordingProbe.running) recordingProbe.running = true
    }
  }

  // ---------------------------------------------------------- reconciliation

  // Optimistic state for the subprocess-backed toggles. The tile shows what
  // was asked for until the backing source agrees; if it has not agreed
  // within three seconds the tile reverts and says why, inline.
  property var pending: ({})
  property var pendingSince: ({})
  property var pendingMessages: ({})
  property var tileErrors: ({})

  // `patience` is how long to wait for the system to agree before giving up
  // on it. Most switches answer in well under a second; a theme change
  // rewrites every config on disk and tells the shell to reload, so it gets
  // an order of magnitude more room before the card calls it a failure.
  property var pendingPatience: ({})

  function beginPending(id, want, message, patience) {
    var next = ({}); for (var k in pending) next[k] = pending[k]; next[id] = want; pending = next
    var since = ({}); for (var s in pendingSince) since[s] = pendingSince[s]; since[id] = Date.now(); pendingSince = since
    var msgs = ({}); for (var m in pendingMessages) msgs[m] = pendingMessages[m]; msgs[id] = message; pendingMessages = msgs
    var wait = ({}); for (var w in pendingPatience) wait[w] = pendingPatience[w]
    wait[id] = Number(patience) > 0 ? Number(patience) : 3000
    pendingPatience = wait
    root.setTileError(id, "")
  }

  function clearPending(id) {
    if (pending[id] === undefined) return
    var next = ({}); for (var k in pending) if (k !== id) next[k] = pending[k]; pending = next
  }

  function failPending(id, message) {
    root.clearPending(id)
    root.setTileError(id, message)
  }

  function setTileError(id, message) {
    var next = ({}); for (var k in tileErrors) next[k] = tileErrors[k]
    if (message) next[id] = message; else delete next[id]
    tileErrors = next
    if (message) errorTimer.restart()
  }

  function reconcile() {
    var now = Date.now()
    for (var id in pending) {
      var patience = root.pendingPatience[id] || 3000
      if (now - (pendingSince[id] || now) > patience) root.failPending(id, pendingMessages[id] || "No response")
    }
  }

  Timer {
    id: reconcileTimer
    interval: 250
    repeat: true
    running: root.opened && Object.keys(root.pending).length > 0
    onTriggered: root.reconcile()
  }

  // While something is in flight, ask the system more often than the idle
  // five seconds, so an optimistic tile settles as soon as it is true rather
  // than at the next tick.
  Timer {
    interval: 700
    repeat: true
    running: root.opened && Object.keys(root.pending).length > 0
    onTriggered: {
      if (!stateProbe.running) stateProbe.running = true
      if (!recordingProbe.running) recordingProbe.running = true
    }
  }

  Timer {
    id: errorTimer
    interval: 4000
    repeat: false
    onTriggered: root.tileErrors = ({})
  }

  // ----------------------------------------------------------------- probes

  // Nothing runs while the card is closed: both timers are bound to `opened`.
  function refreshAll() {
    root.refreshFast()
    root.refreshSlow()
    if (!root.hardwareLoaded && !staticProbe.running) staticProbe.running = true
    if (!suspendProbe.running) suspendProbe.running = true
    if (!sinkAvailabilityProbe.running) sinkAvailabilityProbe.running = true
    root.resolveVolumeSink()
    if (nightlightService && typeof nightlightService.refresh === "function") nightlightService.refresh()
  }

  function refreshFast() {
    if (!recordingProbe.running) recordingProbe.running = true
  }

  function refreshSlow() {
    if (!stateProbe.running) stateProbe.running = true
    if (!monitorProbe.running) monitorProbe.running = true
    if (!profilesProbe.running) profilesProbe.running = true
    if (root.batteryPresent && !batteryProbe.running) batteryProbe.running = true
  }

  Timer { interval: 2000; repeat: true; running: root.opened; onTriggered: root.refreshFast() }
  Timer { interval: 5000; repeat: true; running: root.opened; onTriggered: root.refreshSlow() }

  Timer {
    id: statusTimer
    interval: 2600
    onTriggered: root.status = ""
  }

  // --------------------------------------------------------------- settings

  function refreshSettings() {
    if (!stateReader.running) stateReader.running = true
  }

  function loadSettings(raw) {
    var parsed = Model.parseSettings(raw)
    root.settingsRejected = parsed.rejected
    root.settings = parsed.settings
    root.settingsLoaded = true
    if (root.opened) root.hintVisible = root.settings.hintSeen !== true
    if (parsed.rejected && parsed.rejected !== "no settings saved yet") {
      console.warn("control-centre: settings ignored (" + parsed.rejected + "), using defaults")
      if (root.opened) root.flash("Settings file ignored (" + parsed.rejected + "), using defaults")
    }
  }

  function saveSettings(next) {
    root.settings = next
    if (stateWriter.running) {
      root.settingsWriteQueued = true
      return
    }
    root.settingsWriteQueued = false
    stateWriter.stdinEnabled = true
    stateWriter.running = true
  }

  property bool settingsWriteQueued: false

  Child {
    id: stateReader
    command: [root.pluginDir + "/state.py", "read", root.statePath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadSettings(text)
    }
  }

  Child {
    id: stateWriter
    command: [root.pluginDir + "/state.py", "write", root.statePath]
    stdinEnabled: false
    stdout: StdioCollector { waitForEnd: true }
    onStarted: {
      stateWriter.write(Model.serializeSettings(root.settings))
      stateWriter.stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.flash("Could not save settings")
      if (root.settingsWriteQueued) root.saveSettings(root.settings)
    }
  }

  // The hint has done its job the moment someone uses the card, whatever they
  // used it with, and it is done for good when that first visit ends. Hanging
  // it off the key handler alone left it on screen forever for anyone who
  // opens the card from the bar and clicks.
  function dismissHint() {
    if (root.settings.hintSeen !== true) root.saveSettings(Model.withOption(root.settings, "hintSeen", true))
    if (!root.hintVisible) return
    root.hintVisible = false
  }

  function setEditing(value) {
    root.dismissHint()
    root.editing = value === true
    root.cursor = 0
    root.resetSubCursor()
    pointerGate.reset()
  }

  // ------------------------------------------------------------------- grid

  readonly property var available: ({
    wifi: root.networkManagerAvailable && (root.wifiDevice !== null || root.wiredDevice !== null),
    bluetooth: root.adapter !== null,
    dnd: root.notificationService !== null,
    nightlight: root.nightlightService !== null,
    stayawake: root.idleService !== null,
    mic: root.source !== null,
    recording: true,
    screenshot: root.hasTool("omarchy-capture-screenshot"),
    colour: root.hasTool("hyprpicker"),
    text: root.hasTool("omarchy-capture-text"),
    qr: root.hasTool("omarchy-capture-qr"),
    emoji: root.pluginAvailable(root.pluginFor("emoji")),
    clipboard: root.pluginAvailable(root.pluginFor("clipboard")),
    reminder: root.hasTool("omarchy-reminder"),
    share: root.hasTool("omarchy-menu-share"),
    transcode: root.hasTool("omarchy-transcode"),
    netspeed: root.pluginAvailable("omarchy.speedtest"),
    diskspeed: root.pluginAvailable("omarchy.disk-speedtest"),
    bar: true,
    gaps: true,
    ratio: true,
    layout: root.flags["workspace.layout"] !== undefined && root.flags["workspace.layout"] !== "unknown",
    screensaver: true,
    crashcapture: true,
    touchpad: root.hasPart("touchpad"),
    touchscreen: root.hasPart("touchscreen"),
    laptopdisplay: root.hasPart("laptop"),
    mirror: root.hasPart("laptop") && root.internalMonitorName !== "",
    hybridgpu: root.hasPart("hybrid-gpu"),
    volume: root.sink !== null,
    miclevel: root.source !== null,
    brightness: root.brightnessAvailable,
    warmth: root.nightlightService !== null,
    theme: root.themes.length > 1,
    power: root.profiles.length > 0 || root.batteryPresent,
    media: root.hasMedia,
    actions: true,
    session: true
  })

  // What the card shows is decided once the probes have answered, and then
  // held until the card closes. Availability is a live thing: a song starting
  // adds a full-width row, a recording ending takes a tile away, and either
  // one moves everything below it while someone is reaching for it. The card
  // settles, then stands still.
  property var heldAvailable: root.available
  readonly property bool probesSettled: root.hardwareLoaded
    && Object.keys(root.flags).length > 0
    && root.monitorProbed

  property bool monitorProbed: false

  function holdAvailability() {
    root.heldAvailable = root.available
  }

  // Before the card is open, and while it is still settling just after, the
  // held copy tracks the live one.
  onAvailableChanged: if (!root.opened || !root.probesSettled) root.holdAvailability()
  onProbesSettledChanged: if (root.probesSettled) root.holdAvailability()

  readonly property var gridIds: Model.gridIds(root.settings, root.heldAvailable, root.editing)
  readonly property int cellWidth: Math.floor((root.contentWidth - root.gap * 3) / 4)
  readonly property int gap: Style.spacing.lg
  // Comfortable is the shape the card was designed at. Compact drops the
  // second line from the square tiles and tightens every row, so a full card
  // still fits a small laptop without the grid having to scroll.
  readonly property var tileHeights: ({
    toggle: Style.space(root.compact ? 54 : 74),
    action: Style.space(root.compact ? 54 : 74),
    slider: Style.space(root.compact ? 54 : 62),
    warmth: Style.space(root.compact ? 54 : 62),
    power: Style.space(root.compact ? 58 : 66),
    media: Style.space(root.compact ? 62 : 76),
    actions: Style.space(root.compact ? 40 : 46),
    session: Style.space(root.compact ? 40 : 46),
    // The chips wrap, so the row grows with however many themes exist. Edit
    // mode does not draw them, so there it collapses to a label.
    theme: root.editing ? Style.space(44)
      : Style.space(root.compact ? 40 : 46) + Math.ceil(Math.max(1, root.themes.length) / 4) * Style.space(26),
    option: Style.space(44),
    header: Style.space(22)
  })
  readonly property var grid: Model.layout(root.gridIds, root.cellWidth, root.gap, root.tileHeights)

  // `cursorId` is a binding over `cursor` and `gridIds`, so a handler that
  // runs on `cursor` changing can see the previous value: bindings are not
  // guaranteed to have re-evaluated by the time the change handler runs.
  // Anything reacting to a cursor move therefore reads `idAt()` instead, and
  // the binding is left for the declarative side.
  function idAt(index) {
    return index >= 0 && index < root.gridIds.length ? root.gridIds[index] : ""
  }

  readonly property string cursorId: idAt(cursor)
  readonly property string cursorKind: Model.kindOf(cursorId)

  // What the cursor is pointing at, by identity. The grid changes underneath
  // the card whenever a probe returns, so the index alone is not enough.
  property string pinnedId: ""

  onGridIdsChanged: {
    var next = Model.reindexCursor(root.gridIds, root.pinnedId, root.cursor)
    if (next !== root.cursor) root.cursor = next
    root.pinnedId = root.idAt(root.cursor)
  }

  function resetSubCursor() {
    var kind = Model.kindOf(root.idAt(root.cursor))
    if (kind === "power") {
      var index = root.profiles.indexOf(root.activeProfile)
      root.subCursor = index >= 0 ? index : 0
    } else if (kind === "media") {
      root.subCursor = 1
    } else if (kind === "theme") {
      var themeIndex = root.themes.indexOf(root.currentTheme)
      root.subCursor = themeIndex >= 0 ? themeIndex : 0
    } else {
      root.subCursor = 0
    }
  }

  onCursorChanged: {
    root.resetSubCursor()
    root.pinnedId = root.idAt(root.cursor)
    root.revealCursor()
  }

  // The grid lives in this same file, so it is addressed directly. Handing a
  // function reference around instead means holding one across a plugin
  // reload, and calling it after the object behind it has gone.
  function revealCursor() {
    if (scroller) scroller.revealCell(root.cursor)
  }

  // Whether the stock panel a chevron would open is actually live in the
  // bar. shell.summon only reaches a bar widget that is mounted, so a tile
  // whose panel the user removed hides its chevron instead of pointing at
  // nothing.
  function isAvailable(id) {
    return root.heldAvailable && root.heldAvailable[id] === true
  }

  function panelInBar(id) {
    if (!root.shell) return false
    var resolved = root.shell.pluginRegistry && typeof root.shell.pluginRegistry.resolveEnabledId === "function"
      ? root.shell.pluginRegistry.resolveEnabledId(id) : id
    var layout = root.shell.barConfig && root.shell.barConfig.layout ? root.shell.barConfig.layout : null
    if (!layout) return false
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        var entryId = typeof list[i] === "string" ? list[i] : (list[i] && list[i].id)
        if (entryId === resolved || entryId === id) return true
      }
    }
    return false
  }

  function panelFor(id) {
    if (id === "wifi") return "omarchy.network"
    if (id === "bluetooth") return "omarchy.bluetooth"
    if (id === "volume" || id === "mic") return "omarchy.audio"
    if (id === "brightness") return "omarchy.monitor"
    if (id === "power") return root.batteryPresent ? "omarchy.power" : ""
    return ""
  }

  function openPanel(id) {
    var panel = root.panelFor(id)
    if (!panel || !root.panelInBar(panel) || !root.shell) return false
    root.dismiss()
    var target = panel
    Qt.callLater(function() { root.shell.summon(target, "{}") })
    return true
  }

  // ---------------------------------------------------------------- actions

  // Anything that ends the session or the machine asks twice: the button
  // arms on the first press and says so, and only a second press within two
  // seconds goes through.
  readonly property var destructive: ["sleep", "hibernate", "logout", "reboot", "shutdown"]
  property string armedId: ""
  Timer { id: armTimer; interval: 2000; onTriggered: root.armedId = "" }

  function isDestructive(id) { return root.destructive.indexOf(String(id)) !== -1 }

  readonly property var actionRow: {
    var list = [{ id: "lock", glyph: "󰌾", label: "Lock", armed: false }]
    if (!root.suspendHidden) list.push({ id: "sleep", glyph: "󰒲", label: "Sleep", armed: root.armedId === "sleep" })
    list.push({ id: "screensaver", glyph: "󱄄", label: "Screensaver", armed: false })
    return list
  }

  readonly property var sessionRow: {
    var list = []
    if (root.hasPart("hibernate")) list.push({ id: "hibernate", glyph: "󰤁", label: "Hibernate", armed: root.armedId === "hibernate" })
    list.push({ id: "logout", glyph: "󰍃", label: "Log Out", armed: root.armedId === "logout" })
    list.push({ id: "reboot", glyph: "󰜉", label: "Restart", armed: root.armedId === "reboot" })
    list.push({ id: "shutdown", glyph: "󰐥", label: "Shut Down", armed: root.armedId === "shutdown" })
    return list
  }

  // Anything that photographs the screen has to wait for this card to be off
  // it. Closing is not instant: the fade runs, then the compositor unmaps the
  // surface, and a capture fired on the same tick catches the card sitting
  // over whatever the user wanted a picture of.
  readonly property var capturesScreen: ["screenshot", "colour", "text", "qr"]
  property var queuedCommand: null

  function runAction(id) {
    var argv = Model.actionCommand(id)
    if (!argv) return
    if (root.isDestructive(id) && root.armedId !== id) {
      root.armedId = id
      armTimer.restart()
      return
    }
    root.armedId = ""
    root.dismiss()
    if (root.capturesScreen.indexOf(String(id)) !== -1) {
      root.queuedCommand = argv
      queuedFallback.restart()
      return
    }
    root.runDetached(argv)
  }

  // Run whatever was waiting for the surface to go. Called both by the
  // window actually unmapping and by the fallback, whichever comes first,
  // and only ever runs the once.
  function flushQueuedCommand() {
    var argv = root.queuedCommand
    if (!argv) return
    root.queuedCommand = null
    queuedFallback.stop()
    root.runDetached(argv)
  }

  // A compositor that never reports the surface gone must not swallow the
  // action entirely.
  Timer {
    id: queuedFallback
    interval: 600
    repeat: false
    onTriggered: root.flushQueuedCommand()
  }

  // A one-shot tile. Anything the shell already hosts is summoned rather than
  // run, which costs no child process and does not depend on PATH.
  function runTile(id) {
    var plugin = root.pluginFor(id)
    if (plugin) {
      if (!root.pluginAvailable(plugin)) return
      root.dismiss()
      Qt.callLater(function() { root.shell.summon(plugin, "{}") })
      return
    }
    root.runAction(id)
  }

  function activateToggle(id) {
    if (id === "wifi") root.toggleWifi()
    else if (id === "bluetooth") root.toggleBluetooth()
    else if (id === "dnd" && root.notificationService) root.notificationService.setDoNotDisturb(!root.dnd)
    else if (id === "nightlight" && root.nightlightService) root.nightlightService.setNightlight(!root.nightlight)
    // Inverted on purpose: setIdleEnabled(true) allows idle, which is Stay Awake off.
    else if (id === "stayawake" && root.idleService) root.idleService.setIdleEnabled(root.stayAwake)
    else if (id === "mic") root.toggleInputMute()
    else if (id === "recording") root.toggleRecording()
    else if (root.flagTiles.indexOf(id) !== -1) root.toggleFlag(id)
  }

  function mediaAction(action) {
    if (!root.mediaService || typeof root.mediaService.runAction !== "function") return
    root.mediaService.runAction(action, false)
  }

  function sliderValue(id) {
    if (id === "volume") return root.outputVolume
    if (id === "miclevel") return root.inputVolume
    if (id === "warmth") return root.warmthValue
    if (id === "brightness") return root.brightnessPercent / 100
    return 0
  }

  function setInputVolume(v) {
    if (root.source && root.source.audio) root.source.audio.volume = Math.max(0, Math.min(1, v))
  }

  function nudgeSlider(id, steps) {
    if (id === "volume") root.setOutputVolume(Math.max(0, Math.min(1, root.outputVolume + steps * 0.05)))
    else if (id === "miclevel") root.setInputVolume(Math.max(0, Math.min(1, root.inputVolume + steps * 0.05)))
    else if (id === "warmth") { root.previewWarmth(Math.max(0, Math.min(1, root.warmthValue + steps * 0.05))); root.commitWarmth() }
    else if (id === "brightness") root.setBrightness(root.brightnessPercent + steps * 5)
  }

  // Enter, Space, or a click on the tile body.
  function activate(index) {
    root.dismissHint()
    if (index < 0 || index >= root.gridIds.length) return
    var id = root.gridIds[index]
    var kind = Model.kindOf(id)
    if (root.editing) {
      if (kind === "option") root.activateOption(id)
      else if (Model.tileEnabled(root.settings, id)) root.saveSettings(Model.withTileEnabled(root.settings, id, false))
      else root.saveSettings(Model.withTileShown(root.settings, id))
      return
    }
    if (kind === "toggle") root.activateToggle(id)
    else if (kind === "action") root.runTile(id)
    else if (kind === "session") { var e = root.sessionRow[Math.max(0, Math.min(root.sessionRow.length - 1, root.subCursor))]; if (e) root.runAction(e.id) }
    else if (kind === "theme") { if (root.subCursor >= 0 && root.subCursor < root.themes.length) root.setTheme(root.themes[root.subCursor]) }
    else if (kind === "slider" || kind === "warmth") {
      if (id === "volume") root.toggleOutputMute()
      else if (id === "miclevel") root.toggleInputMute()
      else if (id === "warmth" && root.nightlightService) root.nightlightService.setNightlight(!root.nightlight)
    }
    else if (kind === "power") { if (root.subCursor >= 0 && root.subCursor < root.profiles.length) root.setProfile(root.profiles[root.subCursor]) }
    else if (kind === "media") root.mediaAction(["previous", "playPause", "next"][Math.max(0, Math.min(2, root.subCursor))])
    else if (kind === "actions") { var a = root.actionRow[Math.max(0, Math.min(root.actionRow.length - 1, root.subCursor))]; if (a) root.runAction(a.id) }
  }

  function activateOption(id) {
    if (id === "opt-position") root.saveSettings(Model.withOption(root.settings, "position", Model.nextPosition(root.settings.position)))
    else if (id === "opt-density") root.saveSettings(Model.withOption(root.settings, "density", Model.nextDensity(root.settings.density)))
    else if (id === "opt-motion") root.saveSettings(Model.withOption(root.settings, "reduceMotion", !root.reduceMotion))
    else if (id === "opt-pill") root.saveSettings(Model.withOption(root.settings, "barWidget", root.settings.barWidget !== true))
  }

  function moveTile(id, delta) {
    if (Model.kindOf(id) === "option") return
    var next = Model.withTileMoved(root.settings, id, delta)
    root.saveSettings(next)
    var ids = Model.gridIds(next, root.available, true)
    var index = ids.indexOf(id)
    if (index >= 0) root.cursor = index
  }

  function subCount() {
    var kind = Model.kindOf(root.idAt(root.cursor))
    if (kind === "power") return root.profiles.length
    if (kind === "media") return 3
    if (kind === "actions") return root.actionRow.length
    if (kind === "session") return root.sessionRow.length
    if (kind === "theme") return root.themes.length
    return 0
  }

  // ---------------------------------------------------------------- keyboard

  function handleKey(event) {
    root.dismissHint()
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var key = event.key
    var text = event.text
    var kind = Model.kindOf(root.idAt(root.cursor))

    if (key === Qt.Key_Escape) {
      if (root.editing) root.setEditing(false)
      else root.dismiss()
      return
    }
    if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
      root.cursor = Model.moveSection(root.gridIds, root.cursor, (shift || key === Qt.Key_Backtab) ? -1 : 1)
      return
    }
    if (text === "," && !ctrl) { root.setEditing(!root.editing); return }
    if (root.editing && ctrl && (key === Qt.Key_Left || key === Qt.Key_Right || key === Qt.Key_Up || key === Qt.Key_Down || text === "h" || text === "l" || text === "j" || text === "k")) {
      var back = key === Qt.Key_Left || key === Qt.Key_Up || text === "h" || text === "k"
      root.moveTile(root.cursorId, back ? -1 : 1)
      return
    }
    if (!root.editing && !ctrl && text >= "1" && text <= "9") {
      var digit = Model.toggleIndexForDigit(root.gridIds, parseInt(text, 10))
      if (digit >= 0) { root.cursor = digit; root.activate(digit) }
      return
    }
    if (key === Qt.Key_Down || text === "j") { root.cursor = Model.moveCursor(root.grid.cells, root.cursor, 0, 1); return }
    if (key === Qt.Key_Up || text === "k") { root.cursor = Model.moveCursor(root.grid.cells, root.cursor, 0, -1); return }

    var right = key === Qt.Key_Right || text === "l" || key === Qt.Key_Plus || text === "+" || text === "="
    var left = key === Qt.Key_Left || text === "h" || key === Qt.Key_Minus || text === "-"
    if (right || left) {
      var direction = right ? 1 : -1
      if ((kind === "slider" || kind === "warmth") && !root.editing) root.nudgeSlider(root.idAt(root.cursor), direction * (shift ? 5 : 1))
      else if (root.subCount() > 0 && !root.editing) root.subCursor = Math.max(0, Math.min(root.subCount() - 1, root.subCursor + direction))
      else if (key === Qt.Key_Left || key === Qt.Key_Right || text === "h" || text === "l") root.cursor = Model.moveCursor(root.grid.cells, root.cursor, direction, 0)
      return
    }
    if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      if (shift && !root.editing) root.openPanel(root.cursorId)
      else root.activate(root.cursor)
      return
    }
    if (key === Qt.Key_Space) { root.activate(root.cursor); return }
    if ((text === "o" || text === "O") && !root.editing) { root.openPanel(root.cursorId); return }
  }

  // Support seams: the card's whole state machine over IPC, because keyboard
  // focus in a layer-shell surface cannot be synthesised from outside.
  //   omarchy-shell shell call <id> stateJson ""
  //   omarchy-shell shell call <id> moveBy "1,0"
  //   omarchy-shell shell call <id> pressKey enter
  function stateJson() {
    return JSON.stringify({
      opened: root.opened,
      editing: root.editing,
      cursor: root.cursor,
      cursorId: root.cursorId,
      pinnedId: root.pinnedId,
      subCursor: root.subCursor,
      gridIds: root.gridIds,
      available: root.available,
      held: root.heldAvailable,
      settled: root.probesSettled,
      settings: root.settings,
      settingsLoaded: root.settingsLoaded,
      settingsRejected: root.settingsRejected,
      hintVisible: root.hintVisible,
      screen: root.screenName,
      anchorCentre: root.anchorCentre,
      pending: root.pending,
      errors: root.tileErrors,
      state: {
        wifi: root.wifiEnabled, wifiDevice: root.wifiDevice !== null, wired: root.wiredConnected,
        bluetooth: root.bluetoothOn, dnd: root.dnd, nightlight: root.nightlight, stayAwake: root.stayAwake,
        micMuted: root.inputMuted, micInUse: root.micInUse, recording: root.recording, recordingElapsed: root.recordingElapsed,
        volume: root.outputVolume, muted: root.outputMuted, sink: root.nodeLabel(root.sink), volumeSink: root.volumeSinkName,
        brightness: root.brightnessPercent, brightnessAvailable: root.brightnessAvailable, monitor: root.focusedMonitor,
        flags: root.flags, hardware: root.hardware, themes: root.themes, theme: root.currentTheme,
        profiles: root.profiles, activeProfile: root.activeProfile, battery: root.batteryPresent, batteryFraction: root.batteryFraction,
        onBattery: root.onBattery, media: root.hasMedia, suspendHidden: root.suspendHidden
      }
    })
  }

  function moveBy(text) {
    var parts = String(text || "0,0").split(",")
    root.cursor = Model.moveCursor(root.grid.cells, root.cursor, parseInt(parts[0], 10) || 0, parseInt(parts[1], 10) || 0)
    return root.cursor
  }

  // Returns -1 rather than the unchanged cursor when the tile is not on the
  // grid, so a script driving the seam can tell "moved" from "that tile is
  // not showing right now".
  function setCursor(text) {
    var index = root.gridIds.indexOf(String(text))
    if (index < 0) return -1
    root.cursor = index
    return root.cursor
  }

  function pressKey(name) {
    var map = {
      enter: Qt.Key_Return, space: Qt.Key_Space, escape: Qt.Key_Escape, tab: Qt.Key_Tab,
      up: Qt.Key_Up, down: Qt.Key_Down, left: Qt.Key_Left, right: Qt.Key_Right
    }
    var raw = String(name || "")
    var shift = raw.indexOf("shift+") === 0
    var ctrl = raw.indexOf("ctrl+") === 0
    var base = raw.replace(/^(shift|ctrl)\+/, "")
    var modifiers = (shift ? Qt.ShiftModifier : 0) | (ctrl ? Qt.ControlModifier : 0)
    root.handleKey({ key: map[base] !== undefined ? map[base] : 0, text: map[base] !== undefined ? "" : base, modifiers: modifiers })
    return root.cursor
  }

  // Performs the drop half of a drag, which is the half that changes
  // anything. Keyboard focus and pointer drags inside a layer-shell surface
  // cannot be synthesised from outside, so this is how the gesture is tested.
  //   omarchy-shell shell call <id> dropTile "volume,wifi"
  // Stages a drag at a point in the grid without finishing it, so the drop
  // line can be looked at. A pointer drag inside a layer-shell surface cannot
  // be synthesised from outside any more than keyboard focus can.
  //   omarchy-shell shell call <id> previewDrop "volume,120,30"
  function previewDrop(text) {
    var parts = String(text || "").split(",")
    if (parts.length !== 3) return "usage: previewDrop <draggedId>,<x>,<y>"
    root.draggingId = parts[0].trim()
    var x = Number(parts[1])
    var y = Number(parts[2])
    root.dragStartX = x
    root.dragStartY = y
    root.dragPointX = x
    root.dragPointY = y
    root.dragDX = 0
    root.dragDY = 0
    root.dropPlan = null
    root.applyPlan(Model.dropPlan(root.grid.cells, x, y, root.draggingId, root.gap, root.contentWidth))
    return JSON.stringify(root.dropPlan)
  }

  function cancelDrag() {
    root.draggingId = ""
    root.dropPlan = null
    root.dragDX = 0
    root.dragDY = 0
    return "ok"
  }

  //   omarchy-shell shell call <id> dropTile "volume,wifi"        before wifi
  //   omarchy-shell shell call <id> dropTile "volume,wifi,after"    after it
  function dropTile(text) {
    var parts = String(text || "").split(",")
    if (parts.length < 2) return "usage: dropTile <movedId>,<anchorId>[,after]"
    root.draggingId = parts[0].trim()
    root.dropPlan = { anchorId: parts[1].trim(), after: (parts[2] || "").trim() === "after" }
    root.endDrag()
    return Model.gridIds(root.settings, root.available, root.editing).join(" ")
  }

  function setEditMode(text) {
    root.setEditing(String(text) === "true")
    return root.editing
  }

  // ------------------------------------------------------------------- theme

  readonly property color foreground: Color.popups.text
  readonly property color background: Color.popups.background
  readonly property color accent: Color.accent
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
  readonly property string fontFamily: Style.font.family
  readonly property int padding: Style.spacing.popupPadding
  readonly property int contentWidth: Math.min(Style.space(468), Math.max(Style.space(240), panel.width - Style.gapsOut * 2 - root.padding * 2 - Border.left(root.borderSpec) - Border.right(root.borderSpec)))
  readonly property int headerHeight: Style.space(26)

  readonly property var bar: shell ? shell.bar : null
  readonly property string barPosition: {
    if (bar && bar.position) return String(bar.position)
    if (shell && shell.barConfig && shell.barConfig.position) return String(shell.barConfig.position)
    return "top"
  }
  readonly property bool barHidden: bar ? bar.barHidden === true : false
  readonly property int barSize: bar && bar.barSize ? bar.barSize : Style.bar.sizeHorizontal
  readonly property int barInset: barHidden ? 0 : barSize + Style.gapsOut

  // What a control looks like in the catalogue when it is not on the card.
  // Most glyphs come from the table; the ones that vary with live state are
  // shown at rest, because a hidden control has no state worth reporting.
  function catalogueGlyph(id) {
    if (id === "wifi") return "󰤨"
    if (id === "bluetooth") return "󰂯"
    if (id === "dnd") return "󰂛"
    if (id === "nightlight") return "󰔎"
    if (id === "stayawake") return "󰅶"
    if (id === "mic") return "󰍬"
    if (id === "recording") return "󰻂"
    if (id === "volume") return "󰕾"
    if (id === "brightness") return "󰃠"
    if (id === "power") return "󰂄"
    if (id === "media") return "󰝚"
    if (id === "actions") return "󰌾"
    if (id === "session") return "󰐥"
    return Model.glyphOf(id)
  }

  function tileInfo(id) {
    var editing = root.editing
    var info = { glyph: "", label: Model.labelOf(id), subtitle: "", active: false, busy: false, urgent: false,
                 chevron: false, chevronTooltip: "", tooltip: "", error: root.tileErrors[id] || "" }
    var panel = root.panelFor(id)
    var panelLive = panel !== "" && root.panelInBar(panel)
    if (panel !== "") {
      info.chevron = panelLive
      info.chevronTooltip = panelLive ? "Open the " + Model.labelOf(id) + " panel" : ""
    }
    if (id === "wifi") {
      if (root.wifiDevice === null) {
        info.label = "Network"
        info.glyph = root.wiredConnected ? "󰈀" : "󰤮"
        info.subtitle = root.wiredConnected ? "Ethernet" : "Disconnected"
        info.active = root.wiredConnected
        info.tooltip = panelLive ? "No Wi-Fi radio here. The chevron opens the Network panel" : "No Wi-Fi radio here"
      } else {
        info.active = root.wifiEnabled
        info.glyph = !root.wifiEnabled ? "󰤮" : (root.connectedWifiNetwork ? Model.wifiGlyph(root.wifiSignal) : "󰤯")
        info.subtitle = !root.wifiEnabled ? "Off"
          : (root.connectedWifiNetwork ? String(root.connectedWifiNetwork.name || "") : (root.wiredConnected ? "Ethernet" : "Not connected"))
        info.tooltip = root.wifiEnabled ? "Turn Wi-Fi off" : "Turn Wi-Fi on"
      }
    } else if (id === "bluetooth") {
      var btOn = root.pending.bluetooth !== undefined ? root.pending.bluetooth : root.bluetoothOn
      info.active = btOn
      info.busy = bluetoothProc.running || root.pending.bluetooth !== undefined
      info.glyph = !btOn ? "󰂲" : (root.connectedDeviceNames.length > 0 ? "󰂱" : "󰂯")
      info.subtitle = !btOn ? "Off" : (root.connectedDeviceNames.length > 0 ? Model.joinNames(root.connectedDeviceNames, 2) : "On")
      info.tooltip = btOn ? "Turn Bluetooth off" : "Turn Bluetooth on"
    } else if (id === "dnd") {
      info.active = root.dnd
      info.glyph = "󰂛"
      info.subtitle = root.dnd ? "On" : "Off"
      info.tooltip = root.dnd ? "Allow notifications" : "Silence notifications"
    } else if (id === "nightlight") {
      info.active = root.nightlight
      info.glyph = "󰔎"
      info.subtitle = root.nightlight ? "On" : "Off"
      var svc = root.nightlightService
      info.tooltip = svc ? (svc.nightTemperature || 4000) + "K at night, " + (svc.dayTemperature || 6500) + "K by day" : ""
    } else if (id === "stayawake") {
      info.active = root.stayAwake
      info.glyph = "󰅶"
      info.subtitle = root.stayAwake ? "On" : "Off"
      info.tooltip = root.stayAwake ? "Allow idle lock and screensaver" : "Keep the screen awake"
    } else if (id === "mic") {
      info.active = !root.inputMuted
      info.urgent = root.micInUse
      info.glyph = root.inputMuted ? "󰍭" : "󰍬"
      info.subtitle = root.inputMuted ? "Muted" : (root.micInUse ? "In use" : "Live")
      info.tooltip = root.inputMuted ? "Unmute the microphone" : "Mute the microphone"
    } else if (id === "recording") {
      var rec = root.pending.recording !== undefined ? root.pending.recording : root.recording
      info.active = rec
      info.urgent = rec
      info.busy = stopRecordingProc.running
      info.glyph = "󰻂"
      info.subtitle = rec ? (root.recordingElapsed >= 0 ? Model.formatElapsed(root.recordingElapsed) : "Recording") : "Off"
      info.tooltip = rec ? "Stop recording" : "Start a screen recording"
    }
    else if (root.flagTiles.indexOf(id) !== -1) {
      var state = root.pending[id] !== undefined ? root.pending[id] : root.flagState(id)
      info.active = state
      info.busy = root.pending[id] !== undefined
      info.glyph = Model.glyphOf(id)
      if (id === "layout") info.subtitle = state ? "Scrolling" : "Dwindle"
      else if (id === "laptopdisplay") info.subtitle = state ? "On" : "Off"
      else info.subtitle = state ? "On" : "Off"
      info.tooltip = root.flagTooltip(id, state)
    } else if (Model.kindOf(id) === "action") {
      info.glyph = Model.glyphOf(id)
      info.subtitle = ""
      info.tooltip = root.actionTooltip(id)
    }
    // The chevron is discoverable; the two shortcuts that do the same thing
    // are not, so the tile's own tooltip carries them.
    if (info.chevron && info.tooltip !== "") info.tooltip += "  ·  Right-click opens the full panel"
    if (editing) info.tooltip = Model.tileEnabled(root.settings, id) ? "Enter hides this control" : "Enter shows this control"
    return info
  }

  function flagTooltip(id, state) {
    if (id === "bar") return state ? "Hide the menu bar" : "Show the menu bar"
    if (id === "gaps") return state ? "Remove the gaps between windows" : "Put the gaps back"
    if (id === "ratio") return state ? "Stop squaring a lone window" : "Square a lone window"
    if (id === "layout") return state ? "Switch this workspace back to dwindle" : "Switch this workspace to scrolling"
    if (id === "screensaver") return state ? "Stop the screensaver running on idle" : "Let the screensaver run on idle"
    if (id === "crashcapture") return state ? "Stop capturing crashes" : "Capture crashes"
    if (id === "touchpad") return state ? "Disable the touchpad" : "Enable the touchpad"
    if (id === "touchscreen") return state ? "Disable the touchscreen" : "Enable the touchscreen"
    if (id === "laptopdisplay") return state ? "Turn the laptop screen off" : "Turn the laptop screen on"
    if (id === "mirror") return state ? "Stop mirroring the laptop screen" : "Mirror the laptop screen"
    return ""
  }

  function actionTooltip(id) {
    if (id === "screenshot") return "Pick a region to capture"
    if (id === "colour") return "Pick a colour from the screen"
    if (id === "text") return "Grab text out of the screen"
    if (id === "qr") return "Read a QR code off the screen"
    if (id === "emoji") return "Emoji picker"
    if (id === "clipboard") return "Clipboard history"
    if (id === "reminder") return "Set a reminder"
    if (id === "share") return "Send a file to another machine"
    if (id === "transcode") return "Transcode a video"
    if (id === "netspeed") return "Run a network speed test"
    if (id === "diskspeed") return "Run a disk speed test"
    if (id === "hybridgpu") return "Switch the hybrid GPU mode, in a terminal"
    return ""
  }

  // ------------------------------------------------------------------ drag

  // Edit mode drags a tile to where it should go. The drag is tracked here
  // rather than by moving the item, because the tiles are laid out by the
  // grid: letting one wander would fight its own geometry binding. The tile
  // is drawn offset instead, and only the settings change on drop.
  property string draggingId: ""
  // Where the drop would land: an anchor tile and which side of it, plus the
  // line to draw for it. Null while the pointer is over nothing that can take
  // a drop, in which case the last real plan stands.
  property var dropPlan: null
  property real dragDX: 0
  property real dragDY: 0

  property real dragStartX: 0
  property real dragStartY: 0
  property real dragPointX: 0
  property real dragPointY: 0

  function beginDrag(id, item, pressX, pressY, gridItem) {
    if (!root.editing || Model.kindOf(id) === "option" || Model.isHeader(id)) return
    // Captured before anything has moved, so it is the true grip point.
    var start = item.mapToItem(gridItem, pressX, pressY)
    root.dragStartX = start.x
    root.dragStartY = start.y
    root.draggingId = id
    root.dropPlan = null
    root.dragDX = 0
    root.dragDY = 0
  }

  function updateDrag(item, mouse, gridItem) {
    if (root.draggingId === "") return
    // Where the pointer actually is, in the grid's frame. Mapping up through
    // the dragged tile undoes its own transform on the way, so this stays
    // true however far the tile has been carried, and the offset cannot feed
    // back into the measurement that produced it.
    var point = item.mapToItem(gridItem, mouse.x, mouse.y)
    root.dragDX = point.x - root.dragStartX
    root.dragDY = point.y - root.dragStartY
    root.dragPointX = point.x
    root.dragPointY = point.y

    root.applyPlan(Model.dropPlan(root.grid.cells, point.x, point.y,
                                  root.draggingId, root.gap, root.contentWidth))
  }

  // Over its own slot means "put it back", so the plan clears. Over a heading
  // or a gap means nothing in particular, so the last real plan stands rather
  // than flickering off each time the pointer crosses a few pixels of
  // background.
  function applyPlan(plan) {
    if (plan === null) return
    root.dropPlan = plan.self === true ? null : plan
  }

  // Auto-scroll while dragging near the top or bottom of the visible grid,
  // because the grid stops flicking during a drag and a long catalogue does
  // not fit on one screen. The pointer does not move while this runs, but its
  // position within the content does, so the drag is re-measured each step.
  function dragScrollStep() {
    if (root.draggingId === "" || !scroller) return
    scroller.dragScroll(root.dragPointY)
  }

  function shiftDragBy(delta) {
    if (delta === 0) return
    root.dragPointY += delta
    root.dragDY = root.dragPointY - root.dragStartY
    root.applyPlan(Model.dropPlan(root.grid.cells, root.dragPointX, root.dragPointY,
                                  root.draggingId, root.gap, root.contentWidth))
  }

  Timer {
    interval: 16
    repeat: true
    running: root.draggingId !== ""
    onTriggered: root.dragScrollStep()
  }

  function endDrag() {
    var moved = root.draggingId
    var plan = root.dropPlan
    root.draggingId = ""
    root.dropPlan = null
    root.dragDX = 0
    root.dragDY = 0
    if (!moved || !plan || !plan.anchorId) return
    root.saveSettings(Model.withTileMovedNextTo(root.settings, moved, plan.anchorId, plan.after === true))
    var ids = Model.gridIds(root.settings, root.available, root.editing)
    var index = ids.indexOf(moved)
    if (index >= 0) root.cursor = index
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  function hoverTile(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    if (root.cursor !== index) root.cursor = index
  }

  // ---------------------------------------------------------------- surface

  PanelWindow {
    id: panel
    screen: root.targetScreen
    visible: root.opened || card.opacity > 0
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-control-centre"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // The moment the compositor has actually taken the surface down is the
    // moment a screen capture is safe to start.
    onBackingWindowVisibleChanged: if (!backingWindowVisible) root.flushQueuedCommand()

    // Clicking away from the card while arranging it means "done arranging",
    // not "throw the card away". Escape already reads that way round.
    MouseArea {
      anchors.fill: parent
      enabled: root.opened
      acceptedButtons: Qt.AllButtons
      onPressed: {
        if (root.editing) root.setEditing(false)
        else root.dismiss()
      }
    }

    readonly property int cardWidth: root.contentWidth + root.padding * 2 + Border.left(root.borderSpec) + Border.right(root.borderSpec)
    readonly property int chromeHeight: chrome.implicitHeight + Style.spacing.lg
      + (statusText.visible ? statusText.implicitHeight + Style.spacing.md : 0)
    readonly property int cardInsets: root.padding * 2 + Border.top(root.borderSpec) + Border.bottom(root.borderSpec)
    // As tall as the content wants, until the screen says otherwise. Past
    // that the grid scrolls rather than being cut off.
    readonly property int cardHeight: Math.min(
      panel.height - Style.gapsOut * 2 - (root.barHidden ? 0 : root.barSize),
      panel.chromeHeight + root.grid.height + panel.cardInsets)
    readonly property bool centred: root.settings.position === "centre"
    // Opened from the pill, the card centres on that icon and is clamped to
    // the screen, which is what every stock bar panel does. Opened by key it
    // follows the position setting, and an explicit "centre" always wins:
    // someone who asked for the middle of the screen means it.
    readonly property bool anchored: root.anchorCentre >= 0 && !centred
    function clampAlong(value, size, extent) {
      return Math.round(Math.max(Style.gapsOut, Math.min(value, extent - size - Style.gapsOut)))
    }
    readonly property int restX: {
      if (centred) return Math.round((panel.width - cardWidth) / 2)
      if (root.barPosition === "right") return panel.width - cardWidth - root.barInset
      if (root.barPosition === "left") return root.barInset
      if (anchored) return clampAlong(root.anchorCentre - cardWidth / 2, cardWidth, panel.width)
      return panel.width - cardWidth - Style.gapsOut
    }
    readonly property int restY: {
      if (centred) return Math.round((panel.height - cardHeight) / 2)
      if (root.barPosition === "bottom") return panel.height - cardHeight - root.barInset
      if (root.barPosition === "top") return root.barInset
      if (anchored) return clampAlong(root.anchorCentre - cardHeight / 2, cardHeight, panel.height)
      return Style.gapsOut
    }
    // The card enters from the bar it belongs to: down from a top bar, up from
    // a bottom one, inward from a side one.
    readonly property int slide: Style.space(8)
    readonly property int slideX: root.barPosition === "left" ? -slide : (root.barPosition === "right" ? slide : 0)
    readonly property int slideY: root.barPosition === "bottom" ? slide : (root.barPosition === "top" ? -slide : 0)

    BorderSurface {
      id: card
      // The resting position is assigned, never animated. It is derived from
      // the card's own width and height, and both settle a frame or two after
      // the surface maps and again whenever a probe adds a tile; animating
      // that turned a card pinned to the right edge into one that slid in
      // sideways as it grew. The entrance is a transform instead, which is
      // the only movement anyone should see.
      x: panel.restX
      y: panel.restY
      width: panel.cardWidth
      height: panel.cardHeight
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.padding
      opacity: root.opened ? 1 : 0

      // 1 while closed, 0 once open: the offset the card enters from.
      property real slideProgress: root.opened ? 0 : 1

      Behavior on opacity {
        enabled: !root.reduceMotion
        NumberAnimation { duration: root.opened ? 120 : 80; easing.type: Easing.OutCubic }
      }
      Behavior on slideProgress {
        enabled: !root.reduceMotion
        NumberAnimation { duration: root.opened ? 120 : 80; easing.type: Easing.OutCubic }
      }

      transform: Translate {
        x: panel.slideX * card.slideProgress
        y: panel.slideY * card.slideProgress
      }

      MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onPressed: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          root.handleKey(event)
          event.accepted = true
        }

        // The card is a fixed head and foot with a scrolling middle: a
        // catalogue this long will not fit a laptop screen, and a grid that
        // silently clipped its last rows would be worse than one that scrolls.
        Item {
          id: content
          anchors.fill: parent


          Column {
            id: chrome
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.spacing.lg

            // ---------- header ----------
            Item {
              width: parent.width
              height: root.headerHeight

              Text {
                id: titleText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.editing ? "Edit tiles" : "Control Centre"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              // The title is what must not move, so the hint takes whatever
              // room is left between it and the gear, and gives up characters
              // rather than pushing anything aside.
              Text {
                anchors.left: titleText.right
                anchors.leftMargin: Style.spacing.xl
                anchors.right: gear.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                visible: root.editing
                text: "Enter shows or hides · drag to reorder"
                color: Qt.darker(root.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
              }

              PanelActionButton {
                id: gear
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.editing ? "󰄬" : "󰒓"
                tooltipText: root.editing ? "Done" : "Edit tiles and settings"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.setEditing(!root.editing)
              }
            }

            // ---------- first-run hint ----------
            Text {
              width: parent.width
              visible: root.hintVisible && !root.editing
              text: Model.hintText()
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Flickable {
            id: scroller
            anchors.top: chrome.bottom
            anchors.topMargin: Style.spacing.lg
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: statusText.visible ? statusText.top : parent.bottom
            anchors.bottomMargin: statusText.visible ? Style.spacing.md : 0
            contentWidth: width
            contentHeight: root.grid.height
            clip: true
            interactive: contentHeight > height && root.draggingId === ""
            boundsBehavior: Flickable.StopAtBounds
            flickDeceleration: 6000

            // Keeps the cursor on screen when the keyboard walks off the
            // visible part of a long catalogue.
            // One step of the drag auto-scroll. Returns nothing; it tells the
            // card how far it actually moved so the drag can be re-measured
            // against content that has shifted underneath a still pointer.
            readonly property int dragMargin: Style.space(36)
            readonly property int dragStep: Style.space(8)
            function dragScroll(pointY) {
              if (contentHeight <= height) return
              var top = contentY
              var bottom = contentY + height
              var delta = 0
              if (pointY < top + dragMargin) delta = -dragStep
              else if (pointY > bottom - dragMargin) delta = dragStep
              if (delta === 0) return
              var next = Math.max(0, Math.min(contentHeight - height, contentY + delta))
              delta = next - contentY
              if (delta === 0) return
              contentY = next
              root.shiftDragBy(delta)
            }
            // Deferred, because the height changes while the layout is still
            // settling. By the time it runs the surface may have been torn
            // down under a plugin reload, so it checks it is still there.
            onHeightChanged: Qt.callLater(function() {
              if (scroller && typeof scroller.revealCell === "function") scroller.revealCell(root.cursor)
            })

            function revealCell(index) {
              var cells = root.grid.cells
              if (index < 0 || index >= cells.length) return
              var cell = cells[index]
              if (cell.y < contentY) contentY = cell.y
              else if (cell.y + cell.height > contentY + height)
                contentY = Math.min(Math.max(0, contentHeight - height), cell.y + cell.height - height)
            }

            Item {
              id: gridItem
              width: scroller.width
              height: root.grid.height

            Repeater {
              model: root.gridIds

              delegate: Loader {
                id: cell
                required property int index
                required property string modelData
                readonly property var geometry: index < root.grid.cells.length ? root.grid.cells[index] : null
                readonly property string kind: Model.kindOf(modelData)
                readonly property bool hasCursor: root.cursor === index
                readonly property bool enabledInSettings: Model.tileEnabled(root.settings, modelData)
                readonly property bool beingDragged: root.draggingId === modelData
                x: geometry ? geometry.x : 0
                y: geometry ? geometry.y : 0
                width: geometry ? geometry.width : 0
                height: geometry ? geometry.height : 0
                // The dragged tile is drawn away from its slot rather than
                // moved into a new one: the slot is where it still lives
                // until the drop says otherwise.
                z: beingDragged ? 10 : 0
                opacity: beingDragged ? 0.85 : 1
                transform: Translate {
                  x: cell.beingDragged ? root.dragDX : 0
                  y: cell.beingDragged ? root.dragDY : 0
                }

                sourceComponent: root.editing && !enabledInSettings && kind !== "option" && kind !== "header" ? catalogueComp
                  : kind === "toggle" || kind === "action" ? toggleComp
                  : kind === "slider" || kind === "warmth" ? sliderComp
                  : kind === "power" ? powerComp
                  : kind === "media" ? mediaComp
                  : kind === "actions" || kind === "session" ? actionsComp
                  : kind === "theme" ? themeComp
                  : kind === "header" ? headerComp
                  : optionComp

                Component {
                  id: toggleComp
                  ToggleTile {
                    readonly property var info: root.tileInfo(cell.modelData)
                    anchors.fill: parent
                    glyph: info.glyph
                    label: info.label
                    subtitle: info.subtitle
                    tooltip: info.tooltip
                    active: info.active
                    busy: info.busy
                    urgent: info.urgent
                    chevron: info.chevron
                    chevronTooltip: info.chevronTooltip
                    error: info.error
                    hasCursor: cell.hasCursor
                    editing: root.editing
                    enabledInSettings: cell.enabledInSettings
                    compact: root.compact
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: { root.cursor = cell.index; root.activate(cell.index) }
                    onRightClicked: { root.cursor = cell.index; if (!root.editing) root.openPanel(cell.modelData) }
                    onChevronClicked: root.openPanel(cell.modelData)
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                    draggable: root.editing
                    onDragStarted: function(item, pressX, pressY) { root.beginDrag(cell.modelData, item, pressX, pressY, gridItem) }
                    onDragMoved: function(item, mouse) { root.updateDrag(item, mouse, gridItem) }
                    onDragEnded: root.endDrag()
                  }
                }

                Component {
                  id: sliderComp
                  SliderTile {
                    readonly property string sliderId: cell.modelData
                    readonly property bool isVolume: sliderId === "volume"
                    readonly property bool isMic: sliderId === "miclevel"
                    readonly property bool isWarmth: sliderId === "warmth"
                    anchors.fill: parent
                    label: Model.labelOf(sliderId)
                    glyph: isVolume ? Model.volumeGlyph(root.outputVolume, root.outputMuted, root.isHeadphones(root.sink))
                      : isMic ? (root.inputMuted ? "󰍭" : "󰍬")
                      : isWarmth ? "󰔎" : "󰃠"
                    glyphTooltip: isVolume ? (root.outputMuted ? "Unmute" : "Mute")
                      : isMic ? (root.inputMuted ? "Unmute the microphone" : "Mute the microphone")
                      : isWarmth ? (root.nightlight ? "Back to daylight" : "Warm the screen") : ""
                    value: root.sliderValue(sliderId)
                    valueText: isWarmth ? root.warmthShown + "K"
                      : Math.round((dragging ? liveValue : value) * 100) + "%"
                    minimum: isVolume || isMic ? 0 : (isWarmth ? 0 : 0.01)
                    step: 0.05
                    muted: isVolume ? root.outputMuted : (isMic ? root.inputMuted : false)
                    chip: isVolume ? root.nodeLabel(root.sink)
                      : (sliderId === "brightness" && root.focusedMonitor !== "" && Quickshell.screens.length > 1 ? root.focusedMonitor : "")
                    chipTooltip: isVolume ? (root.candidateSinks.length > 1 ? "Switch to the next output" : "The only output") : "Brightness of the focused display"
                    chevron: root.tileInfo(cell.modelData).chevron
                    chevronTooltip: root.tileInfo(cell.modelData).chevronTooltip
                    tooltip: root.editing ? (cell.enabledInSettings ? "Enter hides this tile" : "Enter shows this tile") : ""
                    hasCursor: cell.hasCursor
                    editing: root.editing
                    enabledInSettings: cell.enabledInSettings
                    compact: root.compact
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onGlyphClicked: {
                      root.cursor = cell.index
                      if (isVolume) root.toggleOutputMute()
                      else if (isMic) root.toggleInputMute()
                      else if (isWarmth && root.nightlightService) root.nightlightService.setNightlight(!root.nightlight)
                    }
                    onChipClicked: { root.cursor = cell.index; if (isVolume) root.cycleSink() }
                    onChevronClicked: root.openPanel(cell.modelData)
                    onClicked: { root.cursor = cell.index; if (root.editing) root.activate(cell.index) }
                    onMoved: function(v) {
                      root.cursor = cell.index
                      if (isVolume) root.setOutputVolume(v)
                      else if (isMic) root.setInputVolume(v)
                      else if (isWarmth) root.previewWarmth(v)
                      else root.previewBrightness(v * 100)
                    }
                    onReleased: function(v) {
                      if (isVolume) root.setOutputVolume(v)
                      else if (isMic) root.setInputVolume(v)
                      else if (isWarmth) { root.previewWarmth(v); root.commitWarmth() }
                      else root.setBrightness(v * 100)
                    }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                    draggable: root.editing
                    onDragStarted: function(item, pressX, pressY) { root.beginDrag(cell.modelData, item, pressX, pressY, gridItem) }
                    onDragMoved: function(item, mouse) { root.updateDrag(item, mouse, gridItem) }
                    onDragEnded: root.endDrag()
                  }
                }

                Component {
                  id: powerComp
                  PowerTile {
                    anchors.fill: parent
                    batteryPresent: root.batteryPresent
                    batteryGlyph: Model.batteryGlyph(root.batteryFraction, root.onBattery, root.fullyCharged)
                    batteryText: Model.batteryLine(root.batteryPresent, root.batteryFraction, root.onBattery, root.batteryInfo, root.fullyCharged)
                    charging: root.charging
                    profiles: root.profiles
                    activeProfile: root.activeProfile
                    pendingProfile: root.pending.power !== undefined ? String(root.pending.power) : ""
                    busy: profileProc.running || root.pending.power !== undefined
                    error: root.tileErrors.power || ""
                    subCursor: cell.hasCursor && !root.editing ? root.subCursor : -1
                    chevron: root.tileInfo("power").chevron
                    chevronTooltip: root.tileInfo("power").chevronTooltip
                    tooltip: root.editing ? (cell.enabledInSettings ? "Enter hides this tile" : "Enter shows this tile") : ""
                    hasCursor: cell.hasCursor
                    editing: root.editing
                    enabledInSettings: cell.enabledInSettings
                    compact: root.compact
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onProfileClicked: function(profile) { root.cursor = cell.index; root.setProfile(profile) }
                    onProfileHovered: function(index) { root.cursor = cell.index; root.subCursor = index }
                    onChevronClicked: root.openPanel("power")
                    onClicked: { root.cursor = cell.index; if (root.editing) root.activate(cell.index) }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                    draggable: root.editing
                    onDragStarted: function(item, pressX, pressY) { root.beginDrag(cell.modelData, item, pressX, pressY, gridItem) }
                    onDragMoved: function(item, mouse) { root.updateDrag(item, mouse, gridItem) }
                    onDragEnded: root.endDrag()
                  }
                }

                Component {
                  id: mediaComp
                  MediaTile {
                    anchors.fill: parent
                    title: root.mediaService ? String(root.mediaService.title || "") : ""
                    artist: root.mediaService ? String(root.mediaService.artist || "") : ""
                    artUrl: root.mediaService ? String(root.mediaService.artUrl || "") : ""
                    playing: root.mediaPlayer ? root.mediaPlayer.isPlaying === true : false
                    canGoPrevious: root.mediaPlayer ? root.mediaPlayer.canGoPrevious === true : false
                    canGoNext: root.mediaPlayer ? root.mediaPlayer.canGoNext === true : false
                    subCursor: cell.hasCursor && !root.editing ? root.subCursor : -1
                    tooltip: root.editing ? (cell.enabledInSettings ? "Enter hides this tile" : "Enter shows this tile") : ""
                    hasCursor: cell.hasCursor
                    editing: root.editing
                    enabledInSettings: cell.enabledInSettings
                    compact: root.compact
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onTransport: function(action) { root.cursor = cell.index; root.mediaAction(action) }
                    onControlHovered: function(index) { root.cursor = cell.index; root.subCursor = index }
                    onClicked: { root.cursor = cell.index; if (root.editing) root.activate(cell.index) }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                    draggable: root.editing
                    onDragStarted: function(item, pressX, pressY) { root.beginDrag(cell.modelData, item, pressX, pressY, gridItem) }
                    onDragMoved: function(item, mouse) { root.updateDrag(item, mouse, gridItem) }
                    onDragEnded: root.endDrag()
                  }
                }

                Component {
                  id: actionsComp
                  ActionsTile {
                    anchors.fill: parent
                    actions: cell.modelData === "session" ? root.sessionRow : root.actionRow
                    subCursor: cell.hasCursor && !root.editing ? root.subCursor : -1
                    tooltip: root.editing ? (cell.enabledInSettings ? "Enter hides this tile" : "Enter shows this tile") : ""
                    hasCursor: cell.hasCursor
                    editing: root.editing
                    enabledInSettings: cell.enabledInSettings
                    compact: root.compact
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onActivated: function(id) { root.cursor = cell.index; root.runAction(id) }
                    onActionHovered: function(index) { root.cursor = cell.index; root.subCursor = index }
                    onClicked: { root.cursor = cell.index; if (root.editing) root.activate(cell.index) }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                    draggable: root.editing
                    onDragStarted: function(item, pressX, pressY) { root.beginDrag(cell.modelData, item, pressX, pressY, gridItem) }
                    onDragMoved: function(item, mouse) { root.updateDrag(item, mouse, gridItem) }
                    onDragEnded: root.endDrag()
                  }
                }

                Component {
                  id: themeComp
                  ThemeTile {
                    anchors.fill: parent
                    themes: root.themes
                    current: root.currentTheme
                    pendingTheme: root.pending.theme !== undefined ? String(root.pending.theme) : ""
                    busy: themeProc.running || root.pending.theme !== undefined
                    error: root.tileErrors.theme || ""
                    subCursor: cell.hasCursor && !root.editing ? root.subCursor : -1
                    tooltip: root.editing ? (cell.enabledInSettings ? "Enter hides this tile" : "Enter shows this tile") : ""
                    hasCursor: cell.hasCursor
                    editing: root.editing
                    enabledInSettings: cell.enabledInSettings
                    compact: root.compact
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onThemeClicked: function(name) { root.cursor = cell.index; root.setTheme(name) }
                    onThemeHovered: function(index) { root.cursor = cell.index; root.subCursor = index }
                    onClicked: { root.cursor = cell.index; if (root.editing) root.activate(cell.index) }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                    draggable: root.editing
                    onDragStarted: function(item, pressX, pressY) { root.beginDrag(cell.modelData, item, pressX, pressY, gridItem) }
                    onDragMoved: function(item, mouse) { root.updateDrag(item, mouse, gridItem) }
                    onDragEnded: root.endDrag()
                  }
                }

                Component {
                  id: catalogueComp
                  CatalogueTile {
                    anchors.fill: parent
                    glyph: root.catalogueGlyph(cell.modelData)
                    label: Model.labelOf(cell.modelData)
                    wide: Model.spanOf(cell.modelData) >= 4
                    hasCursor: cell.hasCursor
                    editing: root.editing
                    enabledInSettings: cell.enabledInSettings
                    compact: root.compact
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    draggable: root.editing
                    onClicked: { root.cursor = cell.index; root.activate(cell.index) }
                    onDragStarted: function(item, pressX, pressY) { root.beginDrag(cell.modelData, item, pressX, pressY, gridItem) }
                    onDragMoved: function(item, mouse) { root.updateDrag(item, mouse, gridItem) }
                    onDragEnded: root.endDrag()
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                  }
                }

                Component {
                  id: headerComp
                  HeaderRow {
                    anchors.fill: parent
                    label: Model.labelOf(cell.modelData)
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }
                }

                Component {
                  id: optionComp
                  OptionTile {
                    readonly property string optionId: cell.modelData
                    anchors.fill: parent
                    label: Model.labelOf(optionId)
                    description: optionId === "opt-position" ? "Where the card opens"
                      : optionId === "opt-density" ? "How much room each control takes"
                      : optionId === "opt-motion" ? "No slides, fades or pulses"
                      : "A launcher in the bar, for the mouse"
                    isChoice: optionId === "opt-position" || optionId === "opt-density"
                    choices: optionId === "opt-density"
                      ? [{ value: "comfortable", label: "Comfortable" }, { value: "compact", label: "Compact" }]
                      : [{ value: "bar-end", label: "Bar end" }, { value: "centre", label: "Centre" }]
                    value: optionId === "opt-density" ? root.settings.density : root.settings.position
                    checked: optionId === "opt-motion" ? root.reduceMotion : root.settings.barWidget === true
                    hasCursor: cell.hasCursor
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onActivated: { root.cursor = cell.index; root.activateOption(optionId) }
                    onChoiceClicked: function(v) {
                      root.cursor = cell.index
                      root.saveSettings(Model.withOption(root.settings,
                        optionId === "opt-density" ? "density" : "position", v))
                    }
                    onClicked: { root.cursor = cell.index; root.activateOption(optionId) }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                    draggable: false
                    onDragStarted: function(item, pressX, pressY) { root.beginDrag(cell.modelData, item, pressX, pressY, gridItem) }
                    onDragMoved: function(item, mouse) { root.updateDrag(item, mouse, gridItem) }
                    onDragEnded: root.endDrag()
                  }
                }
              }
            }

            // Where the tile will land. A line in the gap, not an outline
            // on a tile: with mixed widths the question is which side of
            // what, and an outline cannot say that. It runs the full width
            // when the move is above or below a row, and stands up between
            // two tiles that will sit side by side.
            Rectangle {
              id: dropLine
              // A plan can name a place without describing one: the IPC seam
              // sets an anchor and a side so a drop can be driven from a
              // script, with no geometry to draw. Read the geometry once and
              // let the whole mark stand or fall on it.
              readonly property var mark: root.dropPlan && root.dropPlan.indicator
                ? root.dropPlan.indicator : null

              visible: mark !== null && root.draggingId !== ""
              z: 20
              color: root.accent
              radius: Math.min(width, height) / 2
              x: mark ? mark.x : 0
              y: mark ? mark.y : 0
              width: mark ? mark.width : 0
              height: mark ? mark.height : 0

              Behavior on x { enabled: !root.reduceMotion; NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
              Behavior on y { enabled: !root.reduceMotion; NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
              Behavior on width { enabled: !root.reduceMotion; NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
              Behavior on height { enabled: !root.reduceMotion; NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

              // A cap at each end, so a line between two tiles reads as an
              // insertion mark rather than as a border someone left on.
              Rectangle {
                width: dropLine.width < dropLine.height ? Style.space(7) : Style.space(3)
                height: dropLine.width < dropLine.height ? Style.space(3) : Style.space(7)
                radius: Math.min(width, height) / 2
                color: dropLine.color
                anchors.horizontalCenter: dropLine.horizontalCenter
                anchors.top: dropLine.top
                anchors.topMargin: dropLine.width < dropLine.height ? 0 : -height / 2 + dropLine.height / 2
                visible: dropLine.width < dropLine.height
              }
              Rectangle {
                width: dropLine.width < dropLine.height ? Style.space(7) : Style.space(3)
                height: dropLine.width < dropLine.height ? Style.space(3) : Style.space(7)
                radius: Math.min(width, height) / 2
                color: dropLine.color
                anchors.horizontalCenter: dropLine.horizontalCenter
                anchors.bottom: dropLine.bottom
                visible: dropLine.width < dropLine.height
              }
            }


            }
          }

          // A hairline that only appears when there is more to see.
          Rectangle {
            visible: scroller.contentHeight > scroller.height
            anchors.right: scroller.right
            anchors.rightMargin: -Style.spacing.xs
            width: Math.max(2, Style.space(2))
            radius: width / 2
            color: Util.alpha(root.foreground, 0.25)
            y: scroller.y + (scroller.height - height) * (scroller.contentHeight > scroller.height
              ? scroller.contentY / (scroller.contentHeight - scroller.height) : 0)
            height: Math.max(Style.space(20), scroller.height * (scroller.height / Math.max(1, scroller.contentHeight)))
          }

          // ---------- status ----------
          Text {
            id: statusText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            visible: root.status !== ""
            text: root.status
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

      }
    }
  }
}
