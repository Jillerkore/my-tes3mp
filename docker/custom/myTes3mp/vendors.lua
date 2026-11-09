-- Vendors that are worth coming back to.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Configure it with
-- TES3MP_VENDOR_GOLD_MINUTES and TES3MP_VENDOR_STOCK_SECONDS; 0 switches a
-- part off.
--
-- Gold. A merchant's gold comes back after 24 in-game hours, checked when a
-- player starts talking to him. The wait is a game setting
-- (fBarterGoldResetDelay), and a TES3MP server can override game settings for
-- every client. So the wait is set to however many in-game hours go by in the
-- configured number of real minutes.
--
-- Stock. The server remembers what a merchant carried the first time anyone
-- bartered with him. When a player opens the barter screen and the configured
-- number of seconds has passed since that merchant was last put in order, his
-- inventory is put back to that list: what was bought is there again, what
-- was sold to him is gone. It happens at the moment of opening rather than on
-- a timer so that nothing changes under a barter screen that is already open.
--
-- Artifacts and unique items are the exception: one that has been bought is
-- not put back. It returns when the cell itself resets (see resets.lua).

local settings = require("custom/myTes3mp/settings")
local uniqueItems = require("custom/myTes3mp/uniqueItems")

local vendors = {}

vendors.goldMinutes = tonumber(settings.vendorGoldMinutes) or 0
vendors.stockSeconds = tonumber(settings.vendorStockSeconds) or 0

-- If somebody else opened the same merchant's barter screen this recently,
-- he may still be trading: do not touch the inventory. The server is not
-- told when a barter screen closes, so this errs well on the long side.
vendors.busySeconds = 600

-- Saved as data/custom/myTes3mpVendors.json:
--   stock[cellDescription][uniqueIndex] = { the merchant's original inventory }
local STATE_FILE = "custom/myTes3mpVendors.json"
local state = { stock = {} }

-- In memory only, keyed by cell .. "|" .. uniqueIndex:
--   lastRefresh[key] = os.time() of the last time he was put in order
--   lastOpen[key]    = { [pid] = os.time() that player last opened his barter screen }
local lastRefresh = {}
local lastOpen = {}

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp vendors] " .. message)
end

local function loadState()
    local loaded = jsonInterface.load(STATE_FILE)
    if type(loaded) == "table" and type(loaded.stock) == "table" then
        for cellDescription, merchants in pairs(loaded.stock) do
            if type(cellDescription) == "string" and type(merchants) == "table" then
                state.stock[cellDescription] = merchants
            end
        end
    end
end

local function copyItems(items)
    local copy = {}
    for _, item in pairs(items) do
        if type(item) == "table" and item.refId ~= nil then
            table.insert(copy, {
                refId = item.refId,
                count = item.count,
                charge = item.charge,
                enchantmentCharge = item.enchantmentCharge,
                soul = item.soul
            })
        end
    end
    return copy
end

local function isUnique(refId)
    return uniqueItems[string.lower(refId)] ~= nil
end

local function countOf(items, refId)
    local total = 0
    local wanted = string.lower(refId)
    for _, item in pairs(items) do
        if type(item) == "table" and item.refId ~= nil and string.lower(item.refId) == wanted then
            total = total + math.abs(tonumber(item.count) or 0)
        end
    end
    return total
end

-- The inventory a merchant should have after being put in order: his
-- original stock, except that unique items he no longer has stay gone.
vendors.Restocked = function(original, current)
    local result = {}
    for _, item in pairs(copyItems(original)) do
        if not isUnique(item.refId) or countOf(current, item.refId) > 0 then
            table.insert(result, item)
        end
    end
    return result
end

local function sameItems(a, b)
    local function summary(items)
        local lines = {}
        for _, item in pairs(items) do
            if type(item) == "table" and item.refId ~= nil then
                table.insert(lines, string.lower(item.refId) .. "|" .. tostring(item.count) .. "|" ..
                    tostring(item.charge) .. "|" .. tostring(item.enchantmentCharge) .. "|" .. tostring(item.soul))
            end
        end
        table.sort(lines)
        return table.concat(lines, "\n")
    end
    return summary(a) == summary(b)
end

