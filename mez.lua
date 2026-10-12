---@diagnostic disable: undefined-global, undefined-field
-- ============================================================================
-- TAC/lua/tac/mez.lua — Enchanter Mez Support Plugin
-- ============================================================================
-- Picks the add an Enchanter should mez without ever putting the mob the group
-- is killing to sleep. Built for a support character in Assist mode: the Main
-- Assist's target is the mob being fought, and every other hostile NPC on
-- Extended Target is a candidate.
--
-- Use it
--   1. Enable the plugin (Plugins tab) and set a Main Assist.
--   2. Give a mez spell gem the target "E: Mez Target" and When "in combat".
--      The spell still decides the action; this plugin only supplies the target.
--
-- Layers (kept apart on purpose):
--   State collection   collectState(): the Main Assist's target, the other
--                      boxes' heartbeats, XTarget and the tracked mez state.
--   Decision           logic.decide(state) -> { id, status, ... }. A pure
--                      function: no MacroQuest calls, no TAC calls, no side
--                      effects, so every rule below is a unit test.
--   Execution          TAC's own gem loop casts the spell; the plugin supplies
--                      the target through the target selector registry.
--   Reporting          logic.statusText / announce turn the decision's status
--                      code into the window line and rate-limited chat.
--
-- Decision rules, in order
--   1. The configured spell must be a supported single-target Enchanter mez.
--      Area mezzes (they hit mobs around the target or the caster, so the
--      protected mob cannot be guaranteed safe) and Echoing Madness (it spreads
--      to nearby mobs) are refused, never half-supported.
--   2. A Main Assist must be configured, and its target must be known.
--      Unknown -> no mez. "No target right now" -> no mez, wait. The MA's
--      target is the one thing this plugin must not get wrong.
--   3. Everything else is a filter on the remaining hostile XTarget NPCs:
--        the MA's target; targets another box is engaged with (fresh
--        heartbeats only -- a missing or stale peer is simply ignored); mobs
--        already damaged (HP below 100%, switchable); ignored / unreachable /
--        locked-out / out-of-range mobs; mobs above the spell's level cap;
--        mobs the tracker says are mezzed, unless the mez is about to run out.
--   4. The nearest remaining mob wins (ties go to the lowest spawn id).
--
-- Mez state is presumed, not observed. TAC records every duration spell it
-- casts (runtime.npcSpellApplied, with the cast time in npcSpellLastCast) and
-- clears the record on a resist, fizzle, interrupt or "did not take hold". This
-- plugin adds one more clear: any other cast failure TAC noticed (cannot see
-- target, out of range, ...) drops the record of the mez it was aimed at. A cast
-- is "pending" for its cast time, then "active" until the earlier of the
-- recorded expiry and the spell's listed duration. A mez that breaks early with
-- no detectable event stays "active" until the refresh window. Damaged-add
-- protection interacts with that: an add that took damage is excluded while the
-- setting is on, even after its mez would have expired.
-- ============================================================================

local plugin = {
    id                 = 'mez',
    name               = 'Mez Support',
    version            = '0.2.0',
    author             = 'Triune',
    description        = 'Chooses which add an Enchanter mezzes (target "E: Mez Target"), never the mob the group is fighting.',
    defaultEnabled     = false,
    tickInterval       = 0.25,
    runOutOfCombatOnly = false,
    hasThread          = false,
    uses               = { boxnet = 'what the other boxes are fighting, so their targets are never mezzed' },
}

local core = nil

local SELECTOR_LABEL = 'Mez Target'

-- Persisted through onSaveSettings / onLoadSettings (per character loadout).
local cfg = {
    damagedProtection = true,
}

