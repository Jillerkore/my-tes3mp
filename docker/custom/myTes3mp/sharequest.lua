-- Do one quest together while keeping separate journals.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Switch it off with
-- TES3MP_SHARE_QUESTS=false.
--
-- Why. Each player here has his own journal and his own quest progress, so
-- two brothers can play the game at their own pace. Sometimes you want to
-- do one quest side by side anyway - without giving up the separate
-- journals for everything else. This is the middle way:
--
--   /sharequest              pick one of your quests from a list
--   /sharequest <quest id>   or name it directly (MS_FargothRing, ...)
--   /unsharequest            stop sharing a quest again
--
-- The server only knows the game's internal quest ids, not their titles,
-- so the list shows the id and the latest journal index you have reached
-- in it, most recently updated first.
--
-- How it works.
--
--   1. You pick a quest. Every other player who is online gets a yes/no box
--      asking whether he wants to do it together with you. Nothing is
--      copied to anybody who says no.
--   2. Whoever says yes receives all the journal entries you have for that
--      quest so far, with the dates they were written. They appear in his
--      journal like any other entry.
--   3. From then on, every new journal entry or journal index for that
--      quest, written by either of you, is passed on to the other one - at
--      once if he is online, otherwise it waits and is delivered when he
--      next logs in.
--   4. /unsharequest ends it for you. What was already copied stays.
--
-- How it avoids loops and duplicates. The server never "echoes" a journal
-- change back: a game client only reports journal entries that its own game
-- scripts write, not the ones the server hands it, so a relayed entry does
-- not come back as a new report. As a second line of defence the server
-- also checks before passing anything on whether the other player's saved
-- journal already holds it, and drops it if so. And a journal index is
-- never passed on if the receiver is already at or past that index, because
-- a client sets an index it is told about without looking at the old one -
-- passing on an old index would move his quest backwards.
--
-- What it does not do. It does nothing while the server runs with shared
-- journals (config.shareJournal), since then everybody has everything. It
-- refuses the Great House stronghold quests (HH_Stronghold, HR_Stronghold,
-- HT_Stronghold): strongholds.lua reads a player's journal to decide what
-- to build and when, and the buildings belong to the whole world, so a
-- stronghold quest handed to somebody who did not earn it would make that
-- script build things for him. Journal text is shown by the receiving game
-- using the NPC who gave the entry, if that NPC happens to be near him;
-- otherwise the game uses the player himself, which only matters for the
-- odd line that mentions the NPC's name.
--
-- Saved as data/custom/myTes3mpShareQuest.json:
--   links[quest id, lower case][account name, lower case] = true
--   queue[account name]  = journal items waiting for that player to log in

local settings = require("custom/myTes3mp/settings")

local sharequest = {}

-- Distinctive ids for the boxes this script shows (the game and the other
-- scripts use small numbers; CoreScripts itself uses 9001-9003).
sharequest.PICK_ID = 7340101   -- list of quests to share
sharequest.ASK_ID = 7340102    -- the yes/no question
sharequest.UNPICK_ID = 7340103 -- list of quests to stop sharing

-- How many quests the list offers, and how many undelivered items one
-- player may have waiting (a safety limit for a very long absence).
sharequest.maxListed = 60
sharequest.maxQueued = 500

local STATE_FILE = "custom/myTes3mpShareQuest.json"
local state = { links = {}, queue = {} }

-- In memory only: what each player was shown and what he was asked.
--   picks[pid]  = { quest keys in list order }   (share list)
--   unpicks[pid] = { quest keys in list order }  (unshare list)
--   offers[targetPid] = { fromPid, fromAccount, key, quest }
local picks, unpicks, offers = {}, {}, {}

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp sharequest] " .. message)
end

local function tell(pid, message)
    tes3mp.SendMessage(pid, color.Yellow .. "[sharequest] " .. color.White .. message .. "\n", false)
end

local function isOnline(pid)
    return Players[pid] ~= nil and Players[pid]:IsLoggedIn()
end

local function accountOf(pid)
    return string.lower(Players[pid].accountName)
end

local function playerPidByAccount(account)
    for pid, player in pairs(Players) do
        if player ~= nil and player:IsLoggedIn() and string.lower(player.accountName) == account then
            return pid
        end
    end
    return nil
end

local function isActive()
    return settings.shareQuests ~= false and config.shareJournal ~= true
end

-- Stronghold quests are off limits (see the header).
sharequest.IsProtected = function(questId)
    return string.match(string.lower(questId), "^h[hrt]_stronghold") ~= nil
