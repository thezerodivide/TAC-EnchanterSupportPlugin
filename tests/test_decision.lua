-- ---------------------------------------------------------------------------
-- Decision logic: the pure decide() function, spell data, status text and chat rate limit
-- ---------------------------------------------------------------------------
(function()
    print('--- Decision logic ---')
    local chunk = assert(loadfile(PLUGIN_FILE))
    local plugin = chunk()
    local L = plugin.logic
    local S = L.STATUS

    assert_eq(plugin.id, 'mez', 'mez: plugin id')
    assert_eq(plugin.defaultEnabled, false, 'mez: in development, so not enabled by default')
    assert_type(L.decide, 'function', 'mez: decide is exposed')

    -- builders -------------------------------------------------------------
    local function mob(id, over)
        local m = { id = id, name = 'mob' .. id, level = 50, dist = 200 - 10 * id, hpPct = 100,
            hostile = true, isNpc = true, ignored = false, unreachable = false,
            lockedOut = false, inRange = true, mez = { state = 'none' } }
        for k, v in pairs(over or {}) do
            if k ~= '__nil' then m[k] = v end
        end
        for _, k in ipairs((over or {}).__nil or {}) do m[k] = nil end
        return m
    end
    local function state(over)
        local s = { spell = 'Glamour of Kintaz', settings = {}, ma = { configured = true, status = 'target', id = 1 },
            peers = {}, mobs = { mob(1), mob(2) } }
        for k, v in pairs(over or {}) do s[k] = v end
        return s
    end
    local function deepcopy(t)
        if type(t) ~= 'table' then return t end
        local c = {}
        for k, v in pairs(t) do c[k] = deepcopy(v) end
        return c
    end

    -- spell data ------------------------------------------------------------
    local supported, unsupported, names = 0, 0, {}
    for _, sp in ipairs(L.SPELLS) do
        assert_nil(names[L.normalize(sp.name)], 'mez data: unique name ' .. sp.name)
        names[L.normalize(sp.name)] = true
        if sp.supported then
            supported = supported + 1
            assert_type(sp.maxMobLevel, 'number', 'mez data: level cap for ' .. sp.name)
            assert_eq(sp.castSec, 2.5, 'mez data: cast time for ' .. sp.name)
            assert_true(type(sp.landed) == 'string' and #sp.landed > 5, 'mez data: landing text for ' .. sp.name)
        else
            unsupported = unsupported + 1
            assert_type(sp.reason, 'string', 'mez data: reason for refusing ' .. sp.name)
        end
    end
    assert_eq(supported, 12, 'mez data: 12 supported single-target Enchanter mezzes')
    assert_eq(unsupported, 8, 'mez data: 8 refused (7 area + Echoing Madness)')
    assert_eq(L.spellInfo('Glamour of Kintaz').maxMobLevel, 57, 'mez data: Glamour of Kintaz level cap')
    assert_eq(L.spellInfo('Euphoria').maxMobLevel, 73, 'mez data: Euphoria level cap')
    assert_eq(L.spellInfo('Dazzle Rk. II').name, 'Dazzle', 'mez data: rank suffix is ignored')
    assert_eq(L.spellInfo('glamour of kintaz').name, 'Glamour of Kintaz', 'mez data: case is ignored')
    assert_nil(L.spellInfo('Kelin\'s Lucid Lullaby'), 'mez data: a Bard song is not an Enchanter mez here')
    assert_nil(L.spellInfo(nil), 'mez data: nil spell')

    -- mez messages (pure matching) -----------------------------------------------------
    assert_eq(#L.landedTexts(), 9, 'msg: 12 supported spells print 9 distinct landing texts')
    local rap = L.spellsForLanding(' swoons in raptured bliss.')
    assert_true(rap['Rapture'] and rap['Ancient: Eternal Rapture'] and not rap['Sleep'], 'msg: Rapture and Ancient: Eternal Rapture share a text, Sleep does not')
    local recs = {
        { mobId = 1, name = 'a Chetari guard', spell = 'Rapture', castAt = 100, expiry = 160 },
        { mobId = 2, name = 'a Chetari warrior', spell = 'Rapture', castAt = 100, expiry = 160 },
    }
    local m = L.matchLanding(rap, 'A Chetari guard', recs, 102, {})
    assert_eq(m and m.mobId, 1, 'msg: a landing message matches the cast by name, ignoring case')
    local none, why = L.matchLanding(rap, 'A Chetari guard', recs, 120, {})
    assert_true(none == nil and why == 'none', 'msg: a landing message long after the cast matches nothing')
    none, why = L.matchLanding(L.spellsForLanding(' falls asleep.'), 'A Chetari guard', recs, 102, {})
    assert_true(none == nil and why == 'none', 'msg: the text of a different spell matches nothing')
    none, why = L.matchLanding(rap, 'A Chetari guard', recs, 102, { ['1:Rapture'] = 100 })
    assert_true(none == nil and why == 'none', 'msg: a cast already confirmed is not confirmed twice')
    recs[3] = { mobId = 3, name = 'a chetari guard', spell = 'Rapture', castAt = 101, expiry = 161 }
    none, why = L.matchLanding(rap, 'A Chetari guard', recs, 102, {})
    assert_true(none == nil and why == 'ambiguous', 'msg: two recent casts on same-named mobs are ambiguous')
    local id, spells = L.matchEnd('a Chetari warrior', nil, recs, 110)
    assert_eq(id, 2, 'msg: an ended mez matches the mob by name')
    assert_eq(spells[1], 'Rapture', 'msg: ...and lists the spell to drop')
    id, spells = L.matchEnd('A Chetari guard', nil, recs, 110)
    assert_true(id == nil and spells == 'ambiguous', 'msg: same-named mobs both mezzed -> ambiguous')
    id, spells = L.matchEnd('a Chetari warrior', 'Sleep', recs, 110)
    assert_true(id == nil and spells == 'none', 'msg: worn off of another spell matches nothing')
    id, spells = L.matchEnd('a Chetari warrior', nil, recs, 200)
    assert_true(id == nil and spells == 'none', 'msg: a record already past its expiry is not matched')
    local pend = { ['1:Rapture'] = { mobId = 1, spell = 'Rapture', at = 100 }, ['2:Rapture'] = { mobId = 2, spell = 'Rapture', at = 100 },
        ['3:Rapture'] = { mobId = 3, spell = 'Rapture', at = 100 }, ['4:Rapture'] = { mobId = 4, spell = 'Rapture', at = 108 } }
    local applied = { [1] = { Rapture = 160 }, [2] = { Rapture = 160 } }   -- 3 was cleared by a failed cast
    local un = L.unconfirmedCasts(pend, { ['2:Rapture'] = 100 }, applied, 110)
    assert_eq(#un, 1, 'msg: only an unconfirmed, still-recorded cast past the window is reported')
    assert_eq(un[1].mobId, 1, 'msg: ...the right one')
    assert_nil(pend['1:Rapture'], 'msg: reported entries are dropped')
    assert_true(pend['4:Rapture'] ~= nil, 'msg: a cast still inside the window keeps waiting')

    -- 1. unsupported spells --------------------------------------------------
    for _, name in ipairs({ 'Mesmerization', 'Fascination', 'Bliss of the Nihil', 'Wake of Felicity',
        'Entrancing Lights', 'Word of Morell', 'Circle of Dreams', 'Echoing Madness' }) do
        local r = L.decide(state({ spell = name }))
        assert_eq(r.status, S.SPELL_UNSUPPORTED, 'decide: ' .. name .. ' is refused')
        assert_nil(r.id, 'decide: ' .. name .. ' picks nothing')
        assert_type(r.reason, 'string', 'decide: ' .. name .. ' says why')
    end
    assert_eq(L.decide(state({ spell = 'Fireball' })).status, S.SPELL_UNSUPPORTED, 'decide: a non-mez spell is refused')
    assert_eq(L.decide(state({ spell = false })).status, S.SPELL_UNSUPPORTED, 'decide: no spell is refused')
    assert_eq(L.decide(state({ spell = 'Mesmerization', ma = { configured = false } })).status, S.SPELL_UNSUPPORTED,
        'decide: an unsupported spell is reported before any Main Assist problem')

    -- 2. Main Assist handling ---------------------------------------------------
    assert_eq(L.decide(state({ ma = { configured = false, status = 'target', id = 1 } })).status, S.MA_NOT_SET, 'ma: not configured')
    assert_eq(L.decide(state({ ma = false })).status, S.MA_NOT_SET, 'ma: missing table counts as not configured')
    assert_eq(L.decide(state({ ma = { configured = true, status = 'unknown' } })).status, S.MA_UNAVAILABLE, 'ma: unknown target -> unavailable')
    assert_eq(L.decide(state({ ma = { configured = true, status = 'target', id = 0 } })).status, S.MA_UNAVAILABLE, 'ma: a target with no id -> unavailable')
    assert_eq(L.decide(state({ ma = { configured = true, status = 'target' } })).status, S.MA_UNAVAILABLE, 'ma: a target with a nil id -> unavailable')
    assert_eq(L.decide(state({ ma = { configured = true, status = 'banana', id = 1 } })).status, S.MA_UNAVAILABLE, 'ma: an unrecognized status fails closed')
    assert_eq(L.decide(state({ ma = { configured = true, status = 'none' } })).status, S.MA_NO_TARGET, 'ma: explicitly no target -> wait')
    assert_eq(L.decide(state({ ma = { configured = true, status = 'none', id = 2 } })).status, S.MA_NO_TARGET, 'ma: "none" ignores any stale id')
    assert_eq(L.decide(state({ ma = { configured = false, status = 'none' } })).status, S.MA_NOT_SET, 'ma: not configured beats no target')
    for _, bad in ipairs({ { configured = false }, { configured = true, status = 'unknown' }, { configured = true, status = 'none' } }) do
        assert_nil(L.decide(state({ ma = bad })).id, 'ma: no mez target when the Main Assist is not usable (' .. tostring(bad.status) .. ')')
    end

    -- 3. the basics ---------------------------------------------------------------
    local r = L.decide(state())
    assert_eq(r.status, S.CANDIDATE, 'basic: an add is a candidate')
    assert_eq(r.id, 2, 'basic: the Main Assist\'s target (1) is skipped, the add (2) is picked')
    assert_eq(r.name, 'mob2', 'basic: the candidate\'s name is returned')
    assert_eq(r.excluded.ma, 1, 'basic: the Main Assist\'s mob is counted as excluded')
    r = L.decide(state({ mobs = { mob(1) } }))
    assert_eq(r.status, S.NO_ELIGIBLE, 'basic: only the Main Assist\'s target on XTarget -> nothing to mez')
    assert_nil(r.id, 'basic: ...and no id')
    assert_eq(L.decide(state({ mobs = {} })).status, S.NO_ELIGIBLE, 'basic: an empty mob list -> nothing to mez')
    assert_eq(L.decide(state({ mobs = false })).status, S.NO_ELIGIBLE, 'basic: a nil mob list -> nothing to mez')
    assert_eq(L.decide({}).status, S.SPELL_UNSUPPORTED, 'basic: an empty state is refused, not an error')
    assert_eq(L.decide(nil).status, S.SPELL_UNSUPPORTED, 'basic: a nil state is refused, not an error')

    -- 4. other boxes ---------------------------------------------------------------
    local three = { mob(1), mob(2), mob(3) }
    r = L.decide(state({ mobs = three, peers = { { fresh = true, id = 2, engaged = true } } }))
    assert_eq(r.id, 3, 'peers: a fresh, engaged peer target is skipped')
    assert_eq(r.excluded.peer, 1, 'peers: ...and counted')
    r = L.decide(state({ mobs = three, peers = { { fresh = false, id = 2, engaged = true } } }))
    assert_eq(r.id, 2, 'peers: a stale heartbeat is ignored')
    r = L.decide(state({ mobs = three, peers = { { fresh = true, id = 2, engaged = false } } }))
    assert_eq(r.id, 2, 'peers: a fresh peer that is not engaged does not protect its target')
    r = L.decide(state({ mobs = three, peers = { { fresh = true, id = 0, engaged = true }, { fresh = true, engaged = true } } }))
    assert_eq(r.id, 2, 'peers: a peer with no target does nothing')
    r = L.decide(state({ mobs = three, peers = { { fresh = true, id = 2, engaged = true }, { fresh = true, id = 3, engaged = true } } }))
    assert_eq(r.status, S.NO_ELIGIBLE, 'peers: two boxes fighting the two adds leaves nothing to mez')
    r = L.decide(state({ mobs = three, peers = { { fresh = true, id = 1, engaged = true } } }))
    assert_eq(r.id, 2, 'peers: a peer on the Main Assist\'s mob changes nothing')
    r = L.decide(state({ mobs = three, peers = false }))
    assert_eq(r.id, 2, 'peers: no peer information at all still decides')

    -- 5. damaged-add protection ----------------------------------------------------------
    local dmg = { mob(1), mob(2, { hpPct = 80 }), mob(3) }
    r = L.decide(state({ mobs = dmg }))
    assert_eq(r.id, 3, 'damaged: protection is on by default')
    assert_eq(r.excluded.damaged, 1, 'damaged: ...and counted')
    r = L.decide(state({ mobs = dmg, settings = { damagedProtection = true } }))
    assert_eq(r.id, 3, 'damaged: explicitly on')
    r = L.decide(state({ mobs = dmg, settings = { damagedProtection = false } }))
    assert_eq(r.id, 2, 'damaged: with the setting off the damaged add is allowed (and is nearest)')
    assert_eq(L.decide(state({ mobs = { mob(1), mob(2, { hpPct = 100 }) } })).id, 2, 'damaged: exactly 100% counts as undamaged')
    assert_eq(L.decide(state({ mobs = { mob(1), mob(2, { hpPct = 99 }) } })).status, S.NO_ELIGIBLE, 'damaged: 99% is damaged')
    assert_eq(L.decide(state({ mobs = { mob(1), mob(2, { __nil = { 'hpPct' } }) } })).id, 2, 'damaged: unknown HP counts as undamaged')

    -- 6. mez state -----------------------------------------------------------------------------
    local function withMez(mz) return state({ mobs = { mob(1), mob(2, { mez = mz }), mob(3) } }) end
    assert_eq(L.decide(withMez({ state = 'pending' })).id, 3, 'mez: a pending mez excludes the mob')
    assert_eq(L.decide(withMez({ state = 'active', remaining = 40 })).id, 3, 'mez: an active mez with time left excludes the mob')
    assert_eq(L.decide(withMez({ state = 'active', remaining = 4.5 })).id, 2, 'mez: an active mez at cast time + 2s is due for a refresh (boundary)')
    assert_eq(L.decide(withMez({ state = 'active', remaining = 4.6 })).id, 3, 'mez: just above the refresh window is still protected')
    assert_eq(L.decide(withMez({ state = 'active', remaining = 1 })).id, 2, 'mez: an active mez about to expire is eligible')
    assert_eq(L.decide(withMez({ state = 'active', remaining = 0 })).id, 2, 'mez: an expired mez is eligible')
    assert_eq(L.decide(withMez({ state = 'active' })).id, 2, 'mez: an active mez with no time left known is eligible')
    assert_eq(L.decide(withMez({ state = 'none' })).id, 2, 'mez: no mez record is eligible')
    assert_eq(L.decide(withMez(false)).id, 2, 'mez: a missing record is eligible')
    r = L.decide(state({ mobs = { mob(1), mob(2, { mez = { state = 'active', remaining = 6.5 } }), mob(3) }, refreshMarginSec = 4 }))
    assert_eq(r.id, 2, 'mez: a custom refresh margin is honoured')
    assert_eq(L.decide(withMez({ state = 'pending' })).excluded.mezzed, 1, 'mez: excluded mezzed mobs are counted')

    -- 7. level cap ------------------------------------------------------------------------------------
    local function lvl(l, spell) return state({ spell = spell or 'Glamour of Kintaz', mobs = { mob(1), mob(2, l == false and { __nil = { 'level' } } or { level = l }) } }) end
    assert_eq(L.decide(lvl(57)).id, 2, 'level: a mob at the cap is eligible')
    assert_eq(L.decide(lvl(58)).status, S.NO_ELIGIBLE, 'level: a mob above the cap is not')
    assert_eq(L.decide(lvl(0)).id, 2, 'level: an unknown level (0) is not blocked')
    assert_eq(L.decide(lvl(false)).id, 2, 'level: a missing level is not blocked')
    assert_eq(L.decide(lvl(60, 'Mesmerize')).status, S.NO_ELIGIBLE, 'level: Mesmerize cannot take a level 60 mob')
    assert_eq(L.decide(lvl(60, 'Euphoria')).id, 2, 'level: Euphoria can')
    assert_eq(L.decide(lvl(58)).excluded.level, 1, 'level: counted')

    -- 8. the other per-mob filters ---------------------------------------------------------------------------
    local function one(over) return L.decide(state({ mobs = { mob(1), mob(2, over) } })) end
    assert_eq(one({ hostile = false }).status, S.NO_ELIGIBLE, 'filter: not hostile')
    assert_eq(one({ isNpc = false }).status, S.NO_ELIGIBLE, 'filter: not an NPC')
    assert_eq(one({ ignored = true }).status, S.NO_ELIGIBLE, 'filter: ignored')
    assert_eq(one({ unreachable = true }).status, S.NO_ELIGIBLE, 'filter: unreachable')
    assert_eq(one({ lockedOut = true }).status, S.NO_ELIGIBLE, 'filter: locked out for this spell')
    assert_eq(one({ inRange = false }).status, S.NO_ELIGIBLE, 'filter: out of range')
    assert_eq(one({ __nil = { 'inRange' } }).status, S.NO_ELIGIBLE, 'filter: unknown range is not assumed in range')
    assert_eq(one({ id = 0 }).status, S.NO_ELIGIBLE, 'filter: a mob with no id')
    assert_eq(one({}).id, 2, 'filter: a clean add passes')

    -- 9. choosing among candidates ---------------------------------------------------------------------------------
    local far = state({ mobs = { mob(1), mob(5, { dist = 90 }), mob(4, { dist = 30 }), mob(9, { dist = 60 }) } })
    assert_eq(L.decide(far).id, 5, 'choice: the farthest candidate wins')
    assert_eq(L.decide(state({ mobs = { mob(1), mob(7, { dist = 20 }), mob(3, { dist = 20 }) } })).id, 3, 'choice: equal distance goes to the lowest id')
    assert_eq(L.decide(state({ mobs = { mob(1), mob(7, { __nil = { 'dist' } }), mob(3, { dist = 80 }) } })).id, 3, 'choice: an unknown distance sorts last')
    assert_eq(L.decide(state({ mobs = { mob(1), mob(7, { __nil = { 'dist' } }) } })).id, 7, 'choice: ...but is still chosen when it is the only one')

    -- 10. combinations ---------------------------------------------------------------------------------------------------
    -- MA target + two adds, one damaged and one already mezzed
    local combo = state({ mobs = { mob(1), mob(2, { hpPct = 60, dist = 15 }), mob(3, { mez = { state = 'active', remaining = 50 }, dist = 20 }) } })
    r = L.decide(combo)
    assert_eq(r.status, S.NO_ELIGIBLE, 'combo: MA target + damaged add + mezzed add -> nothing to mez')
    assert_eq(r.excluded.ma, 1, 'combo: ...MA target counted')
    assert_eq(r.excluded.damaged, 1, 'combo: ...damaged add counted')
    assert_eq(r.excluded.mezzed, 1, 'combo: ...mezzed add counted')
    -- a third, far, clean add is chosen over the three excluded mobs
    local combo2 = deepcopy(combo)
    combo2.mobs[#combo2.mobs + 1] = mob(4, { dist = 120 })
    assert_eq(L.decide(combo2).id, 4, 'combo: the one clean add is picked however far it is')
    -- turn protection off: the damaged add is a candidate again (the only one without the far clean add)
    local combo2off = deepcopy(combo)
    combo2off.settings = { damagedProtection = false }
    assert_eq(L.decide(combo2off).id, 2, 'combo: protection off -> the damaged add is allowed again')
    combo2.settings = { damagedProtection = false }
    assert_eq(L.decide(combo2).id, 4, 'combo: protection off, the farthest of the remaining wins')
    -- the same board with the mezzed add due for a refresh
    local combo3 = deepcopy(combo2)
    combo3.settings = {}
    combo3.mobs[3].mez.remaining = 3
    combo3.mobs[3].dist = 150
    assert_eq(L.decide(combo3).id, 3, 'combo: a mezzed add due for a refresh is a candidate again (here the farthest)')
    -- peers fighting the farthest clean add push the choice nearer
    combo3.peers = { { fresh = true, id = 3, engaged = true } }
    assert_eq(L.decide(combo3).id, 4, 'combo: ...unless another box is fighting it')
    -- a stale peer entry does not
    combo3.peers = { { fresh = false, id = 3, engaged = true } }
    assert_eq(L.decide(combo3).id, 3, 'combo: ...and a stale peer entry does not')
    -- everything wrong at once
    local mess = state({ spell = 'Mesmerize', mobs = {
        mob(1), mob(2, { level = 70 }), mob(3, { ignored = true }), mob(4, { lockedOut = true }),
        mob(5, { inRange = false }), mob(6, { hpPct = 10 }), mob(7, { unreachable = true }), mob(8, { dist = 1 }) },
        peers = { { fresh = true, id = 8, engaged = true } } })
    r = L.decide(mess)
    assert_eq(r.status, S.NO_ELIGIBLE, 'combo: every filter at once leaves nothing')
    local function n(k) return r.excluded[k] or 0 end
    assert_eq(n('ma') + n('level') + n('ignored') + n('lockedOut') + n('range') + n('damaged') + n('unreachable') + n('peer'), 8,
        'combo: every mob is accounted for exactly once')
    for _, k in ipairs({ 'ma', 'level', 'ignored', 'lockedOut', 'range', 'damaged', 'unreachable', 'peer' }) do
        assert_eq(n(k), 1, 'combo: exactly one mob excluded for ' .. k)
    end

    -- 11. purity ---------------------------------------------------------------------------------------------------------------
    local snapshot = deepcopy(combo2)
    local before = deepcopy(snapshot)
    L.decide(snapshot)
    local function equal(a, b)
        if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
        for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
        for k, v in pairs(b) do if a[k] == nil and v ~= nil then return false end end
        return true
    end
    assert_true(equal(snapshot, before), 'pure: decide does not change its input')
    local a1, a2 = L.decide(combo2), L.decide(combo2)
    assert_eq(a1.id, a2.id, 'pure: the same state gives the same answer')
    assert_eq(a1.status, a2.status, 'pure: ...and the same status')

    -- 12. reporting ---------------------------------------------------------------------------------------------------------------------
    assert_eq(L.statusText(L.decide(state())), 'Mez candidate: mob2', 'text: candidate')
    assert_eq(L.statusText(L.decide(state({ ma = { configured = false } }))), 'Configuration: Main Assist not set', 'text: MA not set')
    assert_eq(L.statusText(L.decide(state({ ma = { configured = true, status = 'unknown' } }))), 'Waiting: Main Assist target unavailable', 'text: MA unavailable')
    assert_eq(L.statusText(L.decide(state({ ma = { configured = true, status = 'none' } }))), 'Waiting: Main Assist has no target', 'text: MA has no target')
    assert_eq(L.statusText(L.decide(state({ mobs = { mob(1) } }))), 'No eligible mez targets (skipped: 1 Main Assist target)', 'text: nothing eligible, with the reason')
    assert_eq(L.statusText(L.decide(state({ mobs = {} }))), 'No eligible mez targets', 'text: nothing eligible, nothing excluded')
    assert_true(L.statusText(L.decide(combo)):find('1 damaged', 1, true), 'text: the damaged count is shown')
    assert_true(L.statusText(L.decide(combo)):find('1 already mezzed', 1, true), 'text: the mezzed count is shown')
    assert_true(L.statusText(L.decide(state({ spell = 'Fascination' }))):find('Unsupported mez spell', 1, true), 'text: unsupported spell')
    assert_eq(L.statusText(nil), 'Mez: unknown status', 'text: nil result')
    -- distinct statuses
    local seen = {}
    for _, st in ipairs({ state({ ma = { configured = false } }), state({ ma = { configured = true, status = 'unknown' } }),
        state({ ma = { configured = true, status = 'none' } }), state({ mobs = {} }), state() }) do
        seen[L.statusText(L.decide(st))] = true
    end
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    assert_eq(distinct, 5, 'text: the five situations read differently')

    -- rate limiting -------------------------------------------------------------------------------------------------------------------------
    assert_eq(L.announce(nil, S.MA_UNAVAILABLE, 100), true, 'announce: the first message is said')
    assert_eq(L.announce({ status = S.MA_UNAVAILABLE, at = 100 }, S.MA_UNAVAILABLE, 110), false, 'announce: an unchanged status is quiet')
    assert_eq(L.announce({ status = S.MA_UNAVAILABLE, at = 100 }, S.MA_UNAVAILABLE, 130), true, 'announce: ...and repeats after the gap')
    assert_eq(L.announce({ status = S.MA_UNAVAILABLE, at = 100 }, S.MA_UNAVAILABLE, 120, 15), true, 'announce: a custom gap is honoured')
    assert_eq(L.announce({ status = S.MA_UNAVAILABLE, at = 100 }, S.MA_NO_TARGET, 101), true, 'announce: a changed status is said at once')
    assert_eq(L.announce(nil, S.CANDIDATE, 100), false, 'announce: candidates are not announced in chat')
    assert_eq(L.announce({ status = S.NO_ELIGIBLE, at = 100 }, S.CANDIDATE, 200), false, 'announce: ...even after a different status')
end)()

