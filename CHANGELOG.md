# Changelog

## Unreleased (0.2.0, work in progress)

- **Mez Support plugin (`mez.lua`).** Adds the target `E: Mez Target`, which chooses the nearest add that the Main Assist and the other boxes are not fighting, for single-target Enchanter mezzes
  (Mesmerize, Enthrall, Entrance, Dazzle, Glamour of Kintaz, Rapture, Ancient: Eternal Rapture, Apathy, Sleep, Bliss, Felicity, Euphoria). It fails closed when the Main Assist's target is unknown, skips already-damaged
  adds (switchable), renews a mez only when it is about to run out, refuses area mezzes and Echoing Madness, reports distinct statuses in its settings panel and (rate-limited) in chat, and removes its dropdown entry when disabled.
  Needs a TAC with the target selector registry (`patches/tac-target-selector-registry.patch`). Unit-tested; not yet run in game.
- **Debug trace for the first in-game test.** Through `core.log.debug` (category `mez`, shown only while TAC's Debug Mode is on): the Main Assist input and its source (Box Network feed or `/assist` peek), the peers considered,
  each change of pick with the skipped counts, each mez cast TAC records, and each failed cast that clears a record. Lines are written only when something changes.
- **Mez messages.** The plugin listens for the game's own text: the landing text of each supported mez (from the spell file; Rapture's seen in a real log, the other eight not yet), "<mob> has been awakened by <who>."
  and "Your <spell> spell has worn off of <mob>.". An awakened or worn-off mez drops the record at once, so the mob can be mezzed again; a landing message only confirms the cast in the debug trace
  (and a cast with no landing message within 8 s is traced). Messages carry the mob's name, not its id, so they are matched to TAC's records by name and ignored when that is ambiguous. `tools/verify_spell_data.py` checks the landing texts.
- Standalone test runner (`tests/run.lua`), a spell-data checker (`tools/verify_spell_data.py`) and a rule-mutation checker (`tools/mutation_check.py`).

History: the plugin began as part of the `wip/mez-support` branch of `thezerodivide/TriuneAutocombat-4Class` (0.1.0 was the decision logic only; 0.2.0 added state collection, tracking, the selector and the settings panel).
