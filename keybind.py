#!/usr/bin/python3 -I
"""Own one clearly marked block in the user's Hyprland bindings file.

This is the only thing the plugin writes outside its own state, and it is the
user's window manager config, so the rules are strict:

  * the combination is re-validated here against a fixed grammar, whatever the
    caller claims to have checked. It is the only value that varies, and it is
    the one thing a user typed.
  * only the block between the two markers is ever touched. Everything else in
    the file is copied through byte for byte.
  * the file is read with O_NOFOLLOW under a size cap, written to a private
    temp file in the same directory, fsynced, and renamed into place, so an
    interrupted write cannot leave a half-written config that Hyprland then
    fails to parse.
  * a copy of the previous contents is kept beside it the first time, so there
    is always a way back that does not involve this program.

    keybind.py show <path>              print the managed combination, if any
    keybind.py set <path> "SUPER + I"   write or replace the block
    keybind.py clear <path>             remove the block

Isolated mode in the shebang (-I) ignores PYTHON* variables and the user site
directory, so nothing in the environment can inject code into this process.
"""

import errno
import os
import re
import stat
import sys
import tempfile

MAX_BYTES = 512 * 1024
PLUGIN_ID = "io.github.jesse-chelin.control-centre"
DESCRIPTION = "Control Centre"
BEGIN = "-- >>> Control Centre plugin: managed keybinding >>>"
END = "-- <<< Control Centre plugin: managed keybinding <<<"
NOTE = (
    "-- Written by the Control Centre plugin. Change it from the card's",
    "-- settings, or delete these five lines to be rid of it.",
)
# Every note line any version of this has written. Recognising the older
# wording is what stops an upgrade leaving a stale comment and a second copy
# of the binding behind in a file that already had the block.
KNOWN_NOTES = frozenset(NOTE) | {
    "-- settings, or delete these three lines to be rid of it.",
}

MODS = ("SUPER", "CTRL", "ALT", "SHIFT")
NAMED_KEYS = {
    "BACKSLASH", "SLASH", "PERIOD", "COMMA", "SEMICOLON", "APOSTROPHE",
    "BRACKETLEFT", "BRACKETRIGHT", "MINUS", "EQUAL", "GRAVE", "SPACE",
    "RETURN", "TAB", "BACKSPACE", "DELETE", "INSERT", "HOME", "END",
    "PRIOR", "NEXT", "UP", "DOWN", "LEFT", "RIGHT", "PRINT",
}


def fail(reason):
    sys.stderr.write("control-centre keybind: %s\n" % reason)
    sys.stdout.write(reason)
    return 1


def valid_combo(combo):
    """One shape only, and every part named in a list in this file."""
    if not re.match(r"^[A-Z0-9 +]{3,60}$", combo or ""):
        return False
    parts = combo.split(" + ")
    if len(parts) < 2:
        return False
    key = parts.pop()
    seen = set()
    for part in parts:
        if part not in MODS or part in seen:
            return False
        seen.add(part)
    if len(key) == 1:
        return "A" <= key <= "Z"
    if re.match(r"^F([1-9]|1[0-2])$", key):
        return True
    return key in NAMED_KEYS


