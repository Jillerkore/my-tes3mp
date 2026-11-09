-- Roaming world bosses with personal loot.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Set how often a boss appears with
-- TES3MP_WORLD_BOSS_HOURS (real hours; 0 switches it off).
--
-- Why. Morrowind's world is quiet, and two players who have outgrown it have
-- little reason to run around together. A world boss gives them one:
--
--   * Every few real hours - while at least one player is online - a boss
--     appears at a random town, port or guild hall in the open world. A
--     message tells everybody where.
--   * It is a big, tough creature built for the strongest player online, and
--     it is meant to need two players. There is only ever one at a time.
--   * When it falls, every player who is in its area at that moment gets
--     his own reward straight into his pack: gold and one useful item.
--     Nobody fights over a corpse, and nobody who was not there gets
--     anything. (The area is the game cell the boss is in - an open-world
--     cell is about 8000 game units across, a town fits in one or two.)
--   * If nobody kills it within two real hours it leaves, and everybody is
--     told. It also counts as having left if its cell is reset (resets.lua).
--   * /boss tells you whether one is abroad and where.
--
-- How it works.
--
--   Places. The towns, ports and guild halls in travelPoints.lua that lie in
--   the open world. If that file is missing or has none, the bosses stay
--   idle and say so once in the log.
--
--   Creatures. Five tiers, picked by the highest level among the players
--   online. Each is a custom creature record, defined when the server starts
--   as a permanent record of the "creature" record store (so every player
--   receives it at login, and players already online receive it at once). A
--   record is a vanilla creature - for the look and the moves - with its own
--   name, size, level, health and damage. Health and damage follow a formula
--   from the tier's reference level, so they are written down in one place
--   (bosses.tiers and the two functions below them), not copied from the
--   base creature. All of them are hostile on sight and never flee.
--
--   Health in practice. challenge.lua multiplies the health of every enemy
--   once a player's game reports it: by (1.5 + 0.05 x (highest level - 1))
--   under the default "hard" preset, and again by 1 + 0.5 x (players in the
--   cell - 1) counted when the creature is first seen (at most 5 times in
--   all). So the real health is the record's health times that; the table
--   with the numbers is in bosses.Describe() and in the tests.
--
--   Spawning. The server places the creature as a spawned actor at the
--   chosen spot of the chosen cell, even if no player has that cell loaded;
--   every connected game is told, and a player who enters the cell later is
--   sent it with the rest of the cell's contents. The state of the current
--   boss (and when the next is due) is kept in data/custom/myTes3mpBosses.json,
--   so a restart neither loses it nor forgets the schedule.
--
--   Death. The game that controls the cell reports the death to the server.
--   Everybody who took part is rewarded exactly once: the players who have
--   that cell loaded - a client loads the cell it is in and the eight around
--   it - and who have struck or taken a blow in the last two minutes. (If
--   the server keeps no track of combat, having the cell loaded is enough.) The body is removed
--   after a minute and a half so it does not clutter the town.
--
-- A boss recorded in the state whose creature no longer exists is dropped at
-- start-up, and in any case every boss expires after two hours, so a lost
-- boss never keeps the next one from coming.

local settings = require("custom/myTes3mp/settings")

local bosses = {}

-- Real hours between two bosses; 0 = off. (Nothing given means the default, 3.)
bosses.hours = tonumber(settings.worldBossHours)
if bosses.hours == nil then
    bosses.hours = 3
end

-- How long a boss stays before it leaves, in seconds.
bosses.lifeSeconds = 2 * 3600

-- How long a dead boss's body lies around, in seconds.
bosses.corpseSeconds = 90

-- How often the schedule is looked at, in seconds.
bosses.checkSeconds = 30

-- When the next boss is due but nobody is online, it is put off by this
-- much, so that the first player to log in is not met by one at once.
bosses.graceSeconds = 300

-- Distance, in game units, by which the boss is put away from the town's
-- arrival point. 0: exactly there. The arrival points are the only spots
-- known to be on solid ground - a step to the side of a pier is water.
bosses.spawnOffset = 0

