-- Automatic cell resets, with exceptions for the places players live in.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Configure it with TES3MP_CELL_RESET_HOURS
-- and TES3MP_CELL_RESET_KEEP; 0 hours switches it off.
--
-- Why. A TES3MP world never heals: whoever is killed stays dead and whatever
-- is taken stays gone, for everybody. With separate progression that means
-- the second player to reach a quest may find its people dead and its dungeon
-- empty. A reset returns one cell to the state the game's data files describe.
--
-- When. The first time anyone loads a cell a clock starts for it. Once the
-- configured number of real hours has passed and nobody has the cell loaded,
-- it is reset. Then the next visit starts a new clock.
--
-- What is never reset:
--   * the Great House strongholds, inside and out;
--   * any cell where a player has put items into a container by hand, for as
--     long as at least one such container still holds anything at all ("stash"
--     cells) - empty the container and the cell goes back to resetting;
--   * cells named in TES3MP_CELL_RESET_KEEP;
--   * the character creation area.
--
-- What a reset does take: anything left lying on the floor of a cell that is
-- not on that list. Put it in a container.

local settings = require("custom/myTes3mp/settings")
local startupRefs = require("custom/myTes3mp/startupRefs")

local resets = {}

resets.resetSeconds = (tonumber(settings.cellResetHours) or 0) * 3600

-- How often to look for cells whose time has come, in seconds.
resets.checkSeconds = 60

-- At most this many cells are reset per look, so that a long list of overdue
-- cells (after a quiet week, say) is worked off gradually instead of in one
-- burst of disk work and network packets.
resets.maxPerSweep = 25

-- Functions to call with the cell description after a cell has been reset.
resets.listeners = {}

-- Cells never reset, by exact description (lower case).
resets.keepExact = {
    -- Character creation: the prison ship and the dock it lands at.
    ["-1, -9"] = true, ["-1, -10"] = true, ["-2, -9"] = true, ["-2, -10"] = true,
    -- Stronghold sites: Odai Plateau, Bal Isra, Uvirith's Grave.
    ["-5, -5"] = true, ["-5, 9"] = true, ["10, 1"] = true
}

-- Cells never reset, by any part of their name (lower case, plain text).
resets.keepLike = {
    "seyda neen, census and excise office", -- character creation
    "rethan manor",                         -- Hlaalu stronghold interiors
    "indarys manor",                        -- Redoran stronghold interiors
    "tel uvirith"                           -- Telvanni stronghold interiors
}

for _, name in ipairs(settings.cellResetKeep or {}) do
    if type(name) == "string" and name ~= "" then
        table.insert(resets.keepLike, string.lower(name))
    end
end

-- Startup-hidden objects, keyed by lower-case cell description.
local hiddenAtStart = {}
for cellDescription, objects in pairs(startupRefs) do
    hiddenAtStart[string.lower(cellDescription)] = objects
end

-- Saved as data/custom/myTes3mpCellResets.json:
--   timers[cellDescription]  = time (os.time) at which the cell is due
--   stashes[cellDescription] = { [uniqueIndex] = true } for containers a
--                              player has put something into
local STATE_FILE = "custom/myTes3mpCellResets.json"
local state = { timers = {}, stashes = {} }
local unsaved = false

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp resets] " .. message)
end

local function saveState()
    jsonInterface.quicksave(STATE_FILE, state)
    unsaved = false
end

local function loadState()
    local loaded = jsonInterface.load(STATE_FILE)
    if type(loaded) ~= "table" then
        return
    end
    -- Take over only entries of the expected shape; a damaged file must not
    -- be able to reset a cell early or break the sweep.
    if type(loaded.timers) == "table" then
        for cellDescription, dueAt in pairs(loaded.timers) do
            if type(cellDescription) == "string" and type(dueAt) == "number" then
                state.timers[cellDescription] = dueAt
            end
        end
    end
    if type(loaded.stashes) == "table" then
        for cellDescription, marked in pairs(loaded.stashes) do
            if type(cellDescription) == "string" and type(marked) == "table" then
                state.stashes[cellDescription] = marked
            end
        end
    end
end

-- Is this cell on the never-reset list? Returns true and the reason.
resets.IsKept = function(cellDescription)
    local name = string.lower(cellDescription)
    if resets.keepExact[name] then
        return true, "it is a protected place"
    end
    for _, fragment in ipairs(resets.keepLike) do
        if string.find(name, fragment, 1, true) then
            return true, "it is a protected place"
        end
    end
    return false
end

