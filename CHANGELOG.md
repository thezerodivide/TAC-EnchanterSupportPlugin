# Changelog

## Unreleased (0.2.0, work in progress)

- **Mez Support plugin (`mez.lua`).** Adds the target `E: Mez Target`, which chooses the nearest add that the Main Assist and the other boxes are not fighting, for single-target Enchanter mezzes
  (Mesmerize, Enthrall, Entrance, Dazzle, Glamour of Kintaz, Rapture, Ancient: Eternal Rapture, Apathy, Sleep, Bliss, Felicity, Euphoria). It fails closed when the Main Assist's target is unknown, skips already-damaged
  adds (switchable), renews a mez only when it is about to run out, refuses area mezzes and Echoing Madness, reports distinct statuses in its settings panel and (rate-limited) in chat, and removes its dropdown entry when disabled.
  Needs a TAC with the target selector registry (`patches/tac-target-selector-registry.patch`). Unit-tested; not yet run in game.
- Standalone test runner (`tests/run.lua`), a spell-data checker (`tools/verify_spell_data.py`) and a rule-mutation checker (`tools/mutation_check.py`).

History: the plugin began as part of the `wip/mez-support` branch of `thezerodivide/TriuneAutocombat-4Class` (0.1.0 was the decision logic only; 0.2.0 added state collection, tracking, the selector and the settings panel).