-- A player counts as having taken part in the fight if he struck or took a
-- blow within this many seconds of the boss falling.
bosses.foughtWithinSeconds = 120

bosses.random = math.random

------------------------------------------------------------------ the tiers

-- Every tier:
--   minLevel   the highest player level online from which this tier is used
--   refLevel   the level the numbers below are built for (about the middle
--              of the band)
--   base       the vanilla creature it looks and moves like (all of them are
--              in Morrowind.esm, Tribunal.esm or Bloodmoon.esm, which every
--              client must have; none is immune to ordinary weapons)
--   scale      size; 1 is the size of the base
--   gold       gold for each player who was there
--   loot       one of these is picked at random for each player:
--              { item id, count, name to show }; unique items are never used
--
-- The record's numbers come from refLevel:
--   level   = refLevel + 4
--   health  = 100 + 40 x refLevel
--   damage  = 3 x level at most and a third of that at least, for every kind
--             of attack - the ratio vanilla creatures have
bosses.tiers = {
    {
        minLevel = 5, refLevel = 3, base = "kagouti", scale = 1.9,
        name = "Gnarlhide, Terror of the Ashlands", gold = 250,
        loot = {
            { "Misc_SoulGem_Lesser", 1, "Lesser Soul Gem" },
            { "p_restore_health_s", 2, "Restore Health Potion" },
            { "p_restore_magicka_s", 2, "Restore Magicka Potion" },
            { "ingred_fire_salts_01", 2, "Fire Salts" },
            { "ingred_frost_salts_01", 2, "Frost Salts" }
        }
    },
    {
        minLevel = 10, refLevel = 7, base = "clannfear", scale = 1.7,
        name = "Razorclaw the Matriarch", gold = 600,
        loot = {
            { "Misc_SoulGem_Common", 1, "Common Soul Gem" },
            { "p_restore_health_q", 2, "Quality Restore Health Potion" },
            { "p_restore_magicka_q", 2, "Quality Restore Magicka Potion" },
            { "ingred_pearl_01", 2, "Pearl" },
            { "ingred_ruby_01", 1, "Ruby" }
        }
    },
    {
        minLevel = 15, refLevel = 12, base = "BM_bear_black", scale = 2.3,
        name = "Old Ashmaw, the Mountain Grizzly", gold = 1400,
        loot = {
            { "Misc_SoulGem_Greater", 1, "Greater Soul Gem" },
            { "p_restore_health_e", 1, "Exclusive Restore Health Potion" },
            { "p_restore_magicka_e", 1, "Exclusive Restore Magicka Potion" },
            { "ingred_emerald_01", 1, "Emerald" },
            { "ingred_diamond_01", 1, "Diamond" },
            { "repair_master_01", 1, "Master's Prongs" }
        }
    },
    {
        minLevel = 22, refLevel = 18, base = "winged twilight", scale = 1.6,
        name = "Seraphine, the Storm-Winged", gold = 3000,
        loot = {
            { "Misc_SoulGem_Grand", 1, "Grand Soul Gem" },
            { "p_fortify_health_e", 2, "Exclusive Fortify Health Potion" },
            { "p_spell_absorption_e", 2, "Exclusive Spell Absorption Potion" },
            { "ingred_daedras_heart_01", 1, "Daedra's Heart" },
            { "ingred_raw_ebony_01", 2, "Raw Ebony" },
            { "pick_master", 1, "Master's Lockpick" },
            { "probe_master", 1, "Master's Probe" }
        }
    },
    {
        minLevel = 30, refLevel = 26, base = "fabricant_hulking", scale = 1.8,
        name = "The Iron Colossus", gold = 6500,
        loot = {
            { "Misc_SoulGem_Grand", 2, "Grand Soul Gem" },
            { "repair_grandmaster_01", 1, "Grandmaster's Prongs" },
            { "ingred_daedras_heart_01", 2, "Daedra's Heart" },
            { "ingred_raw_ebony_01", 3, "Raw Ebony" },
            { "p_restore_health_e", 3, "Exclusive Restore Health Potion" },
            { "p_fortify_attack_e", 2, "Exclusive Fortify Attack Potion" }
        }
    }
}

