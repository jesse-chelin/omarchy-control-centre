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

  function open(payloadJson) {
    root.bindServices()
    root.editing = false
    root.status = ""
    root.sleepArmed = false
    root.tileErrors = ({})
    root.screenName = root.focusedScreenName()
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
    root.opened = false
    root.editing = false
    root.sleepArmed = false
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

  // ------------------------------------------------------------ brightness

  property bool brightnessAvailable: false
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property string focusedMonitor: ""

  Child {
    id: monitorProbe
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        var available = brightness !== "unavailable" && /^\d{1,3}$/.test(brightness)
        var monitor = String(lines[5] || "").trim()
        root.focusedMonitor = Model.isMonitorName(monitor) ? monitor : ""
        root.brightnessAvailable = available && root.focusedMonitor !== ""
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

  function beginPending(id, want, message) {
    var next = ({}); for (var k in pending) next[k] = pending[k]; next[id] = want; pending = next
    var since = ({}); for (var s in pendingSince) since[s] = pendingSince[s]; since[id] = Date.now(); pendingSince = since
    var msgs = ({}); for (var m in pendingMessages) msgs[m] = pendingMessages[m]; msgs[id] = message; pendingMessages = msgs
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
      if (now - (pendingSince[id] || now) > 3000) root.failPending(id, pendingMessages[id] || "No response")
    }
  }

  Timer {
    id: reconcileTimer
    interval: 250
    repeat: true
    running: root.opened && Object.keys(root.pending).length > 0
    onTriggered: root.reconcile()
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
    if (!suspendProbe.running) suspendProbe.running = true
    if (!sinkAvailabilityProbe.running) sinkAvailabilityProbe.running = true
    root.resolveVolumeSink()
    if (nightlightService && typeof nightlightService.refresh === "function") nightlightService.refresh()
  }

  function refreshFast() {
    if (!recordingProbe.running) recordingProbe.running = true
  }

  function refreshSlow() {
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

  function dismissHint() {
    if (!root.hintVisible) return
    root.hintVisible = false
    if (root.settings.hintSeen !== true) root.saveSettings(Model.withOption(root.settings, "hintSeen", true))
  }

  function setEditing(value) {
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
    volume: root.sink !== null,
    brightness: root.brightnessAvailable,
    power: root.profiles.length > 0 || root.batteryPresent,
    media: root.hasMedia,
    actions: true
  })

  readonly property var gridIds: Model.gridIds(root.settings, root.available, root.editing)
  readonly property int cellWidth: Math.floor((root.contentWidth - root.gap * 3) / 4)
  readonly property int gap: Style.spacing.lg
  readonly property var tileHeights: ({
    toggle: Style.space(74),
    slider: Style.space(62),
    power: Style.space(66),
    media: Style.space(76),
    actions: Style.space(46),
    option: Style.space(44)
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
    } else {
      root.subCursor = 0
    }
  }

  onCursorChanged: {
    root.resetSubCursor()
    root.pinnedId = root.idAt(root.cursor)
  }

  // Whether the stock panel a chevron would open is actually live in the
  // bar. shell.summon only reaches a bar widget that is mounted, so a tile
  // whose panel the user removed hides its chevron instead of pointing at
  // nothing.
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

  property bool sleepArmed: false
  Timer { id: sleepTimer; interval: 2000; onTriggered: root.sleepArmed = false }

  readonly property var actionRow: {
    var list = [{ id: "lock", glyph: "󰌾", label: "Lock", armed: false }]
    if (!root.suspendHidden) list.push({ id: "sleep", glyph: "󰒲", label: "Sleep", armed: root.sleepArmed })
    list.push({ id: "screensaver", glyph: "󱄄", label: "Screensaver", armed: false })
    return list
  }

  function runAction(id) {
    if (id === "sleep") {
      if (!root.sleepArmed) {
        root.sleepArmed = true
        sleepTimer.restart()
        return
      }
      root.sleepArmed = false
      root.dismiss()
      root.runDetached(["systemctl", "suspend"])
      return
    }
    root.dismiss()
    if (id === "lock") root.runDetached(["omarchy-system-lock"])
    else if (id === "screensaver") root.runDetached(["omarchy-launch-screensaver", "force"])
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
  }

  function mediaAction(action) {
    if (!root.mediaService || typeof root.mediaService.runAction !== "function") return
    root.mediaService.runAction(action, false)
  }

  function sliderValue(id) {
    if (id === "volume") return root.outputVolume
    if (id === "brightness") return root.brightnessPercent / 100
    return 0
  }

  function nudgeSlider(id, steps) {
    if (id === "volume") root.setOutputVolume(Math.max(0, Math.min(1, root.outputVolume + steps * 0.05)))
    else if (id === "brightness") root.setBrightness(root.brightnessPercent + steps * 5)
  }

  // Enter, Space, or a click on the tile body.
  function activate(index) {
    if (index < 0 || index >= root.gridIds.length) return
    var id = root.gridIds[index]
    var kind = Model.kindOf(id)
    if (root.editing) {
      if (kind === "option") root.activateOption(id)
      else root.saveSettings(Model.withTileEnabled(root.settings, id, !Model.tileEnabled(root.settings, id)))
      return
    }
    if (kind === "toggle") root.activateToggle(id)
    else if (kind === "slider") { if (id === "volume") root.toggleOutputMute() }
    else if (kind === "power") { if (root.subCursor >= 0 && root.subCursor < root.profiles.length) root.setProfile(root.profiles[root.subCursor]) }
    else if (kind === "media") root.mediaAction(["previous", "playPause", "next"][Math.max(0, Math.min(2, root.subCursor))])
    else if (kind === "actions") { var a = root.actionRow[Math.max(0, Math.min(root.actionRow.length - 1, root.subCursor))]; if (a) root.runAction(a.id) }
  }

  function activateOption(id) {
    if (id === "opt-position") root.saveSettings(Model.withOption(root.settings, "position", Model.nextPosition(root.settings.position)))
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
    var kind = root.cursorKind
    if (kind === "power") return root.profiles.length
    if (kind === "media") return 3
    if (kind === "actions") return root.actionRow.length
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
      if (kind === "slider" && !root.editing) root.nudgeSlider(root.cursorId, direction * (shift ? 5 : 1))
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
      settings: root.settings,
      settingsLoaded: root.settingsLoaded,
      settingsRejected: root.settingsRejected,
      hintVisible: root.hintVisible,
      screen: root.screenName,
      pending: root.pending,
      errors: root.tileErrors,
      state: {
        wifi: root.wifiEnabled, wifiDevice: root.wifiDevice !== null, wired: root.wiredConnected,
        bluetooth: root.bluetoothOn, dnd: root.dnd, nightlight: root.nightlight, stayAwake: root.stayAwake,
        micMuted: root.inputMuted, micInUse: root.micInUse, recording: root.recording, recordingElapsed: root.recordingElapsed,
        volume: root.outputVolume, muted: root.outputMuted, sink: root.nodeLabel(root.sink), volumeSink: root.volumeSinkName,
        brightness: root.brightnessPercent, brightnessAvailable: root.brightnessAvailable, monitor: root.focusedMonitor,
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
  readonly property int contentWidth: Math.min(Style.space(432), Math.max(Style.space(240), panel.width - Style.gapsOut * 2 - root.padding * 2 - Border.left(root.borderSpec) - Border.right(root.borderSpec)))
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
    if (editing) info.tooltip = Model.tileEnabled(root.settings, id) ? "Enter hides this tile" : "Enter shows this tile"
    return info
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

    MouseArea {
      anchors.fill: parent
      enabled: root.opened
      acceptedButtons: Qt.AllButtons
      onPressed: root.dismiss()
    }

    readonly property int cardWidth: root.contentWidth + root.padding * 2 + Border.left(root.borderSpec) + Border.right(root.borderSpec)
    readonly property int cardHeight: Math.min(panel.height - Style.gapsOut * 2 - (root.barHidden ? 0 : root.barSize),
      content.implicitHeight + root.padding * 2 + Border.top(root.borderSpec) + Border.bottom(root.borderSpec))
    readonly property bool centred: root.settings.position === "centre"
    readonly property int restX: {
      if (centred) return Math.round((panel.width - cardWidth) / 2)
      if (root.barPosition === "right") return panel.width - cardWidth - root.barInset
      if (root.barPosition === "left") return root.barInset
      return panel.width - cardWidth - Style.gapsOut
    }
    readonly property int restY: {
      if (centred) return Math.round((panel.height - cardHeight) / 2)
      if (root.barPosition === "bottom") return panel.height - cardHeight - root.barInset
      if (root.barPosition === "top") return root.barInset
      return Style.gapsOut
    }
    readonly property int slide: Style.space(8)
    readonly property int slideX: root.barPosition === "left" ? -slide : (root.barPosition === "right" ? slide : 0)
    readonly property int slideY: root.barPosition === "bottom" ? slide : (root.barPosition === "top" ? -slide : 0)

    BorderSurface {
      id: card
      x: panel.restX + (root.opened ? 0 : panel.slideX)
      y: panel.restY + (root.opened ? 0 : panel.slideY)
      width: panel.cardWidth
      height: panel.cardHeight
      radius: Style.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.padding
      opacity: root.opened ? 1 : 0

      Behavior on opacity {
        enabled: !root.reduceMotion
        NumberAnimation { duration: root.opened ? 120 : 80; easing.type: Easing.OutCubic }
      }
      Behavior on x { enabled: !root.reduceMotion; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on y { enabled: !root.reduceMotion; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

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

        Column {
          id: content
          width: parent.width
          spacing: Style.spacing.lg

          // ---------- header ----------
          Item {
            width: parent.width
            height: root.headerHeight

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.editing ? "Edit tiles" : "Control Centre"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              anchors.right: gear.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              visible: root.editing
              text: "Enter shows or hides · Ctrl+arrows reorder"
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
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

          // ---------- grid ----------
          Item {
            id: gridItem
            width: parent.width
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
                x: geometry ? geometry.x : 0
                y: geometry ? geometry.y : 0
                width: geometry ? geometry.width : 0
                height: geometry ? geometry.height : 0

                sourceComponent: kind === "toggle" ? toggleComp
                  : kind === "slider" ? sliderComp
                  : kind === "power" ? powerComp
                  : kind === "media" ? mediaComp
                  : kind === "actions" ? actionsComp
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
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onClicked: { root.cursor = cell.index; root.activate(cell.index) }
                    onRightClicked: { root.cursor = cell.index; if (!root.editing) root.openPanel(cell.modelData) }
                    onChevronClicked: root.openPanel(cell.modelData)
                    onMoveRequested: function(delta) { root.moveTile(cell.modelData, delta) }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                  }
                }

                Component {
                  id: sliderComp
                  SliderTile {
                    readonly property bool isVolume: cell.modelData === "volume"
                    anchors.fill: parent
                    label: isVolume ? "Volume" : "Brightness"
                    glyph: isVolume ? Model.volumeGlyph(root.outputVolume, root.outputMuted, root.isHeadphones(root.sink)) : "󰃠"
                    glyphTooltip: isVolume ? (root.outputMuted ? "Unmute" : "Mute") : ""
                    value: root.sliderValue(cell.modelData)
                    minimum: isVolume ? 0 : 0.01
                    step: 0.05
                    muted: isVolume ? root.outputMuted : false
                    chip: isVolume ? root.nodeLabel(root.sink) : (root.focusedMonitor !== "" && Quickshell.screens.length > 1 ? root.focusedMonitor : "")
                    chipTooltip: isVolume ? (root.candidateSinks.length > 1 ? "Switch to the next output" : "The only output") : "Brightness of the focused display"
                    chevron: root.tileInfo(cell.modelData).chevron
                    chevronTooltip: root.tileInfo(cell.modelData).chevronTooltip
                    tooltip: root.editing ? (cell.enabledInSettings ? "Enter hides this tile" : "Enter shows this tile") : ""
                    hasCursor: cell.hasCursor
                    editing: root.editing
                    enabledInSettings: cell.enabledInSettings
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onGlyphClicked: { root.cursor = cell.index; if (isVolume) root.toggleOutputMute() }
                    onChipClicked: { root.cursor = cell.index; if (isVolume) root.cycleSink() }
                    onChevronClicked: root.openPanel(cell.modelData)
                    onMoveRequested: function(delta) { root.moveTile(cell.modelData, delta) }
                    onClicked: { root.cursor = cell.index; if (root.editing) root.activate(cell.index) }
                    onMoved: function(v) {
                      root.cursor = cell.index
                      if (isVolume) root.setOutputVolume(v)
                      else root.previewBrightness(v * 100)
                    }
                    onReleased: function(v) {
                      if (isVolume) root.setOutputVolume(v)
                      else root.setBrightness(v * 100)
                    }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
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
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onProfileClicked: function(profile) { root.cursor = cell.index; root.setProfile(profile) }
                    onProfileHovered: function(index) { root.cursor = cell.index; root.subCursor = index }
                    onChevronClicked: root.openPanel("power")
                    onMoveRequested: function(delta) { root.moveTile(cell.modelData, delta) }
                    onClicked: { root.cursor = cell.index; if (root.editing) root.activate(cell.index) }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
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
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onTransport: function(action) { root.cursor = cell.index; root.mediaAction(action) }
                    onControlHovered: function(index) { root.cursor = cell.index; root.subCursor = index }
                    onMoveRequested: function(delta) { root.moveTile(cell.modelData, delta) }
                    onClicked: { root.cursor = cell.index; if (root.editing) root.activate(cell.index) }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                  }
                }

                Component {
                  id: actionsComp
                  ActionsTile {
                    anchors.fill: parent
                    actions: root.actionRow
                    subCursor: cell.hasCursor && !root.editing ? root.subCursor : -1
                    tooltip: root.editing ? (cell.enabledInSettings ? "Enter hides this tile" : "Enter shows this tile") : ""
                    hasCursor: cell.hasCursor
                    editing: root.editing
                    enabledInSettings: cell.enabledInSettings
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onActivated: function(id) { root.cursor = cell.index; root.runAction(id) }
                    onActionHovered: function(index) { root.cursor = cell.index; root.subCursor = index }
                    onMoveRequested: function(delta) { root.moveTile(cell.modelData, delta) }
                    onClicked: { root.cursor = cell.index; if (root.editing) root.activate(cell.index) }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                  }
                }

                Component {
                  id: optionComp
                  OptionTile {
                    readonly property string optionId: cell.modelData
                    anchors.fill: parent
                    label: optionId === "opt-position" ? "Position" : (optionId === "opt-motion" ? "Reduce motion" : "Bar pill")
                    description: optionId === "opt-position" ? "Where the card opens"
                      : (optionId === "opt-motion" ? "No slides, fades or pulses" : "A launcher in the bar, for the mouse")
                    isChoice: optionId === "opt-position"
                    choices: [{ value: "bar-end", label: "Bar end" }, { value: "centre", label: "Centre" }]
                    value: root.settings.position
                    checked: optionId === "opt-motion" ? root.reduceMotion : root.settings.barWidget === true
                    hasCursor: cell.hasCursor
                    reduceMotion: root.reduceMotion
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onActivated: { root.cursor = cell.index; root.activateOption(optionId) }
                    onChoiceClicked: function(v) { root.cursor = cell.index; root.saveSettings(Model.withOption(root.settings, "position", v)) }
                    onClicked: { root.cursor = cell.index; root.activateOption(optionId) }
                    onPointerMoved: function(mouse) { root.hoverTile(cell.index, this, mouse) }
                  }
                }
              }
            }
          }

          // ---------- status ----------
          Text {
            width: parent.width
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
