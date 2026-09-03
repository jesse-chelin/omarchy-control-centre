#!/usr/bin/env python3
"""keybind.py against the file it is trusted with.

This is the only thing the plugin writes outside its own state, and it is the
user's window manager config: a bad write costs them their keyboard. Each case
builds the real thing on disk and checks the refusal, the repair, or the byte
that had to survive.
"""
import os
import pathlib
import stat
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOL = ROOT / "keybind.py"
sys.path.insert(0, str(ROOT))
import keybind  # noqa: E402  the markers and the line shape, from the source of truth

BEGIN = keybind.BEGIN
END = keybind.END
NOTE = "\n".join(keybind.NOTE)
problems = []


def check(condition, message):
    if not condition:
        problems.append(message)


def run(*args):
    out = subprocess.run([sys.executable, "-I", str(TOOL)] + list(args),
                         capture_output=True, text=True)
    return out.returncode, out.stdout


ORIGINAL = '-- my own bindings\nhl.unbind("SUPER + SPACE")\no.bind("SUPER + Q", "Quit", "true")\n'

with tempfile.TemporaryDirectory() as tmp:
    base = pathlib.Path(tmp)
    path = base / "bindings.lua"
    path.write_text(ORIGINAL)

    # Writing, reading back, and replacing.
    check(run("set", str(path), "SUPER + BACKSLASH")[0] == 0, "a valid combination was refused")
    check(run("show", str(path))[1] == "SUPER + BACKSLASH", "the written combination did not read back")
    check(run("set", str(path), "SUPER + CTRL + I")[0] == 0, "replacing failed")
    check(run("show", str(path))[1] == "SUPER + CTRL + I", "replacing did not take")
    text = path.read_text()
    check(text.count("Control Centre plugin: managed keybinding >>>") == 1,
          "replacing left a second block behind")

    # Everything the user wrote survives, byte for byte.
    for line in ORIGINAL.strip().split("\n"):
        check(line in text, "a line of the user's own config was lost: %r" % line)

    # And removing it puts the file back exactly as it was.
    check(run("clear", str(path))[0] == 0, "clearing failed")
    check(path.read_text() == ORIGINAL, "clearing did not restore the original file")
    backup = base / "bindings.lua.before-control-centre"
    check(backup.exists(), "no backup was kept")
    # It holds the file as it was, and it is written private from the first
    # byte: the point of it is being the way back when this got it wrong.
    check(backup.read_text() == ORIGINAL, "the backup is not the file as it was")
    check(stat.S_IMODE(backup.stat().st_mode) == 0o600, "the backup is not private")
    # And it is kept, not refreshed: a backup that tracks the file is not one.
    run("set", str(path), "SUPER + F5")
    check(backup.read_text() == ORIGINAL, "the backup was overwritten by a later write")

    # Nothing that is not a combination gets written.
    for hostile in ("SUPER", "HYPER + A", "SUPER + SUPER + A", "A",
                    'SUPER + ")); os.execute("rm -rf ~", "', "SUPER + A; reboot",
                    "SUPER + \n + A", "super + a", "", "SUPER + " + "A" * 80):
        before = path.read_text()
        code, _ = run("set", str(path), hostile)
        check(code != 0, "a hostile combination was accepted: %r" % hostile)
        check(path.read_text() == before, "a refused write still changed the file: %r" % hostile)

    # A binding the user added by hand is reported, not removed.
    path.write_text(ORIGINAL + 'o.bind("SUPER + I", "Mine", "omarchy-shell shell toggle '
                    'io.github.jesse-chelin.control-centre")\n')
    code, out = run("set", str(path), "SUPER + BACKSLASH")
    check(code == 0, "writing alongside a hand-made binding failed")
    check("also bound outside this block" in out, "a duplicate binding was not reported")
    check('o.bind("SUPER + I", "Mine"' in path.read_text(),
          "the user's own binding was removed rather than reported")
    # And the block itself never counts as a duplicate of itself.
    path.write_text(ORIGINAL)
    code, out = run("set", str(path), "SUPER + BACKSLASH")
    check("also bound" not in out, "the managed block reported itself as a duplicate")

    # Half a block, left by someone editing the file, is repaired rather than
    # doubled or spread.
    path.write_text(ORIGINAL + "\n" + BEGIN + "\n"
                    + keybind.bind_line("SUPER + Z") + "\n")
    check(run("set", str(path), "SUPER + BACKSLASH")[0] == 0, "an unterminated block was not repaired")
    check(path.read_text().count('o.bind("SUPER + Z"') == 0, "an unterminated block was left behind")

    # And the block a missing end marker leaves behind reaches only the lines
    # this wrote. Everything below a stray marker is the user's file, and
    # reading to the end of it was once how every binding under the block went
    # away: the case above cannot show that, because nothing follows it.
    below = 'o.bind("SUPER + B", "Browser", "chromium")\no.bind("SUPER + M", "Music", "true")\n'
    half = ORIGINAL + "\n" + BEGIN + "\n" + NOTE + "\n" + keybind.bind_line("SUPER + Z") + "\n" + below

    path.write_text(half)
    check(run("clear", str(path))[0] == 0, "clear over an unterminated block failed")
    after = path.read_text()
    check('o.bind("SUPER + B"' in after and 'o.bind("SUPER + M"' in after,
          "clear over an unterminated block ate the bindings below it")
    check(ORIGINAL in after, "clear over an unterminated block lost the file above it")
    check(BEGIN not in after and NOTE not in after and 'o.bind("SUPER + Z"' not in after,
          "clear left part of an unterminated block behind")

    path.write_text(half)
    check(run("set", str(path), "SUPER + BACKSLASH")[0] == 0, "set over an unterminated block failed")
    after = path.read_text()
    check('o.bind("SUPER + B"' in after and 'o.bind("SUPER + M"' in after,
          "set over an unterminated block ate the bindings below it")
    check(ORIGINAL in after, "set over an unterminated block lost the file above it")
    check(after.count(BEGIN) == 1 and after.count(END) == 1,
          "set over an unterminated block did not leave exactly one block")
    check('o.bind("SUPER + Z"' not in after, "set left the old managed binding behind")
    check(run("show", str(path))[1] == "SUPER + BACKSLASH",
          "the repaired block did not read back")

    # A stray end marker on its own is this plugin's line too, and is cleaned
    # up rather than left where it can swallow the next block.
    path.write_text(ORIGINAL + END + "\n")
    check(run("clear", str(path))[0] == 0, "a stray end marker was not handled")
    check(END not in path.read_text(), "a stray end marker was left behind")
    check(ORIGINAL in path.read_text(), "a stray end marker took the file with it")

    # The pattern that recognises the managed line has to match the line the
    # writer actually writes; they are two literals that can drift apart.
    check(keybind.BIND_LINE.match(keybind.bind_line("SUPER + BACKSLASH")) is not None,
          "the writer and the reader of the managed line disagree")

    # A symlink is never followed, and the target is untouched.
    secret = base / "elsewhere.lua"
    secret.write_text("-- do not touch\n")
    link = base / "link.lua"
    link.symlink_to(secret)
    code, out = run("set", str(link), "SUPER + BACKSLASH")
    check(code != 0 and "symlink" in out, "a symlink was followed")
    check(secret.read_text() == "-- do not touch\n", "writing through a symlink changed the target")

    # A file too big to be a bindings file is refused rather than read.
    big = base / "big.lua"
    big.write_text("-- x\n" * 200000)
    code, out = run("set", str(big), "SUPER + BACKSLASH")
    check(code != 0 and "larger than" in out, "an oversized file was not refused")

    # A missing file is written from nothing rather than failing.
    fresh = base / "fresh.lua"
    check(run("set", str(fresh), "SUPER + BACKSLASH")[0] == 0, "a missing bindings file was not created")
    check("Control Centre" in fresh.read_text(), "the new file has no binding in it")
    mode = stat.S_IMODE(fresh.stat().st_mode)
    check(mode == 0o644, "the bindings file landed with mode %o, expected 644" % mode)
    check(not list(base.glob(".control-centre-bind.*")), "a temp file was left behind")

if problems:
    print("\n".join(problems))
    sys.exit(1)