end

------------------------------------------------------------------ state

local function saveState()
    jsonInterface.quicksave(STATE_FILE, state)
end

local function validItem(item)
    if type(item) ~= "table" or type(item.quest) ~= "string" or type(item.index) ~= "number" then
        return false
    end
    return item.type == enumerations.journal.ENTRY or item.type == enumerations.journal.INDEX
end

local function cleanItem(item)
    local clean = { type = item.type, quest = item.quest, index = item.index }
    if item.type == enumerations.journal.ENTRY then
        if type(item.actorRefId) == "string" and item.actorRefId ~= "" then
            clean.actorRefId = item.actorRefId
        end
        local stamp = item.timestamp
        if type(stamp) == "table" and type(stamp.daysPassed) == "number" and type(stamp.month) == "number" and
            type(stamp.day) == "number" then
            clean.timestamp = { daysPassed = stamp.daysPassed, month = stamp.month, day = stamp.day }
        end
    end
    return clean
end

-- Take over only what has the expected shape; a damaged file must not be
-- able to hand somebody a broken journal entry.
local function loadState()
    state.links, state.queue = {}, {}
    local loaded = jsonInterface.load(STATE_FILE)
    if type(loaded) ~= "table" then
        return
    end
    if type(loaded.links) == "table" then
        for key, members in pairs(loaded.links) do
            if type(key) == "string" and type(members) == "table" then
                local set, count = {}, 0
                for account, flag in pairs(members) do
                    if type(account) == "string" and flag == true then
                        set[account] = true
                        count = count + 1
                    end
                end
                if count >= 2 then
                    state.links[key] = set
                end
            end
        end
    end
    if type(loaded.queue) == "table" then
        for account, items in pairs(loaded.queue) do
            if type(account) == "string" and type(items) == "table" then
                local list = {}
                for _, item in ipairs(items) do
                    if validItem(item) then
                        table.insert(list, cleanItem(item))
                    end
                end
                if #list > 0 then
                    state.queue[account] = list
                end
            end
        end
    end
end

------------------------------------------------------------------ journals

local function journalOf(player)
    if type(player.data.journal) ~= "table" then
        return {}
    end
    return player.data.journal
end

-- Does this journal already have what the item would give?
--   an entry:  the same entry (quest, index);
--   an index:  any item of that quest at or beyond that index.
local function journalHas(journal, item)
    local key = string.lower(item.quest)
    for _, saved in pairs(journal) do
        if type(saved) == "table" and type(saved.quest) == "string" and type(saved.index) == "number" and
            string.lower(saved.quest) == key then
            if item.type == enumerations.journal.ENTRY then
                if saved.type == enumerations.journal.ENTRY and saved.index == item.index then
                    return true
                end
            elseif saved.index >= item.index then
                return true
            end
        end
    end
    return false
end

-- The items of one quest in a journal, oldest first.
local function questItems(journal, key)
    local items = {}
    for _, saved in ipairs(journal) do
        if validItem(saved) and string.lower(saved.quest) == key then
            table.insert(items, cleanItem(saved))
        end
    end
    return items
end

-- Every quest in a journal, most recently updated first:
--   { { key =, quest = (as the game spells it), index = highest index }, ... }
local function questList(journal)
    local byKey, order = {}, {}
    for position, saved in ipairs(journal) do
        if validItem(saved) then
            local key = string.lower(saved.quest)
            local entry = byKey[key]
            if entry == nil then
                entry = { key = key, quest = saved.quest, index = saved.index }
                byKey[key] = entry
                table.insert(order, entry)
            end
            entry.quest = saved.quest
            entry.index = math.max(entry.index, saved.index)
            entry.last = position
        end
    end
    table.sort(order, function(a, b) return a.last > b.last end)
    return order
end

-- Send journal items to a player's game, where they appear in his journal.
local function sendItems(pid, items)
    tes3mp.ClearJournalChanges(pid)
    for _, item in ipairs(items) do
        if item.type == enumerations.journal.ENTRY then
            local actor = item.actorRefId or "player"
            if item.timestamp ~= nil then
                tes3mp.AddJournalEntryWithTimestamp(pid, item.quest, item.index, actor,
                    item.timestamp.daysPassed, item.timestamp.month, item.timestamp.day)
            else
                tes3mp.AddJournalEntry(pid, item.quest, item.index, actor)
            end
        else
            tes3mp.AddJournalIndex(pid, item.quest, item.index)
        end
    end
    tes3mp.SendJournalChanges(pid)
end

