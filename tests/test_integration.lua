-- All modules at once: the real init.lua with the default settings, two players, the real CoreScripts
-- classes, and stories that cross module borders (combat gating, being downed, the vault and the
-- artifacts, a world boss, a shared quest next to the stronghold helper).
--
-- What is real: init.lua and every script it loads, the cell classes (SaveContainers, LoadObjectsPlaced,
-- AddVisitor...), the real logicHandler.CreateObjects / ActivateObjectForPlayer / DeleteObject /
-- TeleportToPlayer, the real BasePlayer:ProcessDeath / :Resurrect, the real StateHelper:SaveJournal and
-- customEventHooks / customCommandHooks. What is faked is only the C++ server (what the clients report is
-- put into `live`, what the scripts send is recorded) and the clock.
--
-- Facts about the engine that the stories rest on are checked in the "E" section against the sources.
-- A check that fails here is a defect in the scripts' combination, not a broken test; see the report.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local ADD, REMOVE, SUB = T.ADD, T.REMOVE, T.SUB
local ENTRY = enumerations.journal.ENTRY
local StateHelper = require("stateHelper")

------------------------------------------------------------------ real pieces taken from CoreScripts
local savedPatterns = _G.patterns
local Base = dofile(T.cs .. "/scripts/player/base.lua")
dofile(T.cs .. "/scripts/packetReader.lua")
_G.patterns = savedPatterns or _G.patterns
_G.contentFixer.UnequipDeadlyItems = function() end
_G.dataTableBuilder = require("dataTableBuilder")

local function useRealLogicHandler(names)
    local env = setmetatable({}, { __index = _G })
    local chunk = assert(loadfile(T.cs .. "/scripts/logicHandler.lua"))
    setfenv(chunk, env)
    local menus = config.menuHelperFiles
    config.menuHelperFiles = {}
    local real = chunk()
    config.menuHelperFiles = menus
    -- the real functions call the chunk's own `logicHandler`: give it the harness's LoadCell / UnloadCell
    real.LoadCell, real.UnloadCell = logicHandler.LoadCell, logicHandler.UnloadCell
    for _, name in ipairs(names) do
        assert(type(real[name]) == "function", name .. " is not in logicHandler.lua")
        setfenv(real[name], _G)
        logicHandler[name] = real[name]
    end
end

------------------------------------------------------------------ the fake C++ server
local live          -- live[pid] = what the client last reported
local E             -- everything the scripts sent, in order
local cur
local errors        -- ERROR lines logged
local counts        -- counts[name] = number of times a Send*/save was called
local writes        -- writes[file] = number of times a json file was written
local stores, loadedBy

