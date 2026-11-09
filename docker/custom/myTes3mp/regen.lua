-- Health and magicka that come back by themselves, when nobody is fighting.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Switch it off with TES3MP_REGEN=false.
--
-- Morrowind has no natural health regeneration and no magicka regeneration
-- at all, so every fight ends with a trip to bed. Here, a player who has been
-- out of combat for a few seconds (combat.lua decides what that means) gets
-- his health back in about 90 seconds and his magicka in about 3 minutes,
-- whatever his level. During a fight nothing comes back. Nothing comes back
-- for a player who is dead or downed (downed.lua) either, and a player born
-- under the Atronach sign (Stunted Magicka) gets health only: his magicka
-- stays the way the sign made it.
--
-- How it works around the engine. The server cannot simply "heal" a player on
-- a timer: the game client owns the player's health and magicka, the server
-- only hears about them (in steps of 2 for health and 4 for magicka) and can
-- overwrite them in one go, which would be a visible jump every few seconds.
-- What the client does do, all the time and by itself, is apply the effects
-- of the abilities in the player's spellbook, and "Restore Health" and
-- "Restore Magicka" abilities add their magnitude in points per second. So:
--
--   * At server start this script makes a few permanent spell records
--     (myt_regen_health_1, _2, _4, _8, _16 and the same for magicka): abilities
--     with one self-cast Restore effect of that many points per second. They
--     are sent to every client when it logs in, like any permanent record.
--     Because the magnitudes are powers of two, any rate from 1 to 31 points
--     per second is a combination of them.
--   * Every couple of seconds the script looks at each player. If he is out of
--     combat and below his maximum, he is given the combination that is
--     closest to "maximum / 90 seconds" for health and "maximum / 180
--     seconds" for magicka (the rate is whole points per second, so a very
--     weak character regenerates a little faster than that, never slower).
--   * The moment he enters combat, or dies, the abilities are taken away
--     again; they are also taken away shortly after he is back at full.
--
-- The abilities are sent to the client as spellbook changes but are never
-- written to the player's saved spellbook, so they cannot pile up: whatever
-- the client had in a previous session is removed when he logs in, and
-- anything that did end up in his saved spellbook is removed on login and
-- logout. Their names are not shown in the spell list (the game only lists
-- spells and powers there); the Restore icons show in the effects bar.
--
-- Known rough edge: the server only hears about health in steps of 2 and
-- magicka in steps of 4, so "full" is judged to within that much.

local settings = require("custom/myTes3mp/settings")

local regen = {}

-- Off only when explicitly switched off; a missing setting means on.
regen.enabled = settings.regen ~= false

-- About how long a complete refill takes.
regen.healthSeconds = 90
regen.magickaSeconds = 180

-- How often every player is looked at, in seconds, and how long the
-- abilities stay after the server first sees him at full.
regen.checkSeconds = 2
regen.graceSeconds = 3

-- Ability magnitudes, in points per second. Any whole rate up to their sum.
regen.steps = { 1, 2, 4, 8, 16 }

-- The server hears about health once it has moved by 2 and magicka by 4
-- (LocalPlayer::updateStatsDynamic in the client), so that is how close to the
-- maximum counts as full.
local TOLERANCE = { health = 2, magicka = 4 }

-- Spell records. ESM::Spell::ST_Ability is 1 (components/esm/loadspel.hpp);
-- the effect numbers are in enumerations.effects.
local ABILITY = 1
local SELF = 0
local EFFECT = {
    health = enumerations.effects.RESTORE_HEALTH,
    magicka = enumerations.effects.RESTORE_MAGICKA
}
local NAME = { health = "Second Wind", magicka = "Inner Spring" }
local PREFIX = "myt_regen_"

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp regen] " .. message)
end

local function recordId(kind, step)
    return PREFIX .. kind .. "_" .. step
end

regen.RecordId = recordId