-- Put items into an online player's saved journal and into his game, but
-- only those he does not have yet. Returns how many were new.
local function giveNow(pid, items)
    local player = Players[pid]
    local journal = journalOf(player)
    local fresh, seen = {}, {}
    for _, item in ipairs(items) do
        local tag = item.type .. "/" .. string.lower(item.quest) .. "/" .. item.index
        if not seen[tag] and not journalHas(journal, item) then
            seen[tag] = true
            table.insert(fresh, item)
        end
    end
    if #fresh == 0 then
        return 0
    end
    -- The same path a journal report from the player's own game takes, so
    -- CoreScripts' own bookkeeping (it notes a delivered package, for one)
    -- stays right.
    player:SaveJournal({ journal = tableHelper.deepCopy(fresh) })
    sendItems(pid, fresh)
    return #fresh
end

local function enqueue(account, items)
    local list = state.queue[account]
    if list == nil then
        list = {}
        state.queue[account] = list
    end
    for _, item in ipairs(items) do
        local duplicate = false
        for _, waiting in ipairs(list) do
            if waiting.type == item.type and waiting.index == item.index and
                string.lower(waiting.quest) == string.lower(item.quest) then
                duplicate = true
                break
            end
        end
        if not duplicate and #list < sharequest.maxQueued then
            table.insert(list, cleanItem(item))
        end
    end
end

-- Hand items to an account: now if he is online, otherwise at his next login.
local function deliver(account, items)
    local pid = playerPidByAccount(account)
    if pid ~= nil then
        giveNow(pid, items)
    else
        enqueue(account, items)
    end
end

-- A player has just logged in: hand over whatever waited for him.
sharequest.Flush = function(pid)
    if not isOnline(pid) then
        return
    end
    local account = accountOf(pid)
    local waiting = state.queue[account]
    if waiting == nil then
        return
    end
    state.queue[account] = nil
    saveState()
    if not isActive() then
        -- Journals are shared right now; everything reaches him that way.
        return
    end
    -- Quests that have been unshared in the meantime are not delivered.
    local wanted = {}
    for _, item in ipairs(waiting) do
        local members = state.links[string.lower(item.quest)]
        if members ~= nil and members[account] == true then
            table.insert(wanted, item)
        end
    end
    local count = giveNow(pid, wanted)
    if count > 0 then
        log(count .. " journal item(s) delivered to " .. Players[pid].accountName .. " at login")
        tell(pid, "Your brother moved a shared quest on while you were away: " .. count ..
            " new journal item(s).")
    end
end

------------------------------------------------------------------ relaying

sharequest.Relay = function(pid, playerPacket)
    if not isActive() or not isOnline(pid) or type(playerPacket) ~= "table" or
        type(playerPacket.journal) ~= "table" then
        return
    end
    local account = accountOf(pid)

    local perQuest, order = {}, {}
    for _, item in ipairs(playerPacket.journal) do
        if validItem(item) then
            local key = string.lower(item.quest)
            local members = state.links[key]
            if members ~= nil and members[account] == true then
                if perQuest[key] == nil then
                    perQuest[key] = {}
                    table.insert(order, key)
                end
                table.insert(perQuest[key], cleanItem(item))
            end
        end
    end

    local changed = false
    for _, key in ipairs(order) do
        for other, _ in pairs(state.links[key]) do
            if other ~= account then
                local queuedBefore = state.queue[other] ~= nil and #state.queue[other] or 0
                deliver(other, perQuest[key])
                if state.queue[other] ~= nil and #state.queue[other] ~= queuedBefore then
                    changed = true
                end
            end
        end
    end
    if changed then
        saveState()
    end
end

customEventHooks.registerHandler("OnPlayerJournal", function(eventStatus, pid, playerPacket)
    -- If another script refused to let the report be saved, it is not
    -- the player's progress, so it is not passed on either.
    if eventStatus ~= nil and eventStatus.validDefaultHandler == false then
        return
    end
    local ok, problem = pcall(sharequest.Relay, pid, playerPacket)
    if not ok then
        tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp sharequest] Relay failed: " .. tostring(problem))
    end
end)

customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
    local ok, problem = pcall(sharequest.Flush, pid)
    if not ok then
        tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp sharequest] Delivery failed: " .. tostring(problem))
    end
end)

------------------------------------------------------------------ offering

local function describe(entry)
    return entry.quest .. " (journal index " .. entry.index .. ")"
end

