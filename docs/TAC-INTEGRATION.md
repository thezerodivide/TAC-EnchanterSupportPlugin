# TAC internals this plugin relies on

Everything here was read in TAC's source (`TAC/lua/triune.lua`, `TAC/lua/tac/boxnet.lua`) during the design. File positions drift, so functions are named, not numbered.
TAC base used: `thezerodivide/TriuneAutocombat-4Class` `main` at `06755f6` (a merge of upstream `gennro/TriuneAutocombat` PR #21), plus `patches/tac-target-selector-registry.patch`.
If TAC changes any of these, the plugin's collection layer (and the tests that fake them) must change with it.

## 1. The plugin contract

A plugin is a Lua file in `<MacroQuest>/lua/tac/` that returns a table. Fields used here: `id`, `name`, `version`, `author`, `description`, `defaultEnabled`, `tickInterval`,
`runOutOfCombatOnly`, `hasThread`, `uses` (`{ boxnet = 'why' }`, shown on the Plugins tab). Hooks TAC calls (`pm` = plugin manager):

| Hook | When | Used by mez.lua |
|---|---|---|
| `onInit(core)` | the plugin is enabled (also on startup if it was enabled) | registers the selector |
| `onDestroy()` | disabled or reloaded | unregisters the selector |
| `onCombatTick(targetId)` | every main-loop pass, **after** `combatTick`; passes the current game target | clears records of failed mez casts |
| `onDrawSettings()` | the plugin's settings panel on the Plugins tab | status line and the one setting |
| `onSaveSettings()` / `onLoadSettings(t)` | per-character persistence in the loadout | `damagedProtection` |

Other hooks exist (`onTick`, `onDrawUI`, `onZoned`, `onBetweenPulls`, `onCommand`, `onLoadoutSaved`, `wantsCombatHold`) and are not used.
A plugin that dropped into the folder is found by a directory scan; TAC also has a hard-coded fallback list (`known` in `pm.discover`) used only when it cannot list the folder.
**Do not add `mez.lua` to that list in TAC**: an external plugin is found by the scan and by the Rescan button.

`core` (the API table passed to `onInit`) exposes, among much else: `core.runtime` (TAC's whole runtime table), `core.ctrl` and `core.loadout` (resolved live; TAC replaces them on character change), `core.castTracker`,
`core.mq`, `core.ImGui`, `core.colors`, `core.accent`, `core.setTooltip`, `core.px`, `core.saveLoadout`, `core.log`, and (new, from the patch) `core.registerTargetSelector` / `core.unregisterTargetSelector`.

## 2. The target selector registry (from the patch)

```lua
local ok, why = core.registerTargetSelector({
    owner   = 'mez',                 -- the plugin id; its selectors are removed when it is disabled or reloaded
    label   = 'Mez Target',          -- shown in the dropdown as 'E: Mez Target'
    side    = 'E',                   -- 'E' enemy (default) or 'F' friendly
    help    = 'text for the Target help table',
    resolve = function(ctx) return spawnId end,   -- ctx = { token, label, cls, when, spellName, pct, entry }
})
core.unregisterTargetSelector('Mez Target', 'mez')
```

- `resolve` returns a positive spawn id or nil (no target; the entry does not fire). An error counts as no target and is reported once per 30 s. The id then goes through the same checks as every built-in target.
- Refused: a non-table spec, an empty label, a label that starts with a side prefix, a non-function `resolve`, a bad `side`, a label that collides with a built-in target, a label already owned by another plugin.
- The label is added to `COMBO_OPTIONS.TARGETS` after the last entry of its side; `UI.HELP_TARGETS` rows are appended from the registry.
- `pm.disablePlugin(id)` calls `runtime.unregisterTargetSelectorsByOwner(id)`. `reloadPlugin` goes through `disablePlugin`.
- `runtime.isUnknownSelectorToken(token, base)`: true for an `E:`/`F:` token that is neither built in nor registered. In `resolveTargetId`, such a token returns nil. Empty, nil and legacy (no `E:`/`F:` prefix) tokens keep the old
  "current target" fallback.
- `UI.targetCombo(id, token)` / `UI.targetComboOptions(token)`: the Target dropdown now keeps a token that is not in the list, shown as `<token> (unavailable)`.

## 3. What `resolveTargetId` does with the entry

`runtime.resolveTargetId(token, cls, when, spellName, pct, extra)` is called by the gem, AA, ability, clicky and disc loops (14 call sites) and by downtime buffing. `extra` is the
entry table (`kind`, `max_casts`, ...) and some call sites omit it, so **the spell name is the only input the plugin can count on**. After the selector returns an id, `resolveTargetId` validates it
(spawn exists, not dead, not a corpse, ...) and the caller then casts. `castGem` retargets to that id for the cast and restores the previous target afterwards.
`conditionMet(when, ...)` is evaluated separately; the `add is loose` condition still uses the old finder (see `DESIGN.md`), so the guidance is to use When `in combat`.

## 4. The Main Assist and the Box Network

- `runtime.maPcId()`: the Main Assist's spawn id from `ctrl.ma_id` / `ctrl.ma_name`, or nil.
- `runtime.boxnetMaTarget(maId)` returns **a table** `{ id, name, hp, type, engaged, combat, age, since }` (the MA's Triune reports its exact target), **`false`** (a fresh heartbeat saying it has no target) or **`nil`** (no
  fresh same-zone feed). The plugin needs this three-way result. `runtime.maTargetId()` collapses "none" and "unknown" into nil, and in Assist mode also requires the target to be engaged and within `xtar_nav_dist`.
- Fallback when there is no feed: `runtime.maTargetId()`, which performs a throttled `/assist <MA>` peek. **That changes the Enchanter's own target.** It is TAC's normal Assist-mode behavior.
- `runtime.boxnetApi()` returns the Box Network plugin's API or nil. `bn.peersInZone(maxAgeSec)` returns the other Triune characters on **this computer** in **this zone** with a heartbeat no older than `maxAgeSec`
  (`runtime.BOXNET_FRESH_SEC = 3.0`). Each entry is `{ name, hb = { target = { id, name, hp, type, engaged, since }, mode, combat, ... } }`. `target.engaged` is true when that character is in combat **or its target's HP is below 100%**.
- `runtime.boxnetClaimedTargets()` exists but returns `{}` unless the character is in **Puller** mode with box pull coordination on, so it is not usable for an Assist-mode Enchanter. The plugin reads `peersInZone` directly.
- Peers are only characters running TAC's Box Network plugin. A piloted character, a box on another PC and a non-TAC character have no heartbeat.

## 5. Cast bookkeeping the mez tracking reads

- `runtime.castGem` writes, right after issuing `/cast`: `runtime.npcSpellLastCast[mobId][spell] = os.clock()`, and for spells with a duration `runtime.npcSpellApplied[mobId][spell] = os.clock() + durationTicks * 6`.
  So the record is **optimistic** (written at cast issue).
- `castTracker` clears `npcSpellApplied[mob][spell]` on `resisted`, `fizzled`, `interrupted`, `did not take hold` (and registers immunity lockouts).
- `castTracker.failed` is set to true for **any** failure of a detrimental cast (including "cannot see target", out of range). The plugin watches it together with `castTracker.lastSpell` / `lastTime`; `castGem` resets
  `failed` to false when the next cast starts. `castTracker.isLockedOut(spell, mobId, kind)` answers the lockout question. `castTracker.recordSuccess` exists (it runs when a cast ends with no failure) and is **not** used.
- Spell durations come from `Spell.Duration()` in ticks, times 6. Focus effects are not included. Mesmerize shows 4 ticks in `spells_us.txt` but "12 s" on the server's list (unresolved).

## 6. Other core functions read through `core.runtime`

`isHostileTarget(id)`, `isIgnored(name)`, `isUnreachable(id)`, `isTargetInRange(spellName, id)` (detrimental spell: distance <= `Spell.Range` + 2), `tickSerial` (one value per main-loop pass; the plugin caches its decision per tick and spell),
`isSpawnPetOrPlayer`. Extended Target is read directly: `mq.TLO.Me.XTargetSlots()`, `mq.TLO.Me.XTarget(i).ID()`, then `mq.TLO.Spawn(id)` fields `CleanName`, `Level`, `Distance3D`, `PctHPs`, `Type`.
(On this server the auto-hater XTarget slots are shared by the whole group, so adds the tank is hit by also show on the Enchanter's XTarget.)

## 7. Conventions in TAC's code that matter here

- Chat colour codes: `'\ay[Triune]\ax text'`, `\ar` red, `\ag` green, `\ao` orange; a single backslash.
- `core.log` debug lines only appear while Debug Mode is on; everything printed also lands in the log file when "Log To File" is on (`MacroQuest/Logs/triune__<Char>.log`).
- Plugin files are loaded with `loadfile` and run in TAC's process; a load error shows on the Plugins tab. Plugins must not call `mq.delay` from draw callbacks.
- TAC's own test file has suites that enumerate shipped plugins (`Suite 88`, `Suite 92`). They are **not** affected by an externally installed plugin.