local function isOurs(spellId)
    return type(spellId) == "string" and string.sub(string.lower(spellId), 1, #PREFIX) == PREFIX
end

-- The spell records, as they go into the "spell" record store.
regen.Records = function()
    local records = {}
    for kind, effectId in pairs(EFFECT) do
        for _, step in ipairs(regen.steps) do
            records[recordId(kind, step)] = {
                name = NAME[kind],
                subtype = ABILITY,
                cost = 0,
                flags = 0,
                effects = { {
                    id = effectId,
                    attribute = -1,
                    skill = -1,
                    rangeType = SELF,
                    area = 0,
                    duration = 0,
                    magnitudeMin = step,
                    magnitudeMax = step
                } }
            }
        end
    end
    return records
end

-- Points per second for a pool of this size, refilled in about this many
-- seconds: whole points, at least 1, at most all the abilities together.
regen.RateFor = function(maximum, seconds)
    local top = 0
    for _, step in ipairs(regen.steps) do
        top = top + step
    end
    local rate = math.floor((tonumber(maximum) or 0) / seconds + 0.5)
    return math.max(1, math.min(top, rate))
end

-- The abilities that add up to this rate.
local function stepsOf(rate)
    local steps = {}
    for _, step in ipairs(regen.steps) do
        if math.floor(rate / step) % 2 == 1 then
            table.insert(steps, step)
        end
    end
    return steps
end

-- active[pid][kind] = points per second this player has been given
local active = {}
-- seenFull[pid][kind] = os.time() the server first saw him at full
local seenFull = {}

local function isOnline(pid)
    return Players[pid] ~= nil and Players[pid]:IsLoggedIn()
end

local function sendSpells(pid, action, spellIds)
    if #spellIds == 0 then
        return
    end
    tes3mp.ClearSpellbookChanges(pid)
    tes3mp.SetSpellbookChangesAction(pid, action)
    for _, spellId in ipairs(spellIds) do
        tes3mp.AddSpell(pid, spellId)
    end
    tes3mp.SendSpellbookChanges(pid)
end

local function rateOf(pid, kind)
    return active[pid] ~= nil and active[pid][kind] or 0
end

-- Give a player exactly this rate of this kind, changing only what differs.
local function setRate(pid, kind, rate)
    local old = rateOf(pid, kind)
    if old == rate then
        return
    end
    local oldSteps, newSteps = {}, {}
    for _, step in ipairs(stepsOf(old)) do
        oldSteps[step] = true
    end
    for _, step in ipairs(stepsOf(rate)) do
        newSteps[step] = true
    end
    local remove, add = {}, {}
    for _, step in ipairs(regen.steps) do
        if oldSteps[step] and not newSteps[step] then
            table.insert(remove, recordId(kind, step))
        elseif newSteps[step] and not oldSteps[step] then
            table.insert(add, recordId(kind, step))
        end
    end
    sendSpells(pid, enumerations.spellbook.REMOVE, remove)
    sendSpells(pid, enumerations.spellbook.ADD, add)
    if active[pid] == nil then
        active[pid] = {}
    end
    active[pid][kind] = rate > 0 and rate or nil
    if rate == 0 and seenFull[pid] ~= nil then
        seenFull[pid][kind] = nil
    end
end

-- Take everything away from a player.
local function clear(pid)
    for kind, _ in pairs(EFFECT) do
        setRate(pid, kind, 0)
    end
    active[pid] = nil
    seenFull[pid] = nil
end

regen.Clear = clear

-- The abilities currently given to a player, as { health = n, magicka = n }.
regen.Rates = function(pid)
    return { health = rateOf(pid, "health"), magicka = rateOf(pid, "magicka") }
end

-- Remove any trace of the abilities from the spellbook the server saves.
local function stripSavedSpellbook(pid)
    local player = Players[pid]
    if player == nil or type(player.data) ~= "table" or type(player.data.spellbook) ~= "table" then
        return
    end
    local changed = false
    for index, spellId in pairs(player.data.spellbook) do
        if isOurs(spellId) then
            player.data.spellbook[index] = nil
            changed = true
        end
    end
    if changed then
        tableHelper.cleanNils(player.data.spellbook)
    end
end

-- Stunted Magicka comes with the Atronach birthsign. The server gets the
-- birthsign from the client at character creation and sends it back at every
-- login; it is also saved with the character.
regen.IsAtronach = function(pid)
    local sign = tes3mp.GetBirthsign(pid)
    if type(sign) ~= "string" or sign == "" then
        local player = Players[pid]
        sign = player ~= nil and type(player.data) == "table" and type(player.data.character) == "table"
            and player.data.character.birthsign or ""
    end
    if type(sign) ~= "string" then
        return false
    end
    -- The game data calls the sign "Wombburned"; "The Atronach" is only the
    -- name it shows. Both are accepted, in case a translation differs.
    sign = string.lower(sign)
    return string.find(sign, "wombburn", 1, true) ~= nil or string.find(sign, "atronach", 1, true) ~= nil
end

local function isDowned(pid)
    return myTes3mpDowned ~= nil and myTes3mpDowned.IsDowned(pid) == true
end

-- May this player be regenerating right now?
local function eligible(pid)
    if not isOnline(pid) or myTes3mpCombat == nil or myTes3mpCombat.InCombat(pid) then
        return false
    end
    if (tonumber(tes3mp.GetHealthCurrent(pid)) or 0) <= 0 or isDowned(pid) then
        return false
    end
    return true
end

local function update(pid, kind, current, maximum, seconds)
    local now = os.time()
    if maximum < 1 then
        setRate(pid, kind, 0)
        return
    end
    if seenFull[pid] == nil then
        seenFull[pid] = {}
    end
    if current >= maximum - TOLERANCE[kind] then
        -- Full, as far as the server can tell. Leave the ability on for a
        -- moment: the last few points are not reported.
        if rateOf(pid, kind) > 0 then
            seenFull[pid][kind] = seenFull[pid][kind] or now
            if now - seenFull[pid][kind] >= regen.graceSeconds then
                setRate(pid, kind, 0)
            end
        end
    else
        seenFull[pid][kind] = nil
        setRate(pid, kind, regen.RateFor(maximum, seconds))
    end
end

-- Look at one player and give or take away what he should have.
regen.Evaluate = function(pid)
    if not eligible(pid) then
        clear(pid)
        return
    end
    update(pid, "health", tonumber(tes3mp.GetHealthCurrent(pid)) or 0,
        tonumber(tes3mp.GetHealthBase(pid)) or 0, regen.healthSeconds)
    if regen.IsAtronach(pid) then
        setRate(pid, "magicka", 0)
    else
        update(pid, "magicka", tonumber(tes3mp.GetMagickaCurrent(pid)) or 0,
            tonumber(tes3mp.GetMagickaBase(pid)) or 0, regen.magickaSeconds)
    end
end

regen.Check = function()
    for pid, _ in pairs(Players) do
        regen.Evaluate(pid)
    end
    -- Forget players who are gone.
    for pid, _ in pairs(active) do
        if not isOnline(pid) then
            active[pid] = nil
            seenFull[pid] = nil
        end
    end
end

-- Make the spell records exist, with the right contents, in the record store.
regen.EnsureRecords = function()
    local store = RecordStores ~= nil and RecordStores["spell"] or nil
    if store == nil then
        tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp regen] There is no spell record store; regeneration is off")
        regen.enabled = false
        return
    end
    local wanted = regen.Records()
    local permanent = store.data.permanentRecords
    local changed = false
    for id, record in pairs(wanted) do
        if not tableHelper.isEqualTo(record, permanent[id] or {}) then
            permanent[id] = record
            changed = true
        end
    end
    -- Records of an earlier version that are no longer wanted.
    for id, _ in pairs(permanent) do
        if isOurs(id) and wanted[id] == nil then
            permanent[id] = nil
            changed = true
        end
    end
    if changed then
        store:QuicksaveToDrive()
        log("Spell records written")
    end
