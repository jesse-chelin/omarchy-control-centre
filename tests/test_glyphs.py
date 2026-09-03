#!/usr/bin/env python3
"""Every Nerd Font glyph in the source exists and depicts what it claims.

JavaScript escapes take four hex digits and Nerd Font codepoints take five,
so the glyphs are embedded literally. That makes a wrong one invisible in
review: it is a single character that renders as something else entirely.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# codepoint -> what it must depict, checked by eye once and pinned here.
# Every one is the glyph the stock shell uses for the same thing, so a user
# recognises it from the bar.
EXPECTED = {
    0xF0928: 'md-wifi_strength_4, full signal',
    0xF0925: 'md-wifi_strength_3',
    0xF0922: 'md-wifi_strength_2',
    0xF091F: 'md-wifi_strength_1',
    0xF092F: 'md-wifi_strength_outline, no signal',
    0xF092E: 'md-wifi_strength_off, radio off',
    0xF0200: 'md-ethernet',
    0xF00AF: 'md-bluetooth',
    0xF00B1: 'md-bluetooth_connect',
    0xF00B2: 'md-bluetooth_off',
    0xF009B: 'md-bell_off, do not disturb (stock Dnd indicator)',
    0xF050E: 'md-theme_light_dark, night light (stock NightLight indicator)',
    0xF0176: 'md-coffee, stay awake (stock StayAwake indicator)',
    0xF0EC2: 'md-record_rec, screen recording (stock ScreenRecording indicator)',
    0xF036C: 'md-microphone',
    0xF036D: 'md-microphone_off',
    0xF057E: 'md-volume_high',
    0xF0580: 'md-volume_medium',
    0xF057F: 'md-volume_low',
    0xF075F: 'md-volume_mute',
    0xF02CB: 'md-headphones',
    0xF00E0: 'md-brightness_7, sun',
    0xF040A: 'md-play',
    0xF03E4: 'md-pause',
    0xF04AD: 'md-skip_next',
    0xF04AE: 'md-skip_previous',
    0xF075A: 'md-music_note, media placeholder',
    0xF033E: 'md-lock',
    0xF04B2: 'md-power_sleep, the stock menu Suspend glyph',
    0xF1104: 'md-monitor_shimmer, the stock menu Screensaver glyph',
    0xF0493: 'md-cog, settings gear',
    0xF0142: 'md-chevron_right',
    0xF0141: 'md-chevron_left',
    0xF012C: 'md-check, done',
    0xF032A: 'md-leaf, power-saver profile',
    0xF029A: 'md-scale_balance, balanced profile',
    0xF04C5: 'md-speedometer, performance profile',
    0xF0084: 'md-battery_charging, unknown profile fallback',
    0xF0450: 'md-refresh, busy spinner',
    0xF062E: 'md-tune, the bar pill (sliders)',
    0xF007A: 'md-battery_10', 0xF007B: 'md-battery_20', 0xF007C: 'md-battery_30',
    0xF007D: 'md-battery_40', 0xF007E: 'md-battery_50', 0xF007F: 'md-battery_60',
    0xF0080: 'md-battery_70', 0xF0081: 'md-battery_80', 0xF0082: 'md-battery_90',
    0xF0079: 'md-battery, full',
    0xF089C: 'md-battery_charging_10', 0xF0086: 'md-battery_charging_20',
    0xF0087: 'md-battery_charging_30', 0xF0088: 'md-battery_charging_40',
    0xF089D: 'md-battery_charging_50', 0xF0089: 'md-battery_charging_60',
    0xF089E: 'md-battery_charging_70', 0xF008A: 'md-battery_charging_80',
    0xF008B: 'md-battery_charging_90', 0xF0085: 'md-battery_charging_100',
}
PRIVATE_USE = [(0xE000, 0xF8FF), (0xF0000, 0xFFFFD), (0x100000, 0x10FFFD)]


def is_private_use(cp):
    return any(lo <= cp <= hi for lo, hi in PRIVATE_USE)


def nerd_font_installed():
    out = subprocess.run(['fc-list', ':', 'family'], capture_output=True, text=True).stdout
    return 'Nerd Font' in out


def font_covers(cp):
    out = subprocess.run(['fc-list', ':charset=%X' % cp, 'family'],
                         capture_output=True, text=True).stdout
    return 'Nerd Font' in out


def main():
    problems = []
    found = set()
    check_coverage = nerd_font_installed()
    if not check_coverage:
        sys.stderr.write('note: no Nerd Font installed, skipped the coverage check\n')
    sources = sorted(list(ROOT.glob('*.qml')) + list(ROOT.glob('Tiles/*.qml')) + list(ROOT.glob('*.js')))
    for path in sources:
        for number, line in enumerate(path.read_text(encoding='utf-8').split('\n'), start=1):
            for char in line:
                cp = ord(char)
                if not is_private_use(cp):
                    continue
                found.add(cp)
                if cp not in EXPECTED:
                    problems.append('%s:%d: glyph U+%X is not pinned in test_glyphs.py'
                                    % (path.name, number, cp))
                elif check_coverage and not font_covers(cp):
                    problems.append('%s:%d: no installed Nerd Font carries U+%X'
                                    % (path.name, number, cp))
    for cp in EXPECTED:
        if cp not in found:
            problems.append('U+%X is pinned in test_glyphs.py but no longer used' % cp)
    if problems:
        print('\n'.join(problems))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
