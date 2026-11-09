-- Who is in a fight right now.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. It has no switch of its own; it is
-- loaded for the features that need it (regeneration, travel, being downed).
--
-- The server is not told when combat starts or ends, so "in combat" is worked
-- out from the two things it can see:
--
--   * a player's health going down - read once a second from the numbers his
--     client keeps reporting to the server;
--   * a player hitting something, or being hit - the game reports every blow.
--
-- A player counts as in combat until `quietSeconds` have gone by without
-- either. Falling, drowning and poison count too; that is deliberate - none
-- of them is a moment to be handed free health or a teleport.
--
-- For the other my-tes3mp scripts:
--
--   myTes3mpCombat.InCombat(pid)          true while the player is fighting
--   myTes3mpCombat.SecondsQuiet(pid)      seconds since he last fought
--   myTes3mpCombat.listeners              functions called as fn(pid) at the
--                                         moment a player enters combat
--   myTes3mpCombat.SecondsSinceFight(pid) seconds since he last struck or took
--                                         a blow, whatever has happened since
--   myTes3mpCombat.Calm(pid)              put him out of combat and forget his
--                                         last health reading - for a script
--                                         that has just changed his health
--                                         itself

local combat = {}

-- Seconds without taking or dealing damage before a player is out of combat.
combat.quietSeconds = 10

-- How often health is read, in seconds.
combat.checkSeconds = 1

combat.listeners = {}

-- lastFight[pid]  = os.time() of the last blow
-- lastHealth[pid] = his health at the last look
-- calmed[pid]     = true from Calm() until his next blow
local lastFight = {}
local lastHealth = {}
local calmed = {}

local function isOnline(pid)
    return Players[pid] ~= nil and Players[pid]:IsLoggedIn()
end

-- Seconds since the player's last blow, struck or taken - a plain record of
-- what happened, for "did he take part in that fight".
combat.SecondsSinceFight = function(pid)
    if lastFight[pid] == nil then
        return math.huge
    end
    return os.time() - lastFight[pid]
end

-- Seconds the player has been out of the fight, for "may he rest now". The
-- same thing, except that a player who has been calmed counts as having been
-- quiet for ever.
combat.SecondsQuiet = function(pid)
    if calmed[pid] then
        return math.huge
    end
    return combat.SecondsSinceFight(pid)
end

combat.InCombat = function(pid)
    return combat.SecondsQuiet(pid) < combat.quietSeconds
end

-- Note that this player has just fought.
combat.Mark = function(pid)
    local wasFighting = combat.InCombat(pid)
    lastFight[pid] = os.time()
    calmed[pid] = nil
    if not wasFighting then
        for _, listener in ipairs(combat.listeners) do
            local ok, problem = pcall(listener, pid)
            if not ok then
                tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp combat] A listener failed: " .. tostring(problem))
            end
        end
    end
end

-- Put a player out of combat and forget his last health reading, so that a
-- drop in health the server itself has just caused is not taken for a blow.
combat.Calm = function(pid)
    calmed[pid] = true
    lastHealth[pid] = nil
end

-- Compare every player's health with what it was at the last look.
combat.Check = function()
    for pid, _ in pairs(Players) do
        if isOnline(pid) then
            local health = tonumber(tes3mp.GetHealthCurrent(pid)) or 0
            local before = lastHealth[pid]
            lastHealth[pid] = health
            -- More than a rounding wobble, and not the jump down to nothing
            -- that a logout or a reload can look like.
            if before ~= nil and health < before - 0.5 and health >= 0 then
                combat.Mark(pid)
            end
        end
    end
end

-- A blow was struck: by the player who sent the report, and perhaps against
-- other players.
customEventHooks.registerHandler("OnObjectHit", function(eventStatus, pid, cellDescription, objects, targetPlayers)
    if isOnline(pid) then
        combat.Mark(pid)
    end
    if type(targetPlayers) == "table" then
        for targetPid, _ in pairs(targetPlayers) do
            if type(targetPid) == "number" and isOnline(targetPid) then
                combat.Mark(targetPid)
            end
        end
    end
end)

customEventHooks.registerHandler("OnPlayerDisconnect", function(eventStatus, pid)
    lastFight[pid] = nil
    lastHealth[pid] = nil
    calmed[pid] = nil
end)

local checkTimerId

function MyTes3mpCombatTick()
    local ok, problem = pcall(combat.Check)
    if not ok then
        tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp combat] Check failed: " .. tostring(problem))
    end
    tes3mp.RestartTimer(checkTimerId, time.seconds(combat.checkSeconds))
end

customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
    checkTimerId = tes3mp.CreateTimer("MyTes3mpCombatTick", time.seconds(combat.checkSeconds))
    tes3mp.StartTimer(checkTimerId)
end)

-- For the other my-tes3mp scripts.
myTes3mpCombat = combat

return combat
