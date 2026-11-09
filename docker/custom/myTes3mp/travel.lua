-- Fast travel between the places you have discovered, and to your friends.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Switch it off with TES3MP_TRAVEL=false.
--
-- Why. Morrowind is big, and with two players who do not always want to be in
-- the same place the walking adds up. The Elder Scrolls Online solves it with
-- wayshrines: find one once, and you can come back to it for good. Here every
-- silt strider port, harbour and Mages Guild hall the game has (travelPoints.lua,
-- generated from the game's own travel services) is a wayshrine.
--
--   * Discovering. Coming to a travel point - arriving by strider or boat,
--     or simply walking through that part of town - discovers it. Outdoors
--     "at a travel point" means in its cell or one of the eight around it, so
--     that you need not find the exact pier. You are told, and it is kept
--     with your character for good.
--   * /travel opens a list of the points you have discovered; pick one and you
--     are there. It is free when you are at a travel point already (the way
--     a wayshrine works), and otherwise costs gold: 10 for
--     every level you have, at least 25. If you cannot pay, you are told what
--     it costs and nothing else happens.
--   * /goto <player> takes you to another player who is online, for free, at
--     most once a minute. Handy for the brother who has wandered off. Going
--     to a brother who has gone down (see downed.lua) is a rescue: that works
--     even in the middle of a fight and regardless of the minute.
--   * /party lists who is online, their level and health, and where they are.
--
-- None of it works in a fight, while dead or downed, or in character creation:
-- travelling is not an escape, and a player who has not made his character yet
-- has nowhere to come from. Fighting is the same notion combat.lua gives
-- the other scripts; downed.lua provides "downed" when it is loaded.
--
-- How it works around the engine.
--
--   * Teleporting is what CoreScripts' own /tp does: tell the player's client
--     the new cell (SetCell, SendCell), then the position (SetPos, SetRot,
--     SendPos). For /goto the stock logicHandler.TeleportToPlayer is used as
--     it is. The client answers with an ordinary cell change, which is also
--     where discovery happens.
--   * The list is a TES3MP list box. The client answers with the number of
--     the line picked, counted from 0 (or a huge number when nothing was
--     picked), in OnGUIAction. The server remembers which points the list
--     showed, and checks everything again when the answer comes: the list
--     may have been open for a while.
--   * Level, health and location are read from what the client keeps telling
--     the server: the level when it changes, health whenever it moves by a
--     couple of points, the cell whenever it changes.
--   * Gold is the item "gold_001" in the player's inventory. It is taken out
--     of the saved inventory and the client is told to remove the same.

local settings = require("custom/myTes3mp/settings")
local points = require("custom/myTes3mp/travelPoints")

local travel = {}

-- Identifier of the list box. Other scripts use other numbers.
travel.PICK_ID = 7340201

-- Gold per level, and the least a trip costs.
travel.goldPerLevel = 10
travel.minimumGold = 25

-- Seconds between two /goto uses.
travel.gotoCooldownSeconds = 60

-- A list that has been open for longer than this is no longer honoured.
travel.pickSeconds = 600

travel.points = points

local GOLD_ID = "gold_001"
local NOTES_KEY = "myTes3mpTravel"

local enabled = settings.travel ~= false

-- pointsByCell[lower-case cell description] = point
local pointsByCell = {}
for _, point in ipairs(points) do
    pointsByCell[string.lower(point.cell)] = point
end

-- The travel point a cell belongs to: the one in that very cell, or else, for
-- an outdoor cell, one in a neighbouring cell. Indoors only the exact cell
-- counts.
local function pointAt(cellDescription)
    if type(cellDescription) ~= "string" then
        return nil
    end
    local name = string.lower(cellDescription)
    if pointsByCell[name] ~= nil then
        return pointsByCell[name]
    end
    local x, y = string.match(name, "^(-?%d+), (-?%d+)$")
    if x == nil then
        return nil
    end
    x, y = tonumber(x), tonumber(y)
    -- A fixed order, so that the same cell always belongs to the same point.
    for dx = -1, 1 do
        for dy = -1, 1 do
            local point = pointsByCell[(x + dx) .. ", " .. (y + dy)]
            if point ~= nil and point.exterior ~= false then
                return point
            end
        end
    end
    return nil
end

-- pending[pid] = { account = ..., at = os.time(), points = { point, ... } }
local pending = {}

-- lastGoto[lower-case account name] = os.time() of the last /goto
local lastGoto = {}

-- dead[pid] = true between OnPlayerDeath and OnPlayerResurrect
local dead = {}

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp travel] " .. message)
end

