-- Artifacts and unique items: one for each player, no farming.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Switch it off with
-- TES3MP_UNIQUE_CLAIMS=false.
--
-- The world is shared, so there is one Umbra and one Goldbrand. Cell resets
-- (resets.lua) bring them back - which lets a second player have his, but
-- would also let the first player collect another one every time. So:
--
--   * Each item in uniqueItems.lua can be taken from its original place once
--     per player. "Original place" is where the game put it: lying in the
--     world, in a container, or on whoever carries it. Taking it there
--     records a claim for that player.
--   * A player who has claimed an item cannot take a fresh copy again. The
--     copy stays where it is for somebody else.
--   * Copies that players handle themselves are never restricted: an item you
--     dropped, or put into a container, can be taken back by anyone, as often
--     as you like. You can hand yours to your brother.
--   * When an item is claimed and another player on this server has not had
--     his yet, the cell is scheduled for an early reset, so that he does not
--     have to wait hours for it to come back.
--
-- Items handed over by quests are not affected (quests cannot be repeated),
-- and neither is buying from a merchant's inventory: the server only learns
-- about a purchase after the fact. vendors.lua keeps a bought unique from
-- being restocked instead.
--
-- Known rough edges, all from the same cause - the game client does these
-- things before asking:
--   * Picking a claimed item up off the ground works for a moment; the item
--     is then taken out of the inventory again and is invisible to that
--     player until he next loads the cell. Buying a unique that lies on a
--     shop's shelf looks the same to the server and is undone the same way.
--   * Reaching for a claimed item in an owned container still counts as
--     attempted theft.

local settings = require("custom/myTes3mp/settings")
local uniqueItems = require("custom/myTes3mp/uniqueItems")

local uniques = {}

-- Real minutes until a cell resets after one of its unique items was claimed
-- and somebody else still needs it. 0 = leave it to the normal schedule.
uniques.respawnSeconds = (tonumber(settings.uniqueRespawnMinutes) or 0) * 60

-- Saved as data/custom/myTes3mpUniques.json:
--   claims[refId][account]              = true once that account took a fresh copy
--   deposits[cell][uniqueIndex][refId]  = how many copies players put into that container
--   accounts[account]                   = true for everybody who ever logged in
local STATE_FILE = "custom/myTes3mpUniques.json"
local state = { claims = {}, deposits = {}, accounts = {} }

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp uniques] " .. message)
end

local function saveState()
    jsonInterface.quicksave(STATE_FILE, state)
end

local function loadState()
    local loaded = jsonInterface.load(STATE_FILE)
    if type(loaded) ~= "table" then
        return
    end
    for _, section in ipairs({ "claims", "deposits", "accounts" }) do
        if type(loaded[section]) == "table" then
            for key, value in pairs(loaded[section]) do
                if type(key) == "string" then
                    state[section][key] = value
                end
            end
        end
    end
end

local function tell(pid, message)
    tes3mp.SendMessage(pid, color.Yellow .. "[uniques] " .. color.White .. message .. "\n", false)
end

local function accountOf(pid)
    return string.lower(Players[pid].accountName)
end

uniques.NameOf = function(refId)
    return uniqueItems[string.lower(refId)]
end

uniques.HasClaimed = function(account, refId)
    local claimed = state.claims[string.lower(refId)]
    return type(claimed) == "table" and claimed[account] == true
end

-- Does anybody who plays here still lack this item?
local function somebodyStillNeeds(refId)
    local claimed = state.claims[string.lower(refId)] or {}
    for account, _ in pairs(state.accounts) do
        if claimed[account] ~= true then
            return true
        end
    end
    return false
end

local function recordClaim(pid, cellDescription, refId)
    local id = string.lower(refId)
    local account = accountOf(pid)
    if type(state.claims[id]) ~= "table" then
        state.claims[id] = {}
    end
    state.claims[id][account] = true
    saveState()

    log(Players[pid].accountName .. " claimed " .. uniques.NameOf(refId) .. " (" .. id .. ") in " .. cellDescription)
    tell(pid, uniques.NameOf(refId) .. " is yours. You will not be able to take another from here.")

    if uniques.respawnSeconds > 0 and myTes3mpResets ~= nil and somebodyStillNeeds(refId) then
        myTes3mpResets.Hasten(cellDescription, uniques.respawnSeconds)
    end
end

