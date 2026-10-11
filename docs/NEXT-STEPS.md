# Next steps and open items

## Where things stand

- The logic is written and unit-tested (see `docs/TESTING.md`). **It has not been run in game.** The owner wants it tested in game before any PR.
- Nothing from this repo has been submitted to TAC upstream. The TAC-side change (the registry) exists as `patches/tac-target-selector-registry.patch` and as the fork branch `wip/mez-support`
  (`thezerodivide/TriuneAutocombat-4Class`, which also holds an earlier copy of this plugin and `MEZ_HANDOFF.md`).
- No license chosen, no CHANGELOG beyond the first entry, no release.

## Do next, in this order

1. **Add useful debug logging for the first in-game test.** Today the plugin writes only *problem* statuses to chat; a candidate pick is shown in the window only, so a fight log would not show what was chosen or skipped.
   Proposed (agreed in principle, not built): through `core.log` (debug lines only while Debug Mode is on), rate-limited, log
   (a) the Main Assist input (`target <id>` / `none` / `unknown`, and whether it came from the Box Network feed or the `/assist` peek),
   (b) the peers considered (name, target id, engaged),
   (c) on a change of pick: the chosen mob (id, name, distance) and the `excluded` counts,
   (d) each time a mez cast is recorded or a failed cast clears a record.
   Keep it out of `decide()`: build the text from the returned `excluded` counts and the collected state.
2. **Test in game** (`docs/TESTING.md` section 2) and fix what the log shows.
3. **Decide whether to offer a standalone mode** (see below).
4. Write CHANGELOG/README for the TAC-side PR and choose a license.
5. **PRs (only when the owner asks):** first the registry to `gennro/TriuneAutocombat` (from the owner's fork, as a draft so CI runs first); the plugin stays in this repo.

## Unverified (the test should settle these)

| Item | What to watch |
|---|---|
| The tank's mob is never mezzed; each add is mezzed once and renewed near expiry | the fight log and the status line |
| The `/assist` peek fallback when the MA is not running TAC | it changes the Enchanter's own target; check it behaves as TAC normally does in Assist mode |
| The pending window (cast time + 0.5 s) | an add re-mezzed during its own cast means it is too short |
| Mesmerize's duration (4 ticks in the spell file vs 12 s in the server's list) | the cap is conservative (12 s); confirm which is real |
| Whether 3 s (`BOXNET_FRESH_SEC`) makes peer heartbeats flap | statuses alternating between candidate and waiting |
| Whether `recordSuccess`/failure flags behave for an Enchanter's casts as read in the code | a failed cast ("cannot see target") should drop its record |
| Enchanter in a four-class gestalt build (the owner's server) | the plugin only checks the *spell*, not the class, so it should work; confirm |

## Known limits (accepted for version one)

- A piloted off-tank holding an undamaged add is invisible (damaged-add protection is the only cover).
- If the Main Assist switches to an add while the mez is mid-cast, the mez still lands. Cancelling mid-cast is possible later if logs show it matters.
- Mez state is presumed; an early break with no detectable event stays "active" until the renew window.
- With "Skip damaged adds" on, an add that took damage stays excluded even after its mez expired (turn the setting off for damage-over-time groups).
- Single-target Enchanter mezzes only; no area mezzes, no Echoing Madness, no Bard/Necromancer/Mage mezzes.

## Ideas, none agreed

- **Standalone mode (no registry).** Give the plugin its own settings window and let it cast through TAC's gem machinery (`runtime.castGem`) so it works on stock upstream TAC. Real extra work; also would compete with the core gem loop for priority
  (the plugin's hook runs after the core loop each pass, so a busy gem loop could starve it). Only worth it if the registry is not accepted upstream.
- **Reading the mob's real buffs** when it is the current target and the client has them (`Target.Buff(i)`, the same calls TAC already uses for target buffs). Only helps the targeted mob; would refine the presumed state.
- **An "awakened" handler**, once a real log shows the message text on this server.
- **Ranking by who the add is attacking**, if the aggro data turns out reliable.
- **Off-tank awareness**, e.g. a configurable second protected character.
- **A `/ac mez` status command.**
- **Making `add is loose` aware of `E: Mez Target`** (the registry could let a selector say what "loose" means for it).
