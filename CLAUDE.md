# Working notes for Claude (read this first)

This repo is a **plugin for TAC (Triune AutoCombat)**: an Enchanter "Mez Support" plugin. It was designed over a long
conversation; the decisions are written down in `docs/DESIGN.md` so you do not have to re-derive them. Read, in order:

1. `README.md` (what it is, how to try it)
2. `docs/DESIGN.md` (what was decided and why, including what was rejected)
3. `docs/TAC-INTEGRATION.md` (the TAC internals this plugin relies on, with the facts verified in TAC's source)
4. `docs/NEXT-STEPS.md` (what is untested, what to do next)
5. `docs/TESTING.md` (how to run the tests and how to test in game)

## Who and where

- Owner: **thezerodivide** (GitHub). This repo: `thezerodivide/TAC-EnchanterSupportPlugin`, local clone `C:\Users\legal\source\repos\TAC-EnchanterSupportPlugin`.
- TAC upstream: `gennro/TriuneAutocombat`. The owner's fork: `thezerodivide/TriuneAutocombat-4Class`, local clone
  `C:\Users\legal\source\repos\TriuneAutocombat-4Class`. **That clone has the owner's uncommitted four-class work in it. Do not modify,
  stash, reset or commit it** unless asked.
- The plugin needs a TAC build that has the **target selector registry** (see `patches/`). The fork's branch
  `wip/mez-support` has the registry plus an earlier copy of this plugin.
- MacroQuest's installed copy of TAC is a plain copy (not a link): `C:\Users\Public\MacroQuest\lua\triune.lua` and `...\lua\tac\*.lua`.
- TAC's own logs: `C:\Users\Public\MacroQuest\Logs\triune__<Character>.log`. EverQuest logs: `C:\Users\Public\Project Triune\Logs`.
- The game's spell database (not in this repo, 27 MB): `C:\Users\Public\RatQuest\RatQuestPatch\files\Resources\spells_us.txt`.

## How the owner likes to work (learned the hard way)

- **Agree the design before building.** Lay out options, give a recommendation, wait for a decision. Do not build something "that isn't needed".
- **Do not infer from labels or assume.** Read the code and cite it. If something is a guess or a heuristic, say so in the answer and in the code comment.
  Several early answers were wrong because a plausible assumption was stated as fact. Verify, then claim.
- **Report faithfully.** If tests fail, say which and why. Say when a check was weaker than it sounds. Say when a step was skipped.
- **No unrequested scope.** Do not add features, settings or "improvements" that were not agreed. Do not widen a change to other files.
- **Outward-facing actions need an explicit request:** pushing, opening PRs, creating repos, editing MacroQuest's installed files.
  Never open a PR against `gennro/TriuneAutocombat` unless explicitly asked; when asked, open it as a **draft** so CI runs first.
  Pushing a branch to the owner's own repos is fine only when asked.
- **Keep TAC general-purpose.** Anything that goes into TAC itself must be generic and behavior-neutral by default. Personal preferences
  live in this plugin, as defaults that can be changed.
- **Test before PRs.** The owner tests in game first. Every rule in the decision logic has a unit test, and `tools/mutation_check.py`
  proves the tests can fail. Keep it that way: when you add a rule, add a test and a mutation.

## Environment

- Windows 11; Git Bash and PowerShell. LuaJIT is on the PATH (`luajit`). **The plugin needs LuaJIT/Lua 5.1** (it is loaded with `setfenv` in tests;
  TAC itself runs on LuaJIT).
- Python: the bare `python` command may be a Microsoft Store stub that fails. Use `C:\Users\legal\AppData\Local\Python\bin\python.exe -I script.py`.
- Line endings: TAC's repo is `* text=auto` (LF in the repo, CRLF in Windows working copies). This repo does the same (`.gitattributes`).
- Big heredocs in the shell tool can fail on quote parsing; write files with the file tool instead.
- MacroQuest colour codes in Lua strings are a **single** backslash escape (`'\ay[Triune Mez]\ax text'`); `\a` is the BEL character MQ looks for.

## Commands

```
luajit tests/run.lua                                   # all unit tests (no TAC needed)
TAC_SOURCE=path/to/triune.lua luajit tests/run.lua     # also checks against TAC's real registry code
python tools/mutation_check.py                         # break rules on purpose; every one must be caught
python tools/verify_spell_data.py [spells_us.txt]      # check the SPELLS table against the game's spell file
```

## Gotchas

- Lua's `pairs` skips `nil` values: a test helper that "removes" a field by passing `nil` does nothing. The tests use `__nil = { 'field' }` or `false`.
- A chunk may not start with `;`. Test files start with `(function()`.
- Do not add a rule to `decide()` without a status or an `excluded` counter for it; the window and chat text are built from those.
- The decision function must stay pure (no `mq`, no `core`). All game reads belong in the collection layer.