local function depositCount(cellDescription, uniqueIndex, refId)
    local cell = state.deposits[cellDescription]
    local container = type(cell) == "table" and cell[uniqueIndex] or nil
    return type(container) == "table" and tonumber(container[string.lower(refId)]) or 0
end

local function changeDeposit(cellDescription, uniqueIndex, refId, change)
    local id = string.lower(refId)
    if type(state.deposits[cellDescription]) ~= "table" then
        state.deposits[cellDescription] = {}
    end
    local cell = state.deposits[cellDescription]
    if type(cell[uniqueIndex]) ~= "table" then
        cell[uniqueIndex] = {}
    end
    local count = math.max(0, (tonumber(cell[uniqueIndex][id]) or 0) + change)
    cell[uniqueIndex][id] = count > 0 and count or nil
    if next(cell[uniqueIndex]) == nil then
        cell[uniqueIndex] = nil
    end
    if next(cell) == nil then
        state.deposits[cellDescription] = nil
    end
end

-- The unique items named in the container packet that has just been received,
-- as a list of { uniqueIndex, refId, count }.
local function uniqueChangesInPacket()
    local changes = {}
    for objectIndex = 0, tes3mp.GetObjectListSize() - 1 do
        local uniqueIndex = tes3mp.GetObjectRefNum(objectIndex) .. "-" .. tes3mp.GetObjectMpNum(objectIndex)
        for itemIndex = 0, tes3mp.GetContainerChangesSize(objectIndex) - 1 do
            local refId = tes3mp.GetContainerItemRefId(objectIndex, itemIndex)
            if uniques.NameOf(refId) ~= nil then
                local count = tonumber(tes3mp.GetContainerItemActionCount(objectIndex, itemIndex)) or 0
                if count <= 0 then
                    count = math.abs(tonumber(tes3mp.GetContainerItemCount(objectIndex, itemIndex)) or 1)
                end
                table.insert(changes, { uniqueIndex = uniqueIndex, refId = refId, count = math.max(1, count) })
            end
        end
    end
    return changes
end

local function isTakingByHand(action, subAction)
    return action == enumerations.container.REMOVE and
        (subAction == enumerations.containerSub.DRAG or subAction == enumerations.containerSub.TAKE_ALL)
end

-- Before the server accepts a container change: refuse to hand a fresh copy
-- to somebody who has already had one. The client only moves the item once
-- the server agrees, so a refusal simply leaves it where it is.
customEventHooks.registerValidator("OnContainer", function(eventStatus, pid, cellDescription, objects)
    if Players[pid] == nil or not Players[pid]:IsLoggedIn() then
        return
    end
    if not isTakingByHand(tes3mp.GetObjectListAction(), tes3mp.GetObjectListContainerSubAction()) then
        return
    end

    local account = accountOf(pid)
    for _, change in ipairs(uniqueChangesInPacket()) do
        if depositCount(cellDescription, change.uniqueIndex, change.refId) <= 0 and
            uniques.HasClaimed(account, change.refId) then
            tell(pid, "You have already claimed " .. uniques.NameOf(change.refId) ..
                ". This one is left for someone else - take the other things one at a time.")
            return customEventHooks.makeEventStatus(false, false)
        end
    end
end)

-- After the server accepted a container change: keep the books.
customEventHooks.registerHandler("OnContainer", function(eventStatus, pid, cellDescription, objects)
    if eventStatus ~= nil and eventStatus.validDefaultHandler == false then
        return
    end
    if Players[pid] == nil or not Players[pid]:IsLoggedIn() then
        return
    end

    local action = tes3mp.GetObjectListAction()
    local subAction = tes3mp.GetObjectListContainerSubAction()
    if action ~= enumerations.container.ADD and action ~= enumerations.container.REMOVE then
        return
    end
    -- Only what players do: by hand, or by buying and selling. The answers a
    -- client gives to the server's own requests are not anybody's doing.
    if subAction == enumerations.containerSub.REPLY_TO_REQUEST or
        subAction == enumerations.containerSub.RESTOCK_RESULT then
        return
    end

    local changes = uniqueChangesInPacket()
    if #changes == 0 then
        return
    end

    for _, change in ipairs(changes) do
        if action == enumerations.container.ADD then
            changeDeposit(cellDescription, change.uniqueIndex, change.refId, change.count)
        elseif depositCount(cellDescription, change.uniqueIndex, change.refId) > 0 then
            -- A copy that a player had put there.
            changeDeposit(cellDescription, change.uniqueIndex, change.refId, -change.count)
        elseif isTakingByHand(action, subAction) and not uniques.HasClaimed(accountOf(pid), change.refId) then
            recordClaim(pid, cellDescription, change.refId)
        end
    end
    saveState()
end)