-- Ask every other player who is online whether he wants to share a quest.
sharequest.Offer = function(pid, key)
    if not isActive() then
        tell(pid, config.shareJournal == true and
            "Journals are shared on this server, so every quest already is." or
            "Quest sharing is switched off on this server.")
        return
    end

    local entry
    for _, candidate in ipairs(questList(journalOf(Players[pid]))) do
        if candidate.key == key then
            entry = candidate
        end
    end
    if entry == nil then
        tell(pid, "You have no quest called " .. key .. " in your journal.")
        return
    end
    if sharequest.IsProtected(entry.quest) then
        tell(pid, entry.quest .. " cannot be shared: the stronghold quests build things for the whole world" ..
            " and must stay each player's own.")
        return
    end

    local account = accountOf(pid)
    local members = state.links[key]
    if members ~= nil and members[account] ~= true then
        tell(pid, entry.quest .. " is already being shared by other players.")
        return
    end

    local asked = 0
    for otherPid, other in pairs(Players) do
        if otherPid ~= pid and other ~= nil and other:IsLoggedIn() and
            not (members ~= nil and members[accountOf(otherPid)] == true) then
            offers[otherPid] = { fromPid = pid, fromAccount = account, key = key, quest = entry.quest }
            tes3mp.CustomMessageBox(otherPid, sharequest.ASK_ID,
                Players[pid].accountName .. " would like to do the quest " .. describe(entry) ..
                " together with you.\nIf you say yes, you get his journal entries for it so far, and from then on" ..
                " new entries for this quest are passed between you. Your other quests stay separate.",
                "Yes;No")
            asked = asked + 1
        end
    end

    if asked == 0 then
        tell(pid, "Nobody else is online to share " .. entry.quest .. " with.")
    else
        tell(pid, "Offered " .. entry.quest .. " to " .. asked .. " player(s).")
    end
end

-- The answer to the yes/no box. button: "0" is Yes.
sharequest.Answer = function(pid, button)
    local offer = offers[pid]
    offers[pid] = nil
    if offer == nil or not isOnline(pid) then
        return
    end
    local from = offer.fromPid
    local offerer = isOnline(from) and accountOf(from) == offer.fromAccount and Players[from] or nil

    if button ~= "0" then
        if offerer ~= nil then
            tell(from, Players[pid].accountName .. " does not want to share " .. offer.quest .. ".")
        end
        return
    end

    if not isActive() then
        tell(pid, "Quest sharing is not possible right now.")
        return
    end
    if offerer == nil then
        tell(pid, "The player who offered " .. offer.quest .. " has left; ask again when he is back.")
        return
    end

    local backlog = questItems(journalOf(offerer), offer.key)
    if #backlog == 0 then
        tell(pid, offer.quest .. " is no longer in his journal.")
        return
    end

    local account = accountOf(pid)
    local members = state.links[offer.key]
    if members == nil then
        members = {}
        state.links[offer.key] = members
    end
    members[offer.fromAccount] = true
    members[account] = true
    saveState()

    local count = giveNow(pid, backlog)
    log(Players[pid].accountName .. " now shares " .. offer.quest .. " with " .. offer.fromAccount ..
        " (" .. count .. " journal item(s) copied)")
    tell(pid, "You now share " .. offer.quest .. " with " .. Players[from].accountName .. ": " .. count ..
        " journal item(s) copied. New entries for it will be passed between you.")
    tell(from, Players[pid].accountName .. " accepted " .. offer.quest .. ". New entries for it will be passed" ..
        " between you.")
end

------------------------------------------------------------------ choosing a quest

sharequest.ShowShareList = function(pid)
    local lines, keys = {}, {}
    local account = accountOf(pid)
    for _, entry in ipairs(questList(journalOf(Players[pid]))) do
        if #keys >= sharequest.maxListed then
            break
        end
        if not sharequest.IsProtected(entry.quest) then
            local members = state.links[entry.key]
            local mark = (members ~= nil and members[account] == true) and "  [shared]" or ""
            table.insert(keys, entry.key)
            table.insert(lines, entry.quest .. "  -  index " .. entry.index .. mark)
        end
    end
    if #keys == 0 then
        tell(pid, "You have no quests in your journal that can be shared.")
        return
    end
    picks[pid] = keys
    tes3mp.ListBox(pid, sharequest.PICK_ID, "Share which quest? (most recent first)", table.concat(lines, "\n"))
end

-- Resolve a typed quest id (any capitals) to the key of a quest in the journal.
local function keyFromText(pid, text)
    local wanted = string.lower(text)
    for _, entry in ipairs(questList(journalOf(Players[pid]))) do
        if entry.key == wanted then
            return entry.key
        end
    end
    return wanted
