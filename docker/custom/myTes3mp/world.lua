-- World housekeeping: the length of a day, and first-time world setup.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost.

local settings = require("custom/myTes3mp/settings")

local world = {}

-- ---- Length of a day -------------------------------------------------------
--
-- TES3MP_DAY_MINUTES is how many real minutes one in-game day lasts. The game
-- expresses that as a time scale: game seconds per real second, so a 24-hour
-- day in N minutes is a scale of 1440 / N. Stock TES3MP uses 30 by day and 40
-- by night (48 and 36 minutes per day); here day and night run at one speed.
-- 0 leaves whatever the world already has, e.g. from /settimescale.

local dayMinutes = tonumber(settings.dayMinutes) or 0

if dayMinutes > 0 then
    world.timeScale = 1440 / dayMinutes

    -- For a world that does not exist yet.
    config.defaultTimeTable.dayTimeScale = world.timeScale
    config.defaultTimeTable.nightTimeScale = world.timeScale

    -- For a world that does.
    customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
        local clock = WorldInstance.data.time
        if clock.dayTimeScale ~= world.timeScale or clock.nightTimeScale ~= world.timeScale then
            clock.dayTimeScale = world.timeScale
            clock.nightTimeScale = world.timeScale
            WorldInstance:QuicksaveToDrive()
        end
        WorldInstance:UpdateFrametimeMultiplier()
        tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp world] One in-game day lasts " ..
            dayMinutes .. " real minutes (time scale " .. world.timeScale .. ")")
    end)
end

-- ---- First-time world setup --------------------------------------------------
--
-- A new game runs "startup scripts" that hide people and objects which only
-- appear later in quests. On a TES3MP server they have to run on a player's
-- game client, once per world, and stock CoreScripts waits for an admin to
-- type /runstartup - but a fresh server has no admin yet. So do it through
-- the first player who logs in, with the same commands /runstartup uses.
--
-- It happens a little after login rather than during it: the client is still
-- loading then, and a player who drops out straight away must not leave the
-- world marked as set up when it is not.

world.startupDelaySeconds = 20

-- Replaces the stock notice telling players to find an admin.
config.startupScriptsInstructions = color.Yellow .. "Setting up the world for its first use...\n"

local startupPending = false

local function scheduleStartup(pid)
    startupPending = true
    local timerId = tes3mp.CreateTimerEx("MyTes3mpWorldStartup", time.seconds(world.startupDelaySeconds),
        "is", pid, Players[pid].accountName)
    tes3mp.StartTimer(timerId)
end

function MyTes3mpWorldStartup(pid, accountName)
    startupPending = false

    if WorldInstance.coreVariables.hasRunStartupScripts == true then
        return
    end
    local player = Players[pid]
    if player == nil or not player:IsLoggedIn() or player.accountName ~= accountName then
        -- Gone again. Somebody else may have logged in while this was
        -- pending; if so, do it through them, otherwise the next login will.
        for otherPid, other in pairs(Players) do
            if other ~= nil and other:IsLoggedIn() then
                scheduleStartup(otherPid)
                break
            end
        end
        return
    end

    for _, scriptName in pairs(config.worldStartupScripts) do
        logicHandler.RunConsoleCommandOnPlayer(pid, "startscript " .. scriptName, false)
    end
    WorldInstance.coreVariables.hasRunStartupScripts = true
    WorldInstance:QuicksaveToDrive()

    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp world] Ran the world startup scripts through " ..
        accountName)
end

customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
    if WorldInstance.coreVariables.hasRunStartupScripts == true or startupPending then
        return
    end
    if Players[pid] == nil or not Players[pid]:IsLoggedIn() then
        return
    end

    scheduleStartup(pid)
end)

return world
