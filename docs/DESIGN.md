# Design: what was decided, and why

This records the decisions reached with the owner, in the order the reasoning went, including what was **rejected** so it is not rebuilt by accident.
"Verified" means checked against TAC's source or a data file; anything else is marked as a guess.

## 1. The problem, and the evidence

Observed in game (owner's description): the group starts fighting several mobs; the Enchanter casts mez on the current target, the one being fought;
that target dies; the group starts on another; the Enchanter casts mez on that one. Repeat.

This matches TAC's code exactly (verified in `HEAD` of `TriuneAutocombat`, before any of this work):

```lua
-- resolveTargetId
elseif b == 'Unmezzed Add' then
    id = firstNPCXtarget(true)

-- runtime.findFirstNPCXtarget(unmezzedOnly, ...): walks the XTarget slots; a mob qualifies if it is hostile, in range,
-- not ignored, not unreachable and (for unmezzedOnly) buffActive(id, 'Mez') is false; of those the LOWEST HP% wins.
```

- The mob being fought is the one being damaged, so it nearly always has the lowest HP%. Nothing excludes it.
- The "is it mezzed" test asks the client for a buff named exactly `Mez`. Real mez spells are named Mesmerize, Entrance and so on, so it never matches; and the
  client generally only exposes buffs for your current target anyway.
- The word "add" in `E: Unmezzed Add` and `E: Nearest Add` is only a label. No code excludes the primary target. `Nearest Add` does not either.
- `add is loose` (a When condition) calls the same finder, so it is true whenever any mob qualifies, including the tank's.
- TAC's combat engine (Hunt, Assist, Manual) has **no concept of a combat target other than the game target**, and no awareness of mez at all.
  (`pullState`/`pullTargetId` exist only for the Puller *Camp* submode. `pursuit.id` is a movement stall tracker, not a combat target.)

## 2. The role

The owner's character build does not need to mez itself; a **separate support Enchanter**, running in **Assist mode** next to a tank/Main Assist, does.
So the authority on "what is being fought" is the **group's**, not the Enchanter's own game target.

## 3. Principles agreed

1. **`E: Unmezzed Add` keeps its existing meaning.** A new selector, `E: Mez Target`, carries the new rules. Existing loadouts are unaffected.
2. **Separate the layers:** state collection (reads the game), decision (a pure function), execution (TAC's own gem loop casts), reporting (status text and chat).
   The decision function has no MacroQuest or TAC calls, so every rule is a unit test.
3. **The Main Assist's target is essential; everything else only improves the choice.** So fail closed on the MA, tolerate missing information about other boxes.
4. **Plugin, not core:** TAC gets only a small, generic, behavior-neutral extension point (the target selector registry). The mez rules live here, as defaults.
5. **No guessing dressed up as fact:** heuristics are labelled in code and docs. Nothing is built around an event or message that has not been shown to exist.

## 4. The decision table

| Situation | Result |
|---|---|
| Spell not a supported single-target Enchanter mez | `spell_unsupported` |
| No Main Assist configured | `ma_not_set` |
| MA target unknown or stale | `ma_unavailable`: no mez |
| MA explicitly has no target | `ma_no_target`: no mez, wait |
| MA target known | that mob excluded |
| Another box has a fresh, engaged target | that mob excluded |
| Another box's heartbeat missing or stale | ignored; never blocks |
| Add HP below 100% | excluded when "Skip damaged adds" is on (default on) |
| Mob above the spell's level cap (unknown level is allowed) | excluded |
| Ignored, unreachable, locked out for the spell, or out of range | excluded |
| Mez pending, or active with more than cast time + 2 s left | excluded |
| Mez active with cast time + 2 s or less left | eligible (renew) |
| Nothing qualifies | `no_eligible` (with counts of what was skipped and why) |
| Otherwise | nearest candidate; ties go to the lowest spawn id |

Order of the early checks: unsupported spell, then MA not set, then MA no target, then MA unavailable. Statuses are distinct on purpose: an inactive plugin must
be able to explain itself.

### Why nearest-first
A deterministic, easy-to-verify heuristic. Ranking by who each add is attacking may be better, but it is not established that the aggro data is reliable enough. This is an
intentional first choice, not a claim that it is optimal crowd control.

### Why fail closed on the MA, tolerant on peers
Peer heartbeats only exist for the owner's *other TAC characters on the same computer, in the same zone*. A piloted character, a box on another PC, or a character not running
TAC has no heartbeat, ever. Failing closed on that would block mezzing in exactly the groups where it is wanted. Mezzing a mob another box is fighting costs a wasted cast;
mezzing the tank's mob is the failure being fixed.

### Why "skip damaged adds"
It covers characters outside the Box Network without claiming damage proves engagement. It is visible, on by default, and switchable so a damage-over-time group is not locked out.

## 5. Mez state

Presumed, not observed. Rules (the owner removed anything stronger than the evidence):

| Evidence | Interpretation |
|---|---|
| Cast issued | pending (for cast time + 0.5 s) |
| Cast completed with no detected failure | presumed active until the earlier of the recorded expiry and the spell's listed duration |
| Explicit failure detected | clear the record |
| Expected end approaches | eligible to renew (remaining <= cast time + 2 s) |
| Mez breaks early with no detectable event | stays presumed active until the renew window (a real limitation) |

- TAC already records every duration spell it casts (`runtime.npcSpellApplied[mob][spell]` = expiry, `runtime.npcSpellLastCast[mob][spell]` = cast time) and clears the
  record on a resist, fizzle, interrupt or "did not take hold". The plugin reuses that and adds one clear: when `castTracker.failed` is set for a mez cast (any other
  failure: cannot see target, out of range, ...), it drops the record of the mob whose cast time matches.
- "Confirmed" means *cast-completion-confirmed*: TAC believes the cast finished without a failure. It does **not** prove the mez landed.
- The listed duration caps the record because the spell file says Mesmerize lasts 4 ticks (TAC would record 24 s) while the server's spell list says 12 s. Which is right is unverified; capping is conservative.

## 6. Spell data

20 Enchanter spells, 12 supported, 8 refused. Verified by `tools/verify_spell_data.py` against `spells_us.txt`:

| Kind | Spells | Why |
|---|---|---|
| Single target (target type 5), supported | Mesmerize 55, Enthrall 55, Entrance 55, Dazzle 55, Glamour of Kintaz 57, Rapture 63, Ancient: Eternal Rapture 63, Apathy 62, Sleep 65, Bliss 68, Felicity 70, Euphoria 73 | the number is the highest mob level the spell works on (the Mesmerize effect's base value); every one casts in 2.5 s |
| Spreads | Echoing Madness | "the madness will frequently echo in the ears of nearby creatures": could reach the mob being fought |
| Area around the target (type 8) | Mesmerization, Fascination, Bliss of the Nihil, Wake of Felicity | affects mobs around the target, so the protected mob cannot be guaranteed safe |
| Area around the caster (type 4) | Entrancing Lights, Word of Morell, Circle of Dreams | changing the target does not change where it lands |

Out of scope: Bard songs (12 of the owner's original 36), Necromancer (Screaming Terror, Death's Silence, Dark Hold), Mage (Elemental Silence). Song of Dawn was excluded early: it is in the
Enthrall category but only lowers hate. Rogue's Ploy and Assassin's Feint carry the Mesmerize effect but the owner declined to include them. The list stops at level 70 (the server list does);
the spell file has 118 more Enchanter mez names above level 70.

## 7. What was considered and rejected (do not rebuild without new evidence)

| Idea | Why not |
|---|---|
| Change `E: Unmezzed Add` / `E: Nearest Add` to exclude the combat target | Existing meaning must stay (a damage spell with that target should still hit the fought mob). A new selector instead. |
| A mez-spell-aware switch inside `E: Unmezzed Add` (spell list decides the meaning) | Tried locally; it papered over the real question of what the token means. Replaced by a separate selector. |
| The plugin sampling the Enchanter's **own game target** as the combat target | Right for a character that fights, wrong for a support character. The MA's target is the authority. TAC's own casts flip the game target, which needed stamps and a timing heuristic. |
| `pursuit.id` or `pullTargetId` as the combat target | `pursuit.id` is a movement stall tracker (reset in ~25 places, can be stale). `pullTargetId` exists only for Puller *Camp*; the owner runs Hunt/Assist. |
| A shadow "combat target" tracker with sticky behavior | Two systems guessing what the engine will kill: the conflict that had to be avoided. |
| Post-cast buff verification that pauses auto-attack and holds the target | Reaches into the combat engine (attack off/on, target restore at five sites). Too intrusive; removed. |
| Reading the mob's mez buff | The client only exposes buffs for your *current target* (and group members). Deferred; "Target.Mezzed"/buff reads are an optional refinement for the targeted mob only. |
| An "X has been awakened by Y" handler | No evidence the message exists on this server (searched the EverQuest logs on the machine: nothing). Do not build around it until a real log shows it. |
| A separate mez tracker | TAC already records every duration spell it casts; reuse it. |
| Lowest-HP fallback when the combat target is unknown | For this selector, protecting the kill target beats mez uptime: return no target. |
| Failing closed on every missing input | Piloted/other-PC characters never have heartbeats. |
| Supporting area mezzes in version one | Different targeting problem (which mobs are hit, not which is targeted); refused with a stated reason. |
| Bard support | Out of scope; songs add their own cast/target handling. |
| Mutating `E: Unmezzed Add` buff check to match mez spells by SPA 31 | Not every mez is guaranteed to use that effect; the explicit spell table is verified instead. |

## 8. The TAC side (the registry)

Details in `docs/TAC-INTEGRATION.md`. Summary of why each piece exists:

- **Registry:** lets a plugin add a Target dropdown entry and supply its resolver, so TAC needs no mez knowledge.
- **Fail-closed for unknown `E:`/`F:` tokens:** a saved `E: Mez Target` read by a TAC without the plugin used to fall into the "else: current target" branch, i.e. mez the tank's mob.
  Now it resolves to no target. Empty/nil/legacy tokens keep the old behavior. (The owner had said inspect callers first: the saved loadouts on the owner's machine use only six token values, none relying on the fallback.)
- **Dropdown keeps unknown tokens:** found while building: the five Target dropdowns used `idxOf(...)` which returns 1 for an unknown token, and each then wrote `TARGETS[1]` (`F: Myself`) back and saved it. A plugin's
  entry would be silently overwritten the first time its tab was drawn while the plugin was off. They now show `<token> (unavailable)` and keep it.

## 9. Open design questions

See `docs/NEXT-STEPS.md`.