local function tell(pid, message)
    tes3mp.SendMessage(pid, color.Yellow .. "[travel] " .. color.White .. message .. "\n", false)
end

local function isOnline(pid)
    return Players[pid] ~= nil and Players[pid]:IsLoggedIn()
end

local function accountOf(pid)
    return string.lower(tostring(Players[pid].accountName))
end

local function cellOf(pid)
    local location = Players[pid].data.location
    if type(location) == "table" and type(location.cell) == "string" then
        return location.cell
    end
    return ""
end

-- A player who has logged in but not yet made his character: his cell is
-- empty or he has no race. The stock scripts create the account when
-- character creation ends.
travel.IsCreatingCharacter = function(pid)
    local data = Players[pid].data
    if cellOf(pid) == "" then
        return true
    end
    return type(data.character) == "table" and data.character.race == ""
end

local function isDowned(pid)
    return myTes3mpDowned ~= nil and type(myTes3mpDowned.IsDowned) == "function" and
        myTes3mpDowned.IsDowned(pid) == true
end

local function isDead(pid)
    if dead[pid] then
        return true
    end
    local health = tonumber((tes3mp.GetHealthCurrent(pid)))
    return health ~= nil and health <= 0
end

-- Why this player may not travel right now, or nil if he may.
travel.Refusal = function(pid)
    if travel.IsCreatingCharacter(pid) then
        return "Finish creating your character first."
    elseif isDowned(pid) then
        return "You cannot travel while downed."
    elseif isDead(pid) then
        return "You cannot travel while dead."
    elseif myTes3mpCombat ~= nil and myTes3mpCombat.InCombat(pid) then
        local wait = math.ceil((tonumber(myTes3mpCombat.quietSeconds) or 10) - myTes3mpCombat.SecondsQuiet(pid))
        return "You cannot travel while in combat. Try again in " .. math.max(1, wait) .. " seconds."
    end
    return nil
end

travel.Level = function(pid)
    local level = tonumber((tes3mp.GetLevel(pid)))
    if level == nil or level < 1 then
        level = tonumber(Players[pid].data.stats and Players[pid].data.stats.level) or 1
    end
    return math.floor(level)
end

travel.Cost = function(pid)
    return math.max(travel.minimumGold, travel.goldPerLevel * travel.Level(pid))
end

-- Is the player at a travel point?
travel.IsAtPoint = function(pid)
    return pointAt(cellOf(pid)) ~= nil
end

------------------------------------------------------------------ gold

local function inventoryOf(pid)
    local inventory = Players[pid].data.inventory
    if type(inventory) ~= "table" then
        inventory = {}
        Players[pid].data.inventory = inventory
    end
    return inventory
end

travel.GoldOf = function(pid)
    local total = 0
    for _, item in pairs(inventoryOf(pid)) do
        if type(item) == "table" and type(item.refId) == "string" and string.lower(item.refId) == GOLD_ID then
            total = total + (tonumber(item.count) or 0)
        end
    end
    return total
end

-- Take gold out of the saved inventory and tell the client to do the same.
local function takeGold(pid, amount)
    local inventory = inventoryOf(pid)
    local removed = {}
    local remaining = amount
    for index, item in pairs(inventory) do
        if remaining > 0 and type(item) == "table" and type(item.refId) == "string" and
            string.lower(item.refId) == GOLD_ID then
            local take = math.min(remaining, tonumber(item.count) or 0)
            if take > 0 then
                table.insert(removed, { refId = item.refId, count = take, charge = item.charge or -1,
                    enchantmentCharge = item.enchantmentCharge or -1, soul = item.soul or "" })
                item.count = item.count - take
                if item.count < 1 then
                    inventory[index] = nil
                end
                remaining = remaining - take
            end
        end
    end
    tableHelper.cleanNils(inventory)
    Players[pid]:LoadItemChanges(removed, enumerations.inventory.REMOVE)
    Players[pid]:QuicksaveToDrive()
