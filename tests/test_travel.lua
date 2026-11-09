-- travel.lua / travelPoints.lua: discovery, /travel, /goto, /party.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report

------------------------------------------------------------ stand-ins the harness does not have
-- The real logicHandler.TeleportToPlayer and CheckPlayerValidity, taken from the
-- CoreScripts file itself (the file cannot be loaded whole: it resets the server's globals).
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

-- What the C++ server knows about each player (T.live[pid]) and what the script told it to do.
T.live = {}
T.calls2 = {}
local function rec(name) return function(...) T.calls2[#T.calls2 + 1] = { name, ... } end end
tes3mp.SetCell, tes3mp.SetPos, tes3mp.SetRot = rec("SetCell"), rec("SetPos"), rec("SetRot")
tes3mp.SendCell, tes3mp.SendPos, tes3mp.ListBox = rec("SendCell"), rec("SendPos"), rec("ListBox")
tes3mp.GetCell = function(pid) return T.live[pid].cell end
tes3mp.GetPosX = function(pid) return T.live[pid].x or 0 end
tes3mp.GetPosY = function(pid) return T.live[pid].y or 0 end
tes3mp.GetPosZ = function(pid) return T.live[pid].z or 0 end
tes3mp.GetRotX = function(pid) return 0 end
tes3mp.GetRotZ = function(pid) return T.live[pid].rz or 0 end
tes3mp.GetLevel = function(pid) return T.live[pid] and T.live[pid].level end
tes3mp.GetHealthCurrent = function(pid) return T.live[pid] and T.live[pid].health end
tes3mp.GetHealthBase = function(pid) return T.live[pid] and T.live[pid].base end

local function callsNamed(name)
    local out = {}
    for _, c in ipairs(T.calls2) do if c[1] == name then out[#out + 1] = c end end
    return out
end

local points = dofile(T.scriptsDir .. "/travelPoints.lua")
package.preload["custom/myTes3mp/travelPoints"] = function() return dofile(T.scriptsDir .. "/travelPoints.lua") end

local function pointNamed(name)
    for _, p in ipairs(points) do if p.name == name then return p end end
    error("no travel point " .. name)
end

local settings
local function setup(opts)
    opts = opts or {}
    settings = T.copy(T.DEFAULT_SETTINGS)
    settings.travel = opts.travel
    if opts.travel == nil and not opts.nilSwitch then settings.travel = true end
    T.fresh(settings)
    package.loaded["custom/myTes3mp/travelPoints"] = nil
    T.calls2 = {}
    T.live = {}
    myTes3mpCombat, myTes3mpDowned, myTes3mpTravel = nil, nil, nil
    useRealLogicHandler({ "TeleportToPlayer", "CheckPlayerValidity" })
    if opts.combat ~= false then T.load("combat") end
    local module = T.load("travel")
    T.postInit()
    return module
end

-- A logged-in player standing in `cell`.
local function player(pid, name, cell, opts)
    opts = opts or {}
    local p = T.player(pid, name, { cell = cell, level = opts.level or 1 })
    p.name = name
    p.data.character = { race = opts.race or "Nord" }
    p.data.location.regionName = opts.region or ""
    p.data.inventory = opts.gold and { { refId = "gold_001", count = opts.gold, charge = -1, enchantmentCharge = -1, soul = "" } } or {}
    p.data.stats.healthCurrent, p.data.stats.healthBase = 1, 1
    T.live[pid] = { cell = cell, level = opts.level or 1, health = opts.health or 100, base = opts.base or 100, x = 5, y = 6, z = 7, rz = 1.5 }
    return p
end

local function say(pid, text)
    return customEventHooks.triggerValidators("OnPlayerSendMessage", { pid, text })
end
local function messagesTo(pid)
    local out = {}
    for _, m in ipairs(T.msgs) do if m[1] == pid then out[#out + 1] = m[2] end end
    return out
end
local function told(pid, text)
    for _, m in ipairs(messagesTo(pid)) do if m:find(text, 1, true) then return true end end
    return false
end
local function clear() T.msgs = {}; T.calls2 = {} end

-- The client reports a new cell: eventHandler.OnPlayerCellChange saves it, then the handlers run.
local function moveTo(pid, cell)
    local prev = Players[pid].data.location.cell
    Players[pid].data.location.cell = cell
    T.live[pid].cell = cell
    customEventHooks.triggerHandlers("OnPlayerCellChange", { validDefaultHandler = true, validCustomHandlers = true },
        { pid, { location = { cell = cell } }, prev })
end
local function pick(pid, index)
    customEventHooks.triggerHandlers("OnGUIAction", { validDefaultHandler = true }, { pid, 7340201, tostring(index) })
end
local function goldOf(pid)
    local n = 0
    for _, i in pairs(Players[pid].data.inventory) do if i.refId:lower() == "gold_001" then n = n + i.count end end
    return n
end
local function discovered(pid)
    local mine = Players[pid].data.customVariables.myTes3mpTravel
    local n = 0
    if mine and mine.found then for _ in pairs(mine.found) do n = n + 1 end end
    return n
end
-- Open the list for pid and return the ListBox call.
local function openList(pid)
    clear()
    say(pid, "/travel")
    return callsNamed("ListBox")[1]
end

------------------------------------------------------------ the data file
do
    report("D1 travelPoints.lua loads and has points for Vvardenfell, Mournhold and Solstheim", #points >= 30,
        #points .. " points")
    local names, cells, bad = {}, {}, nil
    for i, p in ipairs(points) do
        local shape = type(p.name) == "string" and p.name ~= "" and type(p.cell) == "string" and p.cell ~= "" and
            type(p.exterior) == "boolean" and type(p.pos) == "table" and #p.pos == 3 and
            type(p.rot) == "table" and #p.rot == 3
        if shape then
            for k = 1, 3 do
                if type(p.pos[k]) ~= "number" or type(p.rot[k]) ~= "number" then shape = false end
            end
        end
        if shape and (p.rot[1] ~= 0 or p.rot[2] ~= 0) then shape = false end
        if shape and p.exterior then
            local x, y = p.cell:match("^(%-?%d+), (%-?%d+)$")
            -- an exterior arrival point must lie inside the cell it names (cell size 8192)
            shape = x ~= nil and math.floor(p.pos[1] / 8192) == tonumber(x) and math.floor(p.pos[2] / 8192) == tonumber(y)
        elseif shape then
            shape = p.cell:match("^%-?%d+, %-?%d+$") == nil
        end
        if not shape and not bad then bad = i end
        if names[p.name] or cells[p.cell:lower()] then bad = bad or i end
        names[p.name], cells[p.cell:lower()] = true, true
    end
    report("D2 every entry has the documented shape; exterior positions lie in their cell; names and cells are unique",
        bad == nil, bad and ("entry " .. bad) or nil)
    local interiors, exteriors = 0, 0
    for _, p in ipairs(points) do if p.exterior then exteriors = exteriors + 1 else interiors = interiors + 1 end end
    report("D3 both kinds are present", interiors >= 5 and exteriors >= 20, exteriors .. " exterior, " .. interiors .. " interior")
    local mournhold, solstheim = false, false
    for _, p in ipairs(points) do
        if p.cell:find("Mournhold", 1, true) then mournhold = true end
        if p.name:find("Solstheim", 1, true) then solstheim = true end
    end
    report("D4 Mournhold and Solstheim are covered", mournhold and solstheim)
end

------------------------------------------------------------ discovery
do
    setup()
    player(1, "Alice", "Seyda Neen, Census and Excise Office")
    moveTo(1, "-2, -9")
    report("V1 entering a travel point's cell discovers it", discovered(1) == 1 and told(1, "discovered Seyda Neen"))
    report("V2 the discovery is saved with the player", (function()
        for _, c in ipairs(Players[1].calls) do if c == "save" then return true end end
    end)())
    clear()
    moveTo(1, "-2, -9")
    report("V3 coming back is not announced again", discovered(1) == 1 and #messagesTo(1) == 0)
    moveTo(1, "-3, 4")
    report("V4 an ordinary cell discovers nothing", discovered(1) == 1)
    moveTo(1, "Balmora, Guild of Mages")
    report("V5 an interior point is discovered too", discovered(1) == 2 and told(1, "discovered Balmora, Guild of Mages"))

    local p = player(2, "Bob", "Balmora, Guild of Mages")
    customEventHooks.triggerHandlers("OnPlayerAuthentified", { validDefaultHandler = true }, { 2 })
    report("V6 logging in at a travel point discovers it", discovered(2) == 1)
    report("V6b discoveries are per player", discovered(1) == 2 and discovered(2) == 1)

    -- character generation: no cell yet / no race yet
    local c = player(3, "Carol", "")
    c.data.character.race = ""
    local ok, err = pcall(function()
        customEventHooks.triggerHandlers("OnPlayerAuthentified", { validDefaultHandler = true }, { 3 })
        moveTo(3, "-2, -9")
        say(3, "/travel")
        say(3, "/party")
        say(1, "/goto Carol")
    end)
    report("V7 a player still in character generation causes no error", ok, err)
    report("V7b ... and discovers nothing yet", discovered(3) == 0)
    report("V7c ... and /travel tells him to finish first", told(3, "Finish creating your character"))
    report("V7d ... and nobody can /goto him", told(1, "still creating a character"))
    -- a brand new account: empty location cell, no race, default stats
    local d = player(4, "Dora", nil)
    d.data.location.cell = ""
    ok, err = pcall(function() say(4, "/party"); say(4, "/travel"); say(4, "/goto Alice") end)
    report("V7e an empty location (new account) causes no error", ok, err)

    -- a validator that stopped the default handler (cell change refused): nothing happens
    local e = player(5, "Eve", "-3, 4")
    Players[5].data.location.cell = "-2, -9"
    customEventHooks.triggerHandlers("OnPlayerCellChange", { validDefaultHandler = false }, { 5, {}, "-3, 4" })
    report("V8 a refused cell change discovers nothing", discovered(5) == 0)
end

------------------------------------------------------------ /travel: list
do
    setup()
    player(1, "Alice", "-3, 4", { gold = 1000, level = 5 })
    say(1, "/travel")
    report("L1 with nothing discovered there is no list, only an explanation",
        #callsNamed("ListBox") == 0 and told(1, "not discovered any travel points"))

    moveTo(1, "-3, 6")          -- Ald-ruhn
    moveTo(1, "-3, -3")         -- Balmora
    moveTo(1, "-2, -9")         -- Seyda Neen
    moveTo(1, "Vivec, Guild of Mages")
    moveTo(1, "-3, 4")          -- nothing
    local call = openList(1)
    report("L2 the list box is opened with the module's own id", call ~= nil and call[3] == 7340201, call and call[3])
    local items = {}
    for line in (call and call[5] or ""):gmatch("[^\n]+") do items[#items + 1] = line end
    local expected = {}
    for _, p in ipairs(points) do
        if p.name == "Ald-ruhn" or p.name == "Balmora" or p.name == "Seyda Neen" or p.name == "Vivec, Guild of Mages" then
            expected[#expected + 1] = p.name
        end
    end
    report("L3 the list holds exactly the discovered points, in the order of travelPoints.lua",
        table.concat(items, "|") == table.concat(expected, "|"), table.concat(items, "|"))
    report("L4 away from a travel point the label says what it costs (10 x level 5 = 50)",
        call and call[4]:find("costs 50 gold", 1, true) ~= nil, call and call[4])

    moveTo(1, "-3, -3")
    call = openList(1)
    report("L5 at a travel point the label says it is free and marks where you are",
        call[4]:find("free", 1, true) ~= nil and call[5]:find("Balmora (you are here)", 1, true) ~= nil, call[4])
end

------------------------------------------------------------ /travel: paying and arriving
do
    setup()
    player(1, "Alice", "-3, 4", { gold = 120, level = 5 })
    moveTo(1, "-3, 6"); moveTo(1, "Vivec, Guild of Mages"); moveTo(1, "-3, 4")
    local list = openList(1)
    local ald = 0
    for i, line in ipairs((function() local t = {} for l in list[5]:gmatch("[^\n]+") do t[#t + 1] = l end return t end)()) do
        if line == "Ald-ruhn" then ald = i - 1 end
    end
    clear()
    pick(1, ald)
    local setCell, setPos, setRot = callsNamed("SetCell")[1], callsNamed("SetPos")[1], callsNamed("SetRot")[1]
    local p = pointNamed("Ald-ruhn")
    report("P1 an exterior point: cell, position and rotation are sent to the client",
        setCell and setCell[3] == p.cell and setPos and setPos[3] == p.pos[1] and setPos[5] == p.pos[3] and
        setRot and setRot[3] == 0 and setRot[4] == p.rot[3] and #callsNamed("SendCell") == 1 and #callsNamed("SendPos") == 1)
    report("P2 it cost 50 gold, in the saved inventory", goldOf(1) == 70, goldOf(1))
    local removed
    for _, c in ipairs(Players[1].calls) do
        if type(c) == "table" and c[1] == "items" and c[3] == enumerations.inventory.REMOVE then removed = c[2] end
    end
    report("P3 the client is told to remove the same gold", removed and removed[1].refId == "gold_001" and removed[1].count == 50)
    report("P4 the player is told", told(1, "travel to Ald-ruhn for 50 gold"))
    clear()
    pick(1, ald)
    report("P5 a second answer to the same list does nothing", #callsNamed("SetCell") == 0 and goldOf(1) == 70)

    -- interior destination
    moveTo(1, "-3, 4")
    list = openList(1)
    local vivec = 0
    local n = 0
    for l in list[5]:gmatch("[^\n]+") do if l == "Vivec, Guild of Mages" then vivec = n end n = n + 1 end
    clear()
    pick(1, vivec)
    local sc = callsNamed("SetCell")[1]
    report("P6 an interior point sends the cell name", sc and sc[3] == "Vivec, Guild of Mages")
    report("P6b ... and 50 more gold is gone", goldOf(1) == 20)
end

do
    -- cost scales with level, with a floor; gold in several stacks
    setup()
    local function costFor(level, gold)
        local p = player(1, "Alice", "-3, 4", { gold = gold, level = level })
        moveTo(1, "-3, 6"); moveTo(1, "-3, 4")
        openList(1); clear(); pick(1, 0)
        local spent = gold - goldOf(1)
        return spent
    end
    report("P7 level 1 pays the minimum (25)", costFor(1, 100) == 25)
    setup()
    report("P8 level 3 pays 30 (10 per level, above the minimum)", costFor(3, 100) == 30)
    setup()
    report("P9 level 20 pays 200", costFor(20, 500) == 200)

    setup()
    local p = player(1, "Alice", "-3, 4", { level = 10 })
    p.data.inventory = { { refId = "gold_001", count = 60, charge = -1, enchantmentCharge = -1, soul = "" },
        { refId = "misc_item", count = 1, charge = -1, enchantmentCharge = -1, soul = "" },
        { refId = "Gold_001", count = 70, charge = -1, enchantmentCharge = -1, soul = "" } }
    moveTo(1, "-3, 6"); moveTo(1, "-3, 4")
    openList(1); clear(); pick(1, 0)
    report("P10 100 gold is taken across two stacks, other items stay", goldOf(1) == 30 and
        (function() for _, i in pairs(p.data.inventory) do if i.refId == "misc_item" then return true end end end)(), goldOf(1))

    setup()
    p = player(1, "Alice", "-3, 4", { level = 10, gold = 99 })
    moveTo(1, "-3, 6"); moveTo(1, "-3, 4")
    openList(1); clear(); pick(1, 0)
    report("P11 not enough gold (99 of 100): refused with the price, nothing happens",
        #callsNamed("SetCell") == 0 and goldOf(1) == 99 and told(1, "costs 100 gold and you have 99"))

    setup()
    p = player(1, "Alice", "-3, 4", { level = 10 })
    moveTo(1, "-3, 6"); moveTo(1, "-3, 4")
    openList(1); clear(); pick(1, 0)
    report("P12 no gold at all is refused as well", #callsNamed("SetCell") == 0 and told(1, "you have 0"))
end

------------------------------------------------------------ /travel: free at a travel point
do
    setup()
    player(1, "Alice", "-3, 6", { gold = 5, level = 30 })     -- Ald-ruhn
    moveTo(1, "-3, 6"); moveTo(1, "-3, -3"); moveTo(1, "-3, 6")
    local list = openList(1)
    local balmora, n = nil, 0
    for l in list[5]:gmatch("[^\n]+") do if l:find("^Balmora") then balmora = n end n = n + 1 end
    clear(); pick(1, balmora)
    report("F1 from a travel point it is free even without any gold", #callsNamed("SetCell") == 1 and goldOf(1) == 5 and
        told(1, "You travel to Balmora."))
    -- picking the point you stand in
    moveTo(1, "-3, -3")
    list = openList(1); clear(); pick(1, balmora)
    report("F2 choosing the place you are in is refused", #callsNamed("SetCell") == 0 and told(1, "already in Balmora"))
end

------------------------------------------------------------ /travel: refusals
do
    local function ready()
        setup()
        local p = player(1, "Alice", "-3, 4", { gold = 1000, level = 2 })
        moveTo(1, "-3, 6"); moveTo(1, "-3, 4")
        return p
    end
    ready()
    myTes3mpCombat.Mark(1)
    clear(); say(1, "/travel")
    report("R1 in combat: no list, a clear message", #callsNamed("ListBox") == 0 and told(1, "while in combat"))
    T.time = T.time + 11
    report("R1b ten quiet seconds later it works again", openList(1) ~= nil)

    ready()
    openList(1); myTes3mpCombat.Mark(1); clear(); pick(1, 0)
    report("R2 a fight that starts while the list is open stops the trip", #callsNamed("SetCell") == 0 and goldOf(1) == 1000)

    ready()
    customEventHooks.triggerHandlers("OnPlayerDeath", { validDefaultHandler = true }, { 1 })
    clear(); say(1, "/travel")
    report("R3 dead: refused", #callsNamed("ListBox") == 0 and told(1, "while dead"))
    customEventHooks.triggerHandlers("OnPlayerResurrect", { validDefaultHandler = true }, { 1 })
    report("R3b after resurrecting it works", openList(1) ~= nil)

    ready()
    T.live[1].health = 0
    clear(); say(1, "/travel")
    report("R4 health 0 counts as dead too", #callsNamed("ListBox") == 0 and told(1, "while dead"))

    ready()
    myTes3mpDowned = { IsDowned = function(pid) return pid == 1 end }
    clear(); say(1, "/travel")
    report("R5 downed: refused", #callsNamed("ListBox") == 0 and told(1, "while downed"))
    myTes3mpDowned = nil
    report("R5b without downed.lua loaded there is no error", openList(1) ~= nil)

    ready()
    Players[1].data.character.race = ""
    clear(); say(1, "/travel")
    report("R6 character generation: refused", #callsNamed("ListBox") == 0 and told(1, "Finish creating"))

    -- no combat.lua loaded at all
    setup({ combat = false })
    player(1, "Alice", "-3, 4", { gold = 1000 })
    moveTo(1, "-3, 6"); moveTo(1, "-3, 4")
    report("R7 works when combat.lua is not loaded", openList(1) ~= nil)

    -- stale answers
    ready()
    openList(1); T.time = T.time + 601; clear(); pick(1, 0)
    report("R8 a list that sat open for ten minutes is no longer honoured", #callsNamed("SetCell") == 0)
    ready()
    openList(1); clear(); pick(1, 7)
    report("R9 a line number outside the list does nothing", #callsNamed("SetCell") == 0)
    ready()
    openList(1); clear(); pick(1, "18446744073709551615")
    report("R10 'nothing picked' (the client's huge number) does nothing, and closes the offer",
        #callsNamed("SetCell") == 0)
    pick(1, 0)
    report("R10b ... and a later answer finds no offer", #callsNamed("SetCell") == 0)
    ready()
    clear(); pick(1, 0)
    report("R11 an answer without any list does nothing", #callsNamed("SetCell") == 0)
    ready()
    openList(1)
    customEventHooks.triggerHandlers("OnGUIAction", { validDefaultHandler = true }, { 1, 9001, "0" })
    report("R12 other scripts' menu ids are ignored", #callsNamed("SetCell") == 0)
    -- the pid is reused by somebody else
    ready()
    openList(1)
    Players[1].accountName = "Mallory"
    clear(); pick(1, 0)
    report("R13 an answer from a different account on the same pid is ignored", #callsNamed("SetCell") == 0)
    ready()
    openList(1)
    customEventHooks.triggerHandlers("OnPlayerDisconnect", { validDefaultHandler = true }, { 1 })
    clear(); pick(1, 0)
    report("R14 disconnecting drops the offer", #callsNamed("SetCell") == 0)
end

------------------------------------------------------------ /goto
do
    setup()
    player(1, "Alice", "-3, 4", { level = 5 })
    player(2, "Bob Brother", "Vivec, Guild of Mages", { level = 7 })
    T.live[2].x, T.live[2].y, T.live[2].z, T.live[2].rz = 11, 22, 33, 2.5
    clear(); say(1, "/goto bob brother")
    local sc, sp, sr = callsNamed("SetCell")[1], callsNamed("SetPos")[1], callsNamed("SetRot")[1]
    report("G1 /goto <name> (case-insensitive, with a space in it) uses the stock teleport to his cell and spot",
        sc and sc[2] == 1 and sc[3] == "Vivec, Guild of Mages" and sp and sp[3] == 11 and sp[5] == 33 and sr and sr[4] == 2.5 and
        #callsNamed("SendCell") == 1 and #callsNamed("SendPos") == 1)
    report("G1b both players are told (stock messages)", told(1, "teleported to Bob Brother") and told(2, "Alice to your location"))

    clear(); say(1, "/goto 2")
    report("G2 a second /goto within a minute is refused with the time left",
        #callsNamed("SetCell") == 0 and told(1, "again in 60 seconds"))
    T.time = T.time + 59
    clear(); say(1, "/goto 2")
    report("G2b ... still refused at 59 seconds (1 left)", #callsNamed("SetCell") == 0 and told(1, "again in 1 seconds"))
    T.time = T.time + 1
    clear(); say(1, "/goto 2")
    report("G3 after 60 seconds it works again, by player number", #callsNamed("SetCell") == 1)

    T.time = T.time + 100
    clear(); say(2, "/goto Alice")
    report("G4 the cooldown is per player: Bob can go at once", #callsNamed("SetCell") == 1)

    T.time = T.time + 100
    clear(); say(1, "/goto Nobody")
    report("G5 unknown name: told, no cooldown spent", #callsNamed("SetCell") == 0 and told(1, "no player called Nobody"))
    clear(); say(1, "/goto Alice")
    report("G6 himself: refused, no cooldown spent", #callsNamed("SetCell") == 0 and told(1, "with yourself"))
    clear(); say(1, "/goto")
    report("G7 no name: lists who is online", told(1, "Bob Brother"))
    clear(); say(1, "/goto Bob")
    report("G7b a partial name is not guessed", #callsNamed("SetCell") == 0)
    clear(); say(1, "/goto Bob Brother")
    report("G7c ... and the failed tries did not spend the cooldown", #callsNamed("SetCell") == 1)

    T.time = T.time + 100
    myTes3mpCombat.Mark(1)
    clear(); say(1, "/goto 2")
    report("G8 in combat: refused", #callsNamed("SetCell") == 0 and told(1, "while in combat"))
    T.time = T.time + 11
    customEventHooks.triggerHandlers("OnPlayerDeath", { validDefaultHandler = true }, { 1 })
    clear(); say(1, "/goto 2")
    report("G9 dead: refused", #callsNamed("SetCell") == 0 and told(1, "while dead"))
    customEventHooks.triggerHandlers("OnPlayerResurrect", { validDefaultHandler = true }, { 1 })
    myTes3mpDowned = { IsDowned = function(pid) return pid == 1 end }
    clear(); say(1, "/goto 2")
    report("G10 downed: refused", #callsNamed("SetCell") == 0 and told(1, "while downed"))
    myTes3mpDowned = { IsDowned = function(pid) return pid == 2 end }
    clear(); say(1, "/goto 2")
    report("G10b going to a downed brother is allowed (that is how you help)", #callsNamed("SetCell") == 1)
    myTes3mpDowned = nil

    T.time = T.time + 100
    -- target logged out between the command and the reply is impossible in one tick; a logged-out player is simply not found
    Players[2].loggedIn = false
    clear(); say(1, "/goto Bob Brother")
    report("G11 a player who is not logged in is not found", #callsNamed("SetCell") == 0)
end

------------------------------------------------------------ /party
do
    setup()
    player(1, "Zed", "-3, -3", { level = 12, health = 85, base = 100 })
    player(2, "Anna", "Vivec, Guild of Mages", { level = 4, health = 3, base = 7 })
    player(3, "Mia", "-10, 4", { level = 9, health = 50, base = 50, region = "West Gash Region" })
    local c = player(4, "Newbie", "")
    c.data.character.race = ""
    clear(); say(1, "/party")
    local text = messagesTo(1)[1] or ""
    report("Y1 header counts the players", text:find("Online (4):", 1, true) ~= nil, text)
    report("Y2 level, health percentage and cell for each",
        text:find("Anna: level 4, health 43%, Vivec, Guild of Mages", 1, true) ~= nil and
        text:find("Zed (you): level 12, health 85%, Balmora (-3, -3)", 1, true) ~= nil, text)
    report("Y3 an exterior cell shows its region", text:find("Mia: level 9, health 100%, West Gash Region (-10, 4)", 1, true) ~= nil)
    report("Y4 a player in character generation is listed as such", text:find("Newbie: creating a character", 1, true) ~= nil)
    report("Y5 sorted by name", (text:find("Anna", 1, true) or 0) < (text:find("Mia", 1, true) or 0) and
        (text:find("Mia", 1, true) or 0) < (text:find("Newbie", 1, true) or 0) and
        (text:find("Newbie", 1, true) or 0) < (text:find("Zed", 1, true) or 0))
    customEventHooks.triggerHandlers("OnPlayerDeath", { validDefaultHandler = true }, { 2 })
    myTes3mpDowned = { IsDowned = function(pid) return pid == 3 end }
    clear(); say(1, "/party")
    text = messagesTo(1)[1]
    report("Y6 dead and downed players are marked", text:find("Anna: level 4, health 43%, dead", 1, true) ~= nil and
        text:find("Mia: level 9, health 100%, downed", 1, true) ~= nil, text)
    myTes3mpDowned = nil
    -- unknown health (no stats yet) must not crash or divide by zero
    T.live[1].health, T.live[1].base = nil, nil
    Players[1].data.stats.healthBase = 0
    clear(); say(1, "/party")
    report("Y7 unknown health is shown as unknown", (messagesTo(1)[1] or ""):find("Zed (you): level 12, health unknown", 1, true) ~= nil)
    -- /party works for a player in character generation
    clear(); say(4, "/party")
    report("Y8 /party works for a player in character generation", #messagesTo(4) == 1)
end

------------------------------------------------------------ gold only from gold_001
do
    setup()
    local p = player(1, "Alice", "-3, 4", { level = 1 })
    p.data.inventory = { { refId = "gold_005", count = 500, charge = -1, enchantmentCharge = -1, soul = "" } }
    moveTo(1, "-3, 6"); moveTo(1, "-3, 4")
    openList(1); clear(); pick(1, 0)
    report("M1 other items do not count as gold", #callsNamed("SetCell") == 0)
end

------------------------------------------------------------ the switch
do
    setup({ travel = false })
    player(1, "Alice", "-3, 4", { gold = 100 })
    player(2, "Bob", "-3, 4")
    clear()
    say(1, "/travel"); say(1, "/goto Bob"); say(1, "/party")
    moveTo(1, "-3, 6")
    report("W1 with the switch off no command answers and nothing is discovered",
        #T.msgs == 0 and #callsNamed("ListBox") == 0 and #callsNamed("SetCell") == 0 and discovered(1) == 0)
    report("W2 the module says so in the log", T.logContains("switched off"))

    setup({ nilSwitch = true })
    player(1, "Alice", "-3, 4", { gold = 100 })
    moveTo(1, "-3, 6")
    report("W3 a missing switch (nil) counts as on", discovered(1) == 1)
end

------------------------------------------------------------ source facts this module relies on
do
    local logic = T.csSource("logicHandler.lua")
    report("S1 CoreScripts still has logicHandler.TeleportToPlayer(pid, originPid, targetPid)",
        logic:find("logicHandler.TeleportToPlayer = function(pid, originPid, targetPid)", 1, true) ~= nil)
    report("S2 ... and it does SetCell, SendCell, SetPos, SetRot, SendPos",
        logic:find("tes3mp.SetCell(originPid, targetCell)", 1, true) ~= nil and
        logic:find("tes3mp.SendCell(originPid)", 1, true) ~= nil and logic:find("tes3mp.SendPos(originPid)", 1, true) ~= nil)
    local events = T.csSource("eventHandler.lua")
    report("S3 eventHandler.lua raises OnGUIAction handlers with the picked line as a string",
        events:find('data = tostring(data)', 1, true) ~= nil and
        events:find('triggerHandlers("OnGUIAction", eventStatus, {pid, idGui, data})', 1, true) ~= nil)
    report("S4 eventHandler.lua raises OnPlayerCellChange handlers after SaveCell",
        events:find('Players[pid]:SaveCell(packetReader.GetPlayerPacketTables(pid, "PlayerCellChange"))', 1, true) ~= nil and
        events:find('triggerHandlers("OnPlayerCellChange"', 1, true) ~= nil)
end

-- "At a travel point" outdoors is its cell or one of the eight around it.
do
    local travel = setup()
    local function foundNames(pid)
        local names = {}
        for _, point in ipairs(travel.Found(pid)) do names[#names + 1] = point.name end
        table.sort(names)
        return table.concat(names, ",")
    end
    player(1, "Nel", "-3, 4", { gold = 0, level = 5 })
    moveTo(1, "-5, -1")
    report("N1 two cells away from the nearest point: nothing is discovered, and travel is not free",
        foundNames(1) == "" and travel.IsAtPoint(1) == false, foundNames(1))
    moveTo(1, "-3, -2")         -- the cell north of Balmora's strider port at -3, -3
    report("N2 an outdoor point is discovered from a neighbouring cell", foundNames(1) == "Balmora", foundNames(1))
    report("N3 and a neighbouring cell counts as being at the point, so travelling on is free", travel.IsAtPoint(1) == true)
    moveTo(1, "-4, -4")         -- diagonal neighbour
    report("N4 diagonal neighbours count too, and nothing is discovered twice", foundNames(1) == "Balmora" and travel.IsAtPoint(1) == true)
    moveTo(1, "Balmora, Council Club")
    report("N5 indoors only the exact cell counts: a building in town is not the travel point",
        travel.IsAtPoint(1) == false and foundNames(1) == "Balmora")
    moveTo(1, "Balmora, Guild of Mages")
    report("N6 an indoor travel point is discovered in its own cell", foundNames(1):find("Guild of Mages", 1, true) ~= nil, foundNames(1))
end

T.summary()
