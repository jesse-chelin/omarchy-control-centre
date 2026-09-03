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

## The toggle flags

Everything the Omarchy menu calls a trigger toggle is a flag file, and the
file existing is the state:

| Flag | Path under `~/.local/state/omarchy/` |
|---|---|
| Menu bar hidden | `toggles/bar-off` |
| Screensaver disabled | `toggles/screensaver-off` |
| Crash capture disabled | `toggles/crash-capture-off` |
| Suspend hidden from the menu | `toggles/suspend-off` |
| Window gaps removed | `toggles/hypr/window-no-gaps.lua` |
| Square single-window ratio | `toggles/hypr/single-window-aspect-ratio.lua` |
| Touchpad or touchscreen off | `toggles/hypr/<kind>-disabled-name`, non-empty |

The names carry the sense the file has, which is the opposite of the sense
most of the tiles show: `bar-off` present means the Menu Bar tile is off. The
inversion lives in one place, next to the flag reader.

The workspace layout is not a flag: `hyprctl activeworkspace -j` reports
`tiledLayout` as `dwindle` or `scrolling`, and the toggle writes a per
workspace rule. The internal display and its mirror come from
`omarchy-monitor-state`, which the brightness tile already reads.

`probe.sh` gathers all of it in one child rather than a dozen, split into a
`state` half that runs on the open timer and a `static` half for what cannot
change mid-session: which parts the machine has, which optional tools are
installed, and the theme directory names. `omarchy-theme-set` accepts either
the display name or the directory name, so the card passes the directory name
and never has to map a label back.

## Two spellings, on purpose

The plugin is a Control **Centre** and its tile is a Color **Picker**. That is
not a slip: a tile label is the label Omarchy already uses for the same thing,
so it is recognised rather than learned, and Omarchy's own binding for it reads
`o.bind("SUPER + PRINT", "Color picker", ...)`. The plugin's own name is the
author's to spell. The rule, if a label is ever added: match Omarchy where
Omarchy has a word for it, and only otherwise choose.

## Glyphs go missing, silently

Every glyph is embedded as a literal character, because a JavaScript escape
takes four hex digits and a Nerd Font codepoint takes five. That makes a
glyph easy to lose in transit: what is left is a binding to the empty string,
which parses, lints, passes the glyph test (it only checks glyphs that are
present) and draws nothing. It happened once here, to the theme tile.

`tests/test_qml_structure.py` now fails on any icon bound to an empty string,
which is never intentional in this plugin. Worth knowing if you add a
component: the same test's `strip()` helper blanks every string literal for
the duplicate-binding scan, so a check about string *contents* has to read the
raw line instead. Getting that wrong makes the check flag every glyph in the
plugin, which is how this one was first written.

Coverage in the font is not the same as ink on the screen. `fc-list
:charset=<cp>` says a font claims the codepoint; rendering the character and
measuring the mean pixel value says it actually paints something.

## Dragging inside a scrolling grid

The offset a drag applies must not be measured in coordinates that offset
moves. Qt reports a mouse position in the item's own frame, which already has
the item's transform taken out of it, so `delta = mouse - pressPoint` on a
transformed item feeds its own answer back in: set the transform to that
delta and the next event reports a delta smaller by exactly the transform.
The tile oscillates rather than following the pointer. The drag is measured
in the grid's coordinates instead, capturing the grip point once before
anything has moved and mapping the live pointer up through the tile each
time, which undoes the transform on the way and leaves a true position.

Three more things are easy to leave out.

A `Flickable` takes the pointer grab off a child as soon as the pointer has
travelled far enough, so a drag turns into a scroll halfway through unless the
child sets `preventStealing`. The grid also stops being interactive while a
drag is in flight, so the two gestures cannot both claim the same movement.

That leaves no way to reach a target off-screen, so a drag near the top or
bottom edge scrolls the grid itself. The pointer does not move while that
happens but its position within the content does, so each step re-measures
the drag against content that shifted underneath a still pointer.

The dragged tile is drawn offset by a transform rather than moved. Its
position is a binding on the grid's own layout, so moving the item would fight
that binding; nothing about the layout changes until the drop, which rewrites
the settings and lets the grid lay out again on its own.

The drop target is found from the grid's geometry, not by asking what is under
the pointer: the dragged tile is painted away from its slot, so a hit test
against what is drawn answers with the thing being dragged.