end

customCommandHooks.registerCommand("sharequest", function(pid, cmd)
    if not isOnline(pid) then
        return
    end
    if not isActive() then
        tell(pid, config.shareJournal == true and
            "Journals are shared on this server, so every quest already is." or
            "Quest sharing is switched off on this server.")
        return
    end
    if cmd == nil or cmd[2] == nil then
        sharequest.ShowShareList(pid)
        return
    end
    local text = table.concat(cmd, " ", 2)
    sharequest.Offer(pid, keyFromText(pid, text))
end)

------------------------------------------------------------------ ending it

sharequest.Unshare = function(pid, key)
    local account = accountOf(pid)
    local members = state.links[key]
    if members == nil or members[account] ~= true then
        tell(pid, "You are not sharing a quest called " .. key .. ".")
        return
    end

    members[account] = nil
    local remaining = {}
    for other, _ in pairs(members) do
        table.insert(remaining, other)
    end
    if #remaining < 2 then
        state.links[key] = nil
    end

    -- Nothing more is passed to him, so nothing may wait for him either.
    local waiting = state.queue[account]
    if waiting ~= nil then
        local kept = {}
        for _, item in ipairs(waiting) do
            if string.lower(item.quest) ~= key then
                table.insert(kept, item)
            end
        end
        state.queue[account] = #kept > 0 and kept or nil
    end
    if #remaining < 2 then
        -- The link is gone for everybody: drop what was waiting for the rest.
        for _, other in ipairs(remaining) do
            local list = state.queue[other]
            if list ~= nil then
                local kept = {}
                for _, item in ipairs(list) do
                    if string.lower(item.quest) ~= key then
                        table.insert(kept, item)
                    end
                end
                state.queue[other] = #kept > 0 and kept or nil
            end
        end
    end
    saveState()

    log(Players[pid].accountName .. " stopped sharing " .. key)
    tell(pid, "You stopped sharing " .. key .. ". What was already copied stays in both journals.")
    for _, other in ipairs(remaining) do
        local otherPid = playerPidByAccount(other)
        if otherPid ~= nil then
            tell(otherPid, Players[pid].accountName .. " stopped sharing " .. key .. ".")
        end
    end
end

customCommandHooks.registerCommand("unsharequest", function(pid, cmd)
    if not isOnline(pid) then
        return
    end
    if cmd ~= nil and cmd[2] ~= nil then
        sharequest.Unshare(pid, string.lower(table.concat(cmd, " ", 2)))
        return
    end
    local account = accountOf(pid)
    local keys = {}
    for key, members in pairs(state.links) do
        if members[account] == true then
            table.insert(keys, key)
        end
    end
    table.sort(keys)
    if #keys == 0 then
        tell(pid, "You are not sharing any quest.")
        return
    end
    unpicks[pid] = keys
    tes3mp.ListBox(pid, sharequest.UNPICK_ID, "Stop sharing which quest?", table.concat(keys, "\n"))
end)

------------------------------------------------------------------ answers from the boxes

customEventHooks.registerHandler("OnGUIAction", function(eventStatus, pid, idGui, data)
    if not isOnline(pid) then
        return
    end
    -- The list boxes answer with the position of the chosen line, counted
    -- from 0; a closed box without a choice answers with a huge number.
    if idGui == sharequest.PICK_ID or idGui == sharequest.UNPICK_ID then
        local list
        if idGui == sharequest.PICK_ID then
            list, picks[pid] = picks[pid], nil
        else
            list, unpicks[pid] = unpicks[pid], nil
        end
        local position = tonumber(data)
        local key = list ~= nil and position ~= nil and list[position + 1] or nil
        if key == nil then
            return
        end
        if idGui == sharequest.PICK_ID then
            sharequest.Offer(pid, key)
        else
            sharequest.Unshare(pid, key)
        end
    elseif idGui == sharequest.ASK_ID then
        sharequest.Answer(pid, tostring(data))
    end
end)

customEventHooks.registerHandler("OnPlayerDisconnect", function(eventStatus, pid)
    picks[pid], unpicks[pid], offers[pid] = nil, nil, nil
    for target, offer in pairs(offers) do
        if offer.fromPid == pid then
            offers[target] = nil
        end
    end
end)

customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
    loadState()
    local count = 0
    for _, _ in pairs(state.links) do
        count = count + 1
    end
    log("Loaded: players can share single quests (" .. count .. " shared at the moment)")
end)

-- For tests and the other scripts.
sharequest.State = function() return state end

return sharequest