-- Ids of the creature records, one per tier.
bosses.RecordId = function(tierNumber)
    return "myt_boss_" .. tierNumber
end

bosses.RecordLevel = function(tier) return tier.refLevel + 4 end
bosses.RecordHealth = function(tier) return 100 + 40 * tier.refLevel end
bosses.RecordDamage = function(tier)
    local most = 3 * bosses.RecordLevel(tier)
    return { min = math.floor(most / 3), max = most }
end

-- The record as the record store keeps it (and packetBuilder sends it).
bosses.Record = function(tier)
    local damage = bosses.RecordDamage(tier)
    return {
        baseId = tier.base,
        name = tier.name,
        scale = tier.scale,
        level = bosses.RecordLevel(tier),
        health = bosses.RecordHealth(tier),
        damageChop = { min = damage.min, max = damage.max },
        damageSlash = { min = damage.min, max = damage.max },
        damageThrust = { min = damage.min, max = damage.max },
        aiFight = 100,
        aiFlee = 0
    }
end

-- Which tier fits a player level.
bosses.TierFor = function(level)
    local chosen = 1
    for number, tier in ipairs(bosses.tiers) do
        if level >= tier.minLevel then
            chosen = number
        end
    end
    return chosen
end

-- What a fight comes to under challenge.lua's health rule, for a text/table:
-- the multiplier for the given player level and number of players in the
-- cell, and the health that results. Mirrors challenge.HealthMultiplier
-- (which needs the players online, so it cannot be asked for a given level).
bosses.EffectiveHealth = function(tierNumber, playerLevel, playersInCell)
    local tier = bosses.tiers[tierNumber]
    local multiplier = 1
    -- Look at challenge.lua only if it is loaded; this must not load it.
    local challenge = package.loaded["custom/myTes3mp/challenge"]
    if type(challenge) == "table" and type(challenge.preset) == "table" then
        local preset = challenge.preset
        multiplier = (preset.health + preset.healthPerLevel * (playerLevel - 1)) *
            (1 + (preset.group or 0) * math.max(0, playersInCell - 1))
        multiplier = math.min(challenge.healthCap or 5, multiplier)
    end
    return math.floor(bosses.RecordHealth(tier) * multiplier + 0.5), multiplier
end

------------------------------------------------------------------ state

-- Saved as data/custom/myTes3mpBosses.json:
--   nextAt   time (os.time) the next boss is due
--   lastHub  name of the place of the last boss, so it does not repeat
--   boss     the boss that is abroad, or nothing:
--            { tier, hub, cell, uniqueIndex, refId, name, spawnedAt, expiresAt }
--   corpses  dead bosses waiting to be removed:
--            { { cell, uniqueIndex, removeAt }, ... }
local STATE_FILE = "custom/myTes3mpBosses.json"
local state = { nextAt = nil, lastHub = nil, boss = nil, corpses = {} }

local hubs = {}

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp bosses] " .. message)
end

local function logError(message)
    tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp bosses] " .. message)
end

local function isOnline(pid)
    return Players[pid] ~= nil and Players[pid]:IsLoggedIn()
end

local function anyOnlinePid()
    for pid, player in pairs(Players) do
        if player ~= nil and player:IsLoggedIn() then
            return pid
        end
    end
    return nil
end

local function levelOf(player)
    if type(player.data.stats) == "table" then
        return tonumber(player.data.stats.level) or 1
    end
    return 1
end

local function highestLevelOnline()
    local highest = 1
    for _, player in pairs(Players) do
        if player ~= nil and player:IsLoggedIn() then
            highest = math.max(highest, levelOf(player))
        end
    end
    return highest
end

local function saveState()
    jsonInterface.quicksave(STATE_FILE, state)
end

local function validBoss(boss)
    return type(boss) == "table" and type(boss.tier) == "number" and bosses.tiers[boss.tier] ~= nil and
        type(boss.cell) == "string" and type(boss.uniqueIndex) == "string" and type(boss.refId) == "string" and
        type(boss.name) == "string" and type(boss.expiresAt) == "number"
end