-- Picking a unique item up off the ground. Objects the game placed have a
-- unique index ending in "-0"; anything a player dropped does not, and is
-- nobody's business. A pick-up cannot be refused in advance - the client has
-- already done it - so a repeat is undone: the item stays in the world for
-- others and is taken out of the player's inventory again a moment later,
-- once the client's own report of the pick-up has arrived.
uniques.pendingStrips = {}

function MyTes3mpUniqueStrip(pid, accountName, refId)
    local player = Players[pid]
    if player == nil or not player:IsLoggedIn() or player.accountName ~= accountName then
        return
    end
    local item = { refId = refId, count = 1, charge = -1, enchantmentCharge = -1, soul = "" }
    if type(player.data.inventory) == "table" then
        inventoryHelper.removeClosestItem(player.data.inventory, refId, 1, -1, -1, "")
    end
    player:LoadItemChanges({ item }, enumerations.inventory.REMOVE)
    player:QuicksaveToDrive()
end

customEventHooks.registerValidator("OnObjectDelete", function(eventStatus, pid, cellDescription, objects)
    if Players[pid] == nil or not Players[pid]:IsLoggedIn() or type(objects) ~= "table" then
        return
    end
    local account = accountOf(pid)
    for uniqueIndex, object in pairs(objects) do
        if type(object) == "table" and type(object.refId) == "string" and uniques.NameOf(object.refId) ~= nil and
            string.sub(uniqueIndex, -2) == "-0" and uniques.HasClaimed(account, object.refId) then

            tell(pid, "You have already claimed " .. uniques.NameOf(object.refId) ..
                ". It stays here for someone else.")
            local timerId = tes3mp.CreateTimerEx("MyTes3mpUniqueStrip", time.seconds(2), "iss", pid,
                Players[pid].accountName, object.refId)
            tes3mp.StartTimer(timerId)
            return customEventHooks.makeEventStatus(false, false)
        end
    end
end)

customEventHooks.registerHandler("OnObjectDelete", function(eventStatus, pid, cellDescription, objects)
    if eventStatus ~= nil and eventStatus.validDefaultHandler == false then
        return
    end
    if Players[pid] == nil or not Players[pid]:IsLoggedIn() or type(objects) ~= "table" then
        return
    end
    for uniqueIndex, object in pairs(objects) do
        if type(object) == "table" and type(object.refId) == "string" and uniques.NameOf(object.refId) ~= nil and
            string.sub(uniqueIndex, -2) == "-0" and not uniques.HasClaimed(accountOf(pid), object.refId) then
            recordClaim(pid, cellDescription, object.refId)
        end
    end
end)

customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
    if Players[pid] == nil or not Players[pid]:IsLoggedIn() then
        return
    end
    local account = accountOf(pid)
    if state.accounts[account] ~= true then
        state.accounts[account] = true
        saveState()
    end
end)

-- /uniques: what you have claimed so far.
customCommandHooks.registerCommand("uniques", function(pid, cmd)
    local account = accountOf(pid)
    local names = {}
    for id, claimed in pairs(state.claims) do
        if type(claimed) == "table" and claimed[account] == true and uniqueItems[id] ~= nil then
            table.insert(names, uniqueItems[id])
        end
    end
    table.sort(names)
    if #names == 0 then
        tell(pid, "You have not claimed any artifacts or unique items yet.")
    else
        tell(pid, "You have claimed " .. #names .. ": " .. table.concat(names, ", ") .. ".")
    end
end)

customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
    loadState()

    -- A reset cell holds the game's own copies again: whatever players had
    -- put into its containers is gone, and so are the notes about it.
    if myTes3mpResets ~= nil then
        table.insert(myTes3mpResets.listeners, function(cellDescription)
            if state.deposits[cellDescription] ~= nil then
                state.deposits[cellDescription] = nil
                saveState()
            end
        end)
    end
    local count = 0
    for _, _ in pairs(uniqueItems) do
        count = count + 1
    end
    log("Loaded: " .. count .. " artifacts and unique items can be claimed once per player")
end)

return uniques
