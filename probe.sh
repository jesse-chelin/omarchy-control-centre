#!/usr/bin/env bash
# The state the card cannot read from QML, printed as key<TAB>value lines.
#
# One process for the lot, rather than one per tile: the alternative is a
# dozen children every refresh inside a process that lives as long as the
# session. Two modes, because the two halves change at different rates.
#
#   probe.sh state    flag files, workspace layout, current theme.
#                     Cheap: file tests plus one hyprctl. Runs on a timer
#                     while the card is open, and never while it is closed.
#   probe.sh static   what this machine has and what themes exist. Runs once
#                     per card, because a laptop does not grow a touchscreen
#                     mid-session.
#   probe.sh binds    every Hyprland binding, as JSON. Read only when the
#                     shortcut setting is on screen.
#
# Every value printed is a literal this script chose: `on`, `off`, a theme
# directory name, or a layout name matched against a fixed list. Nothing from
# the environment is echoed back, so nothing here can widen what the card
# will act on.

set -uo pipefail
export LC_ALL=C

STATE_DIR="$HOME/.local/state/omarchy"
TOGGLES="$STATE_DIR/toggles"
HYPR_TOGGLES="$TOGGLES/hypr"

emit() { printf '%s\t%s\n' "$1" "$2"; }

# A toggle flag is "the file exists". The names carry the sense the flag file
# has, not the sense the tile shows: `bar-off` present means the bar is
# hidden, and the card inverts it where the label reads the other way round.
flag() {
  if [[ -f "$TOGGLES/$1" ]]; then emit "flag.$1" on; else emit "flag.$1" off; fi
}

hypr_flag() {
  if [[ -f "$HYPR_TOGGLES/$1.lua" ]]; then emit "hypr.$1" on; else emit "hypr.$1" off; fi
}

# The input-device toggles persist the disabled device's name, so a
# non-empty file means the device is off.
input_disabled() {
  if [[ -s "$HYPR_TOGGLES/$1-disabled-name" ]]; then emit "input.$1" off; else emit "input.$1" on; fi
}

present() {
  if command -v "$1" >/dev/null 2>&1; then emit "has.$1" yes; else emit "has.$1" no; fi
}

# A hardware probe answers by exit status. Bound each one so a wedged check
# cannot hold the whole probe open.
hw() {
  if timeout 2s "omarchy-hw-$1" >/dev/null 2>&1; then emit "hw.$1" yes; else emit "hw.$1" no; fi
}

case "${1:-state}" in
  state)
    flag bar-off
    flag screensaver-off
    flag crash-capture-off
    flag suspend-off
    hypr_flag window-no-gaps
    hypr_flag single-window-aspect-ratio
    input_disabled touchpad
    input_disabled touchscreen

    # Only the two layouts Omarchy switches between are reported; anything
    # else is "unknown" rather than passed through.
    layout=$(timeout 2s hyprctl activeworkspace -j 2>/dev/null |
      jq -r '.tiledLayout // ""' 2>/dev/null)
    case "$layout" in
      dwindle | scrolling) emit workspace.layout "$layout" ;;
      *) emit workspace.layout unknown ;;
    esac

    # The theme name is a directory name written by omarchy-theme-set.
    theme=""
    if [[ -r "$STATE_DIR/current/theme.name" ]]; then
      read -r theme <"$STATE_DIR/current/theme.name" || theme=""
    fi
    [[ $theme =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || theme=""
    emit theme.current "$theme"
    ;;

  static)
    for part in laptop touchpad touchscreen webcam hybrid-gpu; do hw "$part"; done
    if timeout 2s omarchy-hibernation-available >/dev/null 2>&1; then
      emit hw.hibernate yes
    else
      emit hw.hibernate no
    fi
    for tool in hyprpicker omarchy-transcode omarchy-reminder omarchy-menu-share \
      omarchy-capture-text omarchy-capture-qr omarchy-capture-screenshot; do
      present "$tool"
    done

    # Theme directory names, not the display names the CLI prints: the name
    # is what `omarchy theme set` takes, and matching a printed label back to
    # a directory is guesswork. Capped, because a themes directory is a place
    # anyone can drop a folder.
    {
      find "$HOME/.config/omarchy/themes/" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -printf '%f\n' 2>/dev/null
      find "${OMARCHY_PATH:-/usr/share/omarchy}/themes/" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null
    } | grep -E '^[a-z0-9][a-z0-9-]{0,63}$' | sort -u | head -40 |
      while read -r name; do emit theme.available "$name"; done
    ;;

  binds)
    # Every binding on the system, so the card can say what already holds a
    # combination rather than only that something does. Read on demand, never
    # on a timer: it is the largest thing this script fetches, and the only
    # one whose size is set by something other than this script.
    #
    # Bounded here rather than after it has crossed into QML. Only the three
    # fields the card reads are passed through, the array is capped, and the
    # whole thing is capped again in bytes, so what the card parses is bounded
    # before it is allocated rather than after. Measured on this machine: 226
    # bindings, 101 KB whole, 14 KB projected.
    timeout 2s hyprctl -j binds 2>/dev/null |
      jq -c '[limit(600; .[] | {modmask, key, description})]' 2>/dev/null |
      head -c 262144 | grep . || echo "[]"
    ;;

  *)
    echo "usage: probe.sh [state|static|binds]" >&2
    exit 2
    ;;
esac