end

------------------------------------------------------------------ discovery

local function notes(pid)
    local variables = Players[pid].data.customVariables
    if type(variables) ~= "table" then
        variables = {}
        Players[pid].data.customVariables = variables
    end
    local mine = variables[NOTES_KEY]
    if type(mine) ~= "table" then
        mine = {}
        variables[NOTES_KEY] = mine
    end
    if type(mine.found) ~= "table" then
        mine.found = {}
    end
    return mine
end

travel.HasFound = function(pid, point)
    return notes(pid).found[string.lower(point.cell)] == true
end

-- The points this player has discovered, in the order of travelPoints.lua.
travel.Found = function(pid)
    local list = {}
    for _, point in ipairs(points) do
        if travel.HasFound(pid, point) then
            table.insert(list, point)
        end
    end
    return list
end

-- Discover the point the player is at, if there is one.
travel.Discover = function(pid)
    if not isOnline(pid) or travel.IsCreatingCharacter(pid) then
        return nil
    end
    local point = pointAt(cellOf(pid))
    if point == nil or travel.HasFound(pid, point) then
        return nil
    end
    notes(pid).found[string.lower(point.cell)] = true
    Players[pid]:QuicksaveToDrive()
    tell(pid, "You have discovered " .. point.name .. ". Use /travel to come back to it.")
    log(Players[pid].accountName .. " discovered " .. point.name)
    return point
end

------------------------------------------------------------------ /travel

local function teleportTo(pid, point)
    tes3mp.SetCell(pid, point.cell)
    tes3mp.SetPos(pid, point.pos[1], point.pos[2], point.pos[3])
    tes3mp.SetRot(pid, point.rot[1], point.rot[3])
    tes3mp.SendCell(pid)
    tes3mp.SendPos(pid)
end

travel.OpenList = function(pid, cmd)
    local reason = travel.Refusal(pid)
    if reason ~= nil then
        tell(pid, reason)
        return
    end

    -- Standing in a travel point's cell counts as discovering it.
    travel.Discover(pid)

    local found = travel.Found(pid)
    if #found == 0 then
        tell(pid, "You have not discovered any travel points yet. Visit a town, a port or a Mages Guild" ..
            " - by foot, silt strider or boat - and it will be added to the list.")
        return
    end

    local here = pointAt(cellOf(pid))
    local lines = {}
    for _, point in ipairs(found) do
        local line = point.name
        if point == here then
            line = line .. " (you are here)"
        end
        table.insert(lines, line)
    end

    pending[pid] = { account = accountOf(pid), at = os.time(), points = found }

    local price
    if here ~= nil then
        price = "Travelling from here is free."
    else
        price = "Travelling from here costs " .. travel.Cost(pid) .. " gold."
    end
    tes3mp.ListBox(pid, travel.PICK_ID, "Travel to where? (" .. #found .. " of " .. #points ..
        " discovered)\n" .. price, table.concat(lines, "\n"))
end

-- The player picked line `index` (counted from 0) of the list he was shown.
travel.Choose = function(pid, index)
    local shown = pending[pid]
    pending[pid] = nil
    if shown == nil or shown.account ~= accountOf(pid) or os.time() - shown.at > travel.pickSeconds then
        return false
    end
    local point = shown.points[index + 1]
    if point == nil then
        return false
    end

    local reason = travel.Refusal(pid)
    if reason ~= nil then
        tell(pid, reason)
        return false
    end
    if string.lower(cellOf(pid)) == string.lower(point.cell) then
        tell(pid, "You are already in " .. point.name .. ".")
        return false
    end

    local cost = 0
    if not travel.IsAtPoint(pid) then
        cost = travel.Cost(pid)
        local gold = travel.GoldOf(pid)
        if gold < cost then
            tell(pid, "Travelling from here costs " .. cost .. " gold and you have " .. gold ..
                ". It is free from any town, port or Mages Guild you have discovered.")
            return false
        end
    end

    teleportTo(pid, point)
    if cost > 0 then
        takeGold(pid, cost)
        tell(pid, "You travel to " .. point.name .. " for " .. cost .. " gold.")
    else
        tell(pid, "You travel to " .. point.name .. ".")
    end
    log(Players[pid].accountName .. " travelled to " .. point.name .. " for " .. cost .. " gold")
    return true
