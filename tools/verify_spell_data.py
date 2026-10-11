#!/usr/bin/env python3
"""Check mez.lua's SPELLS table against the game's spells_us.txt.

    python tools/verify_spell_data.py [path/to/spells_us.txt]

The path defaults to $SPELLS_US, then to the RatQuest patch location used while the
plugin was written. The file is the client's spell database: one spell per line,
fields separated by '^'. Field positions used here (0-based), all verified against
real rows:

    0   spell id                       1   name
    13  cast time in milliseconds      17  buff duration in ticks
    86-97   the 12 effect ids (SPA); 31 is Mesmerize, 254 is "no effect"
    7   the text printed after the mob's name when the spell lands ("cast on other")
    44-55   the 12 effect base values; for Mesmerize this is the highest mob level it works on
    98  target type: 5 single target, 8 area around the target, 4 area around the caster,
        10 undead only, 11 summoned only
    104-119 class levels in the order WAR CLR PAL RNG SHD DRU MNK BRD ROG SHM NEC WIZ MAG ENC BST BER
        (255 or 0 = the class cannot cast it)

Exit status is 0 only when every row of the table checks out.
"""
import collections
import os
import re
import sys

DEFAULT = r'C:\Users\Public\RatQuest\RatQuestPatch\files\Resources\spells_us.txt'
CLASSES = ['WAR', 'CLR', 'PAL', 'RNG', 'SHD', 'DRU', 'MNK', 'BRD', 'ROG', 'SHM', 'NEC', 'WIZ', 'MAG', 'ENC', 'BST', 'BER']
ENC = CLASSES.index('ENC')
HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, '..', 'mez.lua')


def table_rows():
    text = open(PLUGIN, encoding='utf-8').read()
    rows = []
    for m in re.finditer(r"^\s*\{ name = '([^']+)',(.*)\},\s*$", text, re.M):
        name, rest = m.group(1), m.group(2)
        supported = 'supported = true' in rest
        lvl = re.search(r'maxMobLevel = (\d+)', rest)
        cast = re.search(r'castSec = ([\d.]+)', rest)
        landed = re.search(r"landed = (?:'([^']*)'|\"([^\"]*)\")", rest)
        rows.append({'name': name, 'supported': supported,
                     'maxMobLevel': int(lvl.group(1)) if lvl else None,
                     'castSec': float(cast.group(1)) if cast else None,
                     'landed': (landed.group(1) if landed.group(1) is not None else landed.group(2)) if landed else None})
    return rows


def load_spells(path):
    byname = collections.defaultdict(list)
    allrows = []
    with open(path, encoding='latin-1') as f:
        for line in f:
            p = line.rstrip('\n').split('^')
            if len(p) > 130:
                byname[p[1]].append(p)
                allrows.append(p)
    return byname, allrows


def effects(r):
    return [int(x) for x in r[86:98] if x.lstrip('-').isdigit()]


def enc_level(r):
    v = r[104 + ENC]
    return int(v) if v.lstrip('-').isdigit() and 0 < int(v) < 255 else 0


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('SPELLS_US', DEFAULT)
    if not os.path.exists(path):
        print('spells_us.txt not found: %s\n(pass the path, or set SPELLS_US)' % path)
        return 2
    byname, allrows = load_spells(path)
    rows = table_rows()
    if not rows:
        print('could not read the SPELLS table from mez.lua')
        return 2

    bad = 0
    print('%-26s %-12s %-5s %-6s %-6s %-6s %s' % ('spell', 'status', 'ENC', 'target', 'cap', 'cast', 'result'))
    known = set()
    for r in rows:
        known.add(r['name'])
        cands = [s for s in byname.get(r['name'], []) if enc_level(s) > 0]
        if not cands:
            print('%-26s %-12s %s' % (r['name'], 'supported' if r['supported'] else 'refused', 'MISSING (no Enchanter spell by that name)'))
            bad += 1
            continue
        s = cands[0]
        eff = effects(s)
        slot = eff.index(31) if 31 in eff else None
        base = s[44 + slot] if slot is not None else '-'
        tt, cast = s[98], s[13]
        problems = []
        if slot is None:
            problems.append('no Mesmerize effect')
        if r['supported']:
            if tt != '5':
                problems.append('target type %s, expected 5' % tt)
            if r['maxMobLevel'] is None or str(r['maxMobLevel']) != base:
                problems.append('level cap %s vs file %s' % (r['maxMobLevel'], base))
            if r['castSec'] is None or str(int(round(r['castSec'] * 1000))) != cast:
                problems.append('cast %s s vs file %s ms' % (r['castSec'], cast))
            if r['landed'] != s[7]:
                problems.append('landed text %r vs file %r' % (r['landed'], s[7]))
        else:
            if r['name'] != 'Echoing Madness' and tt not in ('4', '8'):
                problems.append('refused as an area mez but target type is %s' % tt)
        bad += 1 if problems else 0
        print('%-26s %-12s %-5d %-6s %-6s %-6s %s' % (r['name'], 'supported' if r['supported'] else 'refused', enc_level(s), tt,
                                                     base, cast, 'OK' if not problems else '; '.join(problems)))

    # Enchanter mezzes in the file that the table does not mention
    extra_low, extra_high = [], 0
    seen = set()
    for s in allrows:
        if 31 in effects(s) and enc_level(s) > 0 and s[1] not in known and s[1] not in seen:
            seen.add(s[1])
            if enc_level(s) <= 70:
                extra_low.append((s[1], enc_level(s), s[98]))
            else:
                extra_high += 1
    print()
    if extra_low:
        print('WARNING: Enchanter spells with the Mesmerize effect, level 70 or lower, that the table does not list:')
        for n, l, tt in sorted(extra_low, key=lambda x: x[1]):
            print('  %-28s level %-3d target type %s' % (n, l, tt))
        bad += len(extra_low)
    else:
        print('No other Enchanter spell with the Mesmerize effect at level 70 or lower.')
    if extra_high:
        print('Info: %d more Enchanter spell names with the Mesmerize effect are above level 70 (not in the table; the server list stops at 70).' % extra_high)
    print('\n%s' % ('ALL ROWS VERIFIED' if bad == 0 else '%d problem(s)' % bad))
    return 0 if bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