A drop is an insertion point, never a swap. "Put it where that one is" has no
meaning once tiles have different widths: a full-width row and a
quarter-width square cannot trade places. `dropPlan` answers with an anchor
tile and which side of it, following the grid's own shape. A full-width block
occupies a whole row, so it can only go above or below something, and so can
anything dropped onto one; between two narrow tiles the answer is left or
right. Which side comes from the half of the target the pointer is in, and
for a vertical move the anchor is the first or last tile of that row rather
than whichever tile the pointer happened to be over.

The mark is a line in the gap rather than an outline on a tile, because an
outline cannot say which side of something a tile will land on. It is drawn
as a sibling of the tiles, not inside the `Repeater`: a `Repeater` only
instantiates its delegate, so a plain child of one renders nowhere at all.

Edit mode shows the card's own order first, then what is left to add. It used
to group everything by category, which made reordering meaningless: moving a
control one place in the settings could move it past something in a different
group and appear to do nothing at all.

## Function references outlive the objects behind them

A deferred call (`Qt.callLater`) can run after a plugin reload has torn down
the object it was going to call, and a stored function reference can point at
one that is already gone. Both showed up here as a single
`Property 'revealCell' ... is not a function` in the shell log.

Everything in this plugin's overlay lives in one QML file, so its ids are
visible from its root functions: address the grid directly rather than
handing a reference to it around, and check a deferred call's target is still
there before using it.

## Screen captures and a surface that is still up

Closing this card is not instant. The fade runs, then the compositor unmaps
the surface, and a capture started on the same tick photographs the card
sitting over whatever the user wanted a picture of. The capture tiles queue
their command and release it when `backingWindowVisible` goes false, with a
fallback timer so a compositor that never reports it cannot swallow the action.

## The card cannot tidy the bar

An obvious-looking feature: a setting that hides the bar icons this card
duplicates. It was measured and dropped, and the reason is worth keeping so it
is not designed again.

`omarchy.network`, `omarchy.bluetooth`, `omarchy.audio`, `omarchy.monitor` and
`omarchy.power` are all `kinds=bar-widget` and nothing else, so their panels
are popups the bar widget owns rather than panel plugins of their own.
`shell.summon()` sends a bar-widget id to `bar.summonBarWidget(id)`, which
needs a live widget and otherwise warns "no live bar widget for". Taking one
of those icons off the bar therefore takes its panel with it: the Wi-Fi list,
Bluetooth pairing, the per-app mixer, monitor layout. `panelInBar()` already
gates each chevron on the widget being in `barConfig.layout`, which is the
right test for exactly this reason, and the card would correctly drop the
chevron -- having caused the loss itself.

That is the trade: this card's whole claim is that the stock panels are one
chevron away, and hiding the duplicates spends that to tidy the bar.

`omarchy.indicators` is the one that would cost nothing from the card's side.
It carries DND, Night Light, Stay Awake, Recording, Reminder and Dictation, of
which this card covers all but Dictation, and nothing chevrons into it. What
hiding it costs is the glance while the card is shut, which is a different
thing from a panel and still not this plugin's to spend.

Two mechanical facts, if it is ever revisited.
`shell.pluginRegistry.setEnabled(id, false)` splices the entry straight out of
`bar.layout`, so no subprocess and no writing to `shell.json` from here. And it
does not remember where the entry was: re-enabling re-inserts at the widget's
default spot, so anything doing this has to record each icon's section and
index itself or it silently reorders someone's bar.

## Someone else's picker

A user who installs their own emoji picker or clipboard has replaced the
built-in one everywhere else, and the tile should not drag them back to it.
An enabled third-party overlay whose id or name says what it is wins over the
first-party plugin of the same kind.

## The card settles, then stands still

Availability is live: a song starting adds a full-width row, a recording
ending takes a control away. Both of those move everything below them while
someone is reaching for it. The grid is therefore built from a held copy of
the availability map, which tracks the live one until the probes have all
answered once and then stops until the card closes. `probesSettled` is the
real condition rather than a timer: the hardware probe has returned, the flag
probe has returned, and the monitor state has been read.

## One label size, one card width

Each tile label used to shrink to fit its own tile, which was kind to the
longest label and unkind to the row it sat in: neighbours came out at two
sizes. The card is sized instead so that the longest label in the catalogue
fits at one size. That is what sets the 468 in `contentWidth`; shortening the
longest label is the other way to buy it back.

## A hidden control is not a control

In edit mode a control that is not on the card draws as a catalogue entry:
glyph, name, and the word Hidden. Drawing the real control and marking it was
the first attempt, and it failed twice over. A working slider sitting at 100%
for something the user has taken off their card is noise, and the mark had
nowhere to sit that did not land on the control's own trailing content, which
is right-aligned on exactly the wide rows where the mark wanted to go.