end

if regen.enabled then
    -- A player enters combat: everything stops at once.
    if myTes3mpCombat ~= nil then
        table.insert(myTes3mpCombat.listeners, function(pid)
            clear(pid)
        end)
    end

    customEventHooks.registerHandler("OnPlayerDeath", function(eventStatus, pid)
        clear(pid)
    end)

    -- A player has just logged in. The client may still have the abilities
    -- from an earlier session (a "set" of the spellbook leaves abilities
    -- alone), and a crash may have left them in the saved spellbook.
    customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
        if not isOnline(pid) then
            return
        end
        active[pid] = nil
        seenFull[pid] = nil
        stripSavedSpellbook(pid)
        local ids = {}
        for kind, _ in pairs(EFFECT) do
            for _, step in ipairs(regen.steps) do
                table.insert(ids, recordId(kind, step))
            end
        end
        sendSpells(pid, enumerations.spellbook.REMOVE, ids)
    end)

    -- Before the player is saved.
    customEventHooks.registerValidator("OnPlayerDisconnect", function(eventStatus, pid)
        active[pid] = nil
        seenFull[pid] = nil
        stripSavedSpellbook(pid)
    end)

    local checkTimerId

    function MyTes3mpRegenTick()
        local ok, problem = pcall(regen.Check)
        if not ok then
            tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp regen] Check failed: " .. tostring(problem))
        end
        tes3mp.RestartTimer(checkTimerId, time.seconds(regen.checkSeconds))
    end

    customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
        if myTes3mpCombat == nil then
            tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp regen] combat.lua is not loaded; regeneration is off")
            regen.enabled = false
            return
        end
        regen.EnsureRecords()
        if not regen.enabled then
            return
        end
        checkTimerId = tes3mp.CreateTimer("MyTes3mpRegenTick", time.seconds(regen.checkSeconds))
        tes3mp.StartTimer(checkTimerId)
        log("Health returns in about " .. regen.healthSeconds .. " s and magicka in about " ..
            regen.magickaSeconds .. " s, out of combat")
    end)
end

return regen
