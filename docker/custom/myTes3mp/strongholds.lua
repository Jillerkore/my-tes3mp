-- Great House strongholds for more than one player.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Turn it off with
-- TES3MP_STRONGHOLD_HELPER=false.
--
-- The problem. Morrowind builds a stronghold with four timer scripts per
-- house (Strong_Build_Start_X, Strong_Build1_X, Strong_Build2_X,
-- Strong_Build3_X; X = H, R or T). Each one waits five day changes, then
-- writes a journal entry for the builder and raises the global "Stronghold"
-- (1, 2, 4, 6), which makes the buildings appear - at all three sites at
-- once; the two a player does not own are occupied by rival nobles.
--
-- Two things go wrong on a multiplayer server:
--
--   1. Each timer gives up at once if "Stronghold" is already past its own
--      stage. That global is shared by the whole world (it has to be - it
--      controls physical buildings), so once one player has built, the next
--      player's timers quit without ever writing his journal entry and his
--      House questline is stuck for good.
--   2. A running timer lives only in the game client's memory. Quit the game
--      during the five-day wait and it is gone; nothing ever restarts it.
--
-- The fix. Keep the wait on the server instead. When a player's stronghold
-- quest reaches one of the four "construction under way" journal stages, note
-- the world day. Once five days have gone by - or as soon as the world is
-- already built that far - give him the journal entry the timer would have
-- written, and raise the world's build stage if it is still behind. Both are
-- done by running the same commands the original scripts run, on that
-- player's own client, so everything downstream (journal sync, the shared
-- global, buildings appearing) goes through the normal TES3MP paths.
--
-- If the game's own timer gets there first, nothing here fires: the player is
-- then no longer at a waiting stage.
--
-- One difference from the original: its timers hold back while the builder is
-- standing on the building site, so that nothing pops into view around him.
-- This does not, so a phase can complete while he is there.

local strongholds = {}

-- Day changes the original timers wait for ("daysPassed > 5", counted from 1).
strongholds.buildDays = 5

-- Journal ids as the game spells them, keyed in lower case.
local quests = {
    hh_stronghold = "HH_Stronghold", -- Hlaalu:   Rethan Manor, Odai Plateau
    hr_stronghold = "HR_Stronghold", -- Redoran:  Indarys Manor, Bal Isra
    ht_stronghold = "HT_Stronghold"  -- Telvanni: Tel Uvirith
}

-- Waiting journal index -> what the timer delivers when the wait is over.
-- The indexes are the same for all three houses.
local stages = {
    [50]  = { journal = 55,  stage = 1 }, -- paid; foundations being laid
    [90]  = { journal = 100, stage = 2 }, -- phase one
    [170] = { journal = 200, stage = 4 }, -- phase two
    [270] = { journal = 300, stage = 6 }  -- phase three
}

-- Notes about who is waiting since when are kept under this key, as
--   customVariables.myTes3mpStrongholds[questId] = { index = N, day = D }
-- in the player's own file - or in the world file when journals are shared
-- (config.shareJournal), because the quest then belongs to everyone.
local STORE_KEY = "myTes3mpStrongholds"

-- Commands that were sent and not yet answered, so that a second look before
-- the client has reacted does not send them again. In memory only:
--   inFlight[owner][questId] = { index = N, sentAt = os.time() }
-- "owner" is the account name, or "*" when journals are shared.
local inFlight = {}

-- How long to wait for a client to act on a command before trying again.
strongholds.retrySeconds = 300

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp strongholds] " .. message)
end

local function isOnline(pid)
    return Players[pid] ~= nil and Players[pid]:IsLoggedIn()
end

-- Whose quest is it: the player's, or - with shared journals - everyone's.
-- Returns the object that stores the journal and the notes, and the key used
-- for in-flight bookkeeping.
local function ownerOf(pid)
    if config.shareJournal == true then
        return WorldInstance, "*"
    end
    return Players[pid], string.lower(Players[pid].accountName)
end

-- Highest journal index reached in each stronghold quest.
local function questIndexes(journal)
    local highest = {}
    if type(journal) ~= "table" then
        return highest
    end
    for _, item in pairs(journal) do
        if type(item) == "table" and type(item.quest) == "string" and type(item.index) == "number" then
            local questId = string.lower(item.quest)
            if quests[questId] ~= nil and item.index > (highest[questId] or -1) then
                highest[questId] = item.index
            end
        end
    end
    return highest
end

-- Current value of the world's "Stronghold" global (0 when nothing is built).
local function worldStage()
    local variables = WorldInstance.data.clientVariables
    if type(variables) ~= "table" or type(variables.globals) ~= "table" then
        return 0
    end
    for id, variable in pairs(variables.globals) do
        if string.lower(id) == "stronghold" and type(variable) == "table" then
            return tonumber(variable.intValue) or 0
        end
    end
    return 0
