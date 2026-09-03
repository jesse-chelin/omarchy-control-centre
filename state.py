#!/usr/bin/python3 -I
"""Read or write the Control Centre settings file, bounded on both sides.

The file lives in a directory the user can write and is read by a process
that lives as long as the session, so nothing here trusts it. Reading opens
with O_NOFOLLOW, refuses anything that is not a regular file owned by this
user, and never hands back more than MAX_BYTES. Writing goes through a
temp file created O_EXCL with mode 0600, fsyncs it, renames it over the
path and fsyncs the directory, and refuses to replace a symlink.

    state.py read <path>      prints the file, or {"rejected": reason}
    state.py write <path>     writes stdin (a JSON object) to <path>

Every refusal on the read side is a JSON document with a reason, exit 0: a
Control Centre that opens on defaults and says why beats one that will not
open. The write side exits non-zero on refusal, because a settings change
that did not land should be reported, not assumed.

Isolated mode (-I) ignores PYTHON* variables and the user site directory, so
the invoking environment cannot inject code into this process.
"""

import errno
import json
import os
import stat
import sys
import tempfile

MAX_BYTES = 65536


def log(message):
    sys.stderr.write("control-centre state: %s\n" % message)


def refuse_read(reason, detail=""):
    log(reason + (": " + detail if detail else ""))
    sys.stdout.write(json.dumps({"rejected": reason[:120]}))
    return 0


def read(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        return refuse_read("no settings saved yet")
    except OSError as error:
        if getattr(error, "errno", None) == errno.ELOOP:
            return refuse_read("it is a symlink, which is never followed", path)
        return refuse_read("it could not be opened", "%s: %s" % (path, error))

    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return refuse_read("it is not a regular file", path)
        if info.st_uid != os.getuid():
            return refuse_read("it is owned by another user", path)
        if info.st_size > MAX_BYTES:
            return refuse_read("it is larger than %d bytes" % MAX_BYTES, path)
        raw = os.read(fd, MAX_BYTES + 1)
        if len(raw) > MAX_BYTES:
            return refuse_read("it grew past %d bytes while being read" % MAX_BYTES, path)
    finally:
        os.close(fd)

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return refuse_read("it is not valid UTF-8", path)

    sys.stdout.write(text)
    return 0


def refuse_write(reason):
    log("write refused, " + reason)
    return 1


def ensure_private_dir(directory):
    """The state directory, created 0700 if missing, refused if it is not ours."""
    try:
        os.mkdir(directory, 0o700)
    except FileExistsError:
        pass
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode):
        raise OSError("%s is not a directory" % directory)
    if info.st_uid != os.getuid():
        raise OSError("%s is owned by another user" % directory)


def write(path):
    raw = sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        return refuse_write("document larger than %d bytes" % MAX_BYTES)
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        return refuse_write("document is not JSON: %s" % error)
    if not isinstance(document, dict):
        return refuse_write("document is not an object")

    directory = os.path.dirname(os.path.abspath(path)) or "."
    try:
        ensure_private_dir(directory)
    except OSError as error:
        return refuse_write(str(error))

    # A symlink at the path is never replaced: os.replace would swap the link
    # itself, which is harmless, but a link left there is a sign that
    # something else is arranging the directory, and the safe answer is no.
    try:
        existing = os.lstat(path)
    except FileNotFoundError:
        existing = None
    if existing is not None and not stat.S_ISREG(existing.st_mode):
        return refuse_write("%s is not a regular file" % path)

    payload = (json.dumps(document, indent=2, sort_keys=False) + "\n").encode("utf-8")
    # mkstemp creates O_EXCL with mode 0600, so the mode is right from the
    # first byte rather than fixed after the fact.
    fd, temp_path = tempfile.mkstemp(prefix=".control-centre.", suffix=".tmp", dir=directory)
    try:
        os.write(fd, payload)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temp_path, path)
        dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError as error:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        return refuse_write("could not write %s: %s" % (path, error))
    return 0


def main(argv):
    if len(argv) != 3 or argv[1] not in ("read", "write"):
        log("usage: state.py read|write <path>")
        return 2
    if argv[1] == "read":
        return read(argv[2])
    return write(argv[2])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
