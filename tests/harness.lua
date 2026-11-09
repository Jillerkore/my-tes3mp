-- Shared bootstrap for the my-tes3mp test suites. See README.md.
--
-- Loads the REAL CoreScripts modules (cell, world, jsonInterface, tableHelper,
-- inventoryHelper, customEventHooks, ...) and fakes only what the C++ server
-- provides (`tes3mp`), plus the disk, the clock, players and a few logicHandler
-- functions. Everything that touches files goes to an in-memory disk.
--
-- Paths come from the environment, set by run.sh:
--   MYT_REPO          the my-tes3mp checkout (default: the parent of this directory)
--   MYT_CORESCRIPTS   the CoreScripts checkout at the pinned commit (required)

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$") or "."
local repo = os.getenv("MYT_REPO") or (here .. "/..")
local cs = os.getenv("MYT_CORESCRIPTS")
assert(cs and cs ~= "", "MYT_CORESCRIPTS is not set; run the suite through tests/run.sh")

local unpack = table.unpack or unpack

local T = { repo = repo, scriptsDir = repo .. "/docker/custom/myTes3mp", cs = cs, here = here }

package.path = cs .. "/scripts/?.lua;" .. cs .. "/lib/lua/?.lua;" .. here .. "/?.lua;" .. package.path

------------------------------------------------------------------ reading CoreScripts / script sources
function T.csSource(rel)
    local f = assert(io.open(cs .. "/scripts/" .. rel, "r"), "cannot read " .. rel)
    local text = f:read("*a"); f:close(); return text
end
function T.scriptSource(name)
    local f = assert(io.open(T.scriptsDir .. "/" .. name, "r"), "cannot read " .. name)
    local text = f:read("*a"); f:close(); return text
end

------------------------------------------------------------------ reporting
T.checks, T.failures = 0, 0
function T.report(name, ok, detail)
    T.checks = T.checks + 1
    if not ok then T.failures = T.failures + 1 end
    print((ok and "PASS " or "FAIL ") .. name .. (detail ~= nil and ("  -- " .. tostring(detail)) or ""))
end
function T.summary()
    print(("\n%d checks, %d fail"):format(T.checks, T.failures))
    os.exit(T.failures == 0 and 0 or 1)
