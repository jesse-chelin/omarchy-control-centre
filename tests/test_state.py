#!/usr/bin/env python3
"""state.py against the hostile things it exists to refuse.

Each case builds the real thing on disk (a symlink, a FIFO, an oversized
file, a directory in the way) and checks the reader answers with a document
carrying a reason, never the content, and the writer refuses rather than
clobbers. The happy path checks the mode the file actually lands with.
"""
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
STATE = ROOT / 'state.py'
problems = []


def check(condition, message):
    if not condition:
        problems.append(message)


def read(path):
    out = subprocess.run([sys.executable, '-I', str(STATE), 'read', str(path)],
                         capture_output=True, text=True)
    return out.returncode, out.stdout


def write(path, payload):
    out = subprocess.run([sys.executable, '-I', str(STATE), 'write', str(path)],
                         input=payload, capture_output=True)
    return out.returncode


def rejected(output):
    try:
        return json.loads(output).get('rejected', '')
    except ValueError:
        return ''


with tempfile.TemporaryDirectory() as tmp:
    base = pathlib.Path(tmp)

    # Happy path: written 0600, read back verbatim.
    target = base / 'cc.json'
    check(write(target, b'{"version": 1, "tiles": []}') == 0, 'write of a valid document failed')
    mode = stat.S_IMODE(target.stat().st_mode)
    check(mode == 0o600, 'settings file landed with mode %o, expected 600' % mode)
    code, out = read(target)
    check(code == 0 and json.loads(out) == {'version': 1, 'tiles': []}, 'valid file was not read back')
    check(not list(base.glob('.control-centre.*.tmp')), 'temp file left behind after a write')

    # Missing file: a document with a reason, exit 0.
    code, out = read(base / 'missing.json')
    check(code == 0 and rejected(out) == 'no settings saved yet', 'missing file did not report cleanly')

    # Symlink: never followed on read, never replaced on write.
    secret = base / 'secret'
    secret.write_text('do not leak')
    link = base / 'link.json'
    link.symlink_to(secret)
    code, out = read(link)
    check('do not leak' not in out and 'symlink' in rejected(out), 'symlink was followed on read')
    check(write(link, b'{}') != 0, 'write through a symlink was accepted')
    check(secret.read_text() == 'do not leak', 'write through a symlink clobbered the target')

    # FIFO: must not hang, must be refused.
    fifo = base / 'fifo.json'
    os.mkfifo(fifo)
    try:
        code, out = read(fifo)
        check('regular file' in rejected(out), 'FIFO was not refused')
    except subprocess.TimeoutExpired:
        problems.append('FIFO hung the reader')

    # Oversized: refused whole, not truncated.
    big = base / 'big.json'
    big.write_bytes(b'{"a":"' + b'x' * 70000 + b'"}')
    code, out = read(big)
    check('larger than' in rejected(out), 'oversized file was not refused')
    check(write(big, b'{"a":"' + b'x' * 70000 + b'"}') != 0, 'oversized write was accepted')

    # Not UTF-8, not JSON, not an object.
    bad = base / 'bad.json'
    bad.write_bytes(b'\xff\xfe{')
    code, out = read(bad)
    check('UTF-8' in rejected(out), 'non UTF-8 file was not refused')
    check(write(base / 'w1.json', b'not json') != 0, 'non-JSON write was accepted')
    check(write(base / 'w2.json', b'[1,2]') != 0, 'non-object write was accepted')

    # Directory in the way of the path.
    blocker = base / 'dir.json'
    blocker.mkdir()
    check(write(blocker, b'{}') != 0, 'write over a directory was accepted')
    code, out = read(blocker)
    check('regular file' in rejected(out) or 'could not be opened' in rejected(out), 'directory was not refused on read')

    # Missing parent directory is created private.
    nested = base / 'state' / 'cc.json'
    check(write(nested, b'{}') == 0, 'write into a missing directory failed')
    dmode = stat.S_IMODE(nested.parent.stat().st_mode)
    check(dmode == 0o700, 'state directory landed with mode %o, expected 700' % dmode)

    # A symlinked directory is refused on both sides. The file is reached
    # through a descriptor on its own directory, so a directory swapped for a
    # link somewhere else cannot redirect either the read or the rename.
    real = base / 'real'
    real.mkdir(mode=0o700)
    link = base / 'link'
    link.symlink_to(real)
    code, out = read(link / 'cc.json')
    check('symlink' in rejected(out), 'a symlinked directory was not refused on read')
    check(write(link / 'cc.json', b'{}') != 0, 'a symlinked directory was accepted on write')
    check(not (real / 'cc.json').exists(), 'the write landed through the link anyway')

    # And no temp file is left behind by a refusal.
    leftovers = [f.name for f in base.iterdir() if f.name.endswith('.tmp')]
    check(leftovers == [], 'temp files were left behind: %s' % leftovers)

if problems:
    print('\n'.join(problems))
    sys.exit(1)
