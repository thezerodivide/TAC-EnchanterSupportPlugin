#!/usr/bin/env python3
"""Break mez.lua on purpose and confirm the tests notice.

    python tools/mutation_check.py

For each mutation: copy mez.lua with one rule broken into a scratch copy of the repo, run
`luajit tests/run.lua` there, and report whether the run failed. A mutation that still
passes means a rule has no test (or a weak one). Needs `luajit` on the PATH.
Exit status is 0 only when every mutation is caught.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
SRC = open(os.path.join(ROOT, 'mez.lua'), encoding='utf-8', newline='').read().replace('\r\n', '\n')

MUTATIONS = [
    # decision
    ('the Main Assist is not excluded', "elseif id == maId then", "elseif false then"),
    ('damaged protection is off by default', "settings.damagedProtection ~= false", "settings.damagedProtection == true"),
    ('refresh boundary > becomes >=', "> refreshAt then", ">= refreshAt then"),
    ('stale peers still protect their target', "if p.fresh == true and p.engaged == true", "if p.engaged == true"),
    ('an unknown Main Assist target is trusted', "ma.status ~= 'target' or maId <= 0", "maId <= 0"),
    ('farthest becomes nearest', "d > bestDist or", "d < bestDist or"),
    ('an unknown distance ranks first', "local d = tonumber(m.dist) or -1", "local d = tonumber(m.dist) or math.huge"),
    # collection and tracking
    ('listed duration no longer caps a record', "remaining = math.min(remaining, last + info.durationSec - now)", "remaining = remaining"),
    ('a fresh cast is never pending', "local pending = last ~= nil and (now - last) < ((info.castSec or 2.5) + 0.5)", "local pending = false"),
    ('a failed cast is never matched to a mob', "if gap <= 3.0 and", "if false and"),
    ('the same failure is handled every tick', "if seen and seen.at == at and seen.spell == spell then return nil end", "if false then return nil end"),
    ('the selector cache ignores the spell', "if serial and cache.serial == serial and cache.spell == spellName and cache.result then",
     "if serial and cache.serial == serial and cache.result then"),
    ('peers are all marked stale', "peers[#peers + 1] = { fresh = true,", "peers[#peers + 1] = { fresh = false,"),
    ('an unknown Main Assist is treated as a target', "if id and id > 0 then ma.status, ma.id = 'target', id end", "ma.status, ma.id = 'target', (id or 999)"),
    ('the damaged setting is ignored', "settings = { damagedProtection = cfg.damagedProtection },", "settings = { damagedProtection = false },"),
    ('the selector is never unregistered', "pcall(core.unregisterTargetSelector, SELECTOR_LABEL, plugin.id)", "local _ = 0"),
    ('a fresh no-target heartbeat is treated as unknown', "        ma.source = 'boxnet'\n        ma.status = 'none'\n    else", "        ma.source = 'boxnet'\n        ma.status = 'unknown'\n    else"),
    # debug trace
    ('the trace repeats an unchanged input', "if input ~= traced.input then", "if true then"),
    ('the trace repeats an unchanged pick', "if pick ~= traced.pick then", "if true then"),
    ('the trace names the wrong Main Assist source', "(ma.source == 'boxnet' and 'Box Network feed' or '/assist peek')", "'Box Network feed'"),
    ('non-mez casts are traced as mez casts', "if at and spellInfo(spell) then", "if at then"),
    ('a cast is traced every tick', "if seen[key] ~= at then", "if true then"),
    ('a cleared record is not traced', "if cleared then trace(", "if false then trace("),
    # mez messages
    ('a landing message counts at any time after the cast', "age >= -1 and age <= LANDING_WINDOW_SEC", "age >= -1"),
    ('mob names are compared case-sensitively', "a:lower() == b:lower()", "a == b"),
    ('two same-named recent casts are not ambiguous', "if found then return nil, 'ambiguous' end", "if false then return nil, 'ambiguous' end"),
    ('a cast can be confirmed twice', "and (confirmed or {})[castKey(r.mobId, r.spell)] ~= r.castAt then", "then"),
    ('two same-named mezzed mobs are not ambiguous', "if mobId and mobId ~= r.mobId then return nil, 'ambiguous' end", "if false then return nil, 'ambiguous' end"),
    ('an expired record still matches an end message', "(r.expiry or 0) > now and", "true and"),
    ('an end message does not drop the record', "if rt.npcSpellApplied and rt.npcSpellApplied[mobId] then rt.npcSpellApplied[mobId][sp] = nil end", "local _ = 0"),
    ('another spell wearing off drops a mez record', "if spell and not info then return end          -- worn off: some other spell", ""),
    ('a landing message does not mark the cast confirmed', "confirmed[castKey(r.mobId, r.spell)] = r.castAt", "local _ = 0"),
    ('a confirmed cast is reported as unconfirmed', "if (confirmed or {})[key] ~= p.at and stillRecorded then", "if stillRecorded then"),
    ('a cleared record is reported as unconfirmed', "and stillRecorded then", "then"),
    ('the listeners are not removed on destroy', "for _, name in ipairs(eventNames) do pcall(mq.unevent, name) end", "local _ = 0"),

    # tank prediction (trace only)
    ('a tie on HP goes to the last slot, not the first', "if hp < lowest then lowest, best = hp, m end", "if hp <= lowest then lowest, best = hp, m end"),
    ('slots are walked in reverse', "if sa ~= sb then return sa < sb end", "if sa ~= sb then return sa > sb end"),
    ('the tank\'s current target is not excluded', "and m.id ~= excludeId then", "then"),
    ('a miss is reported as a match', "(pred.id == actualId) and 'MATCH' or 'MISS'", "'MATCH'"),
    ('an old prediction is still compared', "now - tankPred.at <= PREDICTION_MAX_AGE_SEC", "true"),
    ('a feed flap is compared again', "if actual ~= lastMaTarget then", "if true then"),
    ('the tank\'s name is compared case-sensitively', "tostring(p.name):lower() == tostring(maName):lower()", "tostring(p.name) == tostring(maName)"),
    ('the tank\'s mode is not read', "if maPeer then ma.mode, ma.submode = maPeer.mode, maPeer.submode end", "local _ = 0"),
    ('the slot is not recorded', "slot      = i,", ""),
    ('lockouts are not read', "lockedOut = lockedOut,", "lockedOut = false,"),
    ('range is not read', "inRange   = tlo(function() return rt.isTargetInRange(spellName, id) end, false) == true,", "inRange   = true,"),
]


def run(workdir):
    r = subprocess.run(['luajit', 'tests/run.lua'], cwd=workdir, capture_output=True, text=True)
    out = r.stdout + r.stderr
    m = re.search(r'=== Results: (\d+) passed, (\d+) failed', out)
    return r.returncode, (int(m.group(2)) if m else None), out


def main():
    tmp = tempfile.mkdtemp(prefix='mezmut_')
    try:
        shutil.copytree(os.path.join(ROOT, 'tests'), os.path.join(tmp, 'tests'))
        open(os.path.join(tmp, 'mez.lua'), 'w', encoding='utf-8', newline='').write(SRC)
        code, failed, out = run(tmp)
        if code != 0:
            print('The unmodified plugin does not pass its own tests; fix that first.\n' + out[-800:])
            return 2
        print('baseline: all tests pass\n')
        missed = 0
        for name, old, new in MUTATIONS:
            if SRC.count(old) != 1:
                print('%-52s MUTATION DID NOT APPLY (%d matches); update tools/mutation_check.py' % (name, SRC.count(old)))
                missed += 1
                continue
            open(os.path.join(tmp, 'mez.lua'), 'w', encoding='utf-8', newline='').write(SRC.replace(old, new))
            code, failed, out = run(tmp)
            if code == 0:
                verdict = 'NOT CAUGHT'
                missed += 1
            elif failed is None:
                crash = [l.strip() for l in out.splitlines() if 'luajit' in l and ':' in l][:1]
                verdict = 'caught (the run crashed: %s)' % (crash[0][-70:] if crash else '?')
            else:
                verdict = 'caught (%d failed)' % failed
            print('%-52s %s' % (name, verdict))
        print('\n%s' % ('every mutation was caught' if missed == 0 else '%d mutation(s) not caught' % missed))
        return 0 if missed == 0 else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
