-- Downed instead of dead, when somebody is there to help.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Configure it with
-- TES3MP_DOWNED_SECONDS (default 60); 0 switches it off.
--
-- When a player dies and another player is online and able to help, he is
-- "downed" instead. His body stays where he fell and the others are told
-- where it is. Within the configured time:
--
--   * if another player activates the body (the usual "use" key, aiming at
--     it), the player gets up on the spot, with a quarter of his health and
--     no penalty at all;
--   * if nobody comes in time, or he types /giveup, or the last player who
--     could have helped dies or leaves, the ordinary death happens exactly as
--     the stock scripts do it: the death message, then respawn at a shrine or
--     temple with the jail penalty. The penalty stays; this only adds a
--     chance to avoid it.
--
-- With nobody else online (or nobody else alive and standing), there is no
-- downed state: the stock death happens at once.
--
-- How it works around the engine.
--
--   * The stock death is two steps in CoreScripts: eventHandler.OnPlayerDeath
--     calls Players[pid]:ProcessDeath(), which announces the death and starts
--     a timer, and when that expires Players[pid]:Resurrect() respawns and
--     jails the player. A validator on OnPlayerDeath stops the first step
--     (the event's default handling) while the player is downed, and when his
--     time is up this script calls Players[pid]:ProcessDeath() itself. From
--     there on it is the stock code, untouched.
--   * Another player activating a body reaches the server as OnObjectActivate:
--     the activating player is the event's pid, and the activated player
--     turns up as a key of the targetPlayers table. The game client sends
--     this for other players' bodies as for anything else; it does nothing on
--     its own for them, so the server decides.
--   * To get up in place the server sends a resurrection of the "regular"
--     type, which the client does where it stands (the shrine and temple types
--     teleport). The client then has full health, so a moment later, once the
--     server has heard that the player is alive, his health is set to a
--     quarter of his maximum.
--   * Logging out while downed must not be a way to dodge the penalty. The
--     account is written down as owing a death (data/custom/myTes3mpDowned.json)
--     until a stock respawn has happened or somebody has helped him up. A
--     player who comes back owing one normally dies again at once, because he
--     was saved with no health; if he somehow comes back standing, the server
--     takes his health away a few seconds after he logs in. Either way that
--     death takes the stock path, with no second chance.
--
-- For the other my-tes3mp scripts: myTes3mpDowned.IsDowned(pid).
--
-- Not checked here: how far the helper stands from the body. The game itself
-- only lets a player activate things within arm's reach.

local settings = require("custom/myTes3mp/settings")

local downed = {}

-- Seconds a player lies there. A missing setting means the default.
downed.seconds = tonumber(settings.downedSeconds)
if downed.seconds == nil then
    downed.seconds = 60
end
downed.enabled = downed.seconds > 0

-- How much of his maximum health a helped player gets up with.
downed.reviveHealth = 0.25

-- Seconds left at which the downed player is reminded.
downed.reminders = { 30, 10 }

-- Saved as data/custom/myTes3mpDowned.json:
--   owed[account] = true while that account owes the stock death
local STATE_FILE = "custom/myTes3mpDowned.json"
local state = { owed = {} }

-- In memory only:
--   lying[pid]   = { account, name, since, cell, told = { [seconds] = true } }
--   healAt[pid]  = { due = os.time(), expires = os.time() } for the health
--                  to set once a helped player is known to be alive
--   debtAt[pid]  = os.time() at which a player who logged in owing a death
--                  is made to pay it, if he has not died by himself by then
local lying = {}
local healAt = {}
local debtAt = {}

-- Seconds after logging in before an owed death is collected: long enough
-- for the player's game to have loaded.
downed.debtSeconds = 8

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp downed] " .. message)
end

local function saveState()
    jsonInterface.quicksave(STATE_FILE, state)
end

local function loadState()
    local loaded = jsonInterface.load(STATE_FILE)
    if type(loaded) == "table" and type(loaded.owed) == "table" then
        for account, owes in pairs(loaded.owed) do
            if type(account) == "string" and owes == true then
                state.owed[account] = true
            end
        end
    end
end

local function tell(pid, message)
    tes3mp.SendMessage(pid, color.Yellow .. "[downed] " .. color.White .. message .. "\n", false)
end