end

local function currentDay()
    return tonumber(WorldInstance.data.time.daysPassed) or 0
end

-- Decide what, if anything, is due for one player. Returns the console
-- commands to run on his client and whether the stored notes changed. Apart
-- from those notes and the in-flight table it has no side effects, so it can
-- be tested without a running server.
strongholds.Plan = function(pid)
    local commands = {}
    local changed = false
    local owner, ownerKey = ownerOf(pid)

    if type(owner.data.customVariables) ~= "table" then
        owner.data.customVariables = {}
    end
    local notes = owner.data.customVariables[STORE_KEY]
    if type(notes) ~= "table" then
        notes = nil
    end

    local sent = inFlight[ownerKey]
    local indexes = questIndexes(owner.data.journal)
    local built = worldStage()
    local today = currentDay()
    local now = os.time()

    for questId, questName in pairs(quests) do
        local index = indexes[questId]
        local step = index ~= nil and stages[index] or nil

        if step == nil then
            -- Not waiting on construction (any more): forget what we noted.
            if notes ~= nil and notes[questId] ~= nil then
                notes[questId] = nil
                changed = true
            end
            if sent ~= nil then
                sent[questId] = nil
            end
        else
            if notes == nil then
                notes = {}
                owner.data.customVariables[STORE_KEY] = notes
            end
            local note = notes[questId]
            if type(note) ~= "table" or note.index ~= index or type(note.day) ~= "number" then
                note = { index = index, day = today }
                notes[questId] = note
                changed = true
                log(questName .. " stage " .. index .. " (" .. ownerKey .. "): waiting since day " .. today)
            end

            local due = built >= step.stage or today - note.day >= strongholds.buildDays
            local pending = sent ~= nil and sent[questId] or nil
            local answered = pending == nil or pending.index ~= index or
                now - pending.sentAt >= strongholds.retrySeconds

            if due and answered then
                if built < step.stage then
                    table.insert(commands, "set Stronghold to " .. step.stage)
                    -- Later quests in the same pass must see the new stage.
                    built = step.stage
                end
                table.insert(commands, "Journal " .. questName .. " " .. step.journal)

                if sent == nil then
                    sent = {}
                    inFlight[ownerKey] = sent
                end
                sent[questId] = { index = index, sentAt = now }
            end
        end
    end

    return commands, changed
end

strongholds.Check = function(pid)
    if not isOnline(pid) then
        return
    end

    local commands, changed = strongholds.Plan(pid)
    if changed then
        local owner = ownerOf(pid)
        owner:QuicksaveToDrive()
    end

    for _, command in ipairs(commands) do
        log("Running on " .. Players[pid].accountName .. ": " .. command)
        logicHandler.RunConsoleCommandOnPlayer(pid, command, false)
    end
end

-- With shared journals the first online player found carries out the
-- commands for everyone; the in-flight table keeps the rest from repeating
-- them.
strongholds.CheckAll = function()
    for pid, _ in pairs(Players) do
        strongholds.Check(pid)
    end
end

-- A stronghold quest moved on for this player.
customEventHooks.registerHandler("OnPlayerJournal", function(eventStatus, pid, playerPacket)
    if type(playerPacket) ~= "table" or type(playerPacket.journal) ~= "table" then
        return
    end
    for _, item in pairs(playerPacket.journal) do
        if type(item) == "table" and type(item.quest) == "string" and
            quests[string.lower(item.quest)] ~= nil then
            strongholds.Check(pid)
            return
        end
    end
end)

-- Somebody's construction moved the world on; others may be waiting on it.
customEventHooks.registerHandler("OnClientScriptGlobal", function(eventStatus, pid, variables)
    if type(variables) ~= "table" then
        return
    end
    for id, _ in pairs(variables) do
        if string.lower(id) == "stronghold" then
            strongholds.CheckAll()
            return
        end
    end
end)

-- Days go by while players are busy elsewhere, and a player may log in with a
-- wait that ran out while he was away: look once a minute. The first look
-- happens a minute after start-up, and a freshly logged-in client has long
-- finished loading by the time the next one comes round.
local checkTimerId

function MyTes3mpStrongholdTick()
    -- Whatever goes wrong in one look, the next one must still happen.
    local ok, problem = pcall(strongholds.CheckAll)
    if not ok then
        tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp strongholds] Check failed: " .. tostring(problem))
    end
    tes3mp.RestartTimer(checkTimerId, time.seconds(60))
end

customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
    checkTimerId = tes3mp.CreateTimer("MyTes3mpStrongholdTick", time.seconds(60))
    tes3mp.StartTimer(checkTimerId)
    log("Loaded: stronghold construction is tracked on the server")
end)

return strongholds
