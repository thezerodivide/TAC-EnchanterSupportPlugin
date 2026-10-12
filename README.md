# TAC Enchanter Mez Support

A plugin for [TAC (Triune AutoCombat)](https://github.com/gennro/TriuneAutocombat) that decides **which add an Enchanter should mez**, and never
picks the mob the group is already fighting.

> **Status: work in progress. The logic is unit-tested; it has not been run in game yet.** See `docs/NEXT-STEPS.md`.

## The problem

TAC's existing `E: Unmezzed Add` target picks the lowest-HP hostile mob on Extended Target. In a fight that is almost always the mob the tank is
already hitting. The Enchanter mezzes it, the next hit wakes it, the mob dies, the group moves to the next one, and the Enchanter mezzes that one.
It mezzes the same mob over and over and never the adds.

## What this does

It adds a new target, **`E: Mez Target`**, to TAC's Target dropdowns. For a mez spell you give that target, it chooses the **farthest add (from the Enchanter) that
nobody in the group is fighting**, because the tank's TAC takes the mob nearest to *him* next (an experiment; see `docs/DESIGN.md`):

- never the **Main Assist's target** (the Enchanter must run in Assist mode with a Main Assist set),
- never a mob **another box is engaged with** (from the other characters' Box Network heartbeats),
- never an add that is **already mezzed** (until that mez is about to run out, then it is renewed),
- by default never an add that is **already damaged** (someone is fighting it; switchable),
- never a mob above the spell's **level cap**, or one that is ignored, unreachable, locked out for that spell, or out of range.

If it cannot tell what the Main Assist is fighting, it **does not mez** and says why. TAC's own gem loop does the casting; the plugin only
supplies the target. `E: Unmezzed Add` is untouched.

Single-target Enchanter mezzes only: Mesmerize, Enthrall, Entrance, Dazzle, Glamour of Kintaz, Rapture, Ancient: Eternal Rapture, Apathy, Sleep, Bliss,
Felicity, Euphoria. Area mezzes and Echoing Madness are refused (they can hit the mob being fought).

## Requirements

- TAC **with the target selector registry**. Stock upstream TAC does not have it yet; apply `patches/tac-target-selector-registry.patch`
  (see `patches/README.md`). Without it the plugin prints "this Triune build has no target selector registry" and does nothing.
- Best results when the Main Assist and the other characters also run TAC with the Box Network plugin on the same computer. A Main Assist that
  is not running TAC still works through TAC's `/assist` peek, but the other boxes' targets are then unknown.

## Install and use

1. Copy `mez.lua` into TAC's plugin folder (`<MacroQuest>/lua/tac/`). Click **Rescan** on TAC's Plugins tab if TAC is already running.
2. Enable **Mez Support** on the Plugins tab (it is off by default). Set a **Main Assist** in TAC.
3. Put the Enchanter in **Assist mode**. On the mez spell gem set **Target** `E: Mez Target` and **When** `in combat`.
4. Open the plugin's settings to see its live status line, and to switch off **Skip damaged adds** (useful in damage-over-time fights).

Status lines you may see: `Mez candidate: <mob>`, `Waiting: Main Assist target unavailable`, `Waiting: Main Assist has no target`,
`Configuration: Main Assist not set`, `No eligible mez targets (skipped: ...)`, `Unsupported mez spell: <reason>`. Problems are also said in chat, rate-limited.

If the plugin is disabled or missing, a saved `E: Mez Target` entry shows as `E: Mez Target (unavailable)` and casts at **nothing** (it never falls back
to your current target).

## Limits

- A piloted off-tank holding an undamaged add is invisible to the plugin (damaged-add protection is the only cover).
- If the Main Assist switches to an add while the mez is mid-cast, the mez still lands.
- Mez state is presumed from TAC's cast records, not read from the mob. The game's "awakened" and "worn off" messages drop a record early, but they carry only the mob's name: with two same-named mezzed mobs nothing is dropped, and the mez stays "active" until the refresh window.
- With damaged-add protection on, an add that took damage stays excluded even after its mez would have expired.

## Development

```
luajit tests/run.lua                      # unit tests
python tools/mutation_check.py            # proves the tests can fail
python tools/verify_spell_data.py         # checks the spell table against the game's spell file
```

See `docs/DESIGN.md` for why it works this way, `docs/TAC-INTEGRATION.md` for the TAC internals it depends on, and `CLAUDE.md` if you are an AI assistant continuing the work.

## License

Not chosen yet (the owner decides).