-- ----------------------------------------------------------------------------
-- Spell data (checked against spells_us.txt: class, target type, level cap)
-- ----------------------------------------------------------------------------
-- maxMobLevel is the highest mob level the spell can mesmerize (the Mesmerize
-- effect's base value). castSec is the 2.5 s cast every single-target Enchanter
-- mez shares. durationSec is the listed duration, used only as a conservative
-- cap on how long a cast is presumed to last. landed is the text the game prints
-- after the mob's name when the mez takes hold (the spell file's "cast on other"
-- text; only Rapture's has been seen in a real log). supported = false carries
-- the reason it is refused.
local SPELLS = {
    { name = 'Mesmerize',                maxMobLevel = 55, castSec = 2.5, durationSec = 12, landed = ' has been mesmerized.', supported = true },
    { name = 'Enthrall',                 maxMobLevel = 55, castSec = 2.5, durationSec = 48, landed = ' has been enthralled.', supported = true },
    { name = 'Entrance',                 maxMobLevel = 55, castSec = 2.5, durationSec = 72, landed = ' has been entranced.', supported = true },
    { name = 'Dazzle',                   maxMobLevel = 55, castSec = 2.5, durationSec = 96, landed = ' has been mesmerized.', supported = true },
    { name = 'Glamour of Kintaz',        maxMobLevel = 57, castSec = 2.5, durationSec = 54, landed = ' has been mesmerized by the Glamour of Kintaz.', supported = true },
    { name = 'Rapture',                  maxMobLevel = 63, castSec = 2.5, durationSec = 60, landed = ' swoons in raptured bliss.', supported = true },
    { name = 'Ancient: Eternal Rapture', maxMobLevel = 63, castSec = 2.5, durationSec = 60, landed = ' swoons in raptured bliss.', supported = true },
    { name = 'Apathy',                   maxMobLevel = 62, castSec = 2.5, durationSec = 54, landed = ' stares off into the distance.', supported = true },
    { name = 'Sleep',                    maxMobLevel = 65, castSec = 2.5, durationSec = 54, landed = ' falls asleep.', supported = true },
    { name = 'Bliss',                    maxMobLevel = 68, castSec = 2.5, durationSec = 54, landed = "'s jaw falls as they begin to drool.", supported = true },
    { name = 'Felicity',                 maxMobLevel = 70, castSec = 2.5, durationSec = 54, landed = ' gazes happily into space.', supported = true },
    { name = 'Euphoria',                 maxMobLevel = 73, castSec = 2.5, durationSec = 54, landed = ' gazes happily into space.', supported = true },
    { name = 'Echoing Madness',          supported = false, reason = 'it spreads to nearby mobs and could wake or mez the mob being fought' },
    { name = 'Mesmerization',            supported = false, reason = 'area mez around the target' },
    { name = 'Fascination',              supported = false, reason = 'area mez around the target' },
    { name = 'Bliss of the Nihil',       supported = false, reason = 'area mez around the target' },
    { name = 'Wake of Felicity',         supported = false, reason = 'area mez around the target' },
    { name = 'Entrancing Lights',        supported = false, reason = 'area mez around the caster' },
    { name = 'Word of Morell',           supported = false, reason = 'area mez around the caster' },
    { name = 'Circle of Dreams',         supported = false, reason = 'area mez around the caster' },
}

-- Same normalization TAC uses for spell names: case, rank suffix, punctuation.
local function normalize(name)
    if type(name) ~= 'string' then return '' end
    local s = name:lower()
    s = s:gsub('%s*%(?%s*rk%.?%s*[%ivxlc%d]+%s*%)?', '')
    s = s:gsub('%s*%([^%)]+%)', '')
    s = s:gsub('[%p%s]', '')
    return s
end

local SPELL_BY_KEY = {}
for _, sp in ipairs(SPELLS) do SPELL_BY_KEY[normalize(sp.name)] = sp end

-- The data row for a spell name (rank-insensitive), or nil when it is not one
-- of the Enchanter mezzes.
local function spellInfo(name)
    return SPELL_BY_KEY[normalize(name)]
end

-- ----------------------------------------------------------------------------
-- Status codes
-- ----------------------------------------------------------------------------
local STATUS = {
    CANDIDATE         = 'candidate',
    SPELL_UNSUPPORTED = 'spell_unsupported',
    MA_NOT_SET        = 'ma_not_set',
    MA_UNAVAILABLE    = 'ma_unavailable',
    MA_NO_TARGET      = 'ma_no_target',
    NO_ELIGIBLE       = 'no_eligible',
}

local DEFAULT_REFRESH_MARGIN_SEC = 2.0   -- a mez is renewed when it has cast time + this left

-- ----------------------------------------------------------------------------
-- The decision (pure)
-- ----------------------------------------------------------------------------
-- state = {
--   spell     = 'Glamour of Kintaz',
--   settings  = { damagedProtection = true },       -- default true
--   refreshMarginSec = 2.0,                         -- optional
--   ma        = { configured = true, status = 'target'|'none'|'unknown', id = n },
--   peers     = { { fresh = bool, id = n, engaged = bool }, ... },   -- each other box's target
--   mobs      = { { id, name, level, dist, hpPct, hostile, isNpc,
--                   ignored, unreachable, lockedOut, inRange,
--                   mez = { state = 'none'|'pending'|'active', remaining = seconds } }, ... },
-- }
-- Returns { id = n|nil, status = STATUS.x, name = mobName|nil, reason = text|nil,
--           excluded = { ma = n, peer = n, damaged = n, ... } }.
local function decide(state)
    state = state or {}
    local info = spellInfo(state.spell)
    if not info or not info.supported then
        return {
            status = STATUS.SPELL_UNSUPPORTED,
            reason = info and info.reason or 'not a supported Enchanter mez',
            excluded = {},
        }
    end

    local ma = state.ma or {}
    if not ma.configured then return { status = STATUS.MA_NOT_SET, excluded = {} } end
    if ma.status == 'none' then return { status = STATUS.MA_NO_TARGET, excluded = {} } end
    local maId = tonumber(ma.id) or 0
    if ma.status ~= 'target' or maId <= 0 then return { status = STATUS.MA_UNAVAILABLE, excluded = {} } end

    -- Mobs another box is fighting. A peer that is missing or stale contributes
    -- nothing; it never blocks the decision.
    local peerTargets = {}
    for _, p in ipairs(state.peers or {}) do
        local pid = tonumber(p.id) or 0
        if p.fresh == true and p.engaged == true and pid > 0 then peerTargets[pid] = true end
    end

    local settings = state.settings or {}
    local damagedProtection = settings.damagedProtection ~= false
    local margin = tonumber(state.refreshMarginSec) or DEFAULT_REFRESH_MARGIN_SEC
    local refreshAt = info.castSec + margin

    local excluded = {}
    local function skip(reason)
        excluded[reason] = (excluded[reason] or 0) + 1
    end

    local best, bestDist
    for _, m in ipairs(state.mobs or {}) do
        local id = tonumber(m.id) or 0
        local lvl = tonumber(m.level) or 0
        local mez = m.mez or {}
        local mezState = mez.state or 'none'
        if id <= 0 or m.hostile ~= true or m.isNpc ~= true then
            skip('invalid')
        elseif id == maId then
            skip('ma')
        elseif peerTargets[id] then
            skip('peer')
        elseif m.ignored == true then
            skip('ignored')
        elseif m.unreachable == true then
            skip('unreachable')
        elseif damagedProtection and (tonumber(m.hpPct) or 100) < 100 then
            skip('damaged')
        elseif lvl > 0 and lvl > info.maxMobLevel then
            skip('level')
        elseif m.lockedOut == true then
            skip('lockedOut')
        elseif m.inRange ~= true then
            skip('range')
        elseif mezState == 'pending' then
            skip('mezzed')
        elseif mezState == 'active' and (tonumber(mez.remaining) or 0) > refreshAt then
            skip('mezzed')
        else
            local d = tonumber(m.dist) or math.huge
            if not best or d < bestDist or (d == bestDist and id < best.id) then
                best, bestDist = { id = id, name = m.name }, d
            end
        end
    end

    if not best then return { status = STATUS.NO_ELIGIBLE, excluded = excluded } end
    return { id = best.id, name = best.name, status = STATUS.CANDIDATE, excluded = excluded }
end

-- ----------------------------------------------------------------------------
-- Reporting (pure)
-- ----------------------------------------------------------------------------
local EXCLUDE_LABELS = {
    { 'ma', 'Main Assist target' }, { 'peer', 'fought by another box' }, { 'damaged', 'damaged' },
    { 'mezzed', 'already mezzed' }, { 'level', 'too high a level' }, { 'range', 'out of range' },
    { 'lockedOut', 'locked out' }, { 'unreachable', 'unreachable' }, { 'ignored', 'ignored' },
}

-- One line for the window and the log, built from the decision.
local function statusText(result)
    local s = result and result.status
    if s == STATUS.CANDIDATE then
        return 'Mez candidate: ' .. tostring(result.name or ('#' .. tostring(result.id)))
    elseif s == STATUS.SPELL_UNSUPPORTED then
        return 'Unsupported mez spell: ' .. tostring(result.reason or 'not a supported Enchanter mez')
    elseif s == STATUS.MA_NOT_SET then
        return 'Configuration: Main Assist not set'
    elseif s == STATUS.MA_UNAVAILABLE then
        return 'Waiting: Main Assist target unavailable'
    elseif s == STATUS.MA_NO_TARGET then
        return 'Waiting: Main Assist has no target'
    elseif s == STATUS.NO_ELIGIBLE then
        local parts = {}
        for _, e in ipairs(EXCLUDE_LABELS) do
            local n = result.excluded and result.excluded[e[1]]
            if n and n > 0 then parts[#parts + 1] = string.format('%d %s', n, e[2]) end
        end
        if #parts > 0 then return 'No eligible mez targets (skipped: ' .. table.concat(parts, ', ') .. ')' end
        return 'No eligible mez targets'
    end
    return 'Mez: unknown status'
end

-- Rate limit for chat lines: say a status when it changes, and repeat an
-- unchanged non-candidate status only every `gapSec` seconds. Candidates are
-- never announced here (the selector runs every tick; the window shows them).
local function announce(prev, status, now, gapSec)
    if status == STATUS.CANDIDATE then return false end
    gapSec = tonumber(gapSec) or 30
    if not prev or prev.status ~= status then return true end
    return (now - (prev.at or 0)) >= gapSec
end

-- ----------------------------------------------------------------------------
-- Mez tracking (pure helpers over TAC's own per-mob records)
-- ----------------------------------------------------------------------------
-- applied  = runtime.npcSpellApplied[mobId]  : { [spellName] = expiry (os.clock) }
-- lastCast = runtime.npcSpellLastCast[mobId] : { [spellName] = time the cast was issued }
-- Returns { state = 'none'|'pending'|'active', remaining = seconds }. Of several
-- mezzes on one mob the longest-lasting wins; a fresh cast counts as pending.
local function mezStateOf(applied, lastCast, now)
    local best = { state = 'none', remaining = 0 }
    for spellName, expiry in pairs(applied or {}) do
        local info = spellInfo(spellName)
        if info and tonumber(expiry) then
            local last = lastCast and tonumber(lastCast[spellName]) or nil
            local remaining = expiry - now
            if last and info.durationSec then
                remaining = math.min(remaining, last + info.durationSec - now)
            end
            if remaining > 0 then
                local pending = last ~= nil and (now - last) < ((info.castSec or 2.5) + 0.5)
                local state = pending and 'pending' or 'active'
                if best.state == 'none'
                    or (state == 'pending' and best.state ~= 'pending')
                    or (state == best.state and remaining > best.remaining) then
                    best = { state = state, remaining = remaining }
                end
            end
        end
    end
    return best
end

-- TAC drops a mez record itself on a resist, fizzle, interrupt or "did not take
-- hold", but a cast that failed for another reason ("cannot see target", out of
-- range, ...) leaves the record standing. castTracker.failed is set for every
-- failure of a detrimental cast, so when the last cast was a mez and failed, the
-- record of the mob it was aimed at (the one whose cast time matches) is dropped.
-- Returns the mob id cleared, or nil. `seen` remembers the failure already handled.
local function clearFailedMez(tracker, appliedByMob, lastCastByMob, seen)
    if type(tracker) ~= 'table' or tracker.failed ~= true then return nil end
    local spell, at = tracker.lastSpell, tonumber(tracker.lastTime)
    if not spell or not at or not spellInfo(spell) then return nil end
    if seen and seen.at == at and seen.spell == spell then return nil end
    if seen then seen.at, seen.spell = at, spell end
    local bestId, bestGap
    for mobId, casts in pairs(lastCastByMob or {}) do
        local t = tonumber(casts and casts[spell])
        if t then
            local gap = math.abs(t - at)
            if gap <= 3.0 and (not bestGap or gap < bestGap) then bestId, bestGap = mobId, gap end
        end
    end
    if bestId and appliedByMob and appliedByMob[bestId] then
        appliedByMob[bestId][spell] = nil
        return bestId
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- Mez messages (pure helpers)
-- ----------------------------------------------------------------------------
-- The game prints "<mob> swoons in raptured bliss." when a mez lands, "<mob> has
-- been awakened by <who>." when it breaks and "Your <spell> spell has worn off of
-- <mob>." when it ends. The messages carry the mob's NAME, not its id, so they are
-- matched to TAC's per-mob records by name; if that is not unambiguous nothing is
-- changed. Records: { mobId, name, spell, castAt, expiry } (see collectMezRecords).
local LANDING_WINDOW_SEC = 8   -- a landing message counts only this long after the cast was issued (a guess)

-- The distinct landing texts, in table order.
local function landedTexts()
    local out, seen = {}, {}
    for _, sp in ipairs(SPELLS) do
        if sp.supported and sp.landed and not seen[sp.landed] then
            seen[sp.landed] = true
            out[#out + 1] = sp.landed
        end
    end
    return out
end

-- The set of supported spells that print this landing text.
local function spellsForLanding(text)
    local set = {}
    for _, sp in ipairs(SPELLS) do
        if sp.supported and sp.landed == text then set[sp.name] = true end
    end
    return set
end

local function sameName(a, b)
    return type(a) == 'string' and type(b) == 'string' and a ~= '' and a:lower() == b:lower()
end

local function castKey(mobId, spell) return tostring(mobId) .. ':' .. tostring(spell) end

-- The one cast this landing message belongs to, or nil and a reason ('none' or
-- 'ambiguous'). `confirmed[castKey]` holds the cast time already confirmed.
local function matchLanding(spells, name, records, now, confirmed)
    local found
    for _, r in ipairs(records or {}) do
        local age = now - r.castAt
        if spells[r.spell] and sameName(r.name, name) and age >= -1 and age <= LANDING_WINDOW_SEC
            and (confirmed or {})[castKey(r.mobId, r.spell)] ~= r.castAt then
            if found then return nil, 'ambiguous' end
            found = r
        end
    end
    if found then return found end
    return nil, 'none'
end

-- The one mob whose mez ended: same name and a record still presumed active (and,
-- when the message names the spell, that spell). Returns mobId and the list of the
-- spells to drop, or nil and a reason ('none' or 'ambiguous').
local function matchEnd(name, spell, records, now)
    local mobId, spells
    for _, r in ipairs(records or {}) do
        if sameName(r.name, name) and (r.expiry or 0) > now and (spell == nil or r.spell == spell) then
            if mobId and mobId ~= r.mobId then return nil, 'ambiguous' end
            if mobId == r.mobId then
                spells[#spells + 1] = r.spell
            else
                mobId, spells = r.mobId, { r.spell }
            end
        end
    end
    if mobId then return mobId, spells end
    return nil, 'none'
end

-- Casts that got no landing message in time: `pending` is { key = { mobId, spell, at } }.
-- Entries past the window are removed; those never confirmed (and whose record
-- still stands) are returned so the trace can say so.
local function unconfirmedCasts(pending, confirmed, appliedByMob, now)
    local out = {}
    for key, p in pairs(pending) do
        if now - p.at > LANDING_WINDOW_SEC then
            pending[key] = nil
            local stillRecorded = appliedByMob and appliedByMob[p.mobId] and appliedByMob[p.mobId][p.spell] ~= nil
            if (confirmed or {})[key] ~= p.at and stillRecorded then out[#out + 1] = p end
        end
    end
    table.sort(out, function(a, b) return a.at < b.at end)
    return out
end

-- ----------------------------------------------------------------------------
-- Debug trace text (pure: built from the collected state and the decision)
-- ----------------------------------------------------------------------------
-- What the decision was given: the Main Assist input and the peers considered.
local function describeInput(state)
    local ma = state and state.ma or {}
    local maText
    if not ma.configured then
        maText = 'MA not set'
    elseif ma.status == 'target' then
        maText = 'MA target #' .. tostring(ma.id)
    elseif ma.status == 'none' then
        maText = 'MA no target'
    else
        maText = 'MA unknown'
    end
    if ma.configured and ma.source then
        maText = maText .. ' (' .. (ma.source == 'boxnet' and 'Box Network feed' or '/assist peek') .. ')'
    end
    local peers = {}
    for _, p in ipairs(state and state.peers or {}) do
        peers[#peers + 1] = string.format('%s>#%s%s', tostring(p.name or '?'), tostring(p.id or 0), p.engaged and ' engaged' or '')
    end
    local text = string.format('%s; peers: %s', maText, #peers > 0 and table.concat(peers, ', ') or 'none')
    if ma.configured then
        text = text .. '; MA mode ' .. (ma.mode and ma.mode ~= '' and (ma.mode .. ((ma.submode and ma.submode ~= '') and ('/' .. ma.submode) or '')) or 'unknown')
    end
    return text
end

-- The tank's mode, from his heartbeat: the peer whose name is the Main Assist's.
local function findMaPeer(peers, maName)
    for _, p in ipairs(peers or {}) do
        if maName and maName ~= '' and p.name and tostring(p.name):lower() == tostring(maName):lower() then return p end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- Tank prediction (trace only; nothing here changes what the plugin picks)
-- ----------------------------------------------------------------------------
-- TAC's own finder for "the next target" (runtime.findFirstNPCXtarget, used by Hunt, Manual
-- and Puller Camp) walks the Extended Target slots in order and keeps the hostile with the
-- LOWEST HP%; the comparison is strict, so on equal HP the first slot wins. This mirrors
-- that, WITHOUT the tank's own ignore/unreachable lists or his distance cap (not visible
-- from here), and on THIS character's slot order (it is not known to equal the tank's).
local PREDICTION_MAX_AGE_SEC = 10   -- a prediction older than this is not compared (a guess)

local function bySlot(mobs)
    local list = {}
    for _, m in ipairs(mobs or {}) do list[#list + 1] = m end
    table.sort(list, function(a, b)
        local sa, sb = tonumber(a.slot) or 999, tonumber(b.slot) or 999
        if sa ~= sb then return sa < sb end
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)
    return list
end

local function predictTankNext(mobs, excludeId)
    local best, lowest = nil, 101
    for _, m in ipairs(bySlot(mobs)) do
        if m.hostile == true and m.isNpc == true and (tonumber(m.id) or 0) > 0 and m.id ~= excludeId then
            local hp = tonumber(m.hpPct) or 100
            if hp < lowest then lowest, best = hp, m end
        end
    end
    return best
end

local function describeMob(m)
    return string.format('#%s "%s" (slot %s, hp %s%%)', tostring(m.id), tostring(m.name or '?'), tostring(m.slot or '?'),
        tostring(m.hpPct or '?'))
end

-- "1:#12 a wraith 100% d17 | 2:..." in slot order.
local function describeXtarget(mobs)
    local parts = {}
    for _, m in ipairs(bySlot(mobs)) do
        parts[#parts + 1] = string.format('%s:#%s %s %s%% d%s', tostring(m.slot or '?'), tostring(m.id), tostring(m.name or '?'),
            tostring(m.hpPct or '?'), m.dist and string.format('%.0f', m.dist) or '?')
    end
    return #parts > 0 and table.concat(parts, ' | ') or 'empty'
end

local function makePrediction(mobs, excludeId, now)
    local m = predictTankNext(mobs, excludeId)
    if not m then return nil end
    return { id = m.id, name = m.name, slot = m.slot, hp = m.hpPct, at = now, list = describeXtarget(mobs) }
end

-- The line logged when the tank's target changes to `actualId`: what the rule expected, what he took.
local function describePrediction(pred, actualId, mobs, mode)
    local actual
    for _, m in ipairs(mobs or {}) do if m.id == actualId then actual = m end end
    local took = actual and describeMob(actual) or ('#' .. tostring(actualId) .. ' (not on this Extended Target)')
    return string.format('tank prediction (MA mode %s): expected %s, took %s: %s; list when predicted: %s',
        (mode and mode ~= '') and mode or 'unknown',
        string.format('#%s "%s" (slot %s, hp %s%%)', tostring(pred.id), tostring(pred.name or '?'), tostring(pred.slot or '?'), tostring(pred.hp or '?')),
        took, (pred.id == actualId) and 'MATCH' or 'MISS', tostring(pred.list))
end

-- What the decision chose, and what it skipped and why.
local function describeResult(result, state)
    local text = statusText(result)
    if result and result.status == STATUS.CANDIDATE then
        local dist
        for _, m in ipairs(state and state.mobs or {}) do
            if m.id == result.id then dist = m.dist end
        end
        text = string.format('pick #%s "%s"%s', tostring(result.id), tostring(result.name or '?'),
            dist and string.format(' dist %.0f', dist) or '')
        local parts = {}
        for _, e in ipairs(EXCLUDE_LABELS) do
            local n = result.excluded and result.excluded[e[1]]
            if n and n > 0 then parts[#parts + 1] = string.format('%d %s', n, e[2]) end
        end
        if #parts > 0 then text = text .. ' (skipped: ' .. table.concat(parts, ', ') .. ')' end
    end
    return text
end

-- Mez casts TAC has recorded since the last look. `seen` maps "mob:spell" to the
-- cast time already reported; returns a list of { mobId, spell, at }.
local function newMezCasts(lastCastByMob, seen)
    local out = {}
    for mobId, casts in pairs(lastCastByMob or {}) do
        for spell, at in pairs(casts or {}) do
            at = tonumber(at)
            if at and spellInfo(spell) then
                local key = tostring(mobId) .. ':' .. spell
                if seen[key] ~= at then
                    seen[key] = at
                    out[#out + 1] = { mobId = mobId, spell = spell, at = at }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.at < b.at end)
    return out
end

-- ----------------------------------------------------------------------------
-- State collection (reads the game through the core API)
-- ----------------------------------------------------------------------------
local function tlo(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return default
end

local function isNameIgnored(rt, name)
    if not name or name == '' then return false end
    if type(rt.isIgnored) == 'function' then
        local ok, v = pcall(rt.isIgnored, name)
        if ok then return v == true end
    end
    return false
end

-- The Main Assist's state: configured?, and whether we know its target.
local function collectMainAssist(rt, ctrl, mq)
    local maId = tlo(function() return rt.maPcId() end, nil)
    local configured = (tonumber(ctrl.ma_id) or 0) > 0 or (ctrl.ma_name ~= nil and ctrl.ma_name ~= '') or (maId ~= nil and maId > 0)
    if not configured then return { configured = false, status = 'unknown' } end
    local ma = { configured = true, status = 'unknown' }

    -- The MA's own Triune reports its exact target over the Box Network:
    -- a table = target, false = fresh heartbeat with no target, nil = no feed.
    local fed = nil
    if type(rt.boxnetMaTarget) == 'function' then
        local ok, v = pcall(rt.boxnetMaTarget, maId)
        if ok then fed = v end
    end
    local function validHostile(id)
        local good = false
        pcall(function()
            local s = mq.TLO.Spawn(id)
            good = s() and s.Type() == 'NPC' and not s.Dead() and rt.isHostileTarget(id) == true
        end)
        return good
    end
    if type(fed) == 'table' then
        ma.source = 'boxnet'
        if validHostile(tonumber(fed.id) or 0) then
            ma.status, ma.id = 'target', tonumber(fed.id)
        else
            ma.status = 'none'           -- the MA is targeting something that is not an enemy
        end
    elseif fed == false then
        ma.source = 'boxnet'
        ma.status = 'none'
    else
        -- no Box Network feed (the MA is not running Triune): TAC's /assist peek
        ma.source = 'assist'
        local id = tlo(function() return rt.maTargetId() end, nil)
        if id and id > 0 then ma.status, ma.id = 'target', id end
    end
    return ma
end

-- Other boxes' targets, from their heartbeats. peersInZone returns only fresh
-- ones, so anything stale or missing is simply absent.
local function collectPeers(rt)
    local peers = {}
    local bn = type(rt.boxnetApi) == 'function' and tlo(function() return rt.boxnetApi() end, nil) or nil
    if not bn or type(bn.peersInZone) ~= 'function' then return peers end
    local ok, list = pcall(bn.peersInZone, rt.BOXNET_FRESH_SEC or 3.0)
    if not ok or type(list) ~= 'table' then return peers end
    for _, p in ipairs(list) do
        local hb = type(p.hb) == 'table' and p.hb or {}
        local t = hb.target
        local isT = type(t) == 'table'
        peers[#peers + 1] = { fresh = true, id = isT and tonumber(t.id) or 0, engaged = isT and t.engaged == true,
            name = p.name, mode = hb.mode, submode = hb.submode }
    end
    return peers
end

-- Every hostile NPC on Extended Target with what the decision needs.
local function collectMobs(rt, mq, spellName, kind, tracker, now)
    local mobs = {}
    local slots = tlo(function() return mq.TLO.Me.XTargetSlots() end, 13)
    local seen = {}
    for i = 1, slots do
        local id = 0
        pcall(function()
            local xt = mq.TLO.Me.XTarget(i)
            if xt() then id = xt.ID() or 0 end
        end)
        if id > 0 and not seen[id] then
            seen[id] = true
            local s = mq.TLO.Spawn(id)
            if s() then
                local name = tlo(function() return s.CleanName() end, '')
                local lockedOut = false
                if tracker and type(tracker.isLockedOut) == 'function' then
                    lockedOut = tlo(function() return tracker.isLockedOut(spellName, id, kind) end, false) == true
                end
                local applied = rt.npcSpellApplied and rt.npcSpellApplied[id]
                local lastCast = rt.npcSpellLastCast and rt.npcSpellLastCast[id]
                mobs[#mobs + 1] = {
                    id        = id,
                    slot      = i,
                    name      = name,
                    level     = tonumber(tlo(function() return s.Level() end, 0)) or 0,
                    dist      = tonumber(tlo(function() return s.Distance3D() or s.Distance() end, nil)),
                    hpPct     = tonumber(tlo(function() return s.PctHPs() end, nil)),
                    hostile   = tlo(function() return rt.isHostileTarget(id) end, false) == true,
                    isNpc     = tlo(function() return s.Type() end, '') == 'NPC',
                    ignored   = isNameIgnored(rt, name),
                    unreachable = tlo(function() return rt.isUnreachable(id) end, false) == true,
                    lockedOut = lockedOut,
                    inRange   = tlo(function() return rt.isTargetInRange(spellName, id) end, false) == true,
                    mez       = mezStateOf(applied, lastCast, now),
                }
            end
        end
    end
    return mobs
end

-- One snapshot of everything decide() needs. `coreApi` is the TAC core API.
local function collectState(coreApi, spellName, entry, now)
    local rt, ctrl, mq = coreApi.runtime, coreApi.ctrl, coreApi.mq
    local ma, peers = collectMainAssist(rt, ctrl, mq), collectPeers(rt)
    local maName = ctrl and ctrl.ma_name
    if (not maName or maName == '') and ma.configured then
        local id = tlo(function() return rt.maPcId() end, nil)
        if id then maName = tlo(function() return mq.TLO.Spawn(id).CleanName() end, nil) end
    end
    local maPeer = findMaPeer(peers, maName)
    if maPeer then ma.mode, ma.submode = maPeer.mode, maPeer.submode end
    return {
        spell    = spellName,
        settings = { damagedProtection = cfg.damagedProtection },
        ma       = ma,
        peers    = peers,
        mobs     = collectMobs(rt, mq, spellName, entry and entry.kind, coreApi.castTracker, now or os.clock()),
    }
end

-- ----------------------------------------------------------------------------
-- Selector, reporting and failure observation
-- ----------------------------------------------------------------------------
local last = { result = nil, text = '', spell = nil, at = 0 }
local announced = nil
local failureSeen = { at = nil, spell = nil }
local cache = { serial = nil, spell = nil, result = nil }
local traced = { input = nil, pick = nil }
local castsSeen = {}
local tankPred = nil       -- the last prediction of the tank's next target
local lastMaTarget = 0    -- the Main Assist's target at the last comparison
local confirmed = {}      -- castKey -> cast time whose landing message was seen
local pendingLanding = {} -- castKey -> { mobId, spell, at } waiting for a landing message
local eventNames = {}

-- Debug trace through TAC's logger (lines only appear while Debug Mode is on).
-- It never raises: a logging problem must not stop the selector.
local function trace(fmt, ...)
    local lg = core and core.log
    if type(lg) ~= 'table' or type(lg.debug) ~= 'function' then return end
    pcall(lg.debug, 'mez', fmt, ...)
end

-- Log the input and the pick, but only when they change (the selector runs every tick).
local function traceDecision(state, result)
    local input = describeInput(state)
    if input ~= traced.input then
        traced.input = input
        trace('input: %s', input)
    end
    local pick = describeResult(result, state)
    if pick ~= traced.pick then
        traced.pick = pick
        trace('%s: %s', tostring(state.spell), pick)
        trace('xtarget: %s', describeXtarget(state.mobs))
    end
end

-- Log what the tank's rule expected against what he took, each time his target changes.
-- Trace only: nothing here feeds the pick.
local function traceTankPrediction(state, now)
    local ma = state.ma or {}
    if ma.status == 'target' and (tonumber(ma.id) or 0) > 0 then
        local actual = tonumber(ma.id)
        if actual ~= lastMaTarget then
            lastMaTarget = actual
            if tankPred and now - tankPred.at <= PREDICTION_MAX_AGE_SEC then
                local mode = ma.mode and ((ma.mode or '') .. ((ma.submode and ma.submode ~= '') and ('/' .. ma.submode) or '')) or nil
                trace('%s', describePrediction(tankPred, actual, state.mobs, mode))
            end
            tankPred = nil
        end
        tankPred = makePrediction(state.mobs, actual, now)
    elseif ma.status == 'none' then
        tankPred = makePrediction(state.mobs, nil, now)
    end
end

-- TAC's records of mez casts, with each mob's name (the messages carry only names).
local function collectMezRecords(rt, mq)
    local out = {}
    for mobId, spells in pairs(rt.npcSpellApplied or {}) do
        local name
        for spell, expiry in pairs(spells or {}) do
            local castAt = tonumber(rt.npcSpellLastCast and rt.npcSpellLastCast[mobId] and rt.npcSpellLastCast[mobId][spell])
            if spellInfo(spell) and tonumber(expiry) and castAt then
                name = name or tlo(function() return mq.TLO.Spawn(mobId).CleanName() end, '')
                out[#out + 1] = { mobId = mobId, name = name, spell = spell, castAt = castAt, expiry = tonumber(expiry) }
            end
        end
    end
    return out
end

-- "<mob> <landing text>": confirm the cast it belongs to (trace only; nothing else changes).
local function handleLanded(text, name)
    if not core then return end
    local now = os.clock()
    local r, why = matchLanding(spellsForLanding(text), name, collectMezRecords(core.runtime, core.mq), now, confirmed)
    if r then
        confirmed[castKey(r.mobId, r.spell)] = r.castAt
        trace('landed: %s on #%s "%s" (%.1f s after the cast)', r.spell, tostring(r.mobId), tostring(r.name), now - r.castAt)
    else
        trace('landing message for "%s" matched no recent cast (%s)', tostring(name), why)
    end
end

-- "<mob> has been awakened by <who>." (spell = nil) or "Your <spell> spell has worn
-- off of <mob>.": drop the record, so the mob can be mezzed again at once.
local function handleEnded(name, spell, how)
    if not core then return end
    local rt, now = core.runtime, os.clock()
    local info = spell and spellInfo(spell)
    if spell and not info then return end          -- worn off: some other spell
    local mobId, spells = matchEnd(name, info and info.name or nil, collectMezRecords(rt, core.mq), now)
    if not mobId then
        if spells == 'ambiguous' then
            trace('%s "%s": more than one mob has that name, no record changed', how, tostring(name))
        end
        return
    end
    for _, sp in ipairs(spells) do
        if rt.npcSpellApplied and rt.npcSpellApplied[mobId] then rt.npcSpellApplied[mobId][sp] = nil end
        confirmed[castKey(mobId, sp)] = nil
    end
    cache = { serial = nil, spell = nil, result = nil }
    trace('%s "%s": cleared the mez record for #%s (%s)', how, tostring(name), tostring(mobId), table.concat(spells, ', '))
end

local function registerEvents()
    local mq = core and core.mq
    if not (mq and type(mq.event) == 'function') then return end
    local function add(name, pattern, fn)
        if type(mq.unevent) == 'function' then pcall(mq.unevent, name) end
        if pcall(mq.event, name, pattern, function(...) pcall(fn, ...) end) then eventNames[#eventNames + 1] = name end
    end
    for i, text in ipairs(landedTexts()) do
        add('MezSupportLanded' .. i, '#1#' .. text .. '#*#', function(_, name) handleLanded(text, name) end)
    end
    add('MezSupportAwakened', '#1# has been awakened by #2#.#*#', function(_, name) handleEnded(name, nil, 'awakened') end)
    add('MezSupportWornOff', 'Your #1# spell has worn off of #2#.#*#', function(_, spell, name) handleEnded(name, spell, 'worn off') end)
end

local function unregisterEvents()
    local mq = core and core.mq
    if mq and type(mq.unevent) == 'function' then
        for _, name in ipairs(eventNames) do pcall(mq.unevent, name) end
    end
    eventNames = {}
end

local function remember(result, spellName, now)
    last.result, last.spell, last.at = result, spellName, now
    last.text = statusText(result)
    if announce(announced, result.status, now) then
        announced = { status = result.status, at = now }
        print(string.format('\ay[Triune Mez]\ax %s', last.text))
    end
    -- a candidate means the problem cleared: the next one is said at once
    if result.status == STATUS.CANDIDATE then announced = nil end
end

-- The function TAC calls for the "E: Mez Target" entry.
local function resolve(ctx)
    if not core then return nil end
    local spellName = ctx and ctx.spellName
    local rt = core.runtime
    local serial = rt and rt.tickSerial
    if serial and cache.serial == serial and cache.spell == spellName and cache.result then
        return cache.result.id
    end
    local now = os.clock()
    local state = collectState(core, spellName, ctx and ctx.entry, now)
    local result = decide(state)
    traceDecision(state, result)
    traceTankPrediction(state, now)
    remember(result, spellName, now)
    cache = { serial = serial, spell = spellName, result = result }
    return result.id
end

local HELP = 'Mez: the nearest add that no one in the group is fighting. Never the Main Assist\'s target, '
    .. 'never a mob another box is engaged with, never an already mezzed or (optionally) damaged add. '
    .. 'Needs a Main Assist; refuses area mezzes. Set the gem\'s When to "in combat".'

function plugin.onInit(coreApi)
    core = coreApi
    local ok, why = true, nil
    if core and type(core.registerTargetSelector) == 'function' then
        ok, why = core.registerTargetSelector({
            owner = plugin.id, label = SELECTOR_LABEL, side = 'E', help = HELP, resolve = resolve,
        })
        if not ok then print('\ar[Triune Mez]\ax could not register the target selector: ' .. tostring(why)) end
    else
        print('\ar[Triune Mez]\ax this Triune build has no target selector registry; update Triune.')
    end
    registerEvents()
end

function plugin.onDestroy()
    unregisterEvents()
    if core and type(core.unregisterTargetSelector) == 'function' then
        pcall(core.unregisterTargetSelector, SELECTOR_LABEL, plugin.id)
    end
    core = nil
    announced = nil
    cache = { serial = nil, spell = nil, result = nil }
    traced = { input = nil, pick = nil }
    castsSeen = {}
    confirmed, pendingLanding = {}, {}
    tankPred, lastMaTarget = nil, 0
end

-- Each combat tick: notice a failed mez cast and drop the record of the mob it was aimed at.
function plugin.onCombatTick()
    if not core then return end
    local rt = core.runtime
    for _, c in ipairs(newMezCasts(rt and rt.npcSpellLastCast, castsSeen)) do
        trace('mez cast recorded: %s on #%s', c.spell, tostring(c.mobId))
        pendingLanding[castKey(c.mobId, c.spell)] = { mobId = c.mobId, spell = c.spell, at = c.at }
    end
    for _, p in ipairs(unconfirmedCasts(pendingLanding, confirmed, rt and rt.npcSpellApplied, os.clock())) do
        trace('no landing message seen for %s on #%s within %d s of the cast', p.spell, tostring(p.mobId), LANDING_WINDOW_SEC)
    end
    local cleared = clearFailedMez(core.castTracker, rt and rt.npcSpellApplied, rt and rt.npcSpellLastCast, failureSeen)
    if cleared then trace('failed mez cast: cleared the record for #%s', tostring(cleared)) end
end

function plugin.onSaveSettings()
    return { damagedProtection = cfg.damagedProtection ~= false }
end

function plugin.onLoadSettings(s)
    if type(s) ~= 'table' then return end
    if s.damagedProtection ~= nil then cfg.damagedProtection = (s.damagedProtection == true) end
end

function plugin.onDrawSettings()
    if not core then return end
    local ImGui = core.ImGui
    local colors = core.colors or {}
    local GOLD = colors.GOLD or { 1.0, 0.70, 0.54, 1 }
    local GOOD = colors.GOOD or { 0.40, 0.85, 0.50, 1.0 }
    local WARN = colors.WARN or { 0.95, 0.75, 0.30, 1.0 }
    local MUTED = colors.MUTED or { 0.6, 0.6, 0.6, 1.0 }
    core.accent(GOLD, 'Mez Support')
    ImGui.TextWrapped(HELP)
    ImGui.Dummy(0, core.px(4))

    local prot = ImGui.Checkbox('Skip damaged adds##mezDamaged', cfg.damagedProtection == true)
    if prot ~= (cfg.damagedProtection == true) then
        cfg.damagedProtection = prot
        cache = { serial = nil, spell = nil, result = nil }
        if core.saveLoadout then core.saveLoadout(true) end
    end
    core.setTooltip('A mob below full health is being fought by someone, so it is not mezzed. Turn this off in a damage-over-time fight '
        .. 'where adds are often damaged without being the group\'s target.')

    ImGui.Dummy(0, core.px(4))
    core.accent(GOLD, 'Status')
    if last.result then
        local c = (last.result.status == STATUS.CANDIDATE) and GOOD or WARN
        ImGui.TextColored(c[1], c[2], c[3], c[4], last.text)
        ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4],
            string.format('%s, %.0f s ago', tostring(last.spell or '?'), math.max(0, os.clock() - (last.at or 0))))
    else
        ImGui.TextDisabled('No mez entry has used "E: ' .. SELECTOR_LABEL .. '" yet.')
    end
end

plugin.logic = {
    SPELLS       = SPELLS,
    STATUS       = STATUS,
    spellInfo    = spellInfo,
    decide       = decide,
    statusText   = statusText,
    announce     = announce,
    normalize    = normalize,
    mezStateOf   = mezStateOf,
    clearFailedMez = clearFailedMez,
    describeInput  = describeInput,
    findMaPeer     = findMaPeer,
    predictTankNext = predictTankNext,
    describeXtarget = describeXtarget,
    describePrediction = describePrediction,
    describeResult = describeResult,
    newMezCasts    = newMezCasts,
    landedTexts    = landedTexts,
    spellsForLanding = spellsForLanding,
    matchLanding   = matchLanding,
    matchEnd       = matchEnd,
    unconfirmedCasts = unconfirmedCasts,
    collectMezRecords = collectMezRecords,
    handleLanded   = handleLanded,
    handleEnded    = handleEnded,
    collectState = collectState,
    resolve      = resolve,
    settings     = cfg,
}

return plugin
