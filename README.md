# Control Centre

One key opens every daily system control in a single native Omarchy card:
Wi-Fi, Bluetooth, volume, brightness, night light, Do Not Disturb, stay awake,
power profile, microphone, screen recording, media, and lock/sleep/screensaver.
Anything deeper opens the stock Omarchy panel it belongs to.

![Control Centre](preview.png)

## What it does

| | |
|---|---|
| One surface | Thirty-eight controls in one card, on the focused monitor |
| Native | Built from the shell's own components, so it follows your theme exactly |
| Never a duplicate | Wi-Fi lists, Bluetooth pairing, the per-app mixer and monitor layout stay in the stock panels, one chevron away |
| Live both ways | A tile reflects a change made anywhere else, and a change made here shows up everywhere else |
| Keyboard first | Arrows, digits, Tab and Enter reach everything; the mouse does too |
| Adapts | A control whose hardware is missing is hidden, not greyed out |
| Yours to arrange | Show, hide and reorder anything from the card itself, no file editing |

## Install

```sh
omarchy plugin add https://github.com/jesse-chelin/omarchy-control-centre --enable
```

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + BACKSLASH", "Control Centre", "omarchy-shell shell toggle io.github.jesse-chelin.control-centre")
```

`SUPER + BACKSLASH`, `SUPER + I` and `SUPER + X` were all unbound in the
Omarchy 4.0.1 defaults. `SUPER + C` is Universal copy and `SUPER + SHIFT + C`
is the Calendar web app, so neither of those is free.

A launcher icon also appears in the bar, so the card is one click away
without a keybinding. It behaves like the stock bar icons: the card opens
under it, the icon takes the accent mark while the card is up, and opening
another bar panel puts it away (and the other way round). Turn it off with
**Bar pill** in the card's edit mode.

## Keys

| Key | Action |
|---|---|
| Arrows, `h` `j` `k` `l` | Move between tiles |
| Enter, Space | Flip the tile under the cursor |
| Shift+Enter, `o` | Open the stock panel behind the tile |
| Left, Right, `+`, `-` | Move a slider by one step, or pick within a tile |
| Shift + those | Move a slider by five steps |
| `1` to `9` | Flip the nth toggle directly |
| Tab, Shift+Tab | Jump between sections |
| `,` | Edit mode: reorder and hide tiles, and change settings |
| Ctrl+arrows | In edit mode, move the tile under the cursor |
| Esc | Leave edit mode, then close |

## The controls

Thirty-eight of them. Every one reads or writes the same thing the matching
stock Omarchy panel, bar indicator or menu entry does, so the card and the
rest of the desktop never disagree. Sixteen are on when you install it; the
rest are one keystroke away in edit mode.

| Group | Controls |
|---|---|
| Connectivity | Wi-Fi, Bluetooth |
| Sound | Volume, Mic Level, Microphone mute |
| Display | Brightness, Night Light, Warmth |
| Focus | Do Not Disturb, Stay Awake, Screensaver, Crash Capture |
| Capture | Recording, Screenshot, Colour, Grab Text, Scan QR |
| Tools | Emoji, Clipboard, Reminder, Share, Transcode, Net Speed, Disk Speed |
| Desktop | Menu Bar, Window Gaps, Square Ratio, Scrolling layout, Theme |
| Hardware | Touchpad, Touchscreen, Laptop Screen, Mirror, Hybrid GPU |
| Power | Power profile and battery |
| Media | Now playing with transport |
| System | Lock, Sleep, Screensaver; Log Out, Restart, Shut Down, Hibernate |

A control hides itself when the machine cannot back it: no Bluetooth adapter,
no backlight, no battery, no touchscreen, nothing playing. A chevron hides
itself when the stock panel it would open is not in your bar, because the
shell can only summon a panel that is mounted there. Anything that ends the
session or the machine asks twice: it arms on the first press, says so, and
only goes through on a second press within two seconds.

Wi-Fi, Bluetooth, Volume, Microphone, Brightness and Power each open their
stock panel from the chevron, for the network list, pairing, the per-app
mixer and monitor layout. The card never tries to replace those.

## Making it yours

Press `,` or click the gear. Edit mode is the whole catalogue, grouped, with
the controls already on your card shown solid and the rest dimmed. Enter shows
or hides the one under the cursor, Ctrl and the arrows move it, and the card
saves as you go. A long catalogue scrolls, and the cursor drags the view along
with it.

## Settings

Under the Settings heading in edit mode: the card can
open at the bar end or in the centre, all animation can be turned off, and the
bar pill can be turned off. **Centre** is honoured however the card was
opened; **Bar end** means under the bar icon when you click it, and at the end
of the bar when you press the key. Everything is saved as you change it.

State lives in `~/.local/state/omarchy/control-centre.json`, written with mode
0600. Delete it to start over; the card re-reads it every time it opens.

## Trust boundaries

The card runs inside a process that lives as long as your session, so the
places where something outside it gets a say are deliberately narrow.

**No network, no credentials, no privilege.** The plugin makes no network
requests, holds no tokens, and installs nothing.
No sudo or pkexec is required, and neither is ever invoked.

**The settings file.** It sits in a directory anything running as you can
write, so it is read and written by `state.py` rather than by QML, which has
no way to cap what it reads. Reading opens with `O_NOFOLLOW`, and refuses a
symlink, anything that is not a regular file, anything owned by another user,
and anything over 64 KiB. Writing creates a private temp file with the mode
set at creation, fsyncs it, renames it into place, fsyncs the directory, and
refuses to replace anything that is not a regular file. Whatever survives the
read is then rebuilt field by field against the same bounds it is written
under: an unknown tile id is dropped, a missing one is added, and a value
outside its allowed set falls back to the default. A file that is refused
costs you your layout, not your session; the card opens on defaults and says
why.

**The child processes.** Omarchy commands for the things QML cannot read or
do directly: the monitor state, power profiles, battery status, the audio
sink, whether a recording is running, and one `probe.sh` that reads every
toggle flag, hardware answer and theme name in a single pass rather than one
child per control. Every command a control can run is a literal argument
vector in a table in `Model.js`, so the complete set of things this plugin can
execute is a list you can read in one sitting. Each runs with a cleared
environment holding only the variables those scripts need, with a fixed
argument vector that is never built by string concatenation, under a watchdog
that sends `TERM` and then `KILL`. Every value that reaches an argument vector
is validated first against an allowlist or a pattern: a monitor name, a
PipeWire node name or id, a power profile, a percentage. Every byte read back
is parsed within a bound.

**Nothing runs while the card is closed.** Every timer is bound to the card
being open, which is verifiable: with the card closed, no probe process is
ever spawned.

## Removal

```sh
omarchy plugin remove io.github.jesse-chelin.control-centre
rm -f ~/.local/state/omarchy/control-centre.json
```

Then remove the binding you added to `~/.config/hypr/bindings.lua` and run
`hyprctl reload`. If you turned the bar pill on, `omarchy bar` no longer lists
it once the plugin is removed. The plugin registers nothing with any service,
holds no credentials, starts no daemon, and leaves nothing else behind.

## Development

```sh
./check.sh
```

Runs the manifest validation, `qmllint`, the model unit tests, the structural
scans `qmllint` misses, the settings-file tests and the glyph check. It is the
same command CI runs.

The card exposes its whole state machine over IPC, because keyboard focus
inside a layer-shell surface cannot be synthesised from outside:

```sh
id=io.github.jesse-chelin.control-centre
omarchy-shell shell call $id stateJson ""
omarchy-shell shell call $id setCursor volume     # -1 if that tile is not showing
omarchy-shell shell call $id moveBy "0,1"
omarchy-shell shell call $id pressKey enter       # or shift+enter, escape, left, ...
omarchy-shell shell call $id setEditMode true
```

`keepLoaded` overlays are held by a `Loader` keyed on the source URL, so edits
to the QML need `omarchy-restart-shell` to take effect.

`NOTES.md` records what was measured on the running system while this was
built, and is worth reading before changing how a tile reads its state.

## License

MIT