end

------------------------------------------------------------------ /goto

local function findPlayer(text)
    local number = tonumber(text)
    if number ~= nil then
        return isOnline(number) and number or nil
    end
    local wanted = string.lower(text)
    for pid, player in pairs(Players) do
        if player ~= nil and player:IsLoggedIn() and
            (string.lower(tostring(player.name)) == wanted or string.lower(tostring(player.accountName)) == wanted) then
            return pid
        end
    end
    return nil
end

local function otherNames(pid)
    local names = {}
    for otherPid, player in pairs(Players) do
        if otherPid ~= pid and player ~= nil and player:IsLoggedIn() then
            table.insert(names, tostring(player.name))
        end
    end
    table.sort(names)
    return names
end

travel.Goto = function(pid, cmd)
    local text = tableHelper.concatenateFromIndex(cmd, 2)

    -- Going to a brother who is down is a rescue: it is allowed in the middle
    -- of a fight and does not wait for the cooldown. Everything else about
    -- the traveller still has to be in order (alive, not down himself).
    local rescue = false
    if text ~= nil and text ~= "" then
        local rescuedPid = findPlayer(text)
        rescue = rescuedPid ~= nil and rescuedPid ~= pid and isDowned(rescuedPid)
    end

    local reason = travel.Refusal(pid)
    if reason ~= nil and not (rescue and not isDowned(pid) and not isDead(pid) and
        not travel.IsCreatingCharacter(pid)) then
        tell(pid, reason)
        return
    end

    if text == nil or text == "" then
        local names = otherNames(pid)
        if #names == 0 then
            tell(pid, "Nobody else is online.")
        else
            tell(pid, "Use /goto <player name>. Online: " .. table.concat(names, ", ") .. ".")
        end
        return
    end

    local targetPid = findPlayer(text)
    if targetPid == nil then
        tell(pid, "There is no player called " .. text .. " online.")
        return
    elseif targetPid == pid then
        tell(pid, "You are already with yourself.")
        return
    elseif travel.IsCreatingCharacter(targetPid) then
        tell(pid, Players[targetPid].name .. " is still creating a character.")
        return
    end

    local account = accountOf(pid)
    local waited = os.time() - (lastGoto[account] or -math.huge)
    if waited < travel.gotoCooldownSeconds and not rescue then
        tell(pid, "You can use /goto again in " .. math.ceil(travel.gotoCooldownSeconds - waited) .. " seconds.")
        return
    end

    logicHandler.TeleportToPlayer(pid, pid, targetPid)
    lastGoto[account] = os.time()
    log(Players[pid].accountName .. " went to " .. Players[targetPid].accountName .. " in " .. cellOf(targetPid))
end

------------------------------------------------------------------ /party

local function healthPercent(pid)
    local current = tonumber((tes3mp.GetHealthCurrent(pid)))
    local base = tonumber((tes3mp.GetHealthBase(pid)))
    if current == nil or base == nil or base <= 0 then
        local stats = Players[pid].data.stats or {}
        current = tonumber(stats.healthCurrent)
        base = tonumber(stats.healthBase)
    end
    if current == nil or base == nil or base <= 0 then
        return nil
    end
    return math.max(0, math.floor(current / base * 100 + 0.5))
end

local function describeCell(pid)
    local cell = cellOf(pid)
    local point = pointAt(cell)
    if point ~= nil then
        return point.name .. " (" .. cell .. ")"
    end
    local region = Players[pid].data.location.regionName
    if string.match(cell, "^%-?%d+, %-?%d+$") and type(region) == "string" and region ~= "" then
        return region .. " (" .. cell .. ")"
    end
    return cell