local function isOnline(pid)
    return Players[pid] ~= nil and Players[pid]:IsLoggedIn()
end

local function accountOf(pid)
    return string.lower(tostring(Players[pid].accountName))
end

local function nameOf(pid)
    return logicHandler.GetChatName(pid)
end

local function cellOf(pid)
    local cell = tes3mp.GetCell(pid)
    if type(cell) ~= "string" or cell == "" then
        cell = Players[pid].data.location ~= nil and Players[pid].data.location.cell or nil
    end
    return cell or "an unknown place"
end

downed.IsDowned = function(pid)
    return lying[pid] ~= nil
end

-- Is there somebody who could help this player: online, standing, and not
-- lying down himself?
local function hasHelper(pid)
    for otherPid, _ in pairs(Players) do
        if otherPid ~= pid and isOnline(otherPid) and lying[otherPid] == nil and
            (tonumber(tes3mp.GetHealthCurrent(otherPid)) or 1) > 0 then
            return true
        end
    end
    return false
end

local function setOwed(pid, owes)
    local account = accountOf(pid)
    if (state.owed[account] == true) ~= owes then
        state.owed[account] = owes or nil
        saveState()
    end
end

local function goDown(pid)
    local name = nameOf(pid)
    local cell = cellOf(pid)
    lying[pid] = { account = accountOf(pid), name = name, since = os.time(), cell = cell, told = {} }
    setOwed(pid, true)

    tell(pid, "You are down. If another player activates your body within " .. downed.seconds ..
        " seconds, you get up with no penalty. Type /giveup to respawn now, with the usual penalty.")
    for otherPid, _ in pairs(Players) do
        if otherPid ~= pid and isOnline(otherPid) then
            tell(otherPid, name .. " is down in " .. cell .. "! Activate the body within " .. downed.seconds ..
                " seconds to help him up.")
        end
    end
    log(name .. " is down in " .. cell)
end

-- The stock death, from here on.
local function giveUp(pid, why)
    lying[pid] = nil
    healAt[pid] = nil
    if not isOnline(pid) then
        return
    end
    if why == "command" then
        tell(pid, "You give up.")
    elseif why == "nobody" then
        tell(pid, "There is nobody left who could help you.")
    else
        tell(pid, "Nobody came in time.")
    end
    log(nameOf(pid) .. " dies after all (" .. why .. ")")
    local ok, problem = pcall(function()
        Players[pid]:ProcessDeath()
    end)
    if not ok then
        tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp downed] ProcessDeath failed: " .. tostring(problem))
    end
end

downed.GiveUp = giveUp

local function revive(pid, helperPid)
    local name = nameOf(pid)
    lying[pid] = nil
    setOwed(pid, false)
    tes3mp.Resurrect(pid, enumerations.resurrect.REGULAR)
    healAt[pid] = { due = os.time() + 2, expires = os.time() + 20 }
    tell(pid, nameOf(helperPid) .. " helps you up.")
    tell(helperPid, "You help " .. name .. " up.")
    log(nameOf(helperPid) .. " helped " .. name .. " up")
end

downed.Revive = revive

-- The player has just been told he is alive: now the health.
local function applyReviveHealth(pid)
    local current = tonumber(tes3mp.GetHealthCurrent(pid)) or 0
    if current <= 0 then
        return false -- the server has not heard yet
    end
    local target = math.max(1, math.floor((tonumber(tes3mp.GetHealthBase(pid)) or 0) * downed.reviveHealth))
    if current > target then
        tes3mp.SetHealthCurrent(pid, target)
        -- Getting up with a quarter of one's health is not being hit.
        if myTes3mpCombat ~= nil then
            myTes3mpCombat.Calm(pid)
        end
        tes3mp.SendStatsDynamic(pid)
    end
    return true
end

