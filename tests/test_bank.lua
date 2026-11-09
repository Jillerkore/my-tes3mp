-- bank.lua: /bank (personal) and /vault (shared) chests in a storage cell.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local ADD, REMOVE, SUB = T.ADD, T.REMOVE, T.SUB

------------------------------------------------------------ stand-ins the harness does not have
-- The real object-creation and activation code, taken from the CoreScripts file itself (the file
-- cannot be loaded whole: it resets the server's globals).
local function useRealLogicHandler(names)
    local env = setmetatable({}, { __index = _G })
    local chunk = assert(loadfile(T.cs .. "/scripts/logicHandler.lua"))
    setfenv(chunk, env)
    local menus = config.menuHelperFiles
    config.menuHelperFiles = {}
    local real = chunk()
    config.menuHelperFiles = menus
    for _, name in ipairs(names) do
        assert(type(real[name]) == "function", name .. " is not in logicHandler.lua")
        setfenv(real[name], _G)
        logicHandler[name] = real[name]
    end
end
_G.dataTableBuilder = require("dataTableBuilder")

-- Record what the script sends to clients. E is the list of packets, in order.
local E, cur = {}, {}
local function wrap(name, fn)
    local original = tes3mp[name]
    tes3mp[name] = function(...)
        fn(...)
        if rawequal(original, nil) then return end
        return original(...)
    end
end
local function plain(name, fn) tes3mp[name] = fn end
plain("ClearObjectList", function() cur = { objects = {} } end)
plain("SetObjectListPid", function(pid) cur.pid = pid; T.listPid = pid end)
plain("SetObjectListCell", function(cell) cur.cell = cell end)
plain("SetObjectRefNum", function(n) cur.refNum = n end)
plain("SetObjectMpNum", function(n) cur.mpNum = n end)
plain("SetObjectRefId", function(id) cur.refId = id end)
plain("SetObjectActivatingPid", function(pid) cur.activatedBy = pid end)
plain("SetContainerItemRefId", function(id) cur.itemRefId = id end)
plain("SetContainerItemCount", function(n) cur.itemCount = n end)
plain("AddContainerItem", function()
    cur.items = cur.items or {}
    table.insert(cur.items, { refId = cur.itemRefId, count = cur.itemCount })
end)
plain("AddObject", function()
    table.insert(cur.objects, { refId = cur.refId, uniqueIndex = tostring(cur.refNum) .. "-" .. tostring(cur.mpNum), items = cur.items })
    cur.items = nil
end)
plain("SendObjectPlace", function(everyone) table.insert(E, { "place", cur.pid, cur.cell, everyone, cur.objects }) end)
plain("SendObjectRotate", function() end)
plain("SendObjectActivate", function()
    table.insert(E, { "activate", cur.pid, cur.cell, cur.objects[1] and cur.objects[1].uniqueIndex, cur.activatedBy })
end)
plain("SendContainer", function(...)
    if select("#", ...) == 0 then table.insert(E, { "containerSet", cur.pid, cur.cell, cur.objects }) end
end)
plain("SendRecordDynamic", function() table.insert(E, { "records" }) end)

local function events(kind)
    local out = {}
    for _, e in ipairs(E) do if e[1] == kind then out[#out + 1] = e end end
    return out
end

local CELL = "Clutter Warehouse - Everything Must Go!"
local B

local function setup(opts)
    opts = opts or {}
    local disk = opts.keepDisk and T.disk or nil
    local settings = T.copy(T.DEFAULT_SETTINGS)
    settings.bank = opts.bank
    if opts.bank == nil and not opts.nilSwitch then settings.bank = true end
    T.fresh(settings)
    if disk then T.disk = disk end
    E = {}
    myTes3mpCombat, myTes3mpDowned, myTes3mpBank = nil, nil, nil
    useRealLogicHandler({ "CreateObjects", "CreateObjectAtLocation", "ActivateObjectForPlayer", "IsGeneratedRecord",
        "GetRecordTypeByRecordId", "GetRecordStoreByRecordId" })
    -- the world's counter of created objects; it survives a restart on a real server (world file)
    if not opts.keepDisk then T.mp = 100 end
    function WorldInstance:GetCurrentMpNum() return T.mp end
    function WorldInstance:SetCurrentMpNum(n) T.mp = n end
    local container = { data = { permanentRecords = {} }, saves = 0 }
    function container:Save() self.saves = self.saves + 1 end
    RecordStores.container = container
    T.container_store = container
    if opts.records then container.data.permanentRecords = opts.records end
    if opts.resets then T.load("resets") end
    if opts.combat then T.load("combat") end
    if opts.uniques then T.load("uniques") end
    B = T.load("bank")
    T.postInit()
    return B
end

local function player(pid, name, opts)
    opts = opts or {}
    local p = T.player(pid, name, { cell = opts.cell or "-3, -3" })
    p.name = name
    p.data.character = { race = opts.race or "Nord" }
    return p
end

local function say(pid, text)
    return customEventHooks.triggerValidators("OnPlayerSendMessage", { pid, text })
end
local function told(pid, text)
    for _, m in ipairs(T.msgs) do if m[1] == pid and m[2]:find(text, 1, true) then return true end end
    return false
end
local function clear() T.msgs = {}; E = {} end

-- What the client sends when a container window changes, handled the way eventHandler.OnContainer does:
-- the packet is refused for a cell nobody has loaded (config.allowOnContainerForUnloadedCells is off),
-- then the validators, the real SaveContainers, the handlers.
local function clientContainer(pid, cell, action, sub, uniqueIndex, items, refId)
    local refNum, mpNum = uniqueIndex:match("^(%d+)%-(%d+)$")
    T.packet = { action = action, sub = sub, objects = { { refId = refId or "mytes3mp_bank_chest", refNum = tonumber(refNum),
        mpNum = tonumber(mpNum), items = items } } }
    local isLoaded = LoadedCells[cell] ~= nil
    if not config.allowOnContainerForUnloadedCells and not isLoaded then
        return "unloaded"
    end
    local objects = { { refId = T.packet.objects[1].refId, uniqueIndex = uniqueIndex } }
    local status = customEventHooks.triggerValidators("OnContainer", { pid, cell, objects })
    if status.validDefaultHandler then
        LoadedCells[cell]:SaveContainers(pid)
    end
    customEventHooks.triggerHandlers("OnContainer", status, { pid, cell, objects })
    return status.validDefaultHandler
end
local function put(pid, idx, refId, n, cell)
    return clientContainer(pid, cell or CELL, ADD, SUB.DROP, idx, { { refId = refId, count = n, actionCount = 0 } })
end
local function take(pid, idx, refId, n, cell)
    return clientContainer(pid, cell or CELL, REMOVE, SUB.DRAG, idx, { { refId = refId, count = n, actionCount = n } })
end

local function chestCount()
    local n = 0
    local cell = LoadedCells[CELL]
    if cell then for _, o in pairs(cell.data.objectData) do if o.refId and o.refId:find("mytes3mp_", 1, true) then n = n + 1 end end end
    return n
end
local function contents(idx)
    local out = {}
    local o = LoadedCells[CELL].data.objectData[idx]
    for _, item in pairs(o and o.inventory or {}) do out[item.refId] = (out[item.refId] or 0) + item.count end
    return out
end
local function state() return T.diskState("myTes3mpBank.json") end
local function openedIndex(pid)
    local a = events("activate")
    for i = #a, 1, -1 do if a[i][2] == pid then return a[i][4] end end
end

------------------------------------------------------------ records
do
    setup()
    local r = T.container_store.data.permanentRecords
    report("A1 two permanent container records are registered, copies of an empty vanilla chest",
        r.mytes3mp_bank_chest and r.mytes3mp_vault_chest and r.mytes3mp_bank_chest.baseId == "com_chest_02_empty" and
        r.mytes3mp_vault_chest.baseId == "com_chest_02_empty")
    report("A2 with a very large capacity and distinct names", r.mytes3mp_bank_chest.weight >= 1000000 and
        r.mytes3mp_bank_chest.name ~= r.mytes3mp_vault_chest.name, r.mytes3mp_bank_chest.name .. "/" .. r.mytes3mp_vault_chest.name)
    report("A3 the store was saved", T.container_store.saves == 1)
    -- same again: nothing to do
    local store = T.container_store
    local before = store.saves
    B = T.load("bank"); T.postInit()
    report("A4 a record that is already right is not saved again", store.saves == before, store.saves)
    -- a record that differs (an older version) is corrected
    setup({ records = { mytes3mp_bank_chest = { baseId = "chest_small_01", name = "Old", weight = 5 } } })
    report("A5 an outdated record is replaced", T.container_store.data.permanentRecords.mytes3mp_bank_chest.weight >= 1000000)
    -- no container store at all: logged, no crash
    local ok = pcall(function()
        T.fresh(); RecordStores.container = nil
        T.load("bank"); T.postInit()
    end)
    report("A6 a server without a container record store logs an error and carries on", ok and T.logContains("no container record store"))
end

------------------------------------------------------------ protection from resets
do
    setup({ resets = true })
    report("B1 the storage cell is on the resets script's never-reset list", myTes3mpResets.keepExact[CELL:lower()] == true)
    report("B2 IsKept agrees", myTes3mpResets.IsKept(CELL) == true)
    setup()
    report("B3 without resets.lua nothing breaks (and there is nothing to protect from)", myTes3mpResets == nil and B ~= nil)
    -- resets loaded, but after the bank: the post-init pass still registers it
    T.fresh(); useRealLogicHandler({ "IsGeneratedRecord" })
    RecordStores.container = { data = { permanentRecords = {} }, Save = function() end }
    T.load("bank")
    T.load("resets")
    T.postInit()
    report("B4 even if resets.lua were loaded later, start-up registers the cell", myTes3mpResets.keepExact[CELL:lower()] == true)
end

------------------------------------------------------------ /bank: creation, reuse, opening
do
    setup({ resets = true })
    player(1, "Alice")
    player(2, "Bob")
    report("C1 nothing is created before anybody asks", LoadedCells[CELL] == nil and state() == nil)

    clear(); say(1, "/bank")
    local idx = openedIndex(1)
    report("C2 /bank creates a chest in the storage cell, once", chestCount() == 1 and idx ~= nil and
        LoadedCells[CELL].data.objectData[idx].refId == "mytes3mp_bank_chest")
    report("C2b its unique index is 0-<mpNum> from the world counter", idx == "0-101", idx)
    report("C3 the chest is recorded for the player (and the vault is not)", state().banks.alice == idx and state().vault == nil)
    report("C3b the owner is also written on the chest itself, for recovery",
        LoadedCells[CELL].data.objectData[idx].myTes3mpOwner == "alice")
    report("C4 it is a container the cell knows about (container packet list)", (function()
        for _, i in ipairs(LoadedCells[CELL].data.packets.container) do if i == idx then return true end end end)())

    -- the order of packets to the client
    local order = {}
    for _, e in ipairs(E) do
        if (e[1] == "place" and e[2] == 1 and not e[4]) or e[1] == "containerSet" or e[1] == "activate" then order[#order + 1] = e[1] end
    end
    report("C5 the client is sent the chest, then its contents, then told to open it", table.concat(order, ",") == "place,containerSet,activate",
        table.concat(order, ","))
    local act = events("activate")[1]
    report("C6 the activation is for this player, in the storage cell, by this player",
        act[2] == 1 and act[3] == CELL and act[5] == 1)
    report("C7 the activation goes to this player alone", #events("activate") == 1)

    clear(); say(1, "/bank")
    report("C8 a second /bank reuses the chest", openedIndex(1) == idx and chestCount() == 1)
    report("C9 the cell stays loaded for container packets", LoadedCells[CELL] ~= nil)

    -- per player
    clear(); say(2, "/bank")
    local bobIdx = openedIndex(2)
    report("C10 another player gets a chest of his own", bobIdx ~= nil and bobIdx ~= idx and chestCount() == 2)
    report("C10b ... recorded under his account", state().banks.bob == bobIdx and state().banks.alice == idx)
end

------------------------------------------------------------ using the bank
do
    setup({ resets = true })
    player(1, "Alice"); player(2, "Bob")
    say(1, "/bank"); local a = openedIndex(1)
    say(2, "/bank"); local b = openedIndex(2)

    local ok = put(1, a, "ring_of_x", 1)
    report("D1 the owner can put things in (the server accepts a container packet for the loaded storage cell)", ok == true and contents(a).ring_of_x == 1)
    report("D1b the stock script saved the change to the cell file", T.cellOnDisk(CELL).objectData[a].inventory[1].refId == "ring_of_x")
    ok = put(1, a, "gold_001", 500)
    report("D2 gold and stacks add up", contents(a).gold_001 == 500)
    ok = put(1, a, "gold_001", 250)
    report("D2b ... again", contents(a).gold_001 == 750)
    ok = take(1, a, "gold_001", 700)
    report("D3 the owner can take things out", ok == true and contents(a).gold_001 == 50)

    clear()
    ok = put(2, a, "dagger", 1)
    report("D4 another player cannot put things into somebody's bank", ok == false and contents(a).dagger == nil and told(2, "not your bank"))
    ok = take(2, a, "ring_of_x", 1)
    report("D5 ... or take things out", ok == false and contents(a).ring_of_x == 1)
    report("D6 his own bank is separate", put(2, b, "dagger", 1) == true and contents(b).dagger == 1 and contents(a).dagger == nil)

    -- unknown objects in the storage cell are not ours to serve
    ok = clientContainer(1, CELL, ADD, SUB.DROP, "0-9999", { { refId = "x", count = 1, actionCount = 0 } })
    report("D7 a container packet for an object the bank did not make is refused", ok == false)
    -- other cells are none of this script's business
    LoadedCells["Balmora, Guild of Mages"] = nil
    logicHandler.LoadCell("Balmora, Guild of Mages")
    ok = clientContainer(1, "Balmora, Guild of Mages", ADD, SUB.DROP, "0-1", { { refId = "x", count = 1, actionCount = 0 } }, "chest_small_01")
    report("D8 other cells are untouched by the bank's validator", ok == true)

    -- no deletion
    local status = customEventHooks.triggerValidators("OnObjectDelete", { 1, CELL, { [a] = { refId = "mytes3mp_bank_chest" } }, {} })
    report("D9 a client cannot delete a bank chest", status.validDefaultHandler == false)
    status = customEventHooks.triggerValidators("OnObjectDelete", { 1, "Balmora, Guild of Mages", { ["5-0"] = { refId = "x" } }, {} })
    report("D9b ... but deleting other things is not touched", status.validDefaultHandler ~= false)

    -- what is sent when the bank is opened again: its contents
    clear(); say(1, "/bank")
    local set = events("containerSet")[1]
    local seen = {}
    for _, item in ipairs(set[4][1].items or {}) do seen[item.refId] = item.count end
    report("D10 opening again sends the saved contents to the client", seen.ring_of_x == 1 and seen.gold_001 == 50)
end

------------------------------------------------------------ the vault
do
    setup({ resets = true })
    player(1, "Alice"); player(2, "Bob")
    clear(); say(1, "/vault")
    local v = openedIndex(1)
    report("V1 the first /vault ever creates the shared chest", v ~= nil and chestCount() == 1 and state().vault == v and
        LoadedCells[CELL].data.objectData[v].refId == "mytes3mp_vault_chest")
    clear(); say(2, "/vault")
    report("V2 everybody gets the same chest", openedIndex(2) == v and chestCount() == 1)
    report("V3 anyone can put in and take out", put(1, v, "potion_a", 3) == true and put(2, v, "potion_a", 2) == true and
        contents(v).potion_a == 5 and take(2, v, "potion_a", 4) == true and contents(v).potion_a == 1)
    report("V4 the vault is not anyone's bank (a bank is separate)", (function()
        say(1, "/bank"); local a = openedIndex(1); return a ~= v and chestCount() == 2 end)())

    -- two players with the vault open: both reach for the last potion
    take(1, v, "potion_a", 1)
    local ok = take(2, v, "potion_a", 1)
    report("V5 reaching for the same last item twice: the second finds it gone, nothing goes negative",
        contents(v).potion_a == nil and ok == true)

    -- every change is passed on to everyone, including the sender (the stock SaveContainers does this)
    report("V6 CoreScripts sends container changes to all players", T.csSource("cell/base.lua"):find("tes3mp.SendContainer(true, false)", 1, true) ~= nil)
end

------------------------------------------------------------ refusals
do
    setup({ combat = true })
    player(1, "Alice"); player(2, "Bob")
    myTes3mpCombat.Mark(1)
    clear(); say(1, "/bank"); say(1, "/vault")
    report("E1 in combat: neither opens, nothing is created or sent", #events("activate") == 0 and LoadedCells[CELL] == nil and
        state() == nil and told(1, "fight"))
    T.time = T.time + 11
    clear(); say(1, "/bank")
    report("E1b a few quiet seconds later it opens", #events("activate") == 1)

    customEventHooks.triggerHandlers("OnPlayerDeath", { validDefaultHandler = true }, { 1 })
    clear(); say(1, "/bank")
    report("E2 dead: refused", #events("activate") == 0 and told(1, "while dead"))
    customEventHooks.triggerHandlers("OnPlayerResurrect", { validDefaultHandler = true }, { 1 })
    clear(); say(1, "/bank")
    report("E2b after resurrecting it opens", #events("activate") == 1)

    myTes3mpDowned = { IsDowned = function(pid) return pid == 2 end }
    clear(); say(2, "/vault")
    report("E3 downed: refused", #events("activate") == 0 and told(2, "while downed"))
    myTes3mpDowned = nil
    clear(); say(2, "/vault")
    report("E3b without downed.lua there is no error", #events("activate") == 1)

    local c = player(3, "Newbie"); c.data.character.race = ""
    clear(); say(3, "/bank")
    report("E4 character generation: refused", #events("activate") == 0 and told(3, "Finish creating"))
    local d = player(4, "Fresh"); d.data.location.cell = ""
    local ok = pcall(say, 4, "/bank")
    report("E4b a brand new account (empty location) causes no error", ok and #events("activate") == 0)

    -- an error inside is caught, the player told, the server carries on
    clear()
    local saved = logicHandler.ActivateObjectForPlayer
    logicHandler.ActivateObjectForPlayer = function() error("boom") end
    ok = pcall(say, 1, "/bank")
    logicHandler.ActivateObjectForPlayer = saved
    report("E5 a failure while opening is caught, logged and reported to the player", ok and told(1, "things are safe") and T.logContains("boom"))
end

------------------------------------------------------------ restart, damage, recovery
do
    setup({ resets = true })
    player(1, "Alice"); player(2, "Bob")
    say(1, "/bank"); local a = openedIndex(1)
    say(2, "/vault"); local v = openedIndex(2)
    put(1, a, "ring_of_x", 1)
    put(2, v, "potion_a", 4)

    -- restart: same disk, a fresh server
    setup({ keepDisk = true, resets = true })
    player(1, "Alice"); player(2, "Bob")
    report("F1 after a restart the cell is loaded and the contents are there", LoadedCells[CELL] ~= nil and contents(a).ring_of_x == 1 and contents(v).potion_a == 4)
    clear(); say(1, "/bank"); say(2, "/vault")
    report("F2 the same chests are opened, none made anew", openedIndex(1) == a and openedIndex(2) == v and chestCount() == 2)
    report("F3 container changes are accepted right after a restart", put(1, a, "ring_of_x", 1) == true and contents(a).ring_of_x == 2)
    report("F3b ... the cell was loaded without any visitor", next(LoadedCells[CELL].visitors) == nil)

    -- damaged state file: garbage
    T.disk["custom/myTes3mpBank.json"] = "{ this is not json"
    setup({ keepDisk = true, resets = true })
    player(1, "Alice"); player(2, "Bob")
    clear(); say(1, "/bank"); say(2, "/vault")
    report("G1 a corrupted state file does not lose the banks: the chests are found again from the cell file",
        openedIndex(1) == a and openedIndex(2) == v and chestCount() == 2 and contents(a).ring_of_x == 2, tostring(openedIndex(1)))
    report("G1b it said so in the log", T.logContains("linked again"))

    -- state file with nonsense of the wrong shape
    T.disk["custom/myTes3mpBank.json"] = T.json.encode({ banks = { alice = 12, bob = { "x" }, [""] = "0-1", carl = "0-5" }, vault = { 1 } })
    setup({ keepDisk = true, resets = true })
    player(1, "Alice")
    clear(); say(1, "/bank")
    report("G2 entries of the wrong shape are ignored; the real chest is recovered", openedIndex(1) == a and chestCount() == 2)

    -- a link to a chest that is not in the cell: a new one is made, loudly
    T.disk["custom/myTes3mpBank.json"] = T.json.encode({ banks = { carl = "0-5" } })
    setup({ keepDisk = true, resets = true })
    player(3, "Carl")
    clear(); say(3, "/bank")
    local carl = openedIndex(3)
    report("G3 a link to a missing chest is replaced by a new chest, with an error in the log",
        carl ~= nil and carl ~= "0-5" and T.logContains("missing from") and chestCount() == 3)

    -- state file missing
    T.disk["custom/myTes3mpBank.json"] = nil
    setup({ keepDisk = true, resets = true })
    player(1, "Alice")
    clear(); say(1, "/bank")
    report("G4 a missing state file with the cell file present also recovers", openedIndex(1) == a and chestCount() == 3)
end

------------------------------------------------------------ cell resets
do
    setup({ resets = true })
    player(1, "Alice"); player(2, "Bob")
    say(1, "/bank"); local a = openedIndex(1)
    put(1, a, "ring_of_x", 1)
    -- somebody loads the cell (a console command, say): the resets script starts a clock for ordinary cells
    customEventHooks.triggerHandlers("OnCellLoad", { validDefaultHandler = true }, { 2, CELL })
    local timers = (T.diskState("myTes3mpCellResets.json") or {}).timers or {}
    report("H1 the resets script starts no clock for the storage cell", timers[CELL] == nil)
    local stashes = (T.diskState("myTes3mpCellResets.json") or {}).stashes or {}
    report("H2 putting an item in is also noted as a stash by resets.lua, which only adds to the protection",
        stashes[CELL] ~= nil and stashes[CELL][a] == true)
    T.time = T.time + 5 * 3600
    logicHandler.UnloadCell(CELL)       -- nobody has it loaded
    local before = T.resetCount()
    myTes3mpResets.Sweep()
    logicHandler.LoadCell(CELL)
    report("H3 a sweep long after does not reset it", T.resetCount() == before and contents(a).ring_of_x == 1)

    -- the control: without the protection the same sweep would have emptied the banks
    setup({ resets = true })
    player(1, "Alice"); player(2, "Bob")
    say(1, "/bank"); a = openedIndex(1)
    put(1, a, "ring_of_x", 1)
    myTes3mpResets.keepExact[CELL:lower()] = nil
    customEventHooks.triggerHandlers("OnCellLoad", { validDefaultHandler = true }, { 2, CELL })
    T.time = T.time + 5 * 3600
    -- (the stash note from putting an item in would also protect it; forget that to show the bare effect)
    LoadedCells[CELL].data.objectData[a].inventory = {}   -- the stash note is only kept while a chest holds something
    logicHandler.UnloadCell(CELL)
    myTes3mpResets.Sweep()
    logicHandler.LoadCell(CELL)
    report("H4 (control) without the keepExact entry the same sweep does reset the cell", chestCount() == 0)
end

------------------------------------------------------------ uniques.lua and resets.lua on container packets
do
    setup({ resets = true, uniques = true })
    local items = dofile(T.scriptsDir .. "/uniqueItems.lua")
    local ids = {} for k in pairs(items) do ids[#ids + 1] = k end table.sort(ids)
    local X = ids[1]
    player(1, "Alice"); player(2, "Bob")
    T.auth(1); T.auth(2)
    -- Alice takes the artifact from its chest in the world: her claim
    T.visit(1, "Vivec, Temple")
    T.container(1, "Vivec, Temple", REMOVE, SUB.DRAG, 100, { { refId = X, count = 1, actionCount = 1 } })
    local claimed = T.diskState("myTes3mpUniques.json").claims[X].alice == true
    say(1, "/bank"); local a = openedIndex(1)
    say(2, "/vault"); local v = openedIndex(2)

    report("I1 banking a claimed artifact is allowed", put(1, a, X, 1) == true and contents(a)[X] == 1 and claimed)
    report("I2 the owner can take it out again - it is her own copy, not a fresh claim", take(1, a, X, 1) == true and contents(a)[X] == nil)
    put(1, a, X, 1); take(1, a, X, 1)
    report("I3 and again, as often as she likes", contents(a)[X] == nil)
    put(1, v, X, 1)
    report("I4 she can hand it to her brother through the vault", take(2, v, X, 1) == true and contents(v)[X] == nil)
    report("I5 ... which does not count as his fresh claim", (T.diskState("myTes3mpUniques.json").claims[X] or {}).bob == nil)
    report("I6 the deposit books balance (nothing left over)", next(T.diskState("myTes3mpUniques.json").deposits or {}) == nil,
        T.json.encode(T.diskState("myTes3mpUniques.json").deposits))
    -- resets.lua noted the chests as stash containers in the storage cell
    report("I7 resets.lua records the chest as a stash (harmless: the cell is protected anyway)", (function()
        put(1, a, "gold_001", 5)
        local s = myTes3mpResets.HasStash(CELL)
        return s == true end)())
end

------------------------------------------------------------ the switch
do
    setup({ bank = false })
    player(1, "Alice")
    clear(); say(1, "/bank"); say(1, "/vault")
    report("K1 with the switch off neither command answers and nothing is created", #events("activate") == 0 and #T.msgs == 0 and
        LoadedCells[CELL] == nil and next(T.container_store.data.permanentRecords) == nil)
    report("K2 it says so in the log", T.logContains("switched off"))
    setup({ bank = false, resets = true })
    report("K3 a switched-off bank does not touch the resets list either", myTes3mpResets.keepExact[CELL:lower()] == nil)

    setup({ nilSwitch = true })
    player(1, "Alice")
    clear(); say(1, "/bank")
    report("K4 a missing switch (nil) counts as on", #events("activate") == 1)
end

------------------------------------------------------------ the unloaded-cell rule (why the cell must be kept loaded)
do
    setup()
    player(1, "Alice")
    say(1, "/bank"); local a = openedIndex(1)
    logicHandler.UnloadCell(CELL)
    local r = put(1, a, "ring_of_x", 1)
    report("L1 if the cell were not loaded the server would drop the container packet (so the bank keeps it loaded)", r == "unloaded")
    customEventHooks.triggerHandlers("OnCellUnload", { validDefaultHandler = true }, { 1, CELL })
    report("L2 an unload is undone at once", LoadedCells[CELL] ~= nil and put(1, a, "ring_of_x", 1) == true)
    report("L3 the config switch for unloaded cells is left alone", config.allowOnContainerForUnloadedCells == false)

    local events_src = T.csSource("eventHandler.lua")
    report("L4 eventHandler.lua still drops gameplay container packets for unloaded cells unless the switch is on",
        events_src:find("not config.allowOnContainerForUnloadedCells and  not isCellLoaded and logicHandler.DoesPacketOriginRequireLoadedCell(packetOrigin)", 1, true) ~= nil)
    local logic = T.csSource("logicHandler.lua")
    report("L5 ActivateObjectForPlayer, CreateObjectAtLocation and TES3MP's LoadObjectsPlaced are what the bank calls",
        logic:find("logicHandler.ActivateObjectForPlayer = function", 1, true) ~= nil and
        logic:find("logicHandler.CreateObjectAtLocation = function", 1, true) ~= nil and
        T.csSource("cell/base.lua"):find("function BaseCell:LoadObjectsPlaced", 1, true) ~= nil)
end

T.summary()