end

travel.Party = function(pid, cmd)
    local rows = {}
    for otherPid, player in pairs(Players) do
        if player ~= nil and player:IsLoggedIn() then
            local text
            if travel.IsCreatingCharacter(otherPid) then
                text = "creating a character"
            else
                local health = healthPercent(otherPid)
                local state = ""
                if isDead(otherPid) then
                    state = ", dead"
                elseif isDowned(otherPid) then
                    state = ", downed"
                end
                text = "level " .. travel.Level(otherPid) .. ", health " ..
                    (health ~= nil and (health .. "%") or "unknown") .. state .. ", " .. describeCell(otherPid)
            end
            local name = tostring(player.name)
            if otherPid == pid then
                name = name .. " (you)"
            end
            table.insert(rows, { sort = string.lower(tostring(player.name)), text = name .. ": " .. text })
        end
    end
    table.sort(rows, function(a, b) return a.sort < b.sort end)

    local lines = { "Online (" .. #rows .. "):" }
    for _, row in ipairs(rows) do
        table.insert(lines, row.text)
    end
    tell(pid, table.concat(lines, "\n"))
end

------------------------------------------------------------------ wiring

if enabled then
    customCommandHooks.registerCommand("travel", function(pid, cmd)
        if isOnline(pid) then
            local ok, problem = pcall(travel.OpenList, pid, cmd)
            if not ok then
                tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp travel] /travel failed: " .. tostring(problem))
            end
        end
    end)

    customCommandHooks.registerCommand("goto", function(pid, cmd)
        if isOnline(pid) then
            local ok, problem = pcall(travel.Goto, pid, cmd)
            if not ok then
                tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp travel] /goto failed: " .. tostring(problem))
            end
        end
    end)

    customCommandHooks.registerCommand("party", function(pid, cmd)
        if isOnline(pid) then
            local ok, problem = pcall(travel.Party, pid, cmd)
            if not ok then
                tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp travel] /party failed: " .. tostring(problem))
            end
        end
    end)

    customEventHooks.registerHandler("OnGUIAction", function(eventStatus, pid, idGui, data)
        if tonumber(idGui) ~= travel.PICK_ID or not isOnline(pid) then
            return
        end
        -- Nothing picked: the client answers with the largest possible number.
        local index = tonumber(data)
        if index == nil or index < 0 or index >= 2 ^ 31 then
            pending[pid] = nil
            return
        end
        local ok, problem = pcall(travel.Choose, pid, math.floor(index))
        if not ok then
            tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp travel] Travelling failed: " .. tostring(problem))
        end
    end)

    -- The client reports the cell it is in whenever that changes, including
    -- after the server has moved it. By then SaveCell has put it into the
    -- player's data.
    customEventHooks.registerHandler("OnPlayerCellChange", function(eventStatus, pid)
        if eventStatus ~= nil and eventStatus.validDefaultHandler == false then
            return
        end
        local ok, problem = pcall(travel.Discover, pid)
        if not ok then
            tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp travel] Discovery failed: " .. tostring(problem))
        end
    end)

    -- Somebody who logs in standing at a travel point has discovered it.
    customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
        local ok, problem = pcall(travel.Discover, pid)
        if not ok then
            tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp travel] Discovery failed: " .. tostring(problem))
        end
    end)

    customEventHooks.registerHandler("OnPlayerDeath", function(eventStatus, pid)
        dead[pid] = true
    end)

    customEventHooks.registerHandler("OnPlayerResurrect", function(eventStatus, pid)
        dead[pid] = nil
    end)

    customEventHooks.registerHandler("OnPlayerDisconnect", function(eventStatus, pid)
        dead[pid] = nil
        pending[pid] = nil
    end)

    customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
        log("Loaded: " .. #points .. " travel points; /travel, /goto and /party are available")
    end)
else
    customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
        log("Travel is switched off")
    end)
end

-- For the other my-tes3mp scripts.
myTes3mpTravel = travel

return travel