tes3mp.LogMessage = function(level, m)
    T.log[#T.log + 1] = m
    if level == enumerations.log.ERROR then errors[#errors + 1] = m end
end

local function send(kind, ...) E[#E + 1] = { kind, ... } end
local function plain(name, fn) tes3mp[name] = fn end

plain("GetHealthCurrent", function(pid) return live[pid] and live[pid].hp end)
plain("GetHealthBase", function(pid) return live[pid] and live[pid].hpBase end)
plain("GetMagickaCurrent", function(pid) return live[pid] and live[pid].mp end)
plain("GetMagickaBase", function(pid) return live[pid] and live[pid].mpBase end)
plain("GetBirthsign", function(pid) return live[pid] and live[pid].sign or "" end)
plain("GetLevel", function(pid) return live[pid] and live[pid].level end)
plain("GetCell", function(pid) return live[pid] and live[pid].cell end)
plain("GetPosX", function(pid) return live[pid] and live[pid].x or 0 end)
plain("GetPosY", function(pid) return live[pid] and live[pid].y or 0 end)
plain("GetPosZ", function(pid) return live[pid] and live[pid].z or 0 end)
plain("GetRotX", function() return 0 end)
plain("GetRotZ", function(pid) return live[pid] and live[pid].rz or 0 end)
plain("DoesPlayerHavePlayerKiller", function() return false end)
plain("GetPlayerKillerName", function() return "a kagouti" end)
plain("GetBounty", function() return 0 end)
plain("SendMessage", function(pid, msg, everyone) T.msgs[#T.msgs + 1] = { pid, msg, everyone } end)
-- teleports: the server only asks; the client answers with a cell change (see `arrive`)
plain("SetCell", function(pid, cell) cur = cur or {}; E[#E + 1] = { "setcell", pid, cell } end)
plain("SetPos", function() end)
plain("SetRot", function() end)
plain("SendCell", function(pid) send("sendcell", pid) end)
plain("SendPos", function(pid) send("sendpos", pid) end)
plain("Resurrect", function(pid, kind) send("resurrect", pid, kind) end)
plain("Jail", function(pid, days) send("jail", pid, days) end)
plain("SetHealthCurrent", function(pid, v) send("sethealth", pid, v); live[pid].hp = v end)
plain("SendStatsDynamic", function(pid) send("statsdynamic", pid) end)
plain("ListBox", function(pid, id, label, items) send("listbox", pid, id, label, items) end)
plain("CustomMessageBox", function(pid, id, label, buttons) send("msgbox", pid, id, label, buttons) end)
-- spellbook changes (regen)
local spellCur = {}
plain("ClearSpellbookChanges", function(pid) spellCur[pid] = {} end)
plain("SetSpellbookChangesAction", function(pid, a) spellCur[pid].action = a end)
plain("AddSpell", function(pid, id) table.insert(spellCur[pid], id) end)
plain("SendSpellbookChanges", function(pid)
    send("spells", pid, spellCur[pid].action, table.concat(spellCur[pid], ","))
end)
-- journal (sharequest)
local jcur = {}
plain("ClearJournalChanges", function(pid) jcur[pid] = {} end)
plain("AddJournalEntry", function(pid, q, i) table.insert(jcur[pid], { ENTRY, q, i }) end)
plain("AddJournalEntryWithTimestamp", function(pid, q, i) table.insert(jcur[pid], { ENTRY, q, i }) end)
plain("AddJournalIndex", function(pid, q, i) table.insert(jcur[pid], { "index", q, i }) end)
plain("SendJournalChanges", function(pid) send("journal", pid, jcur[pid]); jcur[pid] = nil end)
-- object lists (the real CreateObjects / ActivateObjectForPlayer / LoadObjectsPlaced write into these)
plain("ClearObjectList", function() cur = { objects = {} } end)
plain("SetObjectListPid", function(pid) cur.pid = pid end)
plain("SetObjectListCell", function(cell) cur.cell = cell end)
plain("SetObjectRefNum", function(n) cur.refNum = n end)
plain("SetObjectMpNum", function(n) cur.mpNum = n end)
plain("SetObjectRefId", function(id) cur.refId = id end)
plain("SetObjectActivatingPid", function(pid) cur.activatedBy = pid end)
plain("AddObject", function()
    table.insert(cur.objects, { refId = cur.refId, uniqueIndex = tostring(cur.refNum) .. "-" .. tostring(cur.mpNum) })
end)
plain("SendObjectPlace", function(everyone) send("place", cur.pid, cur.cell, everyone, cur.objects) end)
plain("SendObjectSpawn", function(everyone) send("spawn", cur.pid, cur.cell, everyone, cur.objects) end)
plain("SendObjectDelete", function(everyone) send("delete", cur.pid, cur.cell, everyone) end)
plain("SendObjectActivate", function()
    send("activate", cur.pid, cur.cell, cur.objects[1] and cur.objects[1].uniqueIndex, cur.activatedBy)
end)
plain("SendContainer", function(...)
    if select("#", ...) == 0 then send("containerset", cur.pid, cur.cell, cur.objects) end
end)
plain("SendRecordDynamic", function() send("records") end)
-- the object list of a delete is built by packetBuilder.AddObjectDelete; the stubs above are enough

-- count what costs something on a real server
for _, name in ipairs({ "SendMessage", "SendSpellbookChanges", "SendObjectPlace", "SendObjectSpawn", "SendObjectDelete",
    "SendObjectActivate", "SendContainer", "SendCellReset", "SendCell", "SendPos", "SendStatsDynamic", "SendJournalChanges",
    "SendInventoryChanges", "ListBox", "CustomMessageBox", "SendRecordDynamic", "SetHealthCurrent" }) do
    local original = tes3mp[name]
    tes3mp[name] = function(...)
        counts[name] = (counts[name] or 0) + 1
        return original(...)
    end
end
local inQuicksave = false
for _, name in ipairs({ "save", "quicksave" }) do
    local original = jsonInterface[name]
    jsonInterface[name] = function(file, ...)
        if not inQuicksave then   -- quicksave falls back to save without cjson: count one write
            writes[file] = (writes[file] or 0) + 1
            counts.jsonwrites = (counts.jsonwrites or 0) + 1
        end
        local was = inQuicksave
        if name == "quicksave" then inQuicksave = true end
        local result = original(file, ...)
        inQuicksave = was
        return result
    end
end

-- the stock death timer's callback and the glue eventHandler.lua puts around deaths
function OnDeathTimeExpiration(pid, accountName)
    if Players[pid] ~= nil and Players[pid]:IsLoggedIn() and Players[pid].accountName == accountName then
        local eventStatus = customEventHooks.triggerValidators("OnDeathTimeExpiration", { pid })
        if eventStatus.validDefaultHandler then Players[pid]:Resurrect() end
        customEventHooks.triggerHandlers("OnDeathTimeExpiration", eventStatus, { pid })
    end
end

------------------------------------------------------------------ the server
local BANK_CELL = "Clutter Warehouse - Everything Must Go!"
local mpCounter

local function boot(opts)
    opts = opts or {}
    local disk, now = T.disk, T.time
    local settings = T.copy(T.DEFAULT_SETTINGS)
    for k, v in pairs(opts.settings or {}) do settings[k] = v end
    T.fresh(settings)
    if opts.keepDisk then T.disk = disk; T.time = now end
    config.shareJournal = false -- this project's setting (progression = separate)
    config.shareKills = false
    live, E, errors, counts, writes, spellCur, jcur = {}, {}, {}, {}, {}, {}, {}
    loadedBy = {}
    T.msgs = {}
    mpCounter = mpCounter or 0
    function WorldInstance:UpdateFrametimeMultiplier() end
    function WorldInstance:GetCurrentMpNum() return mpCounter end
    function WorldInstance:SetCurrentMpNum(n) mpCounter = n end
    stores = {}
    for _, kind in ipairs({ "spell", "creature", "container" }) do
        local s = { data = { permanentRecords = {}, generatedRecords = {} }, saves = 0, loads = {} }
        function s:Save() self.saves = self.saves + 1 end
        function s:QuicksaveToDrive() self.saves = self.saves + 1 end
        function s:LoadRecords(pid, list, ids, everyone) table.insert(self.loads, { pid = pid, ids = ids, everyone = everyone }) end
        RecordStores[kind] = s
        stores[kind] = s
    end
    useRealLogicHandler({ "CreateObjects", "CreateObjectAtLocation", "CreateObjectAtPlayer", "ActivateObjectForPlayer",
        "DeleteObject", "DeleteObjectForEveryone", "DeleteObjectForPlayer", "IsGeneratedRecord", "GetRecordTypeByRecordId",
        "GetRecordStoreByRecordId", "TeleportToPlayer", "CheckPlayerValidity" })
    myTes3mpCombat, myTes3mpDowned, myTes3mpResets, myTes3mpBank, myTes3mpTravel = nil, nil, nil, nil, nil
    -- load through the real init.lua
    local result = dofile(T.scriptsDir .. "/init.lua")
    assert(result == T.settings)
    T.postInit()
end

-- a logged-in player with the real stock death functions and the real journal saver
local function player(pid, name, opts)
    opts = opts or {}
    local p = T.player(pid, name, { cell = opts.cell or "-3, -3", level = opts.level or 1 })
    p.name = name
    p.data.character = { race = "Nord", birthsign = opts.sign or "" }
    p.data.shapeshift = { isWerewolf = false }
    p.data.spellsActive = {}
    p.data.spellbook = {}
    p.data.location.regionName = ""
    p.data.inventory = {}
    if opts.gold then
        p.data.inventory[1] = { refId = "gold_001", count = opts.gold, charge = -1, enchantmentCharge = -1, soul = "" }
    end
    p.data.timestamps.lastLogin = 0
    p.data.stats.healthCurrent, p.data.stats.healthBase = 100, 100
    p.ProcessDeath, p.Resurrect = Base.ProcessDeath, Base.Resurrect
    function p:SaveJournal(packet) StateHelper:SaveJournal(self, packet) end
    live[pid] = { hp = 100, hpBase = 100, mp = 50, mpBase = 50, cell = opts.cell or "-3, -3", level = opts.level or 1,
        x = 100, y = 200, z = 300, rz = 1, sign = opts.sign or "" }
    return p
end

-- the 3x3 block of cells an exterior cell loads (components/misc/constants.hpp:28 CellGridRadius = 1)
local function grid(cell)
    local x, y = cell:match("^(-?%d+), (-?%d+)$")
    if not x then return { cell } end
    local out = {}
    for dx = -1, 1 do for dy = -1, 1 do out[#out + 1] = (tonumber(x) + dx) .. ", " .. (tonumber(y) + dy) end end
    return out
end
loadedBy = {}  -- loadedBy[pid] = { [cell] = true }
-- the client reports the new cell, and the cells around it that it has loaded
local function arrive(pid, cell)
    local prev = Players[pid].data.location.cell
    loadedBy[pid] = loadedBy[pid] or {}
    local want = {}
    for _, c in ipairs(grid(cell)) do want[c] = true end
    for c in pairs(loadedBy[pid]) do
        if not want[c] then T.leave(pid, c); loadedBy[pid][c] = nil end
    end
    for c in pairs(want) do
        if not loadedBy[pid][c] then T.visit(pid, c); loadedBy[pid][c] = true end
    end
    Players[pid].data.location.cell = cell
    live[pid].cell = cell
    customEventHooks.triggerHandlers("OnPlayerCellChange", { validDefaultHandler = true, validCustomHandlers = true },
        { pid, { location = { cell = cell } }, prev })
end

local function login(pid, name, cell, opts)
    local p = player(pid, name, { cell = cell, gold = opts and opts.gold, level = opts and opts.level })
    T.auth(pid)
    arrive(pid, cell)
    return p
end

local function logout(pid)
    customEventHooks.triggerValidators("OnPlayerDisconnect", { pid })
    for c in pairs(loadedBy[pid] or {}) do T.leave(pid, c) end
    loadedBy[pid] = nil
    customEventHooks.triggerHandlers("OnPlayerDisconnect", { validDefaultHandler = true }, { pid })
    Players[pid] = nil
    live[pid] = nil
end

local function say(pid, text) return customEventHooks.triggerValidators("OnPlayerSendMessage", { pid, text }) end
local function clearOut() E = {}; T.msgs = {} end
local function eventsOf(kind)
    local out = {}
    for _, e in ipairs(E) do if e[1] == kind then out[#out + 1] = e end end
    return out
end
local function told(pid, text)
    for _, m in ipairs(T.msgs) do if m[1] == pid and m[2]:find(text, 1, true) then return true end end
    return false
end
local function toldAnyone(text)
    for _, m in ipairs(T.msgs) do if m[2]:find(text, 1, true) then return true end end
    return false
end
local function countMsgs(text)
    local n = 0
    for _, m in ipairs(T.msgs) do if m[2]:find(text, 1, true) then n = n + 1 end end
    return n
end

-- timers --------------------------------------------------------------
local function fireNamed(name)
    local id = T.timerNamed(name)
    assert(id, "no timer " .. name)
    return T.fire(id)
end
local function advance(seconds, perSecond)
    for _ = 1, seconds do
        T.time = T.time + 1
        if perSecond then perSecond() end
    end
end
-- A scheduler that fires every started timer when its interval has passed (what the server does).
local sched
local function schedulerReset()
    sched = {}
    for id, t in ipairs(T.timers) do
        if t.started and not t.types then sched[id] = { next = T.time + t.ms / 1000, every = t.ms / 1000 } end
    end
end
local function runClock(seconds, between)
    for _ = 1, seconds do
        T.time = T.time + 1
        for id, s in pairs(sched) do
            while s.next <= T.time do
                local before = { counts = {}, jw = counts.jsonwrites or 0 }
                for k, v in pairs(counts) do before.counts[k] = v end
                T.timers[id].fired = nil
                T.fire(id)
                s.next = s.next + s.every
                local rec = sched[id].stats or {}
                sched[id].stats = rec
                rec.calls = (rec.calls or 0) + 1
                rec.json = (rec.json or 0) + (counts.jsonwrites or 0) - before.jw
                for k, v in pairs(counts) do
                    if k ~= "jsonwrites" then rec[k] = (rec[k] or 0) + v - (before.counts[k] or 0) end
                end
            end
        end
        if between then between() end
    end
end

-- events ----------------------------------------------------------------
local function death(pid)
    live[pid].hp = 0
    if Players[pid] ~= nil and Players[pid]:IsLoggedIn() then
        local status = customEventHooks.triggerValidators("OnPlayerDeath", { pid })
        if status.validDefaultHandler then Players[pid]:ProcessDeath() end
        customEventHooks.triggerHandlers("OnPlayerDeath", status, { pid })
    end
end
local function resurrected(pid, hp)         -- the client reports that it is alive again
    live[pid].hp = hp or live[pid].hpBase
    customEventHooks.triggerHandlers("OnPlayerResurrect", { validDefaultHandler = true }, { pid })
end
local function activateBody(pid, cell, targetPid)
    local players = { [targetPid] = { activatingPid = pid } }
    local status = customEventHooks.triggerValidators("OnObjectActivate", { pid, cell, {}, players })
    customEventHooks.triggerHandlers("OnObjectActivate", status, { pid, cell, {}, players })
end
local function hit(pid, cell, targets)
    local players = {}
    for _, t in ipairs(targets or {}) do players[t] = { hittingPid = pid } end
    customEventHooks.triggerHandlers("OnObjectHit", { validDefaultHandler = true }, { pid, cell, {}, players })
end
-- eventHandler.OnContainer: refused unless the cell is loaded (eventHandler.lua:1579), then the validators,
-- the real SaveContainers, the handlers.
local function container(pid, cell, action, sub, uniqueIndex, items, refId)
    local refNum, mpNum = uniqueIndex:match("^(%d+)%-(%d+)$")
    T.packet = { action = action, sub = sub, objects = { { refId = refId or "mytes3mp_bank_chest", refNum = tonumber(refNum),
        mpNum = tonumber(mpNum), items = items } } }
    if not config.allowOnContainerForUnloadedCells and LoadedCells[cell] == nil then return "unloaded" end
    local objects = { { refId = T.packet.objects[1].refId, uniqueIndex = uniqueIndex } }
    local status = customEventHooks.triggerValidators("OnContainer", { pid, cell, objects })
    if status.validDefaultHandler then LoadedCells[cell]:SaveContainers(pid) end
    customEventHooks.triggerHandlers("OnContainer", status, { pid, cell, objects })
    return status.validDefaultHandler
end
local function actorDeath(pid, cell, uniqueIndex, refId)
    local actors = { [uniqueIndex] = { refId = refId, killer = {} } }
    local status = customEventHooks.triggerValidators("OnActorDeath", { pid, cell, actors })
    customEventHooks.triggerHandlers("OnActorDeath", status, { pid, cell, actors })
end
local function gui(pid, id, data)
    local status = customEventHooks.triggerValidators("OnGUIAction", { pid, id, tostring(data) })
    customEventHooks.triggerHandlers("OnGUIAction", status, { pid, id, tostring(data) })
end

local function goldOf(pid)
    local n = 0
    for _, i in pairs(Players[pid].data.inventory) do if i.refId:lower() == "gold_001" then n = n + i.count end end
    return n
end
local function itemCount(pid, refId)
    local n = 0
    for _, i in pairs(Players[pid].data.inventory) do if i.refId:lower() == refId:lower() then n = n + i.count end end
    return n
end
local function has(list, value)
    for _, v in ipairs(list) do if v == value then return true end end
    return false
end
local function countOf(cell, refId)
    local n = 0
    local inv = LoadedCells[cell] and LoadedCells[cell].data.objectData
    for _, o in pairs(inv or {}) do
        if o.inventory then for _, i in pairs(o.inventory) do if i.refId:lower() == refId:lower() then n = n + i.count end end end
    end
    return n
end

------------------------------------------------------------------ 0. engine facts the stories rest on
local function csHas(file, text) return T.csSource(file):find(text, 1, true) ~= nil end
report("E1 the server raises OnPlayerResurrect only for the client's own ID_PLAYER_RESURRECT packet (serverCore.lua:388), " ..
    "so a script that calls tes3mp.Resurrect hears of it when the client answers",
    csHas("serverCore.lua", 'function OnPlayerResurrect(pid)'))
report("E2 container packets are refused for a cell that is not in LoadedCells, whoever sent them (eventHandler.lua:1579)",
    csHas("eventHandler.lua", "not config.allowOnContainerForUnloadedCells and  not isCellLoaded and logicHandler.DoesPacketOriginRequireLoadedCell(packetOrigin)"))
report("E2b ... and the gate is on the cell, not on the sender being in it (no visitor check anywhere in OnContainer)",
    not T.csSource("eventHandler.lua"):match("OnContainer = function.-GetVisitorCount"))
report("E3 CreateObjects sends the placed object to EVERY connected client (SendObjectPlace(true))",
    csHas("logicHandler.lua", "tes3mp.SendObjectPlace(true)"))
report("E4 OnGUIAction hands the script a string (eventHandler.lua:705) and ids are plain numbers",
    csHas("eventHandler.lua", "data = tostring(data)"))
report("E5 stock gui ids: 9001-9003 (config.lua:244)", csHas("config.lua", "menuHelper = 9001, confiscate = 9002, recordPrint = 9003"))
report("E6 customEventHooks.triggerHandlers never looks at validCustomHandlers: a vetoing validator does not stop other handlers",
    not T.csSource("customEventHooks.lua"):match("triggerHandlers.-validCustomHandlers"))
report("E7 customCommandHooks does not lower-case the command: '/Bank' is not '/bank' for the custom commands",
    csHas("customCommandHooks.lua", "local callback = customCommandHooks.getCallback(cmd[1])"))

------------------------------------------------------------------ 1. everything loaded at once
boot()
do
    local names = {}
    for _, t in ipairs(T.timers) do names[#names + 1] = t.name end
    table.sort(names)
    report("L1 every module started: timers for combat, strongholds, resets, challenge, regen, downed, bosses",
        has(names, "MyTes3mpCombatTick") and has(names, "MyTes3mpStrongholdTick") and has(names, "MyTes3mpResetTick") and
        has(names, "MyTes3mpChallengeTick") and has(names, "MyTes3mpRegenTick") and has(names, "MyTes3mpDownedTick") and
        has(names, "MyTes3mpBossTick"), table.concat(names, ","))
    report("L2 no error was logged while the modules started", #errors == 0, errors[1])
    report("L3 the other my-tes3mp scripts' globals are all there",
        myTes3mpCombat and myTes3mpDowned and myTes3mpResets and myTes3mpBank and myTes3mpTravel and true)
    local seen, dups = {}, {}
    for _, t in ipairs(T.timers) do
        if seen[t.name] and not t.types then dups[#dups + 1] = t.name end
        seen[t.name] = true
    end
    report("L4 no repeating timer is created twice", #dups == 0, table.concat(dups, ","))
end

-- command names: nothing registered twice, nothing shadows a stock command
do
    local stock = {}
    for _, f in ipairs({ "commandHandler.lua", "defaultCommands.lua" }) do
        local src = T.csSource(f)
        for name in src:gmatch('cmd%[1%] == "(%w+)"') do stock[name] = true end
        for name in src:gmatch('registerCommand%("(%w+)"') do stock[name] = true end
    end
    local clash, mine = {}, {}
    for name in pairs(customCommandHooks.commands) do
        if stock[name] and not (name == "test" or name == "ranktest" or name == "nametest") then clash[#clash + 1] = name end
        mine[#mine + 1] = name
    end
    table.sort(mine)
    report("C1 none of the my-tes3mp chat commands shadows a stock CoreScripts command", #clash == 0, table.concat(clash, ","))
    -- registrations are counted from the sources, because a second registerCommand just overwrites the first
    local names, dup = {}, {}
    for _, file in ipairs({ "bank", "bosses", "downed", "resets", "sharequest", "travel", "uniques", "party", "regen", "combat",
        "strongholds", "vendors", "challenge", "world" }) do
        for name in T.scriptSource(file .. ".lua"):gmatch('registerCommand%("(%w+)"') do
            if names[name] then dup[#dup + 1] = name .. " (" .. names[name] .. " and " .. file .. ")" end
            names[name] = file
        end
    end
    report("C2 no chat command is registered by two modules", #dup == 0, table.concat(dup, ", "))
    local want = { "bank", "vault", "travel", "goto", "party", "giveup", "boss", "sharequest", "unsharequest", "resetinfo", "uniques" }
    local missing = {}
    for _, n in ipairs(want) do if not customCommandHooks.commands[n] then missing[#missing + 1] = n end end
    report("C3 all eleven commands are live under the default settings", #missing == 0, table.concat(missing, ","))
end

-- gui ids ---------------------------------------------------------------
do
    local ids = {}
    local function add(id, who) ids[id] = ids[id] or {}; table.insert(ids[id], who) end
    for _, src in ipairs({ "travel", "sharequest" }) do
        for name, value in T.scriptSource(src .. ".lua"):gmatch("%f[%w_]([%w_%.]*_?ID)%s*=%s*(%d+)") do add(tonumber(value), src .. "." .. name) end
    end
    add(9001, "config.menuHelper"); add(9002, "config.confiscate"); add(9003, "config.recordPrint")
    local okGui, gh = pcall(require, "guiHelper")
    report("G0 guiHelper.lua loads, so its ids are part of the comparison", okGui and type(gh) == "table" and gh.ID ~= nil, gh)
    for k, v in pairs(okGui and gh.ID or {}) do add(v, "guiHelper." .. tostring(k)) end
    -- other modules show no windows
    local others = {}
    for _, m in ipairs({ "bank", "bosses", "challenge", "combat", "downed", "party", "regen", "resets", "strongholds", "uniques",
        "vendors", "world" }) do
        local s = T.scriptSource(m .. ".lua")
        if s:find("ListBox", 1, true) or s:find("CustomMessageBox", 1, true) or s:find("InputDialog", 1, true) then others[#others + 1] = m end
    end
    local clash = {}
    local listing = {}
    for id, who in pairs(ids) do
        listing[#listing + 1] = id .. "=" .. table.concat(who, "+")
        if #who > 1 then clash[#clash + 1] = id .. ": " .. table.concat(who, ", ") end
    end
    table.sort(listing)
    print("# GUI ids in use: " .. table.concat(listing, "; "))
    report("G1 no two windows share an id (travel list, the three sharequest boxes, 9001-9003, guiHelper)", #clash == 0,
        table.concat(clash, " | "))
    report("G2 no other module opens a window", #others == 0, table.concat(others, ","))
    report("G3 the six custom ids are distinct from each other", ids[7340201] and #ids[7340201] == 1 and ids[7340101] and
        ids[7340102] and ids[7340103] and true)
end

-- globals -----------------------------------------------------------------
do
    local before = {}
    local fresh = {}
    T.fresh(T.copy(T.DEFAULT_SETTINGS))
    for k in pairs(_G) do before[k] = _G[k] end
    boot()
    local added, replaced = {}, {}
    for k, v in pairs(_G) do
        if before[k] == nil then added[#added + 1] = tostring(k)
        elseif before[k] ~= v and type(k) == "string" and (k:match("^My") or k:match("^my")) then replaced[#replaced + 1] = tostring(k) end
    end
    table.sort(added)
    print("# globals the modules add: " .. table.concat(added, ", "))
    local foreign = {}
    for _, k in ipairs(added) do
        if not (k:match("^MyTes3mp") or k:match("^myTes3mp") or k == "OnDeathTimeExpiration") then foreign[#foreign + 1] = k end
    end
    report("N1 every global the scripts add is namespaced MyTes3mp*/myTes3mp*", #foreign == 0, table.concat(foreign, ","))
end

-- two players, then every timer, repeatedly, with the clock moving ----------------------
boot()
schedulerReset()
local function sweepAll(label)
    local before = #errors
    local ok, problem = pcall(function()
        for _ = 1, 3 do
            advance(40)
            for id, t in ipairs(T.timers) do
                if t.started then T.fire(id) end
            end
        end
    end)
    report("L5 every timer, three rounds, " .. label .. ": nothing throws", ok, problem)
    report("L6 ... and nothing is logged as an error (the scripts catch their own failures)", #errors == before, errors[before + 1])
end
sweepAll("nobody online")
local alice = login(1, "Alice", "-3, -3", { gold = 400 })
sweepAll("one player")
local bob = login(2, "Bob", "-3, -3", { gold = 400 })
sweepAll("two players")
report("L7 two players are logged in and allied by party.lua",
    has(alice.data.alliedPlayers or {}, "Bob") and has(bob.data.alliedPlayers or {}, "Alice"))
report("L8 both discovered Balmora (the town they stand in) without asking",
    alice.data.customVariables.myTes3mpTravel and alice.data.customVariables.myTes3mpTravel.found["-3, -3"] == true and
    bob.data.customVariables.myTes3mpTravel.found["-3, -3"] == true)

------------------------------------------------------------------ 2. combat gates everything
do
    boot()
    local a = login(1, "Alice", "-3, -3", { gold = 400 })
    local b = login(2, "Bob", "-3, -3", { gold = 400 })
    clearOut()
    live[1].hp = 40
    advance(3)
    fireNamed("MyTes3mpRegenTick")
    local gave = #eventsOf("spells")
    report("K1 hurt and quiet: regeneration gives Alice abilities", gave > 0 and myTes3mpCombat.InCombat(1) == false, gave)
    clearOut()
    hit(1, "-3, -3", {})
    local removed = false
    for _, e in ipairs(eventsOf("spells")) do if e[3] == enumerations.spellbook.REMOVE then removed = true end end
    report("K2 a blow takes the abilities away at once (combat listener)", removed and myTes3mpCombat.InCombat(1))
    clearOut()
    fireNamed("MyTes3mpRegenTick")
    report("K3 and none come back while the fight lasts", #eventsOf("spells") == 0)
    for _, line in ipairs({ "/travel", "/goto Bob", "/bank", "/vault" }) do
        clearOut()
        say(1, line)
        local reply = ""
        for _, m in ipairs(T.msgs) do if m[1] == 1 then reply = reply .. m[2] end end
        report("K4 in combat: '" .. line .. "' is refused (told so, nothing opened, nothing moved)",
            (reply:find("combat") or reply:find("fight")) and #eventsOf("listbox") == 0 and #eventsOf("activate") == 0 and
            #eventsOf("sendcell") == 0, reply)
    end
    report("K5 the refused /bank and /vault created no chest at all", LoadedCells[BANK_CELL] == nil or
        next(LoadedCells[BANK_CELL].data.objectData) == nil)
    report("K5b Bob, not in combat, is not affected by Alice's fight", myTes3mpCombat.InCombat(2) == false)
    -- Bob hit by something: reported by Alice's client as a hit on Bob
    hit(1, "-3, -3", { 2 })
    report("K6 a blow reported against Bob puts Bob in combat too", myTes3mpCombat.InCombat(2))
    advance(11)
    fireNamed("MyTes3mpCombatTick")
    clearOut()
    say(1, "/travel")
    report("K7 ten quiet seconds later /travel works again for Alice", #eventsOf("listbox") == 1 and eventsOf("listbox")[1][3] == 7340201)
    clearOut()
    say(1, "/vault")
    report("K8 ... and /vault", #eventsOf("activate") == 1)
    clearOut()
    live[1].hp = 40
    fireNamed("MyTes3mpRegenTick")
    report("K9 ... and regeneration resumes", #eventsOf("spells") > 0)
end

------------------------------------------------------------------ 3. downed
do
    boot()
    local a = login(1, "Alice", "-3, -3", { gold = 400 })
    local b = login(2, "Bob", "-3, -3", { gold = 400 })
    advance(30)
    clearOut()
    fireNamed("MyTes3mpCombatTick")      -- combat.lua has seen her at full health
    live[1].hp = 30
    fireNamed("MyTes3mpCombatTick")
    death(1)
    fireNamed("MyTes3mpCombatTick")
    report("D1 Alice goes down (Bob is there to help), the stock death is held back",
        myTes3mpDowned.IsDowned(1) and T.timerNamed("OnDeathTimeExpiration") == nil)
    clearOut()
    fireNamed("MyTes3mpRegenTick")
    report("D2 no regeneration for a downed player", #eventsOf("spells") == 0)
    for _, line in ipairs({ "/travel", "/bank", "/vault" }) do
        clearOut()
        say(1, line)
        report("D3 downed: '" .. line .. "' is refused", #eventsOf("listbox") == 0 and #eventsOf("activate") == 0 and
            told(1, "downed"))
    end
    -- the brother comes: /goto
    live[2].cell = "-3, -3"
    clearOut()
    say(2, "/goto Alice")
    report("D4 Bob /goto's the downed Alice: he is teleported to her", #eventsOf("sendcell") == 1 and eventsOf("sendcell")[1][2] == 2)
    clearOut()
    activateBody(2, "-3, -3", 1)
    report("D5 Bob activates the body: resurrect in place, once", #eventsOf("resurrect") == 1 and eventsOf("resurrect")[1][3] == enumerations.resurrect.REGULAR)
    report("D5b Alice is no longer downed and nothing was jailed", not myTes3mpDowned.IsDowned(1) and #eventsOf("jail") == 0)
    resurrected(1, 100)
    fireNamed("MyTes3mpCombatTick")
    advance(3)
    fireNamed("MyTes3mpDownedTick")
    report("D6 a quarter of her health is set once the server has heard she is alive", #eventsOf("sethealth") == 1 and
        eventsOf("sethealth")[1][3] == 25)
    -- the drop from full to 25 looks like damage to combat.lua
    fireNamed("MyTes3mpCombatTick")
    report("D7b ... she regenerates at once", (function() clearOut(); fireNamed("MyTes3mpRegenTick"); return #eventsOf("spells") > 0 end)())
    report("D7c ... and can /travel and /bank at once", (function() clearOut(); say(1, "/travel"); local a1 = #eventsOf("listbox") == 1
        clearOut(); say(1, "/bank"); return a1 and #eventsOf("activate") == 1 end)())
    report("D7 the rescued player is NOT in combat just because her health was set to a quarter (she loses 10 s of regen and /travel)",
        myTes3mpCombat.InCombat(1) == false)
end

do -- nobody comes
    boot()
    login(1, "Alice", "-3, -3"); login(2, "Bob", "-3, -3")
    clearOut()
    death(1)
    advance(59, function() fireNamed("MyTes3mpDownedTick") end)
    report("D8 59 s: still down", myTes3mpDowned.IsDowned(1))
    advance(1, function() fireNamed("MyTes3mpDownedTick") end)
    local timers = 0
    for _, t in ipairs(T.timers) do if t.name == "OnDeathTimeExpiration" then timers = timers + 1 end end
    report("D9 time is up: the stock ProcessDeath ran exactly once", not myTes3mpDowned.IsDowned(1) and timers == 1)
    advance(5, function() fireNamed("MyTes3mpDownedTick") end)
    timers = 0
    for _, t in ipairs(T.timers) do if t.name == "OnDeathTimeExpiration" then timers = timers + 1 end end
    report("D9b ... and not again", timers == 1)
    clearOut()
    say(1, "/travel")
    report("D10 between ProcessDeath and the respawn Alice still cannot travel or bank (dead)", #eventsOf("listbox") == 0)
    T.fire(T.timerNamed("OnDeathTimeExpiration"))
    report("D11 the stock respawn: shrine + jail, as without the script", #eventsOf("resurrect") == 1 and
        eventsOf("resurrect")[1][3] == enumerations.resurrect.IMPERIAL_SHRINE and #eventsOf("jail") == 1)
    resurrected(1, 100)
    clearOut()
    say(1, "/travel")
    report("D12 once the client reports alive, travel works again", #eventsOf("listbox") == 1)
end

do -- the brother dies too / leaves
    boot()
    login(1, "Alice", "-3, -3"); login(2, "Bob", "-3, -3")
    death(1)
    death(2)
    local timers = 0
    for _, t in ipairs(T.timers) do if t.name == "OnDeathTimeExpiration" then timers = timers + 1 end end
    report("D13 Bob dies while Alice is down: Bob takes the stock death at once", not myTes3mpDowned.IsDowned(2) and timers >= 1)
    fireNamed("MyTes3mpDownedTick")
    timers = 0
    for _, t in ipairs(T.timers) do if t.name == "OnDeathTimeExpiration" then timers = timers + 1 end end
    report("D14 and Alice, with nobody left to help, takes it on the next tick (two deaths, not one, not three)",
        not myTes3mpDowned.IsDowned(1) and timers == 2, timers)
end

do -- logging out downed
    boot()
    login(1, "Alice", "-3, -3"); login(2, "Bob", "-3, -3")
    death(1)
    local s = T.diskState("myTes3mpDowned.json")
    report("D15 the debt is written the moment she goes down", s and s.owed and s.owed.alice == true)
    logout(1)
    local s2 = T.diskState("myTes3mpDowned.json")
    report("D16 and survives her logout", s2 and s2.owed and s2.owed.alice == true)
    -- she comes back ALIVE (the saved health was not 0): after downed.debtSeconds the server kills her health
    player(1, "Alice")
    T.auth(1)
    clearOut()
    for _ = 1, 7 do advance(1); fireNamed("MyTes3mpDownedTick") end
    report("D17 owing a death and alive: nothing for 7 s", #eventsOf("sethealth") == 0)
    advance(1); fireNamed("MyTes3mpDownedTick")
    report("D17b at 8 s her health is set to 0 and sent, once", #eventsOf("sethealth") == 1 and eventsOf("sethealth")[1][3] == 0 and
        #eventsOf("statsdynamic") == 1)
    advance(3); fireNamed("MyTes3mpDownedTick")
    report("D17c and not repeated", #eventsOf("sethealth") == 1)
    local function stockTimers() local n = 0 for _, t in ipairs(T.timers) do if t.name == "OnDeathTimeExpiration" then n = n + 1 end end return n end
    local before = stockTimers()
    death(1)           -- her client dies
    report("D18 the death that follows is not a downed state: stock ProcessDeath ran once", not myTes3mpDowned.IsDowned(1) and stockTimers() == before + 1)
    T.fire(T.timerNamed("OnDeathTimeExpiration"))
    resurrected(1, 100)
    report("D19 after the stock resurrect the debt is cleared", T.diskState("myTes3mpDowned.json").owed.alice ~= true)
end

do -- back already dead: nothing extra
    boot()
    login(1, "Alice", "-3, -3"); login(2, "Bob", "-3, -3")
    death(1); logout(1)
    player(1, "Alice"); live[1].hp = 0
    T.auth(1)
    clearOut()
    for _ = 1, 12 do advance(1); fireNamed("MyTes3mpDownedTick") end
    report("D20 back already dead (health 0): the server sends nothing extra", #eventsOf("sethealth") == 0 and #eventsOf("statsdynamic") == 0)
end

do -- /goto as a rescue
    boot()
    login(1, "Alice", "-3, -3"); login(2, "Bob", "-3, -3")
    arrive(2, "1, 1")
    say(1, "/goto Bob")           -- uses up the cooldown
    arrive(1, "-3, -3")
    hit(1, "-3, -3", {})
    clearOut()
    say(1, "/goto Bob")
    report("G4 in combat and on cooldown, Bob standing: refused", #eventsOf("sendcell") == 0)
    death(2)
    clearOut()
    say(1, "/goto Bob")
    report("G5 same for a downed Bob: Alice is teleported (rescue)", #eventsOf("sendcell") == 1 and eventsOf("sendcell")[1][2] == 1)
    -- a downed traveller cannot rescue
    boot()
    login(1, "Alice", "-3, -3"); login(2, "Bob", "-3, -3"); login(3, "Carol", "-3, -3")
    death(1); death(2)
    clearOut()
    say(3, "/goto Alice")
    local ok3 = #eventsOf("sendcell") == 1
    clearOut()
    say(2, "/travel")
    report("G6 a rescuer works; a downed/dead player is told 'downed' or 'dead' and may not travel", ok3 and #eventsOf("listbox") == 0)
    boot()
    login(1, "Alice", "-3, -3"); login(2, "Bob", "-3, -3"); login(3, "Carol", "-3, -3")
    death(1)
    clearOut()
    say(1, "/bank")
    local gotDowned = told(1, "downed")
    clearOut()
    say(1, "/travel")
    report("G7 refusal messages for a downed player say 'downed' (bank and travel)", gotDowned and told(1, "downed"))
end

do -- vendors forget a pid that left
    boot()
    login(1, "Alice", "-3, -3"); login(2, "Bob", "-3, -3")
    local cell = LoadedCells["-3, -3"]
    cell.data.objectData["77-0"] = { refId = "merchant", inventory = { { refId = "ring_a", count = 1, charge = -1, enchantmentCharge = -1, soul = "" } } }
    T.barter(1, "-3, -3", "77-0")
    cell.data.objectData["77-0"].inventory = {}
    advance(20)
    T.barter(2, "-3, -3", "77-0")
    local suppressed = next(cell.data.objectData["77-0"].inventory) == nil
    logout(1)
    advance(20)
    T.barter(2, "-3, -3", "77-0")
    report("V20 Alice opened the barter, Bob is held off while she might still trade; after she leaves he is not",
        suppressed and next(cell.data.objectData["77-0"].inventory) ~= nil)
end

------------------------------------------------------------------ 3b. the Atronach and pid reuse
do
    boot()
    -- The record ids of the thirteen birthsigns in Morrowind.esm (read with a hex dump of the BSGN records):
    -- the Atronach is "Wombburned" ("The Atronach" is its display name). The client reports the record id
    -- (LocalPlayer.cpp:169 getBirthSign(); mwmechanics/mechanicsmanagerimp.cpp:154-159 looks it up by that id).
    local a = login(1, "Alice", "-3, -3")
    local b = login(2, "Bob", "-3, -3")
    live[1].sign = "Wombburned"; a.data.character.birthsign = "Wombburned"
    live[2].sign = "Fay"
    live[1].hp = 30; live[1].mp = 5
    live[2].hp = 30; live[2].mp = 5
    advance(15)
    clearOut()
    fireNamed("MyTes3mpRegenTick")
    local rates = {}
    for _, e in ipairs(eventsOf("spells")) do
        if e[3] == enumerations.spellbook.ADD then
            rates[e[2]] = (rates[e[2]] or "") .. e[4]
        end
    end
    report("S0 the control: a Mage (Fay) gets health and magicka abilities", rates[2] and rates[2]:find("magicka", 1, true) and rates[2]:find("health", 1, true), rates[2])
    report("S1 a character born under the Atronach sign (record id 'Wombburned') gets no magicka ability (regen.lua IsAtronach looks for the word 'atronach' in the id)",
        rates[1] ~= nil and not rates[1]:find("magicka", 1, true), rates[1])
end

do -- the pid of a player who left is reused by the next one: nothing of his must stick
    boot()
    login(1, "Alice", "-3, -3"); login(2, "Bob", "-3, -3")
    live[1].hp = 40
    hit(1, "-3, -3", {})
    death(1)
    say(1, "/vault")
    logout(1)
    login(1, "Carol", "-3, -3")
    clearOut()
    say(1, "/travel")
    local travels = #eventsOf("listbox") == 1
    clearOut()
    say(1, "/bank")
    report("P1 a new player on a reused pid is not in combat, not downed, not dead: /travel and /bank work",
        travels and #eventsOf("activate") == 1 and not myTes3mpDowned.IsDowned(1) and not myTes3mpCombat.InCombat(1))
    report("P2 and gets his own bank, not Alice's", (function()
        local idx = eventsOf("activate")[1] and eventsOf("activate")[1][4]
        return idx ~= nil and myTes3mpBank.OwnerOf(idx) == "carol"
    end)())
end

------------------------------------------------------------------ 4. the vault, artifacts, the storage cell
do
    boot()
    local a = login(1, "Alice", "-3, -3", { gold = 400 })
    local b = login(2, "Bob", "-3, -3", { gold = 400 })
    local ARTIFACT = "claymore_chrysamere_unique"
    local uniqueItems = require("custom/myTes3mp/uniqueItems")
    report("V0 the id used below really is an artifact of uniqueItems.lua", uniqueItems[ARTIFACT] ~= nil)
    clearOut()
    say(1, "/vault")
    local act = eventsOf("activate")
    local chest = act[1] and act[1][4]
    report("V1 /vault creates the chest in the storage cell and tells Alice's client to open it",
        chest ~= nil and act[1][3] == BANK_CELL and act[1][5] == 1, chest)
    report("V1b the storage cell is loaded (permanently) and has no visitor", LoadedCells[BANK_CELL] ~= nil and
        LoadedCells[BANK_CELL]:GetVisitorCount() == 0)
    local placed = eventsOf("place")
    report("V1c the chest creation was broadcast to every client (CreateObjects sends the place packet to everyone, engine fact E3)",
        #placed >= 1 and placed[1][4] == true)
    -- Alice puts the artifact in
    local okPut = container(1, BANK_CELL, ADD, SUB.DROP, chest, { { refId = ARTIFACT, count = 1, actionCount = 0 } })
    report("V2 Alice drops the artifact into the vault: accepted", okPut == true and countOf(BANK_CELL, ARTIFACT) == 1)
    clearOut()
    say(2, "/vault")
    report("V3 Bob opens the same chest", #eventsOf("activate") == 1 and eventsOf("activate")[1][4] == chest)
    local okTake = container(2, BANK_CELL, REMOVE, SUB.DRAG, chest, { { refId = ARTIFACT, count = 1, actionCount = 1 } })
    report("V4 Bob takes it out: allowed (a copy a player handled is nobody's claim)", okTake == true and countOf(BANK_CELL, ARTIFACT) == 0)
    local claims = T.diskState("myTes3mpUniques.json") or {}
    local nClaims = 0
    for _, who in pairs(claims.claims or {}) do for _ in pairs(who) do nClaims = nClaims + 1 end end
    report("V5 no claim was recorded for anybody", nClaims == 0, nClaims)
    local deposits = 0
    for _, c in pairs(claims.deposits or {}) do for _, ch in pairs(c) do for _, n in pairs(ch) do deposits = deposits + n end end end
    report("V6 and the books of artifacts put into containers are back to zero", deposits == 0, deposits)

    -- both have the vault open and reach for the same item
    container(1, BANK_CELL, ADD, SUB.DROP, chest, { { refId = "ring_keen_uniq_fake", count = 1, actionCount = 0 } })
    local first = container(1, BANK_CELL, REMOVE, SUB.DRAG, chest, { { refId = "ring_keen_uniq_fake", count = 1, actionCount = 1 } })
    local second = container(2, BANK_CELL, REMOVE, SUB.DRAG, chest, { { refId = "ring_keen_uniq_fake", count = 1, actionCount = 1 } })
    report("V7 two players take the same single item: the server hands it out once (second request is corrected to nothing)",
        first == true and countOf(BANK_CELL, "ring_keen_uniq_fake") == 0)

    -- someone else's bank
    clearOut()
    say(1, "/bank")
    local bankIndex = eventsOf("activate")[1] and eventsOf("activate")[1][4]
    local refused = container(2, BANK_CELL, ADD, SUB.DROP, bankIndex, { { refId = "gold_001", count = 5, actionCount = 0 } })
    report("V8 Bob cannot change Alice's bank", refused == false and countOf(BANK_CELL, "gold_001") == 0)
    local gone = customEventHooks.triggerValidators("OnObjectDelete", { 2, BANK_CELL, { [chest] = { refId = "mytes3mp_vault_chest" } }, {} })
    report("V9 a client cannot delete the vault chest", gone.validDefaultHandler == false)

    -- the reset code
    local R = myTes3mpResets
    report("V10 the storage cell is on the never-reset list", R.IsKept(BANK_CELL) == true)
    R.Hasten(BANK_CELL, 1)
    advance(5 * 3600)
    local before = T.resetCount()
    -- the reset code only works when a clock has been started for the cell; start one the way a visit would
    customEventHooks.triggerHandlers("OnCellLoad", { validDefaultHandler = true }, { 1, BANK_CELL })
    R.Hasten(BANK_CELL, 1)
    advance(5 * 3600)
    fireNamed("MyTes3mpResetTick")
    local resetOfBank = false
    for _, c in ipairs(T.calls) do if c[1] == "SendCellReset" and c[4]:find(BANK_CELL, 1, true) then resetOfBank = true end end
    report("V11 the storage cell is never reset, also not after Hasten / a visit-start clock / 5 hours", not resetOfBank)
    report("V11b ... and its content survived", countOf(BANK_CELL, "gold_001") == 0 and LoadedCells[BANK_CELL] ~= nil and
        LoadedCells[BANK_CELL]:ContainsObject(chest))
    local stash = R.HasStash(BANK_CELL)
    print("# resets.HasStash(storage cell) after vault drops = " .. tostring(stash) ..
        " (informational: IsKept comes first in Sweep and Info, so nobody asks)")
    clearOut()
    local errorsBefore = #errors
    fireNamed("MyTes3mpChallengeTick")
    report("V12 challenge.lua's tick leaves the storage cell alone (no authority, no command, no error)",
        #T.cmds == 0 and #errors == errorsBefore)
    report("V13 /resetinfo, run by a player in an ordinary cell, does not mention a stash problem", (function()
        clearOut(); say(1, "/resetinfo"); return not toldAnyone("stash") end)())
end

------------------------------------------------------------------ 5. travel next to boss, challenge, resets
local function hubOf(name)
    local points = dofile(T.scriptsDir .. "/travelPoints.lua")
    for _, p in ipairs(points) do if p.name == name then return p end end
end
do
    boot()
    local B = package.loaded["custom/myTes3mp/bosses"]
    local balmora = hubOf("Balmora")
    local a = login(1, "Alice", "1, 1", { gold = 400, level = 5 })     -- somewhere in the wilderness
    local b = login(2, "Bob", "1, 1", { gold = 400, level = 5 })
    -- Alice has seen Balmora before
    a.data.customVariables.myTes3mpTravel = { found = { [balmora.cell] = true } }
    B.random = function(x, y) if x == nil then return 0 end; return 1 end
    -- make Balmora the only choice
    B.State().lastHub = nil
    local oldHubs = B.LoadHubs()
    local only = {}
    for _, h in ipairs(oldHubs) do if h.name == "Balmora" then only[1] = h end end
    package.loaded["custom/myTes3mp/travelPoints"] = only
    B.LoadHubs()
    package.loaded["custom/myTes3mp/travelPoints"] = nil
    clearOut()
    local ok = B.Spawn()
    local boss = B.State().boss
    report("B1 a boss spawns at Balmora (tier chosen for level 1)", ok and boss and boss.cell == balmora.cell and boss.refId == "myt_boss_1", boss and boss.cell)
    report("B1b the creature record was defined and sent to the players who are online", stores.creature.data.permanentRecords.myt_boss_1 ~= nil)
    report("B1c the spawn went to every client (SendObjectSpawn(true))", #eventsOf("spawn") == 1 and eventsOf("spawn")[1][4] == true)
    report("B1d announced to everybody once", countMsgs("A world boss has appeared") == 1 and T.msgs[#T.msgs][3] == true)
    local uniqueItems = require("custom/myTes3mp/uniqueItems")
    local clash = {}
    for n = 1, #B.tiers do
        if uniqueItems[B.RecordId(n):lower()] then clash[#clash + 1] = B.RecordId(n) end
        if uniqueItems[B.tiers[n].base:lower()] then clash[#clash + 1] = B.tiers[n].base end
    end
    report("B2 boss creature ids and their base creatures are not in uniqueItems.lua", #clash == 0, table.concat(clash, ","))

    -- Alice travels there, free of the usual surprises
    clearOut()
    say(1, "/travel")
    local lb = eventsOf("listbox")[1]
    report("B3 Alice (wilderness) is offered Balmora and told it costs gold", lb ~= nil and lb[4]:find("costs 10 gold", 1, true) ~= nil or
        (lb ~= nil and lb[4]:find("costs 50 gold", 1, true) ~= nil), lb and lb[4])
    local goldBefore = goldOf(1)
    local lines = {}
    for line in lb[5]:gmatch("[^\n]+") do lines[#lines + 1] = line end
    local index
    for i, l in ipairs(lines) do if l == "Balmora" then index = i - 1 end end
    clearOut()
    gui(1, 7340201, index)
    report("B4 she pays and the server asks her client to go there", #eventsOf("sendcell") == 1 and goldOf(1) == goldBefore - 50, goldOf(1))
    local removals = 0
    for _, c in ipairs(a.calls) do if type(c) == "table" and c[1] == "items" and c[3] == enumerations.inventory.REMOVE then removals = removals + c[2][1].count end end
    report("B4b server record and what the client was told to remove agree (50: ten per level)", removals == 50, removals)
    arrive(1, balmora.cell)
    -- the cell has one actor: the boss, at full health, as reported by Alice's client
    local ui = boss.uniqueIndex
    local n = tonumber(ui:match("^%d+%-(%d+)$"))
    T.actors[balmora.cell] = { { refNum = 0, mpNum = n, base = 220, current = 220 } }
    for _ = 1, 3 do fireNamed("MyTes3mpChallengeTick") end
    local sethealth = {}
    for _, c in ipairs(T.cmds) do if c.ids[1] == ui then sethealth[#sethealth + 1] = c.cmd end end
    report("B5 challenge.lua toughens the boss exactly once", #sethealth == 1, table.concat(sethealth, ";"))
    local solo = sethealth[1]
    report("B5b the boss's health is fixed by whoever is in the cell when challenge.lua first sees it: Alice alone -> 220 x 1.7 = 374 " ..
        "(a boss 'meant for two' is about a third weaker whenever the brothers do not arrive within one 5 s tick)", solo == "SetHealth 374", solo)
    -- Bob follows with /goto
    clearOut()
    say(2, "/goto Alice")
    arrive(2, balmora.cell)
    report("B6 Bob /goto's Alice; both are in the boss's cell", LoadedCells[balmora.cell]:GetVisitorCount() == 2)
    for _ = 1, 3 do fireNamed("MyTes3mpChallengeTick") end
    local after = 0
    for _, c in ipairs(T.cmds) do if c.ids[1] == ui then after = after + 1 end end
    report("B6b the boss is not toughened a second time for the second player", after == 1, after)

    -- Bob is in a NEIGHBOUR cell (not in the town) when it dies
    arrive(2, "-4, -3")
    clearOut()
    -- Alice is the one fighting it. (Reporting the death earns nothing by itself.)
    myTes3mpCombat.Mark(1)
    actorDeath(1, balmora.cell, ui, "myt_boss_1")
    report("B7 the boss dies: Alice rewarded once", itemCount(1, "gold_001") == goldBefore - 50 + 250, itemCount(1, "gold_001"))
    report("B7b Bob, one cell away, never fought: no reward",
        itemCount(2, "gold_001") == 400, itemCount(2, "gold_001"))
    actorDeath(1, balmora.cell, ui, "myt_boss_1")
    report("B7c a second report of the same death rewards nobody again", itemCount(1, "gold_001") == goldBefore - 50 + 250)
end

do -- the cell's authority is a bystander one cell away: he reports the death but did not fight
    boot()
    local B = package.loaded["custom/myTes3mp/bosses"]
    local balmora = hubOf("Balmora")
    local b = login(2, "Bob", "-4, -3", { level = 5 })      -- his grid loads Balmora first: he is its authority
    local a = login(1, "Alice", "-3, -3", { level = 5 })
    package.loaded["custom/myTes3mp/travelPoints"] = { balmora }
    B.LoadHubs()
    package.loaded["custom/myTes3mp/travelPoints"] = nil
    B.random = function(x, y) if x == nil then return 0 end; return 1 end
    B.Spawn()
    local ui = B.State().boss.uniqueIndex
    hit(1, "-3, -3", {})
    actorDeath(2, "-3, -3", ui, "myt_boss_1")
    report("B7d the authority is Bob (not the fighter)", LoadedCells["-3, -3"]:GetAuthority() == 2)
    report("B7e Bob, a cell away, never fought but reported the death as authority: no reward", itemCount(2, "gold_001") == 0, itemCount(2, "gold_001"))
end

do -- both in the town; reward once each; no reward by relogging
    boot()
    local B = package.loaded["custom/myTes3mp/bosses"]
    local a = login(1, "Alice", "-3, -3", { level = 5 }); local b = login(2, "Bob", "-3, -3", { level = 5 })
    local balmora = hubOf("Balmora")
    local only = { balmora }
    package.loaded["custom/myTes3mp/travelPoints"] = only
    B.LoadHubs()
    package.loaded["custom/myTes3mp/travelPoints"] = nil
    B.random = function(x, y) if x == nil then return 0 end; return 1 end
    B.Spawn()
    local boss = B.State().boss
    local n = tonumber(boss.uniqueIndex:match("^%d+%-(%d+)$"))
    T.actors["-3, -3"] = { { refNum = 0, mpNum = n, base = 220, current = 220 } }
    fireNamed("MyTes3mpChallengeTick")
    local cmd = T.cmds[#T.cmds] and T.cmds[#T.cmds].cmd
    report("B8 both players there from the start: boss health set for two, 220 x 1.7 x 1.5 = 561 -> " .. tostring(cmd),
        cmd == "SetHealth 561", cmd)
    clearOut()
    hit(1, "-3, -3", {}); hit(2, "-3, -3", {})
    actorDeath(1, "-3, -3", boss.uniqueIndex, "myt_boss_1")
    report("B9 both (who fought) rewarded once each", itemCount(1, "gold_001") == 250 and itemCount(2, "gold_001") == 250,
        itemCount(1, "gold_001") .. "/" .. itemCount(2, "gold_001"))
    -- the corpse goes after 90 s
    advance(91)
    fireNamed("MyTes3mpBossTick")
    local deleted = eventsOf("delete")
    report("B10 the body is removed after 90 s for everybody", #deleted == 1, #deleted)
    -- relog for a second reward
    logout(2)
    login(2, "Bob", "-3, -3", { level = 5 })
    local goldAfterRelog = itemCount(2, "gold_001")   -- a fresh player object: the test does not persist inventories
    actorDeath(1, "-3, -3", boss.uniqueIndex, "myt_boss_1")
    report("B11 relogging and replaying the death gives nothing", itemCount(2, "gold_001") == goldAfterRelog)
end

do -- the boss versus the reset clock (resets.lua) and uniques.lua's Hasten
    boot()
    local B = package.loaded["custom/myTes3mp/bosses"]
    local R = myTes3mpResets
    local a = login(1, "Alice", "-3, -3", { level = 5 }); local b = login(2, "Bob", "-3, -3", { level = 5 })
    local balmora = hubOf("Balmora")
    package.loaded["custom/myTes3mp/travelPoints"] = { balmora }
    B.LoadHubs()
    package.loaded["custom/myTes3mp/travelPoints"] = nil
    B.random = function(x, y) if x == nil then return 0 end; return 1 end
    -- Balmora was visited 3 h 50 min ago; both are away from it now
    arrive(1, "10, 10"); arrive(2, "10, 10")
    -- the clock for -3,-3 was started by the first visit: due in 4 h
    advance(3 * 3600 + 50 * 60)
    clearOut()
    B.Spawn()
    fireNamed("MyTes3mpResetTick")   -- not due yet
    report("R1 right after the spawn the boss is there", B.State().boss ~= nil)
    advance(11 * 60)
    fireNamed("MyTes3mpResetTick")   -- now the cell is due and nobody is in it
    report("R2 a boss that has just been announced is NOT wiped by the reset clock of the cell it stands in" ..
        " (a cell visited before the spawn carries its old clock; the boss lives 2 h, the clock may run out in minutes)",
        B.State().boss ~= nil, "boss departed: " .. tostring(toldAnyone("has left")))
end

do -- Hasten from uniques.lua: a claimed artifact in the boss's town
    boot()
    local B = package.loaded["custom/myTes3mp/bosses"]
    local R = myTes3mpResets
    login(1, "Alice", "-3, -3", { level = 5 }); login(2, "Bob", "-3, -3", { level = 5 })
    local balmora = hubOf("Balmora")
    package.loaded["custom/myTes3mp/travelPoints"] = { balmora }
    B.LoadHubs()
    package.loaded["custom/myTes3mp/travelPoints"] = nil
    B.random = function(x, y) if x == nil then return 0 end; return 1 end
    B.Spawn()
    -- Alice is still in town; nothing can reset while she is there
    R.Hasten("-3, -3", 30 * 60)
    advance(31 * 60)
    fireNamed("MyTes3mpResetTick")
    report("R3 while somebody has the cell loaded, a hastened reset does not touch the boss", B.State().boss ~= nil)
    arrive(1, "10, 10"); arrive(2, "10, 10")
    fireNamed("MyTes3mpResetTick")
    report("R4 both leave; the hastened reset is due: the boss's cell is held, the boss is still there", B.State().boss ~= nil and
        not (function() for _, c in ipairs(T.calls) do if c[1] == "SendCellReset" and c[4]:find("-3, -3", 1, true) then return true end end end)())
    -- a holder that throws must not break the sweep
    table.insert(R.holders, 1, function() error("holder broke") end)
    arrive(1, "5, 5"); arrive(2, "5, 5")
    arrive(1, "10, 10"); arrive(2, "10, 10")
    advance(5 * 3600)
    B.State().boss.expiresAt = T.time + 99999
    fireNamed("MyTes3mpResetTick")
    local resetFive = false
    for _, c in ipairs(T.calls) do if c[1] == "SendCellReset" and c[4]:find("5, 5", 1, true) then resetFive = true end end
    report("R5 a throwing holder is ignored: another due cell is still reset, nothing logged as error", resetFive and #errors == 0, errors[1])
    -- the boss dies: the cell resets on a later sweep
    table.remove(R.holders, 1)
    local ui = B.State().boss.uniqueIndex
    login(1, "Alice", "-3, -3", { level = 5 }); hit(1, "-3, -3", {})
    actorDeath(1, "-3, -3", ui, "myt_boss_1")
    arrive(1, "10, 10")
    advance(120)
    fireNamed("MyTes3mpResetTick")
    local resetBalmora = false
    for _, c in ipairs(T.calls) do if c[1] == "SendCellReset" and c[4]:find("-3, -3", 1, true) then resetBalmora = true end end
    report("R6 once the boss is dead the cell is reset on a later sweep", resetBalmora)
end

------------------------------------------------------------------ 6. a shared quest next to the stronghold helper
do
    boot()
    local a = login(1, "Alice", "-3, -3"); local b = login(2, "Bob", "-3, -3")
    local function entry(q, i) return { type = ENTRY, quest = q, index = i, actorRefId = "x", timestamp = { daysPassed = 1, month = 1, day = 1 } } end
    local function client(pid, items)
        local packet = { journal = items }
        local status = customEventHooks.triggerValidators("OnPlayerJournal", { pid, packet })
        if status.validDefaultHandler and config.shareJournal ~= true then Players[pid]:SaveJournal(packet) end
        customEventHooks.triggerHandlers("OnPlayerJournal", status, { pid, packet })
    end
    client(1, { entry("HH_Stronghold", 10), entry("MS_FargothRing", 10), entry("MS_FargothRing", 20) })
    clearOut()
    say(1, "/sharequest HH_Stronghold")
    report("Q1 a stronghold quest is refused when named", #eventsOf("msgbox") == 0 and told(1, "cannot be shared"))
    clearOut()
    say(1, "/sharequest")
    local lb = eventsOf("listbox")[1]
    report("Q2 the pick list does not offer it either", lb ~= nil and not lb[5]:find("Stronghold", 1, true) and lb[5]:find("MS_FargothRing", 1, true) ~= nil)
    clearOut()
    gui(1, 7340101, 0)
    local box = eventsOf("msgbox")[1]
    report("Q3 picking the ordinary quest asks Bob (yes/no box 7340102)", box ~= nil and box[2] == 2 and box[3] == 7340102)
    clearOut()
    local sentCmds = #T.sent
    gui(2, 7340102, 0)
    report("Q4 Bob says yes: he gets the entries", #eventsOf("journal") == 1 and #eventsOf("journal")[1][3] == 2)
    -- the shared quest triggers no stronghold work
    for _ = 1, 3 do advance(61); fireNamed("MyTes3mpStrongholdTick") end
    report("Q5 the stronghold helper sends no console command because of a shared ordinary quest", #T.sent == sentCmds, #T.sent)
    clearOut()
    client(1, { entry("MS_FargothRing", 30) })
    report("Q6 a new entry of Alice's is passed to Bob once", #eventsOf("journal") == 1)
    -- a stronghold report from Alice is still strongholds.lua's business and is not relayed
    clearOut()
    client(1, { { type = ENTRY, quest = "HH_Stronghold", index = 50, actorRefId = "x", timestamp = { daysPassed = 1, month = 1, day = 1 } } })
    report("Q7 a stronghold entry is not relayed", #eventsOf("journal") == 0)
    -- the stronghold helper still sees Alice's own stronghold quest (OnPlayerJournal of strongholds.lua) ...
    local notes = a.data.customVariables.myTes3mpStrongholds
    report("Q8 ... the stronghold helper noted Alice's waiting stage 50 on its own", notes and notes.hh_stronghold and notes.hh_stronghold.index == 50)
    -- ... and Bob, who never had that quest, has none of it
    local bobHas = false
    for _, item in pairs(b.data.journal) do if item.quest:lower() == "hh_stronghold" then bobHas = true end end
    report("Q9 Bob has no stronghold entry, and the helper noted nothing for him", not bobHas and not (b.data.customVariables.myTes3mpStrongholds and
        next(b.data.customVariables.myTes3mpStrongholds)))
    -- a 'No' to the box gives nothing
    client(1, { entry("MS_Other", 5) })
    clearOut()
    say(1, "/sharequest MS_Other")
    gui(2, 7340102, 1)
    local bobGotOther = false
    for _, item in pairs(b.data.journal) do if item.quest:lower() == "ms_other" then bobGotOther = true end end
    report("Q10 Bob answers No: he gets nothing and Alice is told", not bobGotOther and told(1, "does not want to share"))
end

------------------------------------------------------------------ 6b. a server restart in the middle of it all
do
    boot()
    local a = login(1, "Alice", "-3, -3", { gold = 100, level = 5 }); login(2, "Bob", "-3, -3", { level = 5 })
    say(1, "/vault")
    local chest = eventsOf("activate")[1][4]
    container(1, BANK_CELL, ADD, SUB.DROP, chest, { { refId = "gold_001", count = 77, actionCount = 0 } })
    local B = package.loaded["custom/myTes3mp/bosses"]
    local balmora = hubOf("Balmora")
    package.loaded["custom/myTes3mp/travelPoints"] = { balmora }
    B.LoadHubs()
    package.loaded["custom/myTes3mp/travelPoints"] = nil
    B.Spawn()
    local bossIndex = B.State().boss.uniqueIndex
    death(1)
    -- (the cell file and the world's counter survive; players do not)
    local disk, now = T.disk, T.time
    boot({ keepDisk = true })
    local errs = #errors
    login(2, "Bob", "-3, -3")
    clearOut()
    say(2, "/vault")
    report("X1 after a restart the vault is the same chest, with the same content",
        eventsOf("activate")[1] and eventsOf("activate")[1][4] == chest and countOf(BANK_CELL, "gold_001") == 77)
    local B2 = package.loaded["custom/myTes3mp/bosses"]
    report("X2 the boss that was abroad is still the boss (state file) and a second one is not made",
        B2.State().boss and B2.State().boss.uniqueIndex == bossIndex)
    report("X3 the downed player's debt survived", T.diskState("myTes3mpDowned.json").owed.alice == true)
    report("X4 no error logged by the restart", #errors == errs, errors[1])
end

------------------------------------------------------------------ 7. the cost of it all
do
    boot()
    local a = login(1, "Alice", "-3, -3", { gold = 400 }); local b = login(2, "Bob", "-3, -3", { gold = 400 })
    -- ~30 loaded cells, a few with actors, the storage cell
    local cells = {}
    for x = -5, 0 do for y = -5, -1 do cells[#cells + 1] = x .. ", " .. y end end
    for _, c in ipairs(cells) do
        if LoadedCells[c] == nil then T.visit(1, c); loadedBy[1] = loadedBy[1] or {}; loadedBy[1][c] = true end
    end
    local n = 0
    for _ in pairs(LoadedCells) do n = n + 1 end
    say(1, "/vault"); -- the storage cell is loaded permanently
    n = 0
    for _ in pairs(LoadedCells) do n = n + 1 end
    print("# loaded cells in the cost run: " .. n)
    -- every loaded cell has an authority and three enemies at full health, so challenge.lua has work
    local k = 0
    for cell, c in pairs(LoadedCells) do
        if cell ~= BANK_CELL then
            T.actors[cell] = {}
            for e = 1, 3 do
                k = k + 1
                c.data.objectData[(100 + k) .. "-0"] = { refId = "scamp" }
                table.insert(T.actors[cell], { refNum = 100 + k, mpNum = 0, base = 50, current = 50 })
            end
        end
    end
    local function census(title, seconds)
        schedulerReset()
        T.msgs = {}; counts = {}; writes = {}
        runClock(seconds)
        local rows = {}
        for id, s in pairs(sched) do
            local t = T.timers[id]
            local st = s.stats or { calls = 0 }
            local extra = {}
            for key, v in pairs(st) do if key ~= "calls" and key ~= "json" and v ~= 0 then extra[#extra + 1] = key .. "=" .. v end end
            table.sort(extra)
            rows[#rows + 1] = string.format("%-26s every %3ds  calls %4d  json writes %3d  sent %s", t.name, s.every,
                st.calls, st.json or 0, table.concat(extra, " "))
        end
        table.sort(rows)
        print("# timer census, " .. title .. " (" .. seconds .. " s, 2 players, " .. n .. " cells loaded, 93 enemies):")
        for _, r in ipairs(rows) do print("#   " .. r) end
        return rows
    end
    live[1].hp = 60; live[2].hp = 60
    local firstRows = census("first five seconds: every enemy is met", 5)
    local rows = census("steady state", 300)
    local ticks = 0
    for _, r in ipairs(rows) do ticks = ticks + 1 end
    report("W1 the census ran", ticks >= 7, ticks)
    report("W2 no error logged during five simulated minutes with two players and ~30 cells", #errors == 0, errors[1])
end

T.summary()