-- Take over only what has the expected shape; a damaged file must not be
-- able to keep a boss from coming or to remove something else.
local function loadState()
    state = { nextAt = nil, lastHub = nil, boss = nil, corpses = {} }
    local loaded = jsonInterface.load(STATE_FILE)
    if type(loaded) ~= "table" then
        return
    end
    if type(loaded.nextAt) == "number" then
        state.nextAt = loaded.nextAt
    end
    if type(loaded.lastHub) == "string" then
        state.lastHub = loaded.lastHub
    end
    if validBoss(loaded.boss) then
        local boss = loaded.boss
        state.boss = {
            tier = boss.tier, hub = type(boss.hub) == "string" and boss.hub or boss.cell, cell = boss.cell,
            uniqueIndex = boss.uniqueIndex, refId = boss.refId, name = boss.name,
            spawnedAt = tonumber(boss.spawnedAt) or 0, expiresAt = boss.expiresAt
        }
    end
    if type(loaded.corpses) == "table" then
        for _, corpse in ipairs(loaded.corpses) do
            if type(corpse) == "table" and type(corpse.cell) == "string" and type(corpse.uniqueIndex) == "string" and
                type(corpse.removeAt) == "number" then
                table.insert(state.corpses, { cell = corpse.cell, uniqueIndex = corpse.uniqueIndex,
                    removeAt = corpse.removeAt })
            end
        end
    end
end

------------------------------------------------------------------ messages

local function announce(message)
    local pid = anyOnlinePid()
    if pid == nil then
        return
    end
    tes3mp.SendMessage(pid, color.Yellow .. "[boss] " .. color.White .. message .. "\n", true)
end

local function tell(pid, message)
    tes3mp.SendMessage(pid, color.Yellow .. "[boss] " .. color.White .. message .. "\n", false)
end

local function minutesLeft(at)
    return math.max(1, math.ceil((at - os.time()) / 60))
end

------------------------------------------------------------------ records