def read_config(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        return "", None
    except OSError as error:
        if getattr(error, "errno", None) == errno.ELOOP:
            raise OSError("the bindings file is a symlink, which is never followed")
        raise OSError("the bindings file could not be opened: %s" % error)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise OSError("the bindings file is not a regular file")
        if info.st_uid != os.getuid():
            raise OSError("the bindings file is owned by another user")
        if info.st_size > MAX_BYTES:
            raise OSError("the bindings file is larger than %d bytes" % MAX_BYTES)
        raw = os.read(fd, MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            raise OSError("the bindings file grew while being read")
    finally:
        os.close(fd)
    try:
        return raw.decode("utf-8"), stat.S_IMODE(info.st_mode)
    except UnicodeDecodeError:
        raise OSError("the bindings file is not valid UTF-8")


def strip_block(text):
    """Everything except the managed block, and what the block held.

    The block is recognised by its own shape rather than by "everything up to
    the end marker": the two markers and the three lines between them are
    literals this program writes, so a line that is none of them is the user's,
    whatever it sits between. That is what makes a file whose end marker has
    been edited away cost the user nothing. Reading to the end marker instead
    reads the rest of someone's config as block contents and drops it, which is
    every binding they have below the block.
    """
    kept, held, inside = [], "", False
    for line in text.split("\n"):
        stripped = line.strip()
        # Both markers are ours wherever they appear, so a stray one left by a
        # half-finished edit is cleaned up rather than left to swallow a block.
        if stripped == BEGIN:
            inside = True
            continue
        if stripped == END:
            inside = False
            continue
        if inside:
            if stripped in KNOWN_NOTES:
                continue
            match = BIND_LINE.match(stripped)
            if match:
                held = match.group(1)
                continue
            # Not a line this wrote: the block ended without saying so.
            inside = False
        kept.append(line)
    return "\n".join(kept), held


def other_bindings(text):
    """Lines outside the block that bind this same plugin, which would fire too."""
    found = []
    for number, line in enumerate(text.split("\n"), start=1):
        stripped = line.strip()
        if stripped.startswith("--"):
            continue
        if PLUGIN_ID in stripped and "bind" in stripped:
            found.append(number)
    return found


def write_config(path, text, mode):
    directory = os.path.dirname(os.path.abspath(path)) or "."
    backup = path + ".before-control-centre"
    if not os.path.exists(backup) and os.path.exists(path):
        with open(path, "rb") as source:
            existing = source.read(MAX_BYTES + 1)
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, existing)
            os.fsync(fd)
        finally:
            os.close(fd)

    fd, temp = tempfile.mkstemp(prefix=".control-centre-bind.", suffix=".tmp", dir=directory)
    try:
        os.write(fd, text.encode("utf-8"))
        os.fsync(fd)
        os.fchmod(fd, mode if mode is not None else 0o644)
        os.close(fd)
        fd = -1
        os.replace(temp, path)
        dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError as error:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temp)
        except OSError:
            pass
        raise OSError("could not write the bindings file: %s" % error)


def bind_line(combo):
    return 'o.bind("%s", "%s", "omarchy-shell shell toggle %s")' % (combo, DESCRIPTION, PLUGIN_ID)


# The same line bind_line writes, with the combination left open. Kept beside
# it, and pinned to it by tests/test_keybind.py so the two cannot drift.
BIND_LINE = re.compile(
    r'^o\.bind\("([A-Z0-9 +]{3,60})", "%s", "omarchy-shell shell toggle %s"\)$'
    % (re.escape(DESCRIPTION), re.escape(PLUGIN_ID))
)


def block_for(combo):
    return "\n".join([BEGIN] + list(NOTE) + [bind_line(combo), END])


def main(argv):
    if len(argv) < 3 or argv[1] not in ("show", "set", "clear"):
        return fail('usage: keybind.py show|set|clear <path> ["SUPER + KEY"]')
    action, path = argv[1], argv[2]

    try:
        text, mode = read_config(path)
    except OSError as error:
        return fail(str(error))

    body, held = strip_block(text)

    if action == "show":
        sys.stdout.write(held)
        return 0

    if action == "set":
        if len(argv) != 4:
            return fail("no combination given")
        combo = argv[3]
        if not valid_combo(combo):
            return fail("that is not a combination this can write")
        body = body.rstrip("\n")
        text = body + "\n\n" + block_for(combo) + "\n"
    else:
        text = body.rstrip("\n") + "\n"

    try:
        write_config(path, text, mode)
    except OSError as error:
        return fail(str(error))

    # Checked against the file without the managed block, or the block's own
    # line answers, and every write warns about itself.
    # Said on stdout because a caller that ignores it still gets a working
    # binding: this is a warning, not a failure.
    duplicates = other_bindings(body)
    if duplicates:
        sys.stdout.write("also bound outside this block on line %s"
                         % ", ".join(str(n) for n in duplicates))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
