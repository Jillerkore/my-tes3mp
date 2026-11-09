-- A personal bank and a shared family vault, usable anywhere.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Switch it off with TES3MP_BANK=false.
--
-- Why. Inventory space and weight are what slow a Morrowind adventure down,
-- and the world is full of places where leaving things is risky: a cell reset
-- (resets.lua) takes what lies on the floor, and a chest in someone's house
-- is a long walk away. Two brothers also want a place where one can leave
-- something for the other. So:
--
--   /bank   opens a container that only you can use
--   /vault  opens one container that everybody on the server shares
--
-- Both work anywhere, but not in a fight, while dead or downed, or in
-- character creation. What you put in stays until you take it out.
--
-- How it works around the engine. The game client can only show a container
-- that exists in a cell, so each bank and the vault is a real chest that the
-- server creates in a cell nobody ever visits ("Clutter Warehouse", a debug
-- cell in Morrowind.esm that no door of the normal game leads to). When you
-- type the command the server:
--
--   1. makes sure the chest exists (created the first time: your bank on your
--      first /bank, the vault on the first /vault anybody types);
--   2. sends your client the chest and its contents - the client does not
--      have that cell loaded, so it has to be told about the chest;
--   3. tells your client that you activated it, which opens the ordinary
--      container window.
--
-- Everything you move in that window is reported to the server like any other
-- container, and saved in the storage cell's file. The chests use two custom
-- container records (a copy of an empty vanilla chest with a very large
-- capacity) which this script registers as permanent records, so every
-- client learns them when it logs in.
--
-- Safety of the contents:
--   * The storage cell is kept out of the cell resets (resets.keepExact), or
--     a reset would empty every bank at once. It is also kept loaded, because
--     the server refuses container changes for cells nobody has loaded
--     (config.allowOnContainerForUnloadedCells is off, and stays off).
--   * Only the owner can change his bank; anyone can change the vault. The
--     chests cannot be deleted by a client.
--   * Which chest is whose is kept in data/custom/myTes3mpBank.json - and also
--     written on the chest itself in the cell's file, so that if the first
--     file is damaged the banks are found again instead of being made anew.
--
-- Two players with the vault open at once: the server saves each change and
-- passes it on to everybody, so both windows follow along. If both reach for
-- the same item the server gives it to the first and tells the second client
-- what is really left.
--
-- Artifacts and unique items (uniques.lua): putting one into a bank or the
-- vault counts as handing a copy to a container, like any chest; taking it
-- out again is never a "fresh" claim, and is allowed for whoever does it.

local settings = require("custom/myTes3mp/settings")

local bank = {}

-- Where the chests are kept: a vanilla interior that exists in Morrowind.esm
-- and that no normal door leads to.
bank.STORAGE_CELL = "Clutter Warehouse - Everything Must Go!"

-- Custom records, copies of an empty vanilla chest.
bank.BANK_RECORD = "mytes3mp_bank_chest"
bank.VAULT_RECORD = "mytes3mp_vault_chest"
bank.BASE_RECORD = "com_chest_02_empty"
bank.CAPACITY = 1000000

local VAULT = "<vault>"
local STATE_FILE = "custom/myTes3mpBank.json"

local enabled = settings.bank ~= false

-- Saved as data/custom/myTes3mpBank.json:
--   banks[account] = uniqueIndex of that player's chest in the storage cell
--   vault          = uniqueIndex of the shared chest
local state = { banks = {} }

-- ownerOf[uniqueIndex] = account (lower case), or VAULT
local ownerOf = {}

-- dead[pid] = true between OnPlayerDeath and OnPlayerResurrect
local dead = {}

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp bank] " .. message)
end

local function logError(message)
    tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp bank] " .. message)
end

local function tell(pid, message)
    tes3mp.SendMessage(pid, color.Yellow .. "[bank] " .. color.White .. message .. "\n", false)
end

local function isOnline(pid)
    return Players[pid] ~= nil and Players[pid]:IsLoggedIn()
end

local function accountOf(pid)
    return string.lower(tostring(Players[pid].accountName))
end

