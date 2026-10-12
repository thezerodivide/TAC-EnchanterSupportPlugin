# Next steps and open items

## Where things stand

- The logic is written and unit-tested (see `docs/TESTING.md`). **It has not been run in game.** The owner wants it tested in game before any PR.
- Nothing from this repo has been submitted to TAC upstream. The TAC-side change (the registry) exists as `patches/tac-target-selector-registry.patch` and as the fork branch `wip/mez-support`
  (`thezerodivide/TriuneAutocombat-4Class`, which also holds an earlier copy of this plugin and `MEZ_HANDOFF.md`).
- No license chosen, no CHANGELOG beyond the first entry, no release.

## Do next, in this order

1. **Debug logging for the first in-game test: built, unit-tested, not yet seen in game.** Through `core.log.debug` (category `mez`), written only when something changes:
   (a) the Main Assist input (`target <id>` / `none` / `unknown`, and whether it came from the Box Network feed or the `/assist` peek),
   (b) the peers considered (name, target id, engaged),
   (c) on a change of pick: the chosen mob (id, name, distance) and the `excluded` counts,
   (d) each time a mez cast is recorded or a failed cast clears a record.
   The text is built outside `decide()` (`describeInput`, `describeResult`, `newMezCasts`). Caveat: (d) notices a cast by polling TAC's `npcSpellLastCast` each combat tick, so it is logged up to a tick late and only if the plugin is enabled.
2. **Test in game** (`docs/TESTING.md` section 2) and fix what the log shows.
3. **Decide whether to offer a standalone mode** (see below).
4. Write CHANGELOG/README for the TAC-side PR and choose a license.
5. **PRs (only when the owner asks):** first the registry to `gennro/TriuneAutocombat` (from the owner's fork, as a draft so CI runs first); the plugin stays in this repo.

## Mez messages: built, partly unverified

Seen in a real EverQuest log (2026-10-11, Rapture): `<mob> swoons in raptured bliss.` about 2 s after the cast begins, `<mob> has been awakened by <who>.` and `Your Rapture spell has worn off of <mob>.`.
The landing texts of the other eleven spells come from `spells_us.txt` and have not been seen in game. Built: an awakened or worn-off message drops the mez record; a landing message only confirms the cast in the
debug trace, and a cast with no landing message within 8 s (`LANDING_WINDOW_SEC`, a guess) is traced. **Not built, to decide after more tests:** clearing the record and retrying when no landing message arrives,
and a retry limit. Matching is by mob name; two same-named mobs both recently mezzed make a message ambiguous and nothing is changed.

## Farthest-first (built as an experiment) and the tank prediction trace

The pick is now the **farthest** add from the Enchanter (see `docs/DESIGN.md`). Judge it from the logs: how many landed mezzes were woken within a few seconds (baseline before the change, 2026-10-11 and 12: 30 mezzes landed; of the 22 whose wake was matched to a mob, 14 were woken within 3 s; same-name wakes and mobs killed while mezzed are not in that count), and how many casts failed with "cannot see your target"
(distant adds make that likelier). The text below describes the earlier plan and is partly superseded: the tank's rule is the aggro switch (nearest to him), not lowest HP.

Observation in game (2026-10-11): in fast fights the mezzed add is often the tank's next target within a second or two, so the mez is wasted. Kylaeris's saved loadout is Puller/Hunt; in Hunt, Manual and Puller Camp TAC picks the next target with
`runtime.findFirstNPCXtarget`: lowest HP%, first Extended Target slot on a tie. Agreed idea: mez the opposite (the add the tank would reach last). Built so far: only the `tank prediction` trace (`MATCH`/`MISS` per change of the tank's target)
and the tank's mode in the input line. Unknown until the trace has data: whether this character's slot order equals the tank's, and how the tank's ignore/unreachable lists and distance cap change the result. **Not built:** the ranking itself
(highest HP%, then highest slot; distance as tie-break; only when the tank's mode is known to use that rule, otherwise nearest) and a "mez only when at least N adds" setting.

## Unverified (the test should settle these)

| Item | What to watch |
|---|---|
| The tank's mob is never mezzed; each add is mezzed once and renewed near expiry | the fight log and the status line |
| The `/assist` peek fallback when the MA is not running TAC | it changes the Enchanter's own target; check it behaves as TAC normally does in Assist mode |
| The pending window (cast time + 0.5 s) | an add re-mezzed during its own cast means it is too short |
| Mesmerize's duration (4 ticks in the spell file vs 12 s in the server's list) | the cap is conservative (12 s); confirm which is real |
| Whether 3 s (`BOXNET_FRESH_SEC`) makes peer heartbeats flap | statuses alternating between candidate and waiting |
| The eleven landing texts not yet seen (Mesmerize, Enthrall, Entrance, Dazzle, Glamour of Kintaz, Ancient: Eternal Rapture, Apathy, Sleep, Bliss, Felicity, Euphoria) | `landed:` lines in the trace; "no landing message seen" lines |
| Whether the Main Assist's area attacks keep waking mezzed adds (both wakes seen so far were "by" the Main Assist) | "awakened" lines and what the Main Assist hit at the time |
| Picks with no line of sight (a mob 190 away was picked and the cast failed with "You cannot see your target") | failed-cast lines; no line-of-sight rule exists |
| Whether `recordSuccess`/failure flags behave for an Enchanter's casts as read in the code | a failed cast ("cannot see target") should drop its record |
| Enchanter in a four-class gestalt build (the owner's server) | the plugin only checks the *spell*, not the class, so it should work; confirm |

## Known limits (accepted for version one)

- A piloted off-tank holding an undamaged add is invisible (damaged-add protection is the only cover).
- If the Main Assist switches to an add while the mez is mid-cast, the mez still lands. Cancelling mid-cast is possible later if logs show it matters.
- Mez state is still presumed. An early break is now caught by the "awakened" and "worn off" messages when the name match is unambiguous; with two same-named mezzed mobs it stays "active" until the renew window.
- With "Skip damaged adds" on, an add that took damage stays excluded even after its mez expired (turn the setting off for damage-over-time groups).
- Single-target Enchanter mezzes only; no area mezzes, no Echoing Madness, no Bard/Necromancer/Mage mezzes.

## Ideas, none agreed

- **Standalone mode (no registry).** Give the plugin its own settings window and let it cast through TAC's gem machinery (`runtime.castGem`) so it works on stock upstream TAC. Real extra work; also would compete with the core gem loop for priority
  (the plugin's hook runs after the core loop each pass, so a busy gem loop could starve it). Only worth it if the registry is not accepted upstream.
- **Reading the mob's real buffs** when it is the current target and the client has them (`Target.Buff(i)`, the same calls TAC already uses for target buffs). Only helps the targeted mob; would refine the presumed state.
- **Landing-based verification and retry** (clear the record and retry when no landing message arrives): needs the other eleven texts seen first. A target hold and buff read was considered and not needed for this; it would also need the engine to stop auto-attacking the held target.
- **Ranking by who the add is attacking**, if the aggro data turns out reliable.
- **Off-tank awareness**, e.g. a configurable second protected character.
- **A `/ac mez` status command.**
- **Making `add is loose` aware of `E: Mez Target`** (the registry could let a selector say what "loose" means for it).