-- Make sure the five creature records exist with the numbers above, and that
-- players who are online have them. Returns true when the records are usable.
bosses.DefineRecords = function()
    local store = RecordStores ~= nil and RecordStores["creature"] or nil
    if store == nil or type(store.data) ~= "table" then
        logError("The creature record store is not available; no bosses can appear")
        return false
    end
    if type(store.data.permanentRecords) ~= "table" then
        store.data.permanentRecords = {}
    end

    local changed = {}
    for number, tier in ipairs(bosses.tiers) do
        local id = bosses.RecordId(number)
        local record = bosses.Record(tier)
        local old = store.data.permanentRecords[id]
        if type(old) ~= "table" or not tableHelper.isEqualTo(old, record) then
            store.data.permanentRecords[id] = record
            table.insert(changed, id)
        end
    end

    if #changed > 0 then
        store:QuicksaveToDrive()
        local pid = anyOnlinePid()
        if pid ~= nil then
            -- Players already online will not get permanent records at login.
            store:LoadRecords(pid, store.data.permanentRecords, changed, true)
        end
        log("Defined " .. #changed .. " boss creature record(s)")
    end
    return true
end

------------------------------------------------------------------ places

local function parseCell(description)
    local x, y = string.match(description, "^(-?%d+), (-?%d+)$")
    if x == nil then
        return nil
    end
    return tonumber(x), tonumber(y)
end

local function inCell(description, x, y)
    local gridX, gridY = parseCell(description)
    return gridX ~= nil and math.floor(x / 8192) == gridX and math.floor(y / 8192) == gridY
end

-- The open-world arrival points of travelPoints.lua that are usable.
bosses.LoadHubs = function()
    hubs = {}
    local ok, points = pcall(require, "custom/myTes3mp/travelPoints")
    if not ok or type(points) ~= "table" then
        log("No travel points available (" .. tostring(ok and "not a list" or points) .. "); bosses stay idle")
        return hubs
    end
    for _, point in ipairs(points) do
        if type(point) == "table" and point.exterior == true and type(point.name) == "string" and
            type(point.cell) == "string" and type(point.pos) == "table" and
            type(point.pos[1]) == "number" and type(point.pos[2]) == "number" and type(point.pos[3]) == "number" and
            inCell(point.cell, point.pos[1], point.pos[2]) then
            table.insert(hubs, point)
        end
    end
    if #hubs == 0 then
        log("The travel points hold no open-world place; bosses stay idle")
    end
    return hubs
end

local function chooseHub()
    local candidates = {}
    for _, hub in ipairs(hubs) do
        if hub.name ~= state.lastHub then
            table.insert(candidates, hub)
        end
    end
    if #candidates == 0 then
        candidates = hubs
    end
    if #candidates == 0 then
        return nil
    end
    return candidates[bosses.random(1, #candidates)]
end

-- Where exactly: near the arrival point, but inside the same cell.
local function locationAt(hub)
    local x, y, z = hub.pos[1], hub.pos[2], hub.pos[3]
    local angle = bosses.random() * 2 * math.pi
    local nx = x + math.cos(angle) * bosses.spawnOffset
    local ny = y + math.sin(angle) * bosses.spawnOffset
    if not inCell(hub.cell, nx, ny) then
        nx, ny = x, y
    end
    local rotZ = type(hub.rot) == "table" and tonumber(hub.rot[3]) or 0
    return { posX = nx, posY = ny, posZ = z, rotX = 0, rotY = 0, rotZ = rotZ }
end

------------------------------------------------------------------ objects

-- Run fn(cell) on a cell object, loading it from disk for the duration if no
-- player has it loaded.
local function withCell(cellDescription, fn)
    local temporary = false
    if LoadedCells[cellDescription] == nil then
        logicHandler.LoadCell(cellDescription)
        temporary = true
    end
    local ok, result = pcall(fn, LoadedCells[cellDescription])
    if temporary and LoadedCells[cellDescription] ~= nil then
        logicHandler.UnloadCell(cellDescription)
    end
    if not ok then
        error(result, 0)
    end
    return result
end

-- Is this object still part of that cell's data (and alive)?
local function objectAlive(cellDescription, uniqueIndex, refId)
    return withCell(cellDescription, function(cell)
        local object = cell.data.objectData[uniqueIndex]
        if type(object) ~= "table" or type(object.refId) ~= "string" or
            string.lower(object.refId) ~= string.lower(refId) then
            return false
        end
        return not tableHelper.containsValue(cell.data.packets.death or {}, uniqueIndex)
    end)
end

-- Take an object out of a cell for everybody, loaded or not.
local function removeObject(cellDescription, uniqueIndex)
    if next(Players) ~= nil then
        -- Tells every connected game and forgets the object in the cell's
        -- data, loading the cell for a moment if it is not loaded.
        logicHandler.DeleteObjectForEveryone(cellDescription, uniqueIndex)
    else
        withCell(cellDescription, function(cell)
            cell:DeleteObjectData(uniqueIndex)
        end)
    end
end

------------------------------------------------------------------ the boss comes

bosses.Spawn = function()
    if #hubs == 0 or state.boss ~= nil or not bosses.DefineRecords() then
        return false
    end
    -- Nobody online is ready for even the first tier: no boss for now. (The
    -- caller looks again a little later.)
    if highestLevelOnline() < bosses.tiers[1].minLevel then
        return false
    end
    local number = bosses.TierFor(highestLevelOnline())
    local tier = bosses.tiers[number]
    local hub = chooseHub()
    local refId = bosses.RecordId(number)

    local ok, uniqueIndex = pcall(logicHandler.CreateObjectAtLocation, hub.cell, locationAt(hub),
        { refId = refId }, "spawn")
    if not ok or uniqueIndex == nil then
        logError("Could not place " .. refId .. " in " .. hub.cell .. ": " .. tostring(uniqueIndex))
        -- Try again at the next look rather than at the next period.
        return false
    end

    local now = os.time()
    state.boss = {
        tier = number, hub = hub.name, cell = hub.cell, uniqueIndex = uniqueIndex, refId = refId,
        name = tier.name, spawnedAt = now, expiresAt = now + bosses.lifeSeconds
    }
    state.lastHub = hub.name
    state.nextAt = now + bosses.hours * 3600
    saveState()

    log(tier.name .. " (" .. refId .. ", " .. uniqueIndex .. ") appeared at " .. hub.name .. " (" .. hub.cell .. ")")
    announce("A world boss has appeared at " .. hub.name .. ": " .. tier.name .. "! It is a fight for more than one" ..
        " adventurer - everyone who is there when it falls gets a reward of his own. It will leave in " ..
        math.floor(bosses.lifeSeconds / 60) .. " minutes.")
    return true
end

-- The boss is gone without being killed (time ran out, or its cell was reset).
bosses.Depart = function(reason, removeIt)
    local boss = state.boss
    if boss == nil then
        return
    end
    state.boss = nil
    saveState()
    if removeIt then
        local ok, problem = pcall(removeObject, boss.cell, boss.uniqueIndex)
        if not ok then
            logError("Could not remove " .. boss.uniqueIndex .. " from " .. boss.cell .. ": " .. tostring(problem))
        end
    end
    log(boss.name .. " left (" .. reason .. ")")
    announce(boss.name .. " has left " .. boss.hub .. " - nobody brought it down this time.")
end

------------------------------------------------------------------ the boss falls

local function giveReward(pid, tier)
    local player = Players[pid]
    local items = {}

    table.insert(items, { refId = "gold_001", count = tier.gold, charge = -1, enchantmentCharge = -1, soul = "" })
    local pick = tier.loot[bosses.random(1, #tier.loot)]
    table.insert(items, { refId = pick[1], count = pick[2], charge = -1, enchantmentCharge = -1, soul = "" })

    for _, item in ipairs(items) do
        inventoryHelper.addItem(player.data.inventory, item.refId, item.count, item.charge, item.enchantmentCharge,
            item.soul)
    end
    player:LoadItemChanges(items, enumerations.inventory.ADD)
    player:QuicksaveToDrive()

    tell(pid, "Your reward: " .. tier.gold .. " gold and " .. pick[2] .. " x " .. pick[3] .. ".")
    log(player.accountName .. " received " .. tier.gold .. " gold and " .. pick[1] .. " x" .. pick[2])
end

-- The boss has died in this cell. Reward everybody who is there; once.
bosses.Killed = function(killerPid, cellDescription)
    local boss = state.boss
    if boss == nil then
        return
    end
    -- Forget the boss before anything is handed out, so that a second report
    -- of the same death cannot reward anybody twice.
    state.boss = nil
    table.insert(state.corpses, { cell = cellDescription, uniqueIndex = boss.uniqueIndex,
        removeAt = os.time() + bosses.corpseSeconds })
    saveState()

    local tier = bosses.tiers[boss.tier]

    -- Who took part: everybody who has the boss's cell loaded at this moment
    -- and has fought recently. Having the cell loaded alone would also pay a
    -- player who is a whole cell away and never lifted a hand.
    local function fought(pid)
        if myTes3mpCombat == nil then
            return true
        end
        -- SecondsSinceFight still counts a player who went down and was
        -- helped up; SecondsQuiet (for an older combat.lua) would not.
        local since = myTes3mpCombat.SecondsSinceFight or myTes3mpCombat.SecondsQuiet
        return since(pid) <= bosses.foughtWithinSeconds
    end
    local present, seen = {}, {}
    local cell = LoadedCells[cellDescription]
    local visitors = cell ~= nil and cell.visitors or {}
    for _, pid in ipairs(visitors) do
        if isOnline(pid) and fought(pid) and not seen[string.lower(Players[pid].accountName)] then
            seen[string.lower(Players[pid].accountName)] = true
            table.insert(present, pid)
        end
    end
    -- The game that reported the death has the cell loaded too, even if the
    -- visitor list missed it - but reporting is only a matter of whose game
    -- controls the cell, so it earns nothing by itself: he must have fought.
    if isOnline(killerPid) and fought(killerPid) and not seen[string.lower(Players[killerPid].accountName)] then
        table.insert(present, killerPid)
    end

    local names = {}
    for _, pid in ipairs(present) do
        local ok, problem = pcall(giveReward, pid, tier)
        if ok then
            table.insert(names, Players[pid].accountName)
        else
            logError("Could not reward pid " .. tostring(pid) .. ": " .. tostring(problem))
        end
    end

    log(boss.name .. " was killed in " .. cellDescription .. "; rewarded: " .. table.concat(names, ", "))
    announce(boss.name .. " has been slain at " .. boss.hub .. "! Rewarded: " ..
        (#names > 0 and table.concat(names, ", ") or "nobody") .. ".")
end

customEventHooks.registerHandler("OnActorDeath", function(eventStatus, pid, cellDescription, actors)
    if eventStatus ~= nil and eventStatus.validDefaultHandler == false then
        return
    end
    local boss = state.boss
    if boss == nil or type(actors) ~= "table" then
        return
    end
    -- The object is told apart by its number, which no other object in the
    -- world shares; its cell can have changed since it appeared.
    local actor = actors[boss.uniqueIndex]
    if actor == nil then
        return
    end
    if type(actor.refId) == "string" and string.lower(actor.refId) ~= string.lower(boss.refId) then
        return
    end
    local ok, problem = pcall(bosses.Killed, pid, cellDescription)
    if not ok then
        logError("Handling the boss's death failed: " .. tostring(problem))
    end
end)

-- A server-made actor that walks into the next cell is moved there in the
-- cell data (cell/base.lua, SaveActorCellChanges); keep track of it.
customEventHooks.registerHandler("OnActorCellChange", function(eventStatus, pid, cellDescription)
    local boss = state.boss
    if boss == nil then
        return
    end
    tes3mp.ReadReceivedActorList()
    for index = 0, tes3mp.GetActorListSize() - 1 do
        local uniqueIndex = tes3mp.GetActorRefNum(index) .. "-" .. tes3mp.GetActorMpNum(index)
        if uniqueIndex == boss.uniqueIndex then
            local newCell = tes3mp.GetActorCell(index)
            if type(newCell) == "string" and newCell ~= "" and newCell ~= boss.cell then
                boss.cell = newCell
                saveState()
            end
        end
    end
end)

------------------------------------------------------------------ the schedule

bosses.Tick = function()
    local now = os.time()
    local changed = false

    -- Bodies.
    local kept = {}
    for _, corpse in ipairs(state.corpses) do
        if now >= corpse.removeAt then
            local ok, problem = pcall(removeObject, corpse.cell, corpse.uniqueIndex)
            if not ok then
                logError("Could not remove a body in " .. corpse.cell .. ": " .. tostring(problem))
            end
            changed = true
        else
            table.insert(kept, corpse)
        end
    end
    state.corpses = kept

    -- A boss that has stayed long enough.
    if state.boss ~= nil and now >= state.boss.expiresAt then
        bosses.Depart("time ran out", true)
    end

    -- The next boss.
    if state.boss == nil and bosses.hours > 0 and #hubs > 0 then
        if state.nextAt == nil then
            state.nextAt = now + bosses.hours * 3600
            changed = true
        elseif now >= state.nextAt then
            if anyOnlinePid() == nil then
                state.nextAt = now + bosses.graceSeconds
                changed = true
            else
                if not bosses.Spawn() then
                    -- Something is wrong with the place or the record; do
                    -- not retry (and log) every look.
                    state.nextAt = now + bosses.graceSeconds
                    changed = true
                end
            end
        end
    end

    if changed then
        saveState()
    end
end

local tickTimerId

function MyTes3mpBossTick()
    -- Whatever goes wrong in one look, the next one must still happen.
    local ok, problem = pcall(bosses.Tick)
    if not ok then
        logError("Check failed: " .. tostring(problem))
    end
    tes3mp.RestartTimer(tickTimerId, time.seconds(bosses.checkSeconds))
end

------------------------------------------------------------------ commands

bosses.Info = function(pid)
    local boss = state.boss
    if boss == nil then
        if bosses.hours <= 0 then
            tell(pid, "World bosses are switched off on this server.")
        elseif #hubs == 0 then
            tell(pid, "No world boss is abroad, and none can appear: there is no place for one.")
        else
            local when = type(state.nextAt) == "number" and state.nextAt > os.time() and
                (" The next one is expected in about " .. minutesLeft(state.nextAt) .. " minutes.") or ""
            tell(pid, "No world boss is abroad." .. when)
        end
        return
    end
    tell(pid, boss.name .. " is abroad at " .. boss.hub .. " (" .. boss.cell .. "). It leaves in about " ..
        minutesLeft(boss.expiresAt) .. " minutes. Everyone who is there when it falls gets a reward.")
end

customCommandHooks.registerCommand("boss", bosses.Info)

-- Somebody who logs in while a boss is abroad should know.
customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
    if state.boss ~= nil and isOnline(pid) then
        bosses.Info(pid)
    end
end)

------------------------------------------------------------------ start

-- A reset cell holds only what the game's data files describe: a boss in it
-- is gone. (Bosses are transient; nothing is protected from a reset.)
local function onCellReset(cellDescription)
    if state.boss ~= nil and state.boss.cell == cellDescription then
        bosses.Depart("its cell was reset", false)
    end
    local kept = {}
    for _, corpse in ipairs(state.corpses) do
        if corpse.cell ~= cellDescription then
            table.insert(kept, corpse)
        end
    end
    if #kept ~= #state.corpses then
        state.corpses = kept
        saveState()
    end
end

-- Describe the tiers (for the log and for the tests).
bosses.Describe = function()
    local lines = {}
    for number, tier in ipairs(bosses.tiers) do
        local damage = bosses.RecordDamage(tier)
        local low = bosses.EffectiveHealth(number, tier.minLevel, 2)
        table.insert(lines, string.format("tier %d from level %d: %s (%s, scale %.1f), level %d, health %d, damage %d-%d, " ..
            "about %d health with two players at level %d", number, tier.minLevel, tier.name, tier.base, tier.scale,
            bosses.RecordLevel(tier), bosses.RecordHealth(tier), damage.min, damage.max, low, tier.minLevel))
    end
    return lines
end

customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
    -- The server does not seed the random generator; without this the same
    -- place would come first after every restart.
    math.randomseed(os.time())

    loadState()

    -- Rewards must never be unique items.
    local ok, uniqueItems = pcall(require, "custom/myTes3mp/uniqueItems")
    if ok and type(uniqueItems) == "table" then
        for _, tier in ipairs(bosses.tiers) do
            local allowed = {}
            for _, entry in ipairs(tier.loot) do
                if uniqueItems[string.lower(entry[1])] == nil then
                    table.insert(allowed, entry)
                else
                    logError("Dropped " .. entry[1] .. " from the rewards: it is a unique item")
                end
            end
            tier.loot = allowed
        end
    end

    if bosses.hours <= 0 then
        log("World bosses are off")
        if state.boss ~= nil then
            bosses.Depart("switched off", true)
        end
        return
    end

    bosses.LoadHubs()
    bosses.DefineRecords()

    -- A boss in the state whose creature is gone must not block the next.
    if state.boss ~= nil then
        local present, result = pcall(objectAlive, state.boss.cell, state.boss.uniqueIndex, state.boss.refId)
        if not present or not result then
            log("The boss recorded in the state (" .. state.boss.uniqueIndex .. " in " .. state.boss.cell ..
                ") no longer exists; forgetting it")
            state.boss = nil
            saveState()
        end
    end

    if myTes3mpResets ~= nil then
        table.insert(myTes3mpResets.listeners, onCellReset)
        -- A cell with a boss standing in it is not reset under it.
        if type(myTes3mpResets.holders) == "table" then
            table.insert(myTes3mpResets.holders, function(cellDescription)
                return state.boss ~= nil and state.boss.cell == cellDescription
            end)
        end
    end

    tickTimerId = tes3mp.CreateTimer("MyTes3mpBossTick", time.seconds(bosses.checkSeconds))
    tes3mp.StartTimer(tickTimerId)
    log("Loaded: a world boss about every " .. bosses.hours .. " hours at " .. #hubs .. " places")
    for _, line in ipairs(bosses.Describe()) do
        log(line)
    end
end)

-- For tests and the other scripts.
bosses.State = function() return state end

return bosses
