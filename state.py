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
import secrets
import stat
import sys

MAX_BYTES = 65536


def open_parent(path):
    """The directory the file lives in, held open, and the file's own name.

    Every step after this one is relative to that descriptor rather than to a
    pathname, so the directory cannot be swapped between the check and the
    open, or between the write and the rename. O_NOFOLLOW refuses a symlinked
    directory outright: a settings file is not somewhere else.
    """
    absolute = os.path.abspath(path)
    directory = os.path.dirname(absolute) or "/"
    name = os.path.basename(absolute)
    if not name or name in (".", ".."):
        raise OSError("%s does not name a file" % path)
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(fd)
        if info.st_uid != os.getuid():
            raise OSError("%s is owned by another user" % directory)
    except OSError:
        os.close(fd)
        raise
    return fd, name


def log(message):
    sys.stderr.write("control-centre state: %s\n" % message)


def refuse_read(reason, detail=""):
    log(reason + (": " + detail if detail else ""))
    sys.stdout.write(json.dumps({"rejected": reason[:120]}))
    return 0


def read(path):
    try:
        dir_fd, name = open_parent(path)
    except FileNotFoundError:
        return refuse_read("no settings saved yet")
    except OSError as error:
        # O_NOFOLLOW with O_DIRECTORY answers ENOTDIR for a symlink on Linux,
        # because the directory test runs after the link is refused. Both mean
        # the same thing here: what is at that name is not a directory this
        # will open.
        if getattr(error, "errno", None) in (errno.ELOOP, errno.ENOTDIR):
            return refuse_read("its directory is a symlink, which is never followed", path)
        return refuse_read("its directory could not be opened", "%s: %s" % (path, error))

    try:
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                         dir_fd=dir_fd)
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
    finally:
        os.close(dir_fd)

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
        dir_fd, name = open_parent(path)
    except OSError as error:
        return refuse_write(str(error))

    payload = (json.dumps(document, indent=2, sort_keys=False) + "\n").encode("utf-8")
    temp = ".control-centre.%s.tmp" % secrets.token_hex(8)
    try:
        # A symlink at the name is never replaced. os.replace would swap the
        # link itself, which is harmless, but a link left there is a sign that
        # something else is arranging the directory, and the answer is no.
        try:
            existing = os.lstat(name, dir_fd=dir_fd)
        except FileNotFoundError:
            existing = None
        if existing is not None and not stat.S_ISREG(existing.st_mode):
            return refuse_write("%s is not a regular file" % path)

        # Unpredictable name, created exclusively, mode set at creation, and
        # every step relative to the directory opened above.
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                     0o600, dir_fd=dir_fd)
        try:
            os.write(fd, payload)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.rename(temp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        os.fsync(dir_fd)
    except OSError as error:
        try:
            os.unlink(temp, dir_fd=dir_fd)
        except OSError:
            pass
        return refuse_write("could not write %s: %s" % (path, error))
    finally:
        os.close(dir_fd)
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