downed.Check = function()
    local now = os.time()

    -- Deaths owed by players who left while they were down.
    for pid, due in pairs(debtAt) do
        if not isOnline(pid) or state.owed[accountOf(pid)] ~= true then
            debtAt[pid] = nil
        elseif now >= due then
            debtAt[pid] = nil
            if (tonumber(tes3mp.GetHealthCurrent(pid)) or 0) > 0 then
                tell(pid, "You left while you were down. That death is still owed.")
                tes3mp.SetHealthCurrent(pid, 0)
                tes3mp.SendStatsDynamic(pid)
            end
        end
    end
    local pids = {}
    for pid, _ in pairs(lying) do
        table.insert(pids, pid)
    end
    for _, pid in ipairs(pids) do
        local d = lying[pid]
        if not isOnline(pid) or accountOf(pid) ~= d.account then
            lying[pid] = nil
        elseif not hasHelper(pid) then
            giveUp(pid, "nobody")
        else
            local remaining = d.since + downed.seconds - now
            if remaining <= 0 then
                giveUp(pid, "time")
            else
                for _, left in ipairs(downed.reminders) do
                    if left < downed.seconds and remaining <= left and not d.told[left] then
                        d.told[left] = true
                        tell(pid, remaining .. " seconds left. Type /giveup to respawn now.")
                    end
                end
            end
        end
    end

    pids = {}
    for pid, _ in pairs(healAt) do
        table.insert(pids, pid)
    end
    for _, pid in ipairs(pids) do
        local pending = healAt[pid]
        if not isOnline(pid) or now >= pending.expires then
            healAt[pid] = nil
        elseif now >= pending.due and applyReviveHealth(pid) then
            healAt[pid] = nil
        end
    end
end

if downed.enabled then
    -- Take over the death. The default handling (ProcessDeath) is stopped while
    -- the player is downed; the other handlers still run.
    customEventHooks.registerValidator("OnPlayerDeath", function(eventStatus, pid)
        if eventStatus ~= nil and eventStatus.validDefaultHandler == false then
            return
        end
        if not isOnline(pid) then
            return
        end
        if lying[pid] ~= nil then
            return customEventHooks.makeEventStatus(false, nil) -- reported twice
        end
        if state.owed[accountOf(pid)] == true then
            return -- he left while downed: no second chance, stock death
        end
        if not hasHelper(pid) then
            return -- alone: stock death
        end
        goDown(pid)
        return customEventHooks.makeEventStatus(false, nil)
    end)

    -- Somebody activated something: perhaps a body.
    customEventHooks.registerHandler("OnObjectActivate", function(eventStatus, pid, cellDescription, objects, targetPlayers)
        if eventStatus ~= nil and eventStatus.validDefaultHandler == false then
            return
        end
        if type(targetPlayers) ~= "table" or not isOnline(pid) or lying[pid] ~= nil then
            return
        end
        if (tonumber(tes3mp.GetHealthCurrent(pid)) or 1) <= 0 then
            return
        end
        for targetPid, _ in pairs(targetPlayers) do
            if type(targetPid) == "number" and targetPid ~= pid and lying[targetPid] ~= nil and isOnline(targetPid) then
                revive(targetPid, pid)
            end
        end
    end)

    -- A respawn has happened the stock way: the death is paid for.
    customEventHooks.registerHandler("OnPlayerResurrect", function(eventStatus, pid)
        if isOnline(pid) and lying[pid] == nil then
            setOwed(pid, false)
        end
    end)

    -- Gone while downed: the account keeps owing the death (see the header).
    customEventHooks.registerHandler("OnPlayerDisconnect", function(eventStatus, pid)
        lying[pid] = nil
        healAt[pid] = nil
        debtAt[pid] = nil
    end)

    -- Back again, still owing it.
    customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
        if isOnline(pid) and state.owed[accountOf(pid)] == true then
            debtAt[pid] = os.time() + downed.debtSeconds
        end
    end)

    customCommandHooks.registerCommand("giveup", function(pid, cmd)
        if lying[pid] == nil then
            tell(pid, "You are not down.")
        else
            giveUp(pid, "command")
        end
    end)

    local checkTimerId

    function MyTes3mpDownedTick()
        local ok, problem = pcall(downed.Check)
        if not ok then
            tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp downed] Check failed: " .. tostring(problem))
        end
        tes3mp.RestartTimer(checkTimerId, time.seconds(1))
    end

    customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
        loadState()
        checkTimerId = tes3mp.CreateTimer("MyTes3mpDownedTick", time.seconds(1))
        tes3mp.StartTimer(checkTimerId)
        log("A fallen player has " .. downed.seconds .. " seconds to be helped up")
    end)

    -- For the other my-tes3mp scripts.
    myTes3mpDowned = downed
end

return downed