end
function T.copy(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = deepcopy(x) end
    return c
end

------------------------------------------------------------------ real CoreScripts modules
function doesModuleExist() return false end -- use dkjson only (cjson is a C module)
_G.class = require("classy")
require("utils")
_G.tableHelper = require("tableHelper")
_G.fileHelper = require("fileHelper")
_G.time = require("time")
_G.enumerations = require("enumerations")
_G.color = require("color")
package.loaded.contentFixer = { FixCell = function() end } -- quest fixes for cells: not under test
_G.contentFixer = package.loaded.contentFixer

T.disk = {}
T.json = require("dkjson")
T.calls, T.msgs, T.log, T.timers, T.sent, T.cmds, T.containerSets = {}, {}, {}, {}, {}, {}, {}
T.time = 1700000000
os.time = function() return T.time end

local function noop() end
_G.tes3mp = setmetatable({}, { __index = function() return noop end })
local tm = tes3mp
function tm.GetDataPath() return "/data" end
tm.LogMessage = function(_, m) T.log[#T.log + 1] = m end
tm.LogAppend = noop
tm.GetCaseInsensitiveFilename = function(dir, name)
    local want = (dir .. name):lower()
    for p in pairs(T.disk) do
        if ("/data/" .. p):lower() == want then return ("/data/" .. p):sub(#dir + 1) end
    end
    return "invalid"
end
tm.SendMessage = function(pid, msg) T.msgs[#T.msgs + 1] = { pid, msg } end

_G.config = require("config")
config.dataPath = "/data"
T.configDefaults = deepcopy(config)

-- timers: both CreateTimer and CreateTimerEx; the type string is checked
-- the way the server does (callback must be a global function)
tm.CreateTimer = function(name, ms)
    assert(type(name) == "string" and _G[name], "timer callback must be a global function: " .. tostring(name))
    T.timers[#T.timers + 1] = { name = name, ms = ms, args = {}, restarts = 0 }
    return #T.timers
end
tm.CreateTimerEx = function(name, ms, types, ...)
    local args = { ... }
    assert(type(name) == "string" and _G[name], "timer callback must be a global function: " .. tostring(name))
    assert(#types == select("#", ...), "type string length must match the arguments")
    for k = 1, #types do
        local t = types:sub(k, k)
        if t == "i" then assert(type(args[k]) == "number", "argument " .. k .. " must be a number")
        elseif t == "s" then assert(type(args[k]) == "string", "argument " .. k .. " must be a string")
        else error("unsupported timer argument type " .. t) end
    end
    T.timers[#T.timers + 1] = { name = name, ms = ms, types = types, args = args, restarts = 0 }
    return #T.timers
end
tm.StartTimer = function(id) T.timers[id].started = true end
tm.RestartTimer = function(id) T.timers[id].restarts = T.timers[id].restarts + 1 end
-- T.sent: console commands run on a player; T.cmds: console commands run on objects.
-- Run a timer's callback once, as the server would when it elapses.
function T.fire(id)
    local t = T.timers[id]
    t.fired = (t.fired or 0) + 1
    return _G[t.name](unpack(t.args))
end
function T.timerNamed(name)
    for id, t in ipairs(T.timers) do if t.name == name then return id, t end end
end

-- cell reset notices
tm.ClearCellsToReset = function() T.cellsToReset = {} end
tm.AddCellToReset = function(c) table.insert(T.cellsToReset, c) end
tm.SendCellReset = function(pid, others)
    T.calls[#T.calls + 1] = { "SendCellReset", pid, others, table.concat(T.cellsToReset, "|") }
end

-- the received object list (what the client sent), for the real SaveContainers
tm.GetObjectListOrigin = function() return 0 end
tm.GetObjectListAction = function() return T.packet.action end
tm.GetObjectListContainerSubAction = function() return T.packet.sub end
tm.GetObjectListSize = function() return #T.packet.objects end
tm.GetObjectRefNum = function(i) return T.packet.objects[i + 1].refNum end
tm.GetObjectMpNum = function(i) return T.packet.objects[i + 1].mpNum or 0 end
tm.GetObjectRefId = function(i) return T.packet.objects[i + 1].refId end
tm.GetContainerChangesSize = function(i) return #T.packet.objects[i + 1].items end
tm.GetContainerItemRefId = function(o, i) return T.packet.objects[o + 1].items[i + 1].refId end
tm.GetContainerItemCount = function(o, i) return T.packet.objects[o + 1].items[i + 1].count end
tm.GetContainerItemCharge = function() return -1 end
tm.GetContainerItemEnchantmentCharge = function() return -1 end
tm.GetContainerItemSoul = function() return "" end
tm.GetContainerItemActionCount = function(o, i) return T.packet.objects[o + 1].items[i + 1].actionCount or 0 end
-- the object list being built for sending
tm.ClearObjectList = function() T.objstates = {} end
tm.SetObjectListPid = function(pid) T.listPid = pid end
tm.SetObjectRefNum = function(n) T.cur = { refNum = n } end
tm.SetObjectMpNum = function(n) T.cur.mpNum = n end
tm.SetObjectRefId = function(n) T.cur.refId = n end
tm.SetObjectState = function(s) T.cur.state = s end
tm.AddObject = function() T.objstates[#T.objstates + 1] = T.cur end
tm.SendObjectState = function() T.calls[#T.calls + 1] = { "SendObjectState", #T.objstates } end
-- LoadContainers (server -> client SET) calls SendContainer() with no arguments;
-- SaveContainers' echo to the players passes arguments. Only the first is recorded (T.containerSets).
tm.SendContainer = function(...)
    if select("#", ...) == 0 then T.containerSets[#T.containerSets + 1] = { pid = T.listPid } end
end

-- what the C++ server holds about a cell's actors: T.actors[cell] = { {refNum, mpNum, base, current} }
T.actors = {}
tm.ReadCellActorList = function(desc) T.actorCell = desc end
tm.GetActorListSize = function() return #(T.actors[T.actorCell] or {}) end
tm.GetActorRefNum = function(i) return T.actors[T.actorCell][i + 1].refNum end
tm.GetActorMpNum = function(i) return T.actors[T.actorCell][i + 1].mpNum or 0 end
tm.DoesActorHaveStatsDynamic = function(i) return true end
tm.GetActorHealthBase = function(i) return T.actors[T.actorCell][i + 1].base end
tm.GetActorHealthCurrent = function(i) return T.actors[T.actorCell][i + 1].current end
tm.GetActorHealthModified = function(i) return T.actors[T.actorCell][i + 1].base end
tm.GetActorMagickaBase = function() return 0 end
tm.GetActorMagickaCurrent = function() return 0 end
tm.GetActorMagickaModified = function() return 0 end
tm.GetActorFatigueBase = function() return 0 end
tm.GetActorFatigueCurrent = function() return 0 end
tm.GetActorFatigueModified = function() return 0 end

------------------------------------------------------------------ logicHandler (only what is needed)
_G.logicHandler = {
    IsGeneratedRecord = function() return false end,
    GetChatName = function(pid) return "p" .. tostring(pid) end,
}
-- LoadCell / UnloadCell: copied from CoreScripts logicHandler.lua (the real module needs the whole server)
logicHandler.LoadCell = function(d)
    if LoadedCells[d] == nil then
        LoadedCells[d] = Cell(d)
        if LoadedCells[d]:HasEntry() then LoadedCells[d]:LoadFromDrive() else LoadedCells[d]:CreateEntry() end
    else
        LoadedCells[d]:SaveActorPositions(); LoadedCells[d]:SaveActorStatsDynamic()
    end
end
logicHandler.UnloadCell = function(d)
    if LoadedCells[d] ~= nil then LoadedCells[d]:SaveToDrive(); LoadedCells[d] = nil end
end

-- fake io library over T.disk, installed into the real jsonInterface
local ioLib = { open = function(path, mode)
    local rel = path:gsub("^/data/", "")
    if mode == "r" then
        local text = T.disk[rel]
        if not text then
            for p, v in pairs(T.disk) do if p:lower() == rel:lower() then text = v end end
        end
        if not text then return nil end
        return { read = function() return text end, close = noop }
    end
    local buf = {}
    return { write = function(_, s) buf[#buf + 1] = s end, close = function() T.disk[rel] = table.concat(buf) end }
end }
_G.jsonInterface = require("jsonInterface")
jsonInterface.setLibrary(ioLib)

_G.packetBuilder = require("packetBuilder")
_G.inventoryHelper = require("inventoryHelper")

function T.freshHooks()
    package.loaded["customEventHooks"] = nil
    package.loaded["customCommandHooks"] = nil
    _G.customEventHooks = require("customEventHooks")
    _G.customCommandHooks = require("customCommandHooks")
end
T.freshHooks()
require("cell.base")
_G.Cell = require("cell.json")

------------------------------------------------------------------ the scripts under test
local MODULES = { "world", "party", "combat", "strongholds", "resets", "challenge", "vendors", "uniques",
    "regen", "downed", "travel", "bank", "sharequest", "bosses",
    "uniqueItems", "startupRefs", "travelPoints" }

T.DEFAULT_SETTINGS = { progression = "separate", strongholdHelper = true, cellResetHours = 4, cellResetKeep = {},
    dayMinutes = 10, party = true, challenge = "hard", vendorGoldMinutes = 1, vendorStockSeconds = 15,
    uniqueClaims = true, uniqueRespawnMinutes = 30, regen = true, downedSeconds = 60, travel = true, bank = true,
    shareQuests = true, worldBossHours = 3 }

local function installModules(settings)
    for _, n in ipairs(MODULES) do
        package.loaded["custom/myTes3mp/" .. n] = nil
        package.preload["custom/myTes3mp/" .. n] = function() return dofile(T.scriptsDir .. "/" .. n .. ".lua") end
    end
    package.preload["custom/myTes3mp/settings"] = nil
    package.loaded["custom/myTes3mp/settings"] = settings
end

-- Replace some modules by do-nothing stand-ins (used to test init.lua).
function T.stubModules(loaded, order, names)
    for _, n in ipairs(names) do
        package.loaded["custom/myTes3mp/" .. n] = nil
        package.preload["custom/myTes3mp/" .. n] = function()
            loaded[n] = true; order[#order + 1] = n; return {}
        end
    end
end

-- Load one of the scripts under test, as the server's `require` would, and
-- return its module table.
function T.load(name)
    local m = dofile(T.scriptsDir .. "/" .. name .. ".lua")
    package.loaded["custom/myTes3mp/" .. name] = m
    return m
end
function T.postInit()
    customEventHooks.triggerHandlers("OnServerPostInit", { validDefaultHandler = true }, {})
end

-- A clean server: empty disk, no players, no cells, pristine config, a fake
-- world clock. `opts.day` / `opts.night` set the time scales.
function T.fresh(settings, opts)
    opts = opts or {}
    T.disk = {}
    T.calls, T.msgs, T.log, T.timers, T.sent, T.cmds, T.containerSets = {}, {}, {}, {}, {}, {}, {}
    T.actors, T.packet, T.objstates = {}, nil, {}
    T.time = 1700000000
    T.freshHooks()
    for k in pairs(config) do config[k] = nil end
    for k, v in pairs(deepcopy(T.configDefaults)) do config[k] = v end
    config.dataPath = "/data"
    LoadedCells, Players = {}, {}
    myTes3mpResets, myTes3mpCombat, myTes3mpDowned = nil, nil, nil
    for name in pairs(_G) do
        if type(name) == "string" and name:match("^MyTes3mp") then _G[name] = nil end
    end
    _G.WorldInstance = { data = { time = { dayTimeScale = opts.day or 144, nightTimeScale = opts.night or 144,
        daysPassed = 1, hour = 9 }, journal = {}, customVariables = {} }, coreVariables = {} }
    function WorldInstance:QuicksaveToDrive() T.worldSaves = (T.worldSaves or 0) + 1 end
    local store = { data = { permanentRecords = {} }, saves = 0 }
    function store:Save() self.saves = self.saves + 1 end
    _G.RecordStores = { gamesetting = store }
    T.gmst = store
    logicHandler.RunConsoleCommandOnPlayer = function(pid, cmd)
        T.sent[#T.sent + 1] = { pid = pid, cmd = cmd }
    end
    logicHandler.RunConsoleCommandOnObjects = function(pid, cmd, cell, ids)
        T.cmds[#T.cmds + 1] = { pid = pid, cmd = cmd, cell = cell, ids = ids }
    end
    T.settings = settings or T.copy(T.DEFAULT_SETTINGS)
    installModules(T.settings)
end

------------------------------------------------------------------ players and cells
function T.player(pid, name, opts)
    opts = opts or {}
    local p = { pid = pid, accountName = name, loggedIn = opts.loggedIn ~= false, calls = {},
        data = { location = { cell = opts.cell or "Balmora" }, inventory = {}, timestamps = { lastLogin = 0 },
            stats = { level = opts.level or 1 }, settings = { difficulty = "default" }, customVariables = {},
            alliedPlayers = opts.allies, journal = opts.journal or {} } }
    function p:IsLoggedIn() return self.loggedIn end
    function p:QuicksaveToDrive() self.calls[#self.calls + 1] = "save" end
    function p:LoadItemChanges(items, action) self.calls[#self.calls + 1] = { "items", items, action } end
    function p:LoadSettings() self.calls[#self.calls + 1] = "settings"; self.loadedDifficulty = self.data.settings.difficulty end
    function p:LoadAllies() self.calls[#self.calls + 1] = "allies" end
    function p:AddCellLoaded() end
    function p:RemoveCellLoaded() end
    Players[pid] = p
    return p
end

-- A player enters a cell: what eventHandler.OnCellLoad does (load, visitor,
-- authority if none), then the custom handlers.
function T.visit(pid, cell)
    logicHandler.LoadCell(cell)
    LoadedCells[cell]:AddVisitor(pid)
    if LoadedCells[cell]:GetAuthority() == nil then LoadedCells[cell]:SetAuthority(pid) end
    customEventHooks.triggerHandlers("OnCellLoad", { validDefaultHandler = true }, { pid, cell })
end
function T.leave(pid, cell)
    local c = LoadedCells[cell]
    if c then
        c:RemoveVisitor(pid)
        if c:GetAuthority() == pid then c.authority = nil end
        if next(c.visitors) == nil then logicHandler.UnloadCell(cell) end
    end
end

------------------------------------------------------------------ events, as eventHandler.lua raises them
T.ADD, T.REMOVE, T.SET = enumerations.container.ADD, enumerations.container.REMOVE, enumerations.container.SET
T.SUB = enumerations.containerSub

-- eventHandler.OnContainer: validators, then the real SaveContainers, then handlers.
-- items: { {refId=, count=, actionCount=} } as the client fills them.
function T.container(pid, cell, action, sub, refNum, items, refId)
    refId = refId or "chest_small_01"
    T.packet = { action = action, sub = sub, objects = { { refId = refId, refNum = refNum, mpNum = 0, items = items } } }
    local objects = { { refId = refId, uniqueIndex = refNum .. "-0" } }
    local status = customEventHooks.triggerValidators("OnContainer", { pid, cell, objects })
    if status.validDefaultHandler then
        local temp = LoadedCells[cell] == nil
        if temp then logicHandler.LoadCell(cell) end
        LoadedCells[cell]:SaveContainers(pid)
        if temp then logicHandler.UnloadCell(cell) end
    end
    customEventHooks.triggerHandlers("OnContainer", status, { pid, cell, objects })
    return status.validDefaultHandler
end
function T.objectDelete(pid, cell, uniqueIndex, refId)
    local objects = { [uniqueIndex] = { refId = refId } }
    local status = customEventHooks.triggerValidators("OnObjectDelete", { pid, cell, objects, {} })
    customEventHooks.triggerHandlers("OnObjectDelete", status, { pid, cell, objects, {} })
    return status.validDefaultHandler
end
function T.barter(pid, cell, uniqueIndex, refId)
    local objects = { [uniqueIndex] = { refId = refId or "merchant",
        dialogueChoiceType = enumerations.dialogueChoice.BARTER } }
    local status = customEventHooks.triggerValidators("OnObjectDialogueChoice", { pid, cell, objects, {} })
    customEventHooks.triggerHandlers("OnObjectDialogueChoice", status, { pid, cell, objects, {} })
end
function T.auth(pid)
    customEventHooks.triggerHandlers("OnPlayerAuthentified", { validDefaultHandler = true }, { pid })
end
function T.diskState(file)
    local t = T.disk["custom/" .. file]
    return t and T.json.decode(t)
end
function T.cellOnDisk(d)
    local w = ("cell/" .. d .. ".json"):lower()
    for k, v in pairs(T.disk) do if k:lower() == w then return T.json.decode(v) end end
end
function T.resetCount()
    local n = 0
    for _, c in ipairs(T.calls) do if c[1] == "SendCellReset" then n = n + 1 end end
    return n
end
function T.logContains(text)
    for _, m in ipairs(T.log) do if m:find(text, 1, true) then return true end end
    return false
end
function T.messageContains(text)
    for _, m in ipairs(T.msgs) do if m[2]:find(text, 1, true) then return true end end
    return false
end

return T