-- The storage cell must never be reset, whether or not resets.lua is loaded
-- (it is loaded before this file, when it is on at all).
local function protectFromResets()
    if myTes3mpResets ~= nil and type(myTes3mpResets.keepExact) == "table" then
        myTes3mpResets.keepExact[string.lower(bank.STORAGE_CELL)] = true
    end
end

------------------------------------------------------------------ state

local function validIndex(value)
    return type(value) == "string" and string.match(value, "^%d+%-%d+$") ~= nil
end

local function rebuildOwners()
    ownerOf = {}
    for account, uniqueIndex in pairs(state.banks) do
        ownerOf[uniqueIndex] = account
    end
    if state.vault ~= nil then
        ownerOf[state.vault] = VAULT
    end
end

local function saveState()
    jsonInterface.quicksave(STATE_FILE, state)
end

local function loadState()
    state = { banks = {} }
    local loaded = jsonInterface.load(STATE_FILE)
    if type(loaded) ~= "table" then
        return
    end
    if type(loaded.banks) == "table" then
        for account, uniqueIndex in pairs(loaded.banks) do
            if type(account) == "string" and validIndex(uniqueIndex) then
                state.banks[account] = uniqueIndex
            end
        end
    end
    if validIndex(loaded.vault) then
        state.vault = loaded.vault
    end
end

local function ensureCellLoaded()
    if LoadedCells[bank.STORAGE_CELL] == nil then
        logicHandler.LoadCell(bank.STORAGE_CELL)
    end
    return LoadedCells[bank.STORAGE_CELL]
end

-- The chests carry their owner in the cell file ("myTes3mpOwner"). If the
-- state file was lost or damaged, take the links back from there.
local function recoverFromCell()
    local cell = LoadedCells[bank.STORAGE_CELL]
    if cell == nil or type(cell.data.objectData) ~= "table" then
        return 0
    end
    local recovered = 0
    for uniqueIndex, object in pairs(cell.data.objectData) do
        if type(object) == "table" and validIndex(uniqueIndex) then
            if object.refId == bank.BANK_RECORD and type(object.myTes3mpOwner) == "string" and
                state.banks[object.myTes3mpOwner] == nil then
                state.banks[object.myTes3mpOwner] = uniqueIndex
                recovered = recovered + 1
            elseif object.refId == bank.VAULT_RECORD and state.vault == nil then
                state.vault = uniqueIndex
                recovered = recovered + 1
            end
        end
    end
    return recovered
end

------------------------------------------------------------------ the chests

local function newLocation()
    return { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0 }
end

local function createChest(owner)
    local cell = ensureCellLoaded()
    local recordId = owner == VAULT and bank.VAULT_RECORD or bank.BANK_RECORD
    local uniqueIndex = logicHandler.CreateObjectAtLocation(bank.STORAGE_CELL, newLocation(),
        dataTableBuilder.BuildObjectData(recordId), "place")

    local object = cell.data.objectData[uniqueIndex]
    object.inventory = {}
    object.myTes3mpOwner = owner
    tableHelper.insertValueIfMissing(cell.data.packets.container, uniqueIndex)
    cell:SaveToDrive()

    if owner == VAULT then
        state.vault = uniqueIndex
    else
        state.banks[owner] = uniqueIndex
    end
    rebuildOwners()
    saveState()
    log("Created " .. (owner == VAULT and "the family vault" or ("the bank of " .. owner)) .. " as " .. uniqueIndex)
    return uniqueIndex
end

-- The unique index of this owner's chest, creating the chest if it does not
-- exist yet (or has vanished from the cell file).
bank.ChestFor = function(owner)
    local uniqueIndex
    if owner == VAULT then
        uniqueIndex = state.vault
    else
        uniqueIndex = state.banks[owner]
    end

    if uniqueIndex ~= nil then
        if ensureCellLoaded():ContainsObject(uniqueIndex) then
            return uniqueIndex
        end
        logError("The chest " .. uniqueIndex .. " of " .. (owner == VAULT and "the vault" or owner) ..
            " is missing from " .. bank.STORAGE_CELL .. "; making a new one")
    end
    return createChest(owner)
end

