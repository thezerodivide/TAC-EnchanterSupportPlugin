# TAC patch: target selector registry

`tac-target-selector-registry.patch` is the one change this plugin needs inside TAC. It is generic and does not mention mez.

What it does (details in `../docs/TAC-INTEGRATION.md`):

1. **Registry:** a plugin can add an entry to every Target dropdown and supply the function that returns a spawn id
   (`core.registerTargetSelector{ owner, label, side, help, resolve }`). A plugin's selectors are removed when it is disabled or reloaded.
2. **Fail closed:** an `E:`/`F:` target token that is neither built in nor registered resolves to no target instead of falling back to the current target.
3. **Dropdown fix:** the Target dropdowns keep a saved token that is not in the list (shown as `<token> (unavailable)`) instead of overwriting it with `F: Myself`.
4. **Tests:** Suite 113 in `tests/test_pure_logic.lua`, plus a stub for the new call in the three plugin-manager test environments.

It is a single commit (`git format-patch` output) against the owner's fork `main` at `06755f6` (upstream `gennro/TriuneAutocombat` PR #21), touching `TAC/lua/triune.lua` and `tests/test_pure_logic.lua`.

Apply to a clean TAC checkout:

```
git am patches/tac-target-selector-registry.patch          # keeps the commit message
# or
git apply patches/tac-target-selector-registry.patch       # changes only
```

Verified: applies cleanly to that `main`; the full TAC test file then ends at 6532 passed, 2 failed (the two failures are the known unrelated ones, see `../docs/TESTING.md`).

It does **not** apply cleanly to a TAC tree that already has other local changes in the same places. The owner's working copy of TAC (`C:\Users\legal\source\repos\TriuneAutocombat-4Class`) already contains the registry
(plus unrelated uncommitted work), so it does not need the patch. The same change is on the fork branch `wip/mez-support`, together with an earlier copy of this plugin.
A local-only branch `feat/target-selector-registry` (the same commit) exists in that clone's repository; it has not been pushed.

This has not been submitted upstream. Submitting it is the owner's call: open it as a **draft** PR so CI runs first.
