# Control Centre

One key opens every daily system control in a single native Omarchy card:
Wi-Fi, Bluetooth, volume, brightness, night light, Do Not Disturb, stay awake,
power profile, microphone, screen recording, media, and lock/sleep/screensaver.
Anything deeper opens the stock Omarchy panel it belongs to.

![Control Centre](preview.png)

## What it does

| | |
|---|---|
| One surface | Every daily toggle and slider in one card, on the focused monitor |
| Native | Built from the shell's own components, so it follows your theme exactly |
| Never a duplicate | Wi-Fi lists, Bluetooth pairing, the per-app mixer and monitor layout stay in the stock panels, one chevron away |
| Live both ways | A tile reflects a change made anywhere else, and a change made here shows up everywhere else |
| Keyboard first | Arrows, digits, Tab and Enter reach everything; the mouse does too |
| Adapts | A tile whose hardware is missing is hidden, not greyed out |
| Yours to arrange | Reorder and hide tiles from the card itself, no file editing |

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

## The tiles

Each one reads the same source the matching stock Omarchy panel reads, so the
two never disagree.

| Tile | Reads | Chevron opens |
|---|---|---|
| Wi-Fi | NetworkManager through Quickshell; shows the SSID and signal, or Ethernet on a wired box | Network |
| Bluetooth | The BlueZ adapter and its connected devices | Bluetooth |
| Volume | The default PipeWire sink, resolved through any speaker tuning so the slider moves real loudness | Audio |
| Microphone | The default PipeWire source; turns red while something is actually capturing | Audio |
| Brightness | The focused display's backlight, the same reading the Display panel takes | Display |
| Night Light, Do Not Disturb, Stay Awake | The shell's own services, the same ones the bar indicators use | — |
| Power | Power profiles plus battery percentage and time remaining | Power |
| Recording | Whether a screen recording is running, and for how long | — |
| Media | The active MPRIS player: art, title, artist and transport | — |
| Lock, Sleep, Screensaver | — | — |

Sleep asks twice: the button arms on the first press and suspends on a second
press within two seconds.

A tile hides itself when the machine cannot back it: no Bluetooth adapter, no
backlight, no battery and no power profiles, nothing playing. A chevron hides
itself when the stock panel it would open is not in your bar, because the
shell can only summon a panel that is mounted there.

## Settings

Press `,` or click the gear. Tiles can be hidden and reordered, the card can
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

**The child processes.** A handful of Omarchy commands for the things QML
cannot read directly: the monitor state, power profiles, battery status, the
audio sink, whether a recording is running. Each runs with a cleared
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