-- Items made from generated records (enchanted or custom items) must be
-- known to the client before it is shown a container holding them.
local function sendGeneratedRecords(pid, inventory)
    if type(inventory) ~= "table" then
        return
    end
    local wanted = {}
    for _, item in pairs(inventory) do
        if type(item) == "table" and type(item.refId) == "string" and logicHandler.IsGeneratedRecord(item.refId) then
            local recordType = logicHandler.GetRecordTypeByRecordId(item.refId)
            if recordType ~= nil and RecordStores[recordType] ~= nil then
                wanted[recordType] = wanted[recordType] or {}
                table.insert(wanted[recordType], item.refId)
            end
        end
    end
    for recordType, ids in pairs(wanted) do
        local store = RecordStores[recordType]
        store:LoadGeneratedRecords(pid, store.data.generatedRecords, ids)
    end
end

------------------------------------------------------------------ opening

local function isDead(pid)
    if dead[pid] then
        return true
    end
    local health = tonumber((tes3mp.GetHealthCurrent(pid)))
    return health ~= nil and health <= 0
end

local function isDowned(pid)
    return myTes3mpDowned ~= nil and type(myTes3mpDowned.IsDowned) == "function" and
        myTes3mpDowned.IsDowned(pid) == true
end

local function isCreatingCharacter(pid)
    local data = Players[pid].data
    local location = data.location
    if type(location) ~= "table" or location.cell == nil or location.cell == "" then
        return true
    end
    return type(data.character) == "table" and data.character.race == ""
end

-- Why this player may not open a bank right now, or nil if he may.
bank.Refusal = function(pid)
    if isCreatingCharacter(pid) then
        return "Finish creating your character first."
    elseif isDowned(pid) then
        return "You cannot reach your things while downed."
    elseif isDead(pid) then
        return "You cannot reach your things while dead."
    elseif myTes3mpCombat ~= nil and myTes3mpCombat.InCombat(pid) then
        local wait = math.ceil((tonumber(myTes3mpCombat.quietSeconds) or 10) - myTes3mpCombat.SecondsQuiet(pid))
        return "Not in the middle of a fight. Try again in " .. math.max(1, wait) .. " seconds."
    end
    return nil
end

bank.Open = function(pid, owner)
    local reason = bank.Refusal(pid)
    if reason ~= nil then
        tell(pid, reason)
        return false
    end

    local uniqueIndex = bank.ChestFor(owner)
    local cell = ensureCellLoaded()
    local objectData = cell.data.objectData

    -- LoadObjectsPlaced throws away an object whose position it does not
    -- like; make sure it likes ours.
    local object = objectData[uniqueIndex]
    if type(object.location) ~= "table" or tableHelper.getCount(object.location) ~= 6 then
        object.location = newLocation()
    end
    if type(object.inventory) ~= "table" then
        object.inventory = {}
    end

    cell:LoadObjectsPlaced(pid, objectData, { uniqueIndex })
    sendGeneratedRecords(pid, object.inventory)
    cell:LoadContainers(pid, objectData, { uniqueIndex })
    logicHandler.ActivateObjectForPlayer(pid, bank.STORAGE_CELL, uniqueIndex)

    log(Players[pid].accountName .. " opened " .. (owner == VAULT and "the family vault" or "their bank"))
    return true
end

bank.OpenBank = function(pid, cmd)
    return bank.Open(pid, accountOf(pid))
end

bank.OpenVault = function(pid, cmd)
    return bank.Open(pid, VAULT)
end

-- For tests and other scripts: whose chest is this? nil if none of ours.
bank.OwnerOf = function(uniqueIndex)
    return ownerOf[uniqueIndex]
end

bank.VAULT = VAULT

------------------------------------------------------------------ records

-- The two container records. They are permanent records, which the stock
-- scripts send to every player when he logs in.
local function ensureRecords()
    local store = RecordStores ~= nil and RecordStores["container"] or nil
    if store == nil or type(store.data) ~= "table" then
        logError("There is no container record store; banks cannot work")
        return false
    end
    if type(store.data.permanentRecords) ~= "table" then
        store.data.permanentRecords = {}
    end

    local wanted = {
        [bank.BANK_RECORD] = { baseId = bank.BASE_RECORD, name = "Bank", weight = bank.CAPACITY },
        [bank.VAULT_RECORD] = { baseId = bank.BASE_RECORD, name = "Family Vault", weight = bank.CAPACITY }
    }
    local changed = false
    for recordId, record in pairs(wanted) do
        local existing = store.data.permanentRecords[recordId]
        if type(existing) ~= "table" or existing.baseId ~= record.baseId or existing.name ~= record.name or
            existing.weight ~= record.weight then
            store.data.permanentRecords[recordId] = record
            changed = true
        end
    end
    if changed then
        store:Save()
    end
    return true