-- A player has chosen "Barter" with this merchant; the server has not yet
-- told his client to go ahead.
vendors.OnBarter = function(pid, cellDescription, uniqueIndex)
    local cell = LoadedCells[cellDescription]
    if cell == nil then
        return
    end
    local object = cell.data.objectData[uniqueIndex]
    if type(object) ~= "table" or type(object.inventory) ~= "table" then
        -- The server has not been told what he carries; nothing to go by.
        return
    end

    local key = cellDescription .. "|" .. uniqueIndex
    local now = os.time()
    -- Is somebody else possibly still trading with him? Each player's last
    -- opening is kept separately, so that opening the screen again does not
    -- make a player forget that the other one was there first.
    local opens = lastOpen[key] or {}
    local busy = false
    for otherPid, openedAt in pairs(opens) do
        if otherPid ~= pid and now - openedAt < vendors.busySeconds then
            busy = true
        end
    end
    opens[pid] = now
    lastOpen[key] = opens

    if type(state.stock[cellDescription]) ~= "table" then
        state.stock[cellDescription] = {}
    end
    local original = state.stock[cellDescription][uniqueIndex]

    if type(original) ~= "table" then
        -- First barter with this merchant: this is his stock from now on.
        state.stock[cellDescription][uniqueIndex] = copyItems(object.inventory)
        jsonInterface.quicksave(STATE_FILE, state)
        lastRefresh[key] = now
        return
    end

    if now - (lastRefresh[key] or 0) < vendors.stockSeconds then
        return
    end
    if busy then
        return
    end
    lastRefresh[key] = now

    local restocked = vendors.Restocked(original, object.inventory)
    if sameItems(restocked, object.inventory) then
        return
    end

    object.inventory = restocked
    tableHelper.insertValueIfMissing(cell.data.packets.container, uniqueIndex)
    cell:QuicksaveToDrive()

    -- Everybody who has the cell loaded gets the merchant's new inventory,
    -- the player who is about to barter first.
    cell:LoadContainers(pid, cell.data.objectData, { uniqueIndex })
    for _, visitorPid in pairs(cell.visitors) do
        if visitorPid ~= pid then
            cell:LoadContainers(visitorPid, cell.data.objectData, { uniqueIndex })
        end
    end
    log("Restocked " .. tostring(object.refId) .. " in " .. cellDescription)
end

if vendors.stockSeconds > 0 then
    -- A validator runs before the server answers the player's request, so the
    -- fresh inventory reaches him before his barter screen opens.
    customEventHooks.registerValidator("OnObjectDialogueChoice", function(eventStatus, pid, cellDescription, objects)
        if type(objects) ~= "table" then
            return
        end
        for uniqueIndex, object in pairs(objects) do
            if type(object) == "table" and object.dialogueChoiceType == enumerations.dialogueChoice.BARTER then
                local ok, problem = pcall(vendors.OnBarter, pid, cellDescription, uniqueIndex)
                if not ok then
                    tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp vendors] Restock failed: " .. tostring(problem))
                end
            end
        end
    end)
end

-- A player who has left is not trading with anybody.
customEventHooks.registerHandler("OnPlayerDisconnect", function(eventStatus, pid)
    for _, opens in pairs(lastOpen) do
        opens[pid] = nil
    end
end)

customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
    loadState()

    if vendors.goldMinutes > 0 then
        -- In-game hours that pass in the configured number of real minutes.
        -- The time scale is game seconds per real second; with different day
        -- and night scales the slower one is used, so gold is never later
        -- than promised.
        local clock = WorldInstance.data.time
        local scale = math.min(tonumber(clock.dayTimeScale) or 30, tonumber(clock.nightTimeScale) or 30)
        local hours = vendors.goldMinutes * scale / 60

        local store = RecordStores["gamesetting"]
        local record = store.data.permanentRecords["fBarterGoldResetDelay"]
        if type(record) ~= "table" or record.floatVar ~= hours then
            store.data.permanentRecords["fBarterGoldResetDelay"] = { floatVar = hours }
            store:Save()
        end
        log("Merchant gold comes back every " .. vendors.goldMinutes .. " real minute(s) (" .. hours ..
            " in-game hours)")
    end

    if vendors.stockSeconds > 0 then
        log("Merchant stock is put back when you barter, at most every " .. vendors.stockSeconds .. " seconds")
    end
end)

return vendors
