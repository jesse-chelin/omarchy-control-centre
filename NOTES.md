# Notes from the running system

Everything below was measured on Omarchy 4.0.1 (shell 4.0.1-1, Quickshell with
the Networking, Bluetooth, Pipewire, UPower and Mpris modules) on 2026-09-03,
not read out of the source and reasoned about. Re-measure before changing how
a tile reads its state.

## What the shell injects into an overlay

`shell.qml`'s panel `Loader` sets, when the property exists on the root item:
`omarchyPath`, `shell`, `manifest`, `barWidgetRegistry`, `pluginRegistry`, and
`service` (the plugin's own service singleton, if it declares one). `manifest`
carries `__sourceDir`, which is how the plugin finds `state.py` without
assuming an install path.

`shell` exposes `summon(id, payloadJson)`, `hide(id)`, `toggle(id, payload)`,
`callIfLoaded`, `firstPartyServiceFor(id)`, `serviceFor(id)`, `pluginRegistry`,
`barConfig`, `shellConfig`, `bar` and `panelLoaders`.

`omarchy-shell shell toggle <id>` routes to the overlay for a plugin that
declares one, even when the same plugin also declares a bar widget: the bar
path in `shell.qml` is only taken when the manifest has *no* panel, overlay or
menu kind.

`keepLoaded: true` means the Loader mounts the overlay at shell start and holds
it between summons. It also means the shell calls `close()` on every loaded
panel during a plugin reload (`unloadPanels`), so an overlay can be closed out
from under you while you are editing its files. That is development behaviour,
not a bug: `omarchy-restart-shell` is the way to pick up edits.

## Behaving like a bar panel

The bar keeps one open popup at a time in `bar.activePopout`, claimed with
`bar.requestPopout(owner)` and dropped with `bar.releasePopout(owner)`.
Requesting it closes the previous owner by calling its `closeForPopoutSwitch()`
or `close()`. The accent open-panel mark under a bar icon is drawn by the bar
itself, on the test `activePopout === slot.activeItem`, so the owner passed in
has to be the widget instance for the mark to appear.

That is the whole of what makes the pill behave like the stock icons: the bar
widget claims the popout while the overlay is up, and exposes `opened`,
`close()` and `closeForPopoutSwitch()` for the coordinator to drive.

Position comes from the widget rather than from the overlay, because only the
widget knows where it sits: `item.mapToItem(window.contentItem, 0, 0)` inside
the bar window gives a coordinate that maps straight to the screen on the axis
the bar spans, which is what `KeyboardPanel` relies on too. It travels to the
overlay in the summon payload, which is validated on arrival: the payload
reaches `open()` through shell IPC, where anything can send one.

## Wi-Fi

`Networking.wifiEnabled` is writable and toggles the NetworkManager radio with
no polkit prompt for the desktop user; this is exactly what the stock network
panel's `toggleNetwork()` does. `nmcli radio wifi off` was therefore never
needed and is not used.

This machine reports `WIFI-HW missing` and has only a wired device, so the
tile falls back to reporting Ethernet and the radio toggle is not offered.
`Networking.backend === NetworkBackendType.NetworkManager` gates the whole
tile.

## Bluetooth

`Bluetooth.defaultAdapter` is null on a machine with no adapter, which is what
hides the tile. Writing `adapter.enabled` sets BlueZ's `Powered`, which nothing
persists across a reboot; `omarchy-bluetooth-power on|off` moves the rfkill
soft block instead, which systemd-rfkill restores at boot. The stock panel
takes the same route, so the tile shells out rather than writing the property.

## Audio

`Pipewire.defaultAudioSink` is not necessarily where loudness lives: a speaker
tuning or EasyEffects sits in front of the physical sink, and writing its
volume changes the level going *into* the processing. `omarchy-audio-output-sink`
prints the sink that actually carries the level, and the stock audio panel
resolves through it the same way. The tile does that on open and every time the
default sink changes.

Setting `node.audio.volume` directly is what keeps the OSD quiet while
dragging; `omarchy-audio-output-volume` would pop the OSD on every step.

`omarchy-audio-output-set-default <id> <name>` is what makes a sink choice
stick, alongside `Pipewire.preferredDefaultAudioSink`. `omarchy-audio-output-switch`
was not used: it shows an OSD and picks the next sink itself, which would fight
the card's own ordering.

## Brightness

`omarchy-monitor-state` prints, one per line: brightness percent (or
`unavailable`), internal monitor, external monitor, internal enabled, mirror
source, focused monitor, scale, and a JSON array of displays. That is exactly
what the stock Display panel parses, and the tile parses the same two lines it
needs. `brightnessAvailable` is "the first line is a number", plus a focused
monitor name that passes validation.

Writing goes through `omarchy-brightness-display --no-osd --monitor <name> N%`,
debounced at 180 ms while dragging. Do not re-read after a write: the tool
races the driver and can return an empty string, which reads back as 0 and
bounces the slider. The 5 s poll while open picks up external changes.

This VM has no backlight, so the tile is hidden here.

## Power

`omarchy-powerprofiles-list --active-state` prints `name<TAB>0|1` per line, and
`omarchy-powerprofiles-set <ac|battery> <profile>` sets and remembers one. The
ac/battery choice comes from `UPower.onBattery`, which is the same signal the
script's own autodetect uses. `powerprofilesctl` is not installed on this
machine, so the list is empty and the profile chips do not render.

`UPower.displayDevice` gives presence, percentage, state and `onBattery`;
`omarchy-battery-status --shell` adds the human time estimate. No battery here,
so the whole tile is hidden.

## Recording

`pgrep -f '^gpu-screen-recorder'` is the same check the stock indicator makes.
The elapsed time comes from `ps -o etimes= -p <pid>` on the pid pgrep printed,
validated as digits before it reaches an argument vector.

Starting a recording opens the stock capture menu
(`omarchy-menu toggle trigger.capture.screenrecord`) rather than starting one
directly, because that menu is where audio and webcam options are chosen.
Stopping is `omarchy-capture-screenrecording --stop-recording`.

## System actions

`omarchy-system-lock` locks. `omarchy-launch-screensaver force` starts the
screensaver even when the screensaver toggle is off. Suspend is
`systemctl suspend`, which is what the Omarchy menu itself runs;
`omarchy-system-sleep-lock` is the pre-suspend lock helper that runs from a
systemd inhibitor, not something a UI calls. The menu hides Suspend when
`omarchy-toggle-enabled suspend-off` succeeds, and so does this card.

## Keybinding

Checked against the Omarchy 4.0.1 defaults with `hyprctl -j binds`:
`SUPER + C` is Universal copy, `SUPER + SHIFT + C` is the Calendar web app,
`SUPER + CTRL + C` is the Capture menu, and `SUPER + I` in the default set is
"Toggle locking on idle" under `SUPER + CTRL`. `SUPER + BACKSLASH` was free.

## Motion

The card's resting position is derived from its own width and height: it is
pinned to the bar end or centred on the bar icon, so `x` is computed from
`cardWidth`, which settles a frame or two after the layer surface maps and
again whenever a probe adds or removes a tile. A `Behavior` on `x` therefore
animates layout settling, and what that looks like is a card sliding in
sideways as it grows, which is not motion anyone asked for.

The entrance is a `Translate` transform driven by one animated property
instead, and `x`/`y` are assigned outright. Layout settles instantly while the
card is still transparent, and the only movement on screen is the 8 px
entrance from the bar edge.

Measured with the fade disabled and the slide slowed to 1400 ms, differencing
three frames against a closed baseline: the card's left edge is constant to
the pixel across all three, and its top edge moves down into place.

## Measured

- Open latency, warm, including two IPC round trips: 57 to 87 ms.
- With the card closed, no probe process is spawned at all over a 10 s watch.
  With it open, the probes appear on their 2 s and 5 s timers.
- Settings file lands at mode 0600, its directory at 0700.

## Not exercised here

- Non-zero `decoration:rounding`. Omarchy ships `rounding = 0` and none of the
  six installed themes overrides it, and Hyprland's non-legacy config parser
  refuses `hyprctl keyword`. The card and every tile take their radius from
  `Style.cornerRadius`, the same as every stock component, so they follow
  whatever a theme sets.
- A second monitor, and a screen smaller than this one. The card caps its
  height against the screen and its width against the screen minus two gaps.
- A real Bluetooth adapter, a backlight, a battery, and power profiles: none
  exist on this machine, so those tiles were verified only by their hidden
  state and by reading the same sources the stock panels read.