-- Run fn(cell) on a cell object, loading it from disk for the duration if no
-- player has it loaded.
local function withCell(cellDescription, fn)
    local temporary = false
    if LoadedCells[cellDescription] == nil then
        logicHandler.LoadCell(cellDescription)
        temporary = true
    end
    local ok, result = pcall(fn, LoadedCells[cellDescription])
    -- Unload even if fn failed, or the cell would look "in use" from now on.
    if temporary and LoadedCells[cellDescription] ~= nil then
        logicHandler.UnloadCell(cellDescription)
    end
    if not ok then
        error(result, 0)
    end
    return result
end

-- Does a container that a player filled in this cell still hold anything?
-- Forgets containers that have since been emptied or no longer exist.
resets.HasStash = function(cellDescription)
    local marked = state.stashes[cellDescription]
    if type(marked) ~= "table" or next(marked) == nil then
        state.stashes[cellDescription] = nil
        return false
    end

    local found = withCell(cellDescription, function(cell)
        local stillFull = false
        local objectData = cell.data.objectData or {}
        for uniqueIndex, _ in pairs(marked) do
            local object = objectData[uniqueIndex]
            if type(object) == "table" and type(object.inventory) == "table" and
                next(object.inventory) ~= nil then
                stillFull = true
            else
                marked[uniqueIndex] = nil
                unsaved = true
            end
        end
        return stillFull
    end)

    if next(marked) == nil then
        state.stashes[cellDescription] = nil
        unsaved = true
    end
    return found
end

-- Put one cell back to the state the data files describe, then hide again
-- what the game's Startup script hides in it. The cell must not be loaded by
-- any player.
local function resetCell(pid, cellDescription)
    withCell(cellDescription, function(cell)
        cell.isResetting = true
        cell.data.objectData = {}
        cell.data.packets = {}
        cell:EnsurePacketTables()
        cell.data.loadState.hasFullActorList = false
        cell.data.loadState.hasFullContainerData = false
        cell:ClearRecordLinks()

        local hidden = hiddenAtStart[string.lower(cellDescription)]
        if hidden ~= nil then
            local objects = {}
            for uniqueIndex, refId in pairs(hidden) do
                objects[uniqueIndex] = { refId = refId, state = false }
            end
            cell:SaveObjectStates(objects)
        end
    end)

    -- Tell every client to forget what it knew about the cell.
    tes3mp.ClearCellsToReset()
    tes3mp.AddCellToReset(cellDescription)
    tes3mp.SendCellReset(pid, true)

    -- And the other my-tes3mp scripts that keep notes about cells.
    for _, listener in ipairs(resets.listeners) do
        local ok, problem = pcall(listener, cellDescription)
        if not ok then
            tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp resets] A reset listener failed for " ..
                cellDescription .. ": " .. tostring(problem))
        end
    end
end

local function anyOnlinePid()
    for pid, player in pairs(Players) do
        if player ~= nil and player:IsLoggedIn() then
            return pid
        end
    end
    return nil
end

-- Reset every cell that is due, not loaded, and not protected. Needs one
-- online player, because the reset notice has to be sent through somebody.
resets.Sweep = function()
    local pid = anyOnlinePid()
    if pid == nil or resets.resetSeconds <= 0 then
        return 0
    end

    local now = os.time()
    local due = {}
    for cellDescription, dueAt in pairs(state.timers) do
        if type(dueAt) ~= "number" then
            -- Not a time we wrote: start that cell's clock afresh.
            state.timers[cellDescription] = now + resets.resetSeconds
            unsaved = true
        elseif now >= dueAt then
            table.insert(due, cellDescription)
        end
    end

    local count = 0
    for _, cellDescription in ipairs(due) do
        if count >= resets.maxPerSweep then
            break
        end
        if LoadedCells[cellDescription] == nil then
            -- One cell that cannot be handled (an unreadable cell file, say)
            -- must not keep the others from their turn.
            local ok, problem = pcall(function()
                if resets.IsKept(cellDescription) then
                    state.timers[cellDescription] = nil
                elseif resets.HasStash(cellDescription) then
                    -- Look again after another full period.
                    state.timers[cellDescription] = now + resets.resetSeconds
                else
                    resetCell(pid, cellDescription)
                    state.timers[cellDescription] = nil
                    count = count + 1
                    log("Reset " .. cellDescription)
                end
            end)
            if not ok then
                state.timers[cellDescription] = now + resets.resetSeconds
                tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp resets] Could not handle " ..
                    cellDescription .. ", trying again in a full period: " .. tostring(problem))
            end
            unsaved = true
        end
    end
    return count
end

-- Start the clock the first time a cell is loaded after its last reset.
customEventHooks.registerHandler("OnCellLoad", function(eventStatus, pid, cellDescription)
    if resets.resetSeconds <= 0 or type(cellDescription) ~= "string" then
        return
    end
    if state.timers[cellDescription] == nil and not resets.IsKept(cellDescription) then
        state.timers[cellDescription] = os.time() + resets.resetSeconds
        unsaved = true
    end
end)