## Where the accent goes

The shell's shared `selected` token is written by the theme template as the
theme's own foreground, for every theme, so a card built strictly on that
token comes out in exactly one colour. That token governs generic control
chrome; this card is about state, and Omarchy already spends the accent on
state elsewhere: the mark under a bar icon whose panel is open, and the border
of this card.

So the accent marks what is on: an active control's fill, border and glyph, a
slider's filled track, the chosen power profile, the current theme. Everything
else stays neutral, which is what keeps that reading.

Two themes cannot pay for it. One that never set an accent has the foreground
in that slot, and one whose accent is a neutral would give an "on" tile a
paler wash than the plain foreground does. Both fall back to the shared token,
tested by saturation as well as by distance from the foreground. The White
theme is the case that made this necessary: its accent is a mid grey, and
following it made "on" weaker than it had been.

## Setting a keybinding from inside the card

Three facts decide the shape of this, all measured rather than assumed.

`hyprctl keyword bind` is refused by Hyprland's non-legacy parser. A binding
can be added live with `hyprctl eval 'hl.bind(...)'`, which works, but it does
not survive a config reload, so anything persistent has to land in a file.
That rules out the runtime route on its own, and it also means the card never
has to evaluate Lua in the compositor, which is worth not doing.

Writing to `~/.config/hypr/bindings.lua` and calling `hyprctl reload` is the
whole mechanism. The card then re-reads `hyprctl -j binds` and finds its own
binding by the description it wrote, rather than trusting that the write took.

There is a tempting third route that should not be taken. Hyprland auto-loads
every Lua file in `~/.local/state/omarchy/toggles/hypr` on each reload, which
looks like a tidy place for a plugin to drop a generated binding. Omarchy's
own `toggles.lua` carries a comment explaining that they had to stop doing
exactly that, because a generated file there once carried an injected device
name and must never be executed again. Generating Lua from a key combination
someone typed is that same shape.

## A marked block is its lines, not its markers

"Everything between the two markers" is the obvious way to own a block in
someone else's file, and it is wrong in one direction that costs them their
keyboard. If the end marker is gone -- and the README used to invite exactly
that, by calling a five-line block "the three marked lines" -- then reading to
the end marker reads to the end of the file, and every binding below the block
is deleted. Measured against the previous version: a file with a stray begin
marker and two bindings under it came back with neither.

The block is recognised by its own shape instead. Both markers and the three
lines between them are literals this program writes, so a line that is none of
them belongs to the user, whatever it sits between, and an unterminated block
costs them the lines this wrote and nothing else.

The test that was supposed to catch this put its half-block at the end of the
file, where there is nothing below to lose. A repair case has to have
something after it or it is testing the easy half.

## What a capture field cannot do here

A bound combination never reaches any window: `hyprctl -j binds` reports
`non_consuming: false` on every Omarchy binding, so the compositor swallows it
first. Pressing an already-taken combination into a capture field therefore
produces nothing at all, not an error. The conflict has to be found by reading
the binding list and comparing, which also lets the card name what holds it;
224 of 226 bindings carry a readable description.

The number row is refused outright. Hyprland reports its workspace bindings
with an empty key name, so a digit combination cannot be checked against them,
and on Omarchy those are the workspace switches. Refusing beats offering a
check that cannot be made.

## The wheel

A `MouseArea` that declares `onWheel` accepts the event, and an accepted wheel
event stops there. The tile surface had one, added to stop a scroll over a
switch flipping it, and the result was a grid that scrolled only over the gaps
between tiles. A tile has nothing to do with a wheel, so it declares no
handler at all and the event reaches the grid.

That leaves one real consumer, `PanelSlider`, which turns the wheel into a
value. On a card that fits, that is the right thing. On a card long enough to
scroll it is not: someone scrolling past the volume row would turn the volume
up instead. So while the grid can scroll, a wheel-only `MouseArea` covers the
slider and scrolls the card instead. `acceptedButtons: Qt.NoButton` is what
keeps presses falling through to the slider underneath, so dragging still
works; wheel events are delivered to a MouseArea regardless of that property.

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
- Settings file lands at mode 0600. Its directory does not: `stat -c %a
  ~/.local/state/omarchy` says 755, because Omarchy creates that directory
  long before this plugin sees it, and `ensure_private_dir`'s `mkdir(..., 0700)`
  therefore never runs on a real machine. It is there for the case where the
  file is pointed somewhere else, and the owner check runs either way. Do not
  tighten Omarchy's own state directory from here; the file's own mode is what
  protects the file.

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
