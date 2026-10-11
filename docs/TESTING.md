# Testing

## 1. Unit tests (no game needed)

```
luajit tests/run.lua
```

- 351 checks without TAC; 365 with `TAC_SOURCE` pointing at a TAC `triune.lua` that has the registry (the extra 14 run this plugin against TAC's real registry code: register, resolve, disable, fail-closed, re-enable).
- `tests/test_decision.lua`: the pure `decide()` function, the spell data, status text and the chat rate limit. Includes combinations (Main Assist target + a damaged add + an already-mezzed add, peers fighting the nearest add, every filter at once)
  and a purity check (`decide` does not change its input).
- `tests/test_collection.lua`: the state collection against a fake game world (Main Assist outcomes, peers, the per-mob filters, settings, per-tick caching), the mez tracking, failed-cast handling, chat reporting, resilience (core reads that throw,
  a TAC without the registry, a refused registration) and the plugin's lifecycle.
- `python tools/mutation_check.py` breaks 36 rules one at a time in a scratch copy and runs the suite; every one must fail. If you add a rule, add its test **and** a mutation.
- `python tools/verify_spell_data.py` checks the `SPELLS` table against the game's `spells_us.txt` (class level, target type, level cap, cast time).

CI (`.github/workflows/ci.yml`) runs the syntax check and `tests/run.lua` on Linux.

## 2. Testing in game (the next job)

The plugin has **not** been run in game. To test:

1. Use a TAC with the registry. The owner's working copy of TAC already has it; a clean TAC needs `patches/tac-target-selector-registry.patch` (`git am` or `git apply`).
   MacroQuest's installed TAC is a **plain copy**: copy `triune.lua` to `<MacroQuest>/lua/` and `mez.lua` to `<MacroQuest>/lua/tac/` (keep backups; the installed `triune.lua` predates the registry).
2. In TAC enable **Mez Support** (Plugins tab; click Rescan if TAC was running). Set a **Main Assist**. Put the Enchanter in **Assist mode**.
3. On the mez gem: **Target** `E: Mez Target`, **When** `in combat`. Turn on **Debug Mode** and Log To File. The plugin then writes `mez:` lines to the TAC log: the Main Assist input and source, the peers, each change of pick with the skipped counts, each recorded mez cast, each cleared failed cast.
4. Pull a group of 2-4 mobs with the tank; ideally a case where the tank runs TAC (Box Network) and one where the tank is piloted.

What to look for:

- Turn on EverQuest's own chat log too (`/log on`): it shows whether the landing, awakened and worn-off messages appear, to compare with the `mez:` lines. Only Rapture's landing text has been seen so far.

- The tank's mob is never mezzed. Mobs another box fights are skipped. The status line says why.
- Each add is mezzed once and renewed only near expiry (watch for early re-mezzes: suspects are the 0.5 s pending window and the Mesmerize duration cap).
- "Main Assist target unavailable" appears when the MA reports nothing, and the plugin does not mez then.
- `E: Mez Target` appears in the Target dropdown when the plugin is enabled and disappears when it is disabled; a saved entry then shows `(unavailable)` and is not reset to `F: Myself`.
- With a piloted tank (no Box Network feed): the `/assist` peek works and the Enchanter's own target is changed only as TAC normally does.

Capture the TAC log from the fight (`triune__<Char>.log`), what the tank was doing, whether the tank runs TAC, and anything that looked wrong.

## 3. Running TAC's own test file (when changing the TAC side)

TAC's `tests/test_pure_logic.lua` aborts on Windows at Suite 92 because it writes to `/tmp`. Point it at a real directory that already contains a `triune_junk_plugins` folder:

```
mkdir -p C:/some/dir/triune_junk_plugins
TMPDIR=C:/some/dir luajit tests/test_pure_logic.lua
```

Two failures are known and unrelated: Suite 86 (floating-damage shockwave rings; intermittent) and Suite 103 (path separators, only when `TMPDIR` uses forward slashes on Windows). On the registry patch: 6532 passed, 2 failed.
Failures are printed only at the end, so a run that aborts early hides them: always check for the `=== Results` line.