end

------------------------------------------------------------------ wiring

if enabled then
    protectFromResets()

    local function guarded(name, fn)
        return function(pid, cmd)
            if isOnline(pid) then
                local ok, problem = pcall(fn, pid, cmd)
                if not ok then
                    logError("/" .. name .. " failed: " .. tostring(problem))
                    tell(pid, "Something went wrong; your things are safe. Try again in a moment.")
                end
            end
        end
    end

    customCommandHooks.registerCommand("bank", guarded("bank", bank.OpenBank))
    customCommandHooks.registerCommand("vault", guarded("vault", bank.OpenVault))

    -- Nobody but the owner touches a bank. Nothing else lives in this cell.
    customEventHooks.registerValidator("OnContainer", function(eventStatus, pid, cellDescription, objects)
        if string.lower(tostring(cellDescription)) ~= string.lower(bank.STORAGE_CELL) or not isOnline(pid) then
            return
        end
        local account = accountOf(pid)
        for _, object in pairs(objects or {}) do
            local owner = type(object) == "table" and ownerOf[object.uniqueIndex] or nil
            if owner == nil or (owner ~= VAULT and owner ~= account) then
                tell(pid, "That is not your bank.")
                return customEventHooks.makeEventStatus(false, false)
            end
        end
    end)

    customEventHooks.registerValidator("OnObjectDelete", function(eventStatus, pid, cellDescription, objects)
        if string.lower(tostring(cellDescription)) ~= string.lower(bank.STORAGE_CELL) or type(objects) ~= "table" then
            return
        end
        for uniqueIndex, _ in pairs(objects) do
            if ownerOf[uniqueIndex] ~= nil then
                return customEventHooks.makeEventStatus(false, false)
            end
        end
    end)

    -- If the storage cell gets unloaded (someone walked in and out of it with
    -- a console command, say), load it again: the server accepts container
    -- changes only for cells that are loaded.
    customEventHooks.registerHandler("OnCellUnload", function(eventStatus, pid, cellDescription)
        if string.lower(tostring(cellDescription)) == string.lower(bank.STORAGE_CELL) and next(ownerOf) ~= nil then
            local ok, problem = pcall(ensureCellLoaded)
            if not ok then
                logError("Could not load the storage cell again: " .. tostring(problem))
            end
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
    end)

    customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
        protectFromResets()
        local ok, problem = pcall(function()
            ensureRecords()
            loadState()

            -- The cell is loaded now if there is anything in it, and stays
            -- loaded. If there is no file for it yet, the first /bank makes it.
            if next(state.banks) ~= nil or state.vault ~= nil or Cell(bank.STORAGE_CELL):HasEntry() then
                ensureCellLoaded()
                local recovered = recoverFromCell()
                if recovered > 0 then
                    logError("Found " .. recovered .. " chest(s) in the storage cell that the state file did not" ..
                        " know about; they are linked again")
                end
                -- Forget links to chests that are not there; ChestFor makes new ones when needed.
                for account, uniqueIndex in pairs(state.banks) do
                    if not LoadedCells[bank.STORAGE_CELL]:ContainsObject(uniqueIndex) then
                        logError("The chest of " .. account .. " (" .. uniqueIndex .. ") is not in the storage cell")
                    end
                end
                saveState()
            end
            rebuildOwners()
        end)
        if not ok then
            logError("Start-up failed: " .. tostring(problem))
        end
        log("Loaded: /bank and /vault, chests kept in " .. bank.STORAGE_CELL)
    end)
else
    customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
        log("Banks are switched off")
    end)
end

-- For the other my-tes3mp scripts.
myTes3mpBank = bank

return bank