-- Remember containers that a player drops items into. Putting an item into a
-- container by hand is the one container change the client reports as
-- "add, by drop"; taking things out, looting and scripted changes are not.
customEventHooks.registerHandler("OnContainer", function(eventStatus, pid, cellDescription, objects)
    if type(objects) ~= "table" or type(cellDescription) ~= "string" then
        return
    end
    if eventStatus ~= nil and eventStatus.validDefaultHandler == false then
        return
    end
    if tes3mp.GetObjectListAction() ~= enumerations.container.ADD or
        tes3mp.GetObjectListContainerSubAction() ~= enumerations.containerSub.DROP then
        return
    end

    -- Dropping something onto a corpse is reported the same way, but a body
    -- is not where anybody keeps things: leave actors out.
    local actors = {}
    local cell = LoadedCells[cellDescription]
    if cell ~= nil and type(cell.data.packets) == "table" and type(cell.data.packets.actorList) == "table" then
        for _, uniqueIndex in pairs(cell.data.packets.actorList) do
            actors[uniqueIndex] = true
        end
    end

    local marked = state.stashes[cellDescription]
    for _, object in pairs(objects) do
        if type(object) == "table" and object.uniqueIndex ~= nil and not actors[object.uniqueIndex] then
            if marked == nil then
                marked = {}
                state.stashes[cellDescription] = marked
            end
            if marked[object.uniqueIndex] ~= true then
                marked[object.uniqueIndex] = true
                unsaved = true
            end
        end
    end

    -- What protects somebody's belongings is written out at once.
    if unsaved then
        saveState()
    end
end)

-- Bring a cell's reset forward so that it happens at most this many seconds
-- from now (still only once nobody has it loaded). Protected cells stay
-- protected. Used by uniques.lua when somebody still needs an item from here.
resets.Hasten = function(cellDescription, seconds)
    if resets.resetSeconds <= 0 or resets.IsKept(cellDescription) then
        return
    end
    local dueAt = os.time() + seconds
    if state.timers[cellDescription] == nil or state.timers[cellDescription] > dueAt then
        state.timers[cellDescription] = dueAt
        unsaved = true
    end
end

-- /resetinfo: what will happen to the cell you are standing in.
resets.Info = function(pid, cmd)
    local cellDescription = Players[pid].data.location.cell
    local message

    if resets.resetSeconds <= 0 then
        message = "Automatic cell resets are switched off on this server."
    else
        local kept, reason = resets.IsKept(cellDescription)
        if kept then
            message = cellDescription .. " never resets: " .. reason .. "."
        elseif resets.HasStash(cellDescription) then
            message = cellDescription .. " will not reset while a container somebody put things into here" ..
                " still holds anything."
        else
            local dueAt = state.timers[cellDescription]
            local minutes = 0
            if type(dueAt) == "number" then
                minutes = math.max(0, math.ceil((dueAt - os.time()) / 60))
            end
            message = cellDescription .. " resets about " .. math.floor(minutes / 60) .. " h " ..
                (minutes % 60) .. " min from now, once nobody is here. Items left on the floor" ..
                " will be gone; items you put into a container protect the whole cell."
        end
    end

    tes3mp.SendMessage(pid, color.Yellow .. "[resets] " .. color.White .. message .. "\n", false)
end

customCommandHooks.registerCommand("resetinfo", resets.Info)

local sweepTimerId

function MyTes3mpResetTick()
    -- Whatever goes wrong in one sweep, the next one must still happen.
    local ok, problem = pcall(function()
        resets.Sweep()
        if unsaved then
            saveState()
        end
    end)
    if not ok then
        tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp resets] Sweep failed: " .. tostring(problem))
    end
    tes3mp.RestartTimer(sweepTimerId, time.seconds(resets.checkSeconds))
end

customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
    loadState()
    if resets.resetSeconds <= 0 then
        log("Automatic cell resets are off")
        return
    end
    sweepTimerId = tes3mp.CreateTimer("MyTes3mpResetTick", time.seconds(resets.checkSeconds))
    tes3mp.StartTimer(sweepTimerId)
    log("Loaded: cells reset " .. settings.cellResetHours .. " h after they are first visited; " ..
        "strongholds and stash cells are kept")
end)

customEventHooks.registerHandler("OnServerExit", function(eventStatus)
    if unsaved then
        saveState()
    end
end)

-- For the other my-tes3mp scripts; nil when resets are switched off.
myTes3mpResets = resets

return resets
