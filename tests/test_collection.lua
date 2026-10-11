-- ---------------------------------------------------------------------------
-- State collection, mez tracking, the target selector and the plugin lifecycle
-- ---------------------------------------------------------------------------
(function()
    print('--- Collection, tracking and selector ---')

    -- a fake game world ------------------------------------------------------
    local W
    local printed
    local function callable(fields, exists)
        return setmetatable(fields, { __call = function() return exists ~= false end })
    end
    local function newWorld()
        W = { now = 1000, serial = 1, maId = 500, fed = nil, assist = nil, bn = 'default',
            mobs = {}, xt = {}, ignored = {}, unreachable = {}, locked = {}, outOfRange = {},
            xtCalls = 0, logs = {}, registered = nil, unregistered = nil, ctrl = { ma_id = 500, ma_name = 'Tank' } }
        printed = {}
        W.events, W.unevented = {}, {}
        local mq = {
            event = function(name, pattern, fn) W.events[name] = { pattern = pattern, fn = fn } end,
            unevent = function(name) W.events[name] = nil; W.unevented[#W.unevented + 1] = name end,
            TLO = {
            Me = {
                XTargetSlots = function() W.xtCalls = W.xtCalls + 1; return 13 end,
                XTarget = function(i)
                    local id = W.xt[i]
                    return callable({ ID = function() return id end }, id ~= nil)
                end,
            },
            Spawn = function(id)
                local m = W.mobs[id]
                if not m then return callable({}, false) end
                return callable({
                    CleanName = function() return m.name end,
                    Level = function() return m.level end,
                    Distance3D = function() return m.dist end,
                    Distance = function() return m.dist end,
                    PctHPs = function() return m.hp end,
                    Type = function() return m.type end,
                    Dead = function() return false end,
                })
            end,
        } }
        local rt = {
            tickSerial = nil,
            BOXNET_FRESH_SEC = 3.0,
            npcSpellApplied = {}, npcSpellLastCast = {},
            maPcId = function() return W.maId end,
            boxnetMaTarget = function() return W.fed end,
            maTargetId = function() return W.assist end,
            boxnetApi = function()
                if W.bn == 'default' then return nil end
                return W.bn
            end,
            isHostileTarget = function(id) return W.mobs[id] ~= nil and W.mobs[id].hostile ~= false end,
            isIgnored = function(name) return W.ignored[name] == true end,
            isUnreachable = function(id) return W.unreachable[id] == true end,
            isTargetInRange = function(_, id) return W.outOfRange[id] ~= true end,
        }
        W.rt = rt
        W.core = {
            runtime = rt, ctrl = W.ctrl, mq = mq,
            castTracker = { failed = false, isLockedOut = function(_, id) return W.locked[id] == true end },
            registerTargetSelector = function(spec) W.registered = spec; return true end,
            unregisterTargetSelector = function(label, owner) W.unregistered = { label = label, owner = owner }; return true end,
            saveLoadout = function() end,
            log = { debug = function(cat, fmt, ...) W.logs[#W.logs + 1] = cat .. ': ' .. string.format(fmt, ...) end },
        }
        return W
    end
    local function addMob(id, over)
        local m = { name = 'mob' .. id, level = 50, dist = id * 10, hp = 100, type = 'NPC', hostile = true }
        for k, v in pairs(over or {}) do m[k] = v end
        W.mobs[id] = m
        W.xt[#W.xt + 1] = id
        return m
    end
    local function loadPlugin()
        local fn = assert(loadfile(PLUGIN_FILE))
        local env = setmetatable({
            print = function(...) printed[#printed + 1] = table.concat({ ... }, ' ') end,
            os = { clock = function() return W.now end, time = os.time },
        }, { __index = _G })
        setfenv(fn, env)
        return fn()
    end
    local function ctx(spell) return { spellName = spell or 'Glamour of Kintaz', entry = { kind = 'util' } } end

    -- registration -------------------------------------------------------------
    newWorld()
    local plugin = loadPlugin()
    local L = plugin.logic
    plugin.onInit(W.core)
    assert_true(W.registered ~= nil, 'plugin: onInit registers a target selector')
    assert_eq(W.registered.label, 'Mez Target', 'plugin: the selector is called Mez Target')
    assert_eq(W.registered.owner, 'mez', 'plugin: ...owned by the plugin id (so disabling removes it)')
    assert_eq(W.registered.side, 'E', 'plugin: ...on the enemy side')
    assert_type(W.registered.resolve, 'function', 'plugin: ...with a resolver')
    assert_true(#W.registered.help > 20, 'plugin: ...with help text')
    plugin.onDestroy()
    assert_eq((W.unregistered or {}).label, 'Mez Target', 'plugin: onDestroy unregisters the selector')
    assert_eq((W.unregistered or {}).owner, 'mez', 'plugin: ...for its owner')
    assert_nil(W.registered.resolve(ctx()), 'plugin: after onDestroy the resolver returns nothing')

    -- Main Assist --------------------------------------------------------------
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    addMob(1); addMob(2); addMob(3)
    local resolve = W.registered.resolve
    W.fed = { id = 1 }
    assert_eq(resolve(ctx()), 2, 'ma: a boxnet-reported target is excluded; the nearest add wins')
    W.fed = false
    assert_nil(resolve(ctx()), 'ma: a fresh heartbeat with no target -> wait')
    assert_eq(L.decide(L.collectState(W.core, 'Glamour of Kintaz', nil, W.now)).status, L.STATUS.MA_NO_TARGET, 'ma: ...reported as "no target"')
    W.fed = nil; W.assist = nil
    assert_nil(resolve(ctx()), 'ma: no feed and no /assist result -> fail closed')
    assert_eq(L.decide(L.collectState(W.core, 'Glamour of Kintaz', nil, W.now)).status, L.STATUS.MA_UNAVAILABLE, 'ma: ...reported as "unavailable"')
    W.assist = 1
    assert_eq(resolve(ctx()), 2, 'ma: no feed, but /assist found the MA\'s target -> used')
    W.assist = nil; W.fed = { id = 77 }
    assert_nil(resolve(ctx()), 'ma: a reported target that is not on the board is treated as not a hostile NPC (wait)')
    addMob(40, { type = 'PC' }); W.fed = { id = 40 }
    assert_eq(L.decide(L.collectState(W.core, 'Glamour of Kintaz', nil, W.now)).status, L.STATUS.MA_NO_TARGET, 'ma: the MA targeting a player is "no enemy target"')
    W.mobs[40] = nil; W.xt[#W.xt] = nil
    W.fed = { id = 1 }
    W.ctrl.ma_id, W.ctrl.ma_name, W.maId = nil, nil, nil
    assert_eq(L.decide(L.collectState(W.core, 'Glamour of Kintaz', nil, W.now)).status, L.STATUS.MA_NOT_SET, 'ma: nothing configured -> configuration message')
    W.ctrl.ma_name = 'Tank'
    assert_eq(L.decide(L.collectState(W.core, 'Glamour of Kintaz', nil, W.now)).status, L.STATUS.CANDIDATE, 'ma: a configured name is enough')
    W.ctrl.ma_name = nil; W.ctrl.ma_id = 500; W.maId = 500

    -- other boxes ---------------------------------------------------------------
    W.fed = { id = 1 }
    W.bn = { peersInZone = function() return {
        { name = 'Dps', hb = { target = { id = 2, engaged = true } } },
        { name = 'Idle', hb = { target = { id = 3, engaged = false } } },
        { name = 'Nothing', hb = {} },
    } end }
    assert_eq(resolve(ctx()), 3, 'peers: a mob another box is engaged with is skipped; an idle box protects nothing')
    W.bn = { peersInZone = function() return {} end }
    assert_eq(resolve(ctx()), 2, 'peers: no fresh peers -> nothing extra excluded')
    W.bn = { peersInZone = function() error('boom') end }
    assert_eq(resolve(ctx()), 2, 'peers: a failing Box Network read does not break the decision')
    W.bn = 'default'
    assert_eq(resolve(ctx()), 2, 'peers: no Box Network at all still decides')

    -- the mob list -------------------------------------------------------------------
    local function pick(over, spell)
        newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
        addMob(1); addMob(2, over); addMob(3, { dist = 99 })
        W.fed = { id = 1 }
        return W.registered.resolve(ctx(spell))
    end
    assert_eq(pick({}), 2, 'mobs: a clean add is picked')
    assert_eq(pick({ type = 'Pet' }), 3, 'mobs: a non-NPC is skipped')
    assert_eq(pick({ hostile = false }), 3, 'mobs: a non-hostile is skipped')
    assert_eq(pick({ hp = 70 }), 3, 'mobs: a damaged add is skipped (protection on by default)')
    assert_eq(pick({ level = 60 }), 3, 'mobs: a mob above the spell\'s level cap is skipped')
    assert_eq(pick({ level = 60 }, 'Euphoria'), 2, 'mobs: ...but not for a spell with a higher cap')
    -- per-mob flags set after the world is built
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    addMob(1); addMob(2); addMob(3, { dist = 99 }); W.fed = { id = 1 }
    W.ignored.mob2 = true
    assert_eq(W.registered.resolve(ctx()), 3, 'mobs: an ignored name is skipped')
    W.ignored.mob2 = nil; W.unreachable[2] = true
    assert_eq(W.registered.resolve(ctx()), 3, 'mobs: an unreachable mob is skipped')
    W.unreachable[2] = nil; W.locked[2] = true
    assert_eq(W.registered.resolve(ctx()), 3, 'mobs: a locked-out mob is skipped')
    W.locked[2] = nil; W.outOfRange[2] = true
    assert_eq(W.registered.resolve(ctx()), 3, 'mobs: an out-of-range mob is skipped')
    W.outOfRange[2] = nil
    assert_eq(W.registered.resolve(ctx()), 2, 'mobs: with every flag cleared the nearest add is back')
    assert_nil(W.registered.resolve(ctx('Mesmerization')), 'mobs: an area mez gets no target')
    assert_true(printed[#printed] and printed[#printed]:find('Unsupported mez spell', 1, true), 'mobs: ...and the reason is said in chat')

    -- settings -------------------------------------------------------------------------------
    assert_eq(plugin.onSaveSettings().damagedProtection, true, 'settings: damaged-add protection defaults to on')
    plugin.onLoadSettings({ damagedProtection = false })
    assert_eq(plugin.onSaveSettings().damagedProtection, false, 'settings: it can be turned off and is saved')
    local PL = plugin.logic
    plugin.onLoadSettings({ damagedProtection = false })
    newWorld(); addMob(1); addMob(2, { hp = 70 }); addMob(3, { dist = 99 }); W.fed = { id = 1 }
    assert_eq(PL.decide(PL.collectState(W.core, 'Glamour of Kintaz', nil, W.now)).id, 2, 'settings: with protection off a damaged add is allowed')
    plugin.onLoadSettings({ damagedProtection = true })
    assert_eq(PL.decide(PL.collectState(W.core, 'Glamour of Kintaz', nil, W.now)).id, 3, 'settings: loading true turns it back on')
    plugin.onLoadSettings(nil); plugin.onLoadSettings('x'); plugin.onLoadSettings({})
    assert_eq(plugin.onSaveSettings().damagedProtection, true, 'settings: junk input leaves the setting alone')

    -- per-tick caching -------------------------------------------------------------------------------
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    addMob(1); addMob(2); W.fed = { id = 1 }
    W.rt.tickSerial = 7
    W.registered.resolve(ctx()); local after1 = W.xtCalls
    W.registered.resolve(ctx())
    assert_eq(W.xtCalls, after1, 'cache: a second call in the same tick reads nothing')
    W.rt.tickSerial = 8
    W.registered.resolve(ctx())
    assert_true(W.xtCalls > after1, 'cache: the next tick reads again')
    W.rt.tickSerial = 8
    local before = W.xtCalls
    W.registered.resolve(ctx('Euphoria'))
    assert_true(W.xtCalls > before, 'cache: a different spell in the same tick is not served from the cache')
    W.rt.tickSerial = nil
    before = W.xtCalls
    W.registered.resolve(ctx()); W.registered.resolve(ctx())
    assert_true(W.xtCalls >= before + 2, 'cache: without a tick serial nothing is cached')

    -- tracking: mezStateOf --------------------------------------------------------------------------
    local now = 1000
    local function st(applied, last) return L.mezStateOf(applied, last, now) end
    assert_eq(st(nil, nil).state, 'none', 'track: no record')
    assert_eq(st({}, {}).state, 'none', 'track: empty records')
    assert_eq(st({ ['Glamour of Kintaz'] = now + 50 }, { ['Glamour of Kintaz'] = now - 10 }).state, 'active', 'track: a cast with time left is active')
    assert_eq(math.floor(st({ ['Glamour of Kintaz'] = now + 50 }, { ['Glamour of Kintaz'] = now - 10 }).remaining), 44, 'track: remaining is capped by the listed duration (54 s from a cast 10 s ago)')
    assert_eq(st({ ['Glamour of Kintaz'] = now + 50 }, { ['Glamour of Kintaz'] = now - 1 }).state, 'pending', 'track: a cast issued a second ago is still pending')
    assert_eq(st({ ['Glamour of Kintaz'] = now + 50 }, { ['Glamour of Kintaz'] = now - 3.2 }).state, 'active', 'track: after the cast time it is active')
    assert_eq(st({ ['Glamour of Kintaz'] = now - 1 }, { ['Glamour of Kintaz'] = now - 60 }).state, 'none', 'track: an expired record is none')
    assert_eq(st({ ['Mesmerize'] = now + 24 }, { ['Mesmerize'] = now - 20 }).state, 'none', 'track: the listed 12 s duration caps a 24 s record')
    assert_eq(st({ ['Glamour of Kintaz'] = now + 50 }, nil).state, 'active', 'track: a record with no cast time is trusted')
    assert_eq(st({ ['Fireball'] = now + 50 }, { ['Fireball'] = now }).state, 'none', 'track: a non-mez spell record is ignored')
    assert_eq(st({ ['Glamour of Kintaz Rk. II'] = now + 40 }, { ['Glamour of Kintaz Rk. II'] = now - 5 }).state, 'active', 'track: a ranked spell name is recognized')
    local both = st({ ['Dazzle'] = now + 90, ['Entrance'] = now + 60 }, { ['Dazzle'] = now - 10, ['Entrance'] = now - 10 })
    assert_eq(math.floor(both.remaining), 86, 'track: of two mezzes the longest-lasting counts (Dazzle 86 s vs Entrance 60 s)')
    assert_eq(st({ ['Dazzle'] = now + 90, ['Entrance'] = now + 60 }, { ['Dazzle'] = now - 10, ['Entrance'] = now - 0.5 }).state, 'pending', 'track: a fresh cast makes the mob pending')

    -- tracking in the decision -------------------------------------------------------------------------------------
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    addMob(1); addMob(2); addMob(3, { dist = 99 }); W.fed = { id = 1 }
    W.rt.npcSpellApplied[2] = { ['Glamour of Kintaz'] = W.now + 50 }
    W.rt.npcSpellLastCast[2] = { ['Glamour of Kintaz'] = W.now - 10 }
    assert_eq(W.registered.resolve(ctx()), 3, 'flow: a mez TAC recorded keeps that add out of the choice')
    W.rt.npcSpellApplied[2]['Glamour of Kintaz'] = W.now + 3
    assert_eq(W.registered.resolve(ctx()), 2, 'flow: ...until it is about to expire, then it is renewed')
    W.rt.npcSpellApplied[2]['Glamour of Kintaz'] = W.now + 50
    W.rt.npcSpellLastCast[2]['Glamour of Kintaz'] = W.now - 0.5
    assert_eq(W.registered.resolve(ctx()), 3, 'flow: a mez being cast right now (pending) keeps it out too')

    -- tracking: failed casts ------------------------------------------------------------------------------------------------------
    local seen = {}
    local applied = { [2] = { ['Glamour of Kintaz'] = 1050 }, [3] = { ['Glamour of Kintaz'] = 1050 } }
    local lastCasts = { [2] = { ['Glamour of Kintaz'] = 1000.2 }, [3] = { ['Glamour of Kintaz'] = 900 } }
    local tracker = { failed = true, lastSpell = 'Glamour of Kintaz', lastTime = 1000 }
    assert_eq(L.clearFailedMez(tracker, applied, lastCasts, seen), 2, 'fail: a failed mez drops the record of the mob it was aimed at')
    assert_nil(applied[2]['Glamour of Kintaz'], 'fail: ...that record is gone')
    assert_true(applied[3]['Glamour of Kintaz'] ~= nil, 'fail: ...another mob\'s record is untouched')
    assert_nil(L.clearFailedMez(tracker, applied, lastCasts, seen), 'fail: the same failure is handled once')
    assert_nil(L.clearFailedMez({ failed = false, lastSpell = 'Glamour of Kintaz', lastTime = 1000 }, applied, lastCasts, {}), 'fail: a cast that did not fail changes nothing')
    assert_nil(L.clearFailedMez({ failed = true, lastSpell = 'Fireball', lastTime = 1000 }, applied, lastCasts, {}), 'fail: a failed non-mez cast changes nothing')
    assert_nil(L.clearFailedMez({ failed = true, lastSpell = 'Glamour of Kintaz', lastTime = 5000 }, applied, lastCasts, {}), 'fail: no mob cast at that time -> nothing cleared')
    assert_nil(L.clearFailedMez(nil, applied, lastCasts, {}), 'fail: no tracker')
    assert_nil(L.clearFailedMez({ failed = true }, applied, lastCasts, {}), 'fail: a tracker with no cast recorded')
    -- a second, later failure is handled even though the first was
    applied[3]['Glamour of Kintaz'] = 1050; lastCasts[3]['Glamour of Kintaz'] = 1010.1
    assert_eq(L.clearFailedMez({ failed = true, lastSpell = 'Glamour of Kintaz', lastTime = 1010 }, applied, lastCasts, seen), 3, 'fail: a later failure is handled too')
    -- wired through onCombatTick
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    W.rt.npcSpellApplied[2] = { ['Dazzle'] = W.now + 60 }
    W.rt.npcSpellLastCast[2] = { ['Dazzle'] = W.now - 1.1 }
    W.core.castTracker.failed = true; W.core.castTracker.lastSpell = 'Dazzle'; W.core.castTracker.lastTime = W.now - 1.2
    plugin.onCombatTick()
    assert_nil(W.rt.npcSpellApplied[2]['Dazzle'], 'fail: onCombatTick clears the record of a failed mez')
    plugin.onDestroy(); plugin.onCombatTick()
    assert_true(true, 'fail: onCombatTick after onDestroy is harmless')

    -- debug trace ---------------------------------------------------------------------------------------------------------------------------
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    addMob(1); addMob(2, { dist = 30 }); addMob(3, { hp = 50 })
    W.fed = { id = 1 }
    W.bn = { peersInZone = function() return { { name = 'Cleric', hb = { target = { id = 3, engaged = true } } } } end }
    W.registered.resolve(ctx())
    assert_eq(#W.logs, 2, 'trace: the first pick logs the input and the pick')
    assert_true(W.logs[1]:find('MA target #1 (Box Network feed); peers: Cleric>#3 engaged', 1, true), 'trace: the input names the MA target, its source and the peers')
    assert_true(W.logs[2]:find('pick #2 "mob2" dist 30', 1, true), 'trace: the pick names the mob and distance')
    assert_true(W.logs[2]:find('1 Main Assist target', 1, true) and W.logs[2]:find('1 fought by another box', 1, true), 'trace: ...and what was skipped')
    W.rt.tickSerial = 2
    W.registered.resolve(ctx())
    assert_eq(#W.logs, 2, 'trace: an unchanged input and pick log nothing')
    W.fed = nil; W.assist = 1
    W.rt.tickSerial = 3
    W.registered.resolve(ctx())
    assert_true(W.logs[#W.logs] and W.logs[#W.logs]:find('(/assist peek)', 1, true), 'trace: the /assist peek source is logged')
    W.fed = false
    W.rt.tickSerial = 4
    W.registered.resolve(ctx())
    assert_true(W.logs[#W.logs - 1]:find('MA no target', 1, true), 'trace: a no-target Main Assist is logged')
    assert_true(W.logs[#W.logs]:find('Waiting: Main Assist has no target', 1, true), 'trace: ...with the status as the pick')
    W.core.log = nil
    W.rt.tickSerial = 5; W.fed = { id = 1 }
    assert_eq(W.registered.resolve(ctx()), 2, 'trace: a core without a logger still selects')
    W.core.log = { debug = function() error('boom') end }
    W.rt.tickSerial = 6; W.fed = { id = 3 }
    assert_true(W.registered.resolve(ctx()) ~= nil, 'trace: a logger that raises does not stop the selector')
    -- mez casts and failures
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    W.rt.npcSpellLastCast[7] = { ['Dazzle'] = 990, ['Fireball'] = 991 }
    plugin.onCombatTick()
    assert_eq(#W.logs, 1, 'trace: a recorded mez cast is logged (not a non-mez spell)')
    assert_true(W.logs[1]:find('mez cast recorded: Dazzle on #7', 1, true), 'trace: ...with the spell and mob')
    plugin.onCombatTick()
    assert_eq(#W.logs, 1, 'trace: the same cast is logged once')
    W.rt.npcSpellLastCast[7]['Dazzle'] = 1000; W.rt.npcSpellApplied[7] = { ['Dazzle'] = 1060 }
    W.core.castTracker.failed = true; W.core.castTracker.lastSpell = 'Dazzle'; W.core.castTracker.lastTime = 1000
    plugin.onCombatTick()
    assert_eq(#W.logs, 3, 'trace: a new cast and its failure are logged')
    assert_true(W.logs[3]:find('failed mez cast: cleared the record for #7', 1, true), 'trace: a cleared record is logged')
    assert_eq(#L.newMezCasts({ [1] = { Dazzle = 5 } }, {}), 1, 'trace: newMezCasts reports a cast')
    assert_eq(L.describeInput({ ma = { configured = false }, peers = {} }), 'MA not set; peers: none', 'trace: describeInput with no Main Assist')

    -- mez messages -----------------------------------------------------------------------------------------------------------------------
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    local nev = 0
    for _ in pairs(W.events) do nev = nev + 1 end
    assert_eq(nev, 11, 'events: 9 landing texts + awakened + worn off are registered')
    local function eventFor(pattern)
        for name, e in pairs(W.events) do if e.pattern == pattern then return name, e end end
    end
    assert_true(eventFor('#1# swoons in raptured bliss.#*#') ~= nil, 'events: Rapture\'s landing text is listened for')
    assert_true(eventFor("#1#'s jaw falls as they begin to drool.#*#") ~= nil, 'events: Bliss\'s landing text is listened for')
    assert_true(eventFor('#1# has been awakened by #2#.#*#') ~= nil and eventFor('Your #1# spell has worn off of #2#.#*#') ~= nil, 'events: awakened and worn off are listened for')
    local landEv = select(2, eventFor('#1# swoons in raptured bliss.#*#'))
    local awakeEv = select(2, eventFor('#1# has been awakened by #2#.#*#'))
    local wornEv = select(2, eventFor('Your #1# spell has worn off of #2#.#*#'))

    addMob(5, { name = 'a Chetari guard' }); addMob(6, { name = 'a Chetari warrior' })
    W.rt.npcSpellApplied[5] = { Rapture = W.now + 58 }; W.rt.npcSpellLastCast[5] = { Rapture = W.now - 2 }
    W.logs = {}
    landEv.fn('A Chetari guard swoons in raptured bliss.', 'A Chetari guard')
    assert_true(W.logs[1] and W.logs[1]:find('landed: Rapture on #5 "a Chetari guard"', 1, true), 'events: a landing message confirms the cast')
    W.logs = {}
    landEv.fn('A Chetari guard swoons in raptured bliss.', 'A Chetari guard')
    assert_true(W.logs[1] and W.logs[1]:find('matched no recent cast', 1, true), 'events: the same cast is not confirmed twice')
    W.logs = {}
    landEv.fn('x', 'A Chetari warrior')
    assert_true(W.logs[1] and W.logs[1]:find('matched no recent cast', 1, true), 'events: a landing message for a mob we did not mez is noted')
    assert_true(W.rt.npcSpellApplied[5].Rapture ~= nil, 'events: a landing message changes no record')

    W.logs = {}
    awakeEv.fn('a Chetari guard has been awakened by Kylaeris.', 'a Chetari guard', 'Kylaeris')
    assert_nil(W.rt.npcSpellApplied[5].Rapture, 'events: "awakened" drops the record')
    assert_true(W.logs[1] and W.logs[1]:find('cleared the mez record for #5', 1, true), 'events: ...and says so')
    W.logs = {}
    awakeEv.fn('x', 'a Chetari guard', 'Kylaeris')
    assert_eq(#W.logs, 0, 'events: a second "awakened" for a mob with no record is silent')

    W.rt.npcSpellApplied[5] = { Rapture = W.now + 50 }; W.rt.npcSpellLastCast[5] = { Rapture = W.now - 10 }
    wornEv.fn('x', 'Grappling Strike', 'a Chetari guard')
    assert_true(W.rt.npcSpellApplied[5].Rapture ~= nil, 'events: another spell wearing off changes nothing')
    wornEv.fn('x', 'Sleep', 'a Chetari guard')
    assert_true(W.rt.npcSpellApplied[5].Rapture ~= nil, 'events: a different mez wearing off leaves this record')
    wornEv.fn('Your Rapture spell has worn off of a Chetari guard.', 'Rapture', 'a Chetari guard')
    assert_nil(W.rt.npcSpellApplied[5].Rapture, 'events: "worn off" of the cast spell drops the record')

    -- two same-named mobs: nothing is guessed
    addMob(7, { name = 'a Chetari guard' })
    W.rt.npcSpellApplied[5] = { Rapture = W.now + 50 }; W.rt.npcSpellLastCast[5] = { Rapture = W.now - 10 }
    W.rt.npcSpellApplied[7] = { Rapture = W.now + 50 }; W.rt.npcSpellLastCast[7] = { Rapture = W.now - 12 }
    W.logs = {}
    awakeEv.fn('x', 'a Chetari guard', 'Kylaeris')
    assert_true(W.rt.npcSpellApplied[5].Rapture ~= nil and W.rt.npcSpellApplied[7].Rapture ~= nil, 'events: same-named mobs both mezzed -> no record changed')
    assert_true(W.logs[1] and W.logs[1]:find('more than one mob has that name', 1, true), 'events: ...and the trace says why')

    -- the cleared record makes the mob eligible again
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    addMob(1); addMob(2, { name = 'a Chetari guard' }); addMob(3, { dist = 99 })
    W.fed = { id = 1 }
    W.rt.npcSpellApplied[2] = { Rapture = W.now + 50 }; W.rt.npcSpellLastCast[2] = { Rapture = W.now - 10 }
    assert_eq(W.registered.resolve(ctx('Rapture')), 3, 'events: a mezzed add is skipped')
    W.events['MezSupportAwakened'].fn('x', 'a Chetari guard', 'Kylaeris')
    W.rt.tickSerial = 2
    assert_eq(W.registered.resolve(ctx('Rapture')), 2, 'events: ...and picked again once it is awakened')

    -- an unconfirmed cast is traced after the window
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    W.rt.npcSpellApplied[7] = { Rapture = W.now + 60 }; W.rt.npcSpellLastCast[7] = { Rapture = W.now }
    plugin.onCombatTick()
    W.now = W.now + 5; plugin.onCombatTick()
    local silent = true
    for _, l in ipairs(W.logs) do if l:find('no landing message', 1, true) then silent = false end end
    assert_true(silent, 'events: nothing is said inside the window')
    W.now = W.now + 10; plugin.onCombatTick()
    local said = false
    for _, l in ipairs(W.logs) do if l:find('no landing message seen for Rapture on #7', 1, true) then said = true end end
    assert_true(said, 'events: an unconfirmed cast is traced once the window passes')

    -- destroy removes every listener
    plugin.onDestroy()
    nev = 0
    for _ in pairs(W.events) do nev = nev + 1 end
    assert_eq(nev, 0, 'events: onDestroy removes every listener')
    assert_eq(#W.unevented >= 11, true, 'events: ...by name')
    plugin.onInit(W.core)
    nev = 0
    for _ in pairs(W.events) do nev = nev + 1 end
    assert_eq(nev, 11, 'events: re-enabling registers them again, once')

    -- a core without an event API still loads
    newWorld(); plugin = loadPlugin(); W.core.mq.event = nil; W.core.mq.unevent = nil
    plugin.onInit(W.core); plugin.onDestroy()
    assert_true(true, 'events: a core without mq.event is harmless')

    -- chat reporting ------------------------------------------------------------------------------------------------------------------------
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    addMob(1); addMob(2); W.fed = { id = 1 }
    W.rt.tickSerial = nil
    W.fed = nil; W.assist = nil
    printed = {}
    W.registered.resolve(ctx())
    assert_eq(#printed, 1, 'chat: the first problem is said once')
    assert_true(printed[1] and printed[1]:find('Main Assist target unavailable', 1, true), 'chat: ...with the right words')
    W.now = W.now + 5
    W.registered.resolve(ctx())
    assert_eq(#printed, 1, 'chat: an unchanged status is quiet')
    W.now = W.now + 30
    W.registered.resolve(ctx())
    assert_eq(#printed, 2, 'chat: ...and repeats after the gap')
    W.fed = false
    W.registered.resolve(ctx())
    assert_eq(#printed, 3, 'chat: a changed status is said at once')
    W.fed = { id = 1 }
    W.registered.resolve(ctx())
    assert_eq(#printed, 3, 'chat: a candidate is not said in chat')
    W.fed = nil
    W.registered.resolve(ctx())
    assert_eq(#printed, 4, 'chat: a problem after a candidate is said again at once')
    assert_true(printed[1] and printed[1]:find('\a', 1, true) ~= nil, 'chat: lines use the MacroQuest colour code (BEL + letter)')

    -- resilience ------------------------------------------------------------------------------------------------------------------------------------
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    addMob(1); addMob(2); W.fed = { id = 1 }
    W.rt.isHostileTarget = function() error('boom') end
    assert_true(pcall(W.registered.resolve, ctx()), 'resilient: a failing core read does not raise out of the selector')
    newWorld(); plugin = loadPlugin(); plugin.onInit(W.core)
    W.core.registerTargetSelector = nil
    plugin.onInit(W.core)
    assert_true(printed[#printed] and printed[#printed]:find('no target selector registry', 1, true), 'resilient: a Triune without the registry says so')
    newWorld(); plugin = loadPlugin()
    W.core.registerTargetSelector = function() return false, 'label taken' end
    plugin.onInit(W.core)
    assert_true(printed[#printed] and printed[#printed]:find('label taken', 1, true), 'resilient: a refused registration is reported with the reason')
    -- the plugin against the REAL registry code from triune.lua ---------------------------------------------------------
    do
        local text = tacSource()
        if text and not text:find('local function builtinTargetBase', 1, true) then
            print('  (skipped: the TAC_SOURCE file has no target selector registry; apply patches/tac-target-selector-registry.patch)')
            text = nil
        elseif not text then
            print('  (skipped: integration with the real TAC registry; set TAC_SOURCE to a TAC triune.lua that has it)')
        end
        if text then
        local function slice(a, b)
            local s = assert(text:find(a, 1, true), 'missing: ' .. a)
            local e = assert(text:find(b, s, true), 'missing: ' .. b)
            return text:sub(s, e - 1)
        end
        local regCode = slice('local function builtinTargetBase', '-- Local Theme & Common Helpers')
        local OPTS = {
            FRIENDLY = { 'Myself', 'Main Assist', 'Pet' },
            ENEMY    = { 'Current Target', 'Assist Target', 'Nearest Add', 'Unmezzed Add', 'All Enemies' },
            TARGETS  = { 'F: Myself', 'F: Main Assist', 'F: Pet', 'E: Current Target', 'E: Assist Target',
                'E: Nearest Add', 'E: Unmezzed Add', 'E: All Enemies' },
        }
        local rt = {}
        local env = setmetatable({ COMBO_OPTIONS = OPTS, runtime = rt, print = function() end }, { __index = _G })
        local reg = assert((loadstring or load)('runtime.targetSelectors = {}\nruntime.targetSelectorVersion = 0\n'
            .. regCode .. '\nreturn true', 'integration'))
        setfenv(reg, env)
        reg()

        newWorld()
        local pl = loadPlugin()
        W.core.registerTargetSelector = function(spec) return rt.registerTargetSelector(spec) end
        W.core.unregisterTargetSelector = function(l, o) return rt.unregisterTargetSelector(l, o) end
        pl.onInit(W.core)
        assert_true(rt.targetSelectors['Mez Target'] ~= nil, 'integration: the real registry accepts the plugin\'s selector')
        local at
        for i, v in ipairs(OPTS.TARGETS) do if v == 'E: Mez Target' then at = i end end
        assert_eq(at, #OPTS.TARGETS, 'integration: "E: Mez Target" is added to the Target dropdown list')
        assert_eq(OPTS.TARGETS[at - 1], 'E: All Enemies', 'integration: ...with the other enemy targets')
        assert_eq(rt.isUnknownSelectorToken('E: Mez Target', 'Mez Target'), false, 'integration: a loaded plugin\'s token is known')

        addMob(1); addMob(2); addMob(3, { dist = 99 })
        W.fed = { id = 1 }
        local got = rt.runTargetSelector('Mez Target', 'E: Mez Target', 'Enc', 'in combat', 'Glamour of Kintaz', 100, { kind = 'util' })
        assert_eq(got, 2, 'integration: the core runs the plugin\'s selector and gets the nearest add')
        W.fed = false
        assert_nil(rt.runTargetSelector('Mez Target', 'E: Mez Target', 'Enc', 'in combat', 'Glamour of Kintaz', 100, {}), 'integration: no Main Assist target -> no target through the core too')
        W.fed = { id = 1 }

        -- disabling the plugin removes the dropdown entry and makes saved entries fail closed
        assert_eq(rt.unregisterTargetSelectorsByOwner('mez'), 1, 'integration: disabling removes the plugin\'s selector by owner')
        assert_nil(rt.targetSelectors['Mez Target'], 'integration: ...the selector is gone')
        assert_eq(OPTS.TARGETS[#OPTS.TARGETS], 'E: All Enemies', 'integration: ...and its dropdown entry')
        assert_eq(rt.isUnknownSelectorToken('E: Mez Target', 'Mez Target'), true, 'integration: a saved "E: Mez Target" entry now resolves to no target, never the current target')
        assert_nil(rt.runTargetSelector('Mez Target', 'E: Mez Target', 'Enc', 'in combat', 'Glamour of Kintaz', 100, {}), 'integration: ...and the selector cannot be run')

        -- enabling it again brings everything back
        pl.onInit(W.core)
        assert_eq(OPTS.TARGETS[#OPTS.TARGETS], 'E: Mez Target', 'integration: re-enabling restores the dropdown entry')
        assert_eq(rt.runTargetSelector('Mez Target', 'E: Mez Target', 'Enc', 'in combat', 'Glamour of Kintaz', 100, {}), 2, 'integration: ...and the selector')
        pl.onDestroy()
        assert_nil(rt.targetSelectors['Mez Target'], 'integration: the plugin unregisters itself on destroy')
        end
    end
end)()

