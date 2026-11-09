-- downed.lua: dying with company means being downed; a mate activating the body gets you up;
-- otherwise the stock death (real BasePlayer:ProcessDeath / :Resurrect) runs.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local RES = enumerations.resurrect

------------------------------------------------------------ the real stock death code, and the glue eventHandler.lua puts around it
_G.patterns = nil
local Base = dofile(T.cs .. "/scripts/player/base.lua")
dofile(T.cs .. "/scripts/packetReader.lua")
_G.contentFixer.UnequipDeadlyItems = function() end

-- eventHandler.OnPlayerDeath (eventHandler.lua:1020) and OnDeathTimeExpiration (:1987), as written there
local function death(pid)
    if Players[pid] ~= nil and Players[pid]:IsLoggedIn() then
        local eventStatus = customEventHooks.triggerValidators("OnPlayerDeath", { pid })
        if eventStatus.validDefaultHandler then
            Players[pid]:ProcessDeath()
        end
        customEventHooks.triggerHandlers("OnPlayerDeath", eventStatus, { pid })
    end
end
function OnDeathTimeExpiration(pid, accountName)
    if Players[pid] ~= nil and Players[pid]:IsLoggedIn() and Players[pid].accountName == accountName then
        local eventStatus = customEventHooks.triggerValidators("OnDeathTimeExpiration", { pid })
        if eventStatus.validDefaultHandler then
            Players[pid]:Resurrect()
        end
        customEventHooks.triggerHandlers("OnDeathTimeExpiration", eventStatus, { pid })
    end
end

------------------------------------------------------------ a fake game
local hp, hpBase, cellOf = {}, {}, {}
local resurrects, jails, statsSent, healthSet = {}, {}, {}, {}
local packetSender, packetTarget

tes3mp.GetHealthCurrent = function(pid) return hp[pid] or 0 end
tes3mp.GetHealthBase = function(pid) return hpBase[pid] or 0 end
tes3mp.GetCell = function(pid) return cellOf[pid] or "" end
tes3mp.DoesPlayerHavePlayerKiller = function() return false end
tes3mp.GetPlayerKillerName = function() return "a Dremora" end
tes3mp.GetBounty = function() return 0 end
tes3mp.Resurrect = function(pid, kind) resurrects[#resurrects + 1] = { pid = pid, kind = kind } end
tes3mp.Jail = function(pid, days) jails[#jails + 1] = { pid = pid, days = days } end
tes3mp.SetHealthCurrent = function(pid, value) healthSet[#healthSet + 1] = { pid = pid, value = value }; hp[pid] = value end
tes3mp.SendStatsDynamic = function(pid) statsSent[#statsSent + 1] = pid end
-- the object list the real packetReader reads (one activated player)
tes3mp.GetObjectListSize = function() return 1 end
tes3mp.IsObjectPlayer = function() return true end
tes3mp.GetObjectPid = function() return packetTarget end
tes3mp.DoesObjectHavePlayerActivating = function() return true end
tes3mp.GetObjectActivatingPid = function() return packetSender end
tes3mp.GetDrawState = function() return 0 end

-- eventHandler.OnGenericObjectEvent (eventHandler.lua:1369) for "ObjectActivate", with the real packetReader
local function activate(pid, cell, targetPid)
    packetSender, packetTarget = pid, targetPid
    local tables = packetReader.GetObjectPacketTables("ObjectActivate")
    local status = customEventHooks.triggerValidators("OnObjectActivate", { pid, cell, tables.objects, tables.players })
    customEventHooks.triggerHandlers("OnObjectActivate", status, { pid, cell, tables.objects, tables.players })
end

local D
local function timers(name) local n = 0 for _, t in ipairs(T.timers) do if t.name == name then n = n + 1 end end return n end
-- before: runs after the server is reset and before downed.lua is loaded (a disk to start from, a validator that runs first)
local function setup(settings, before)
    hp, hpBase, cellOf, resurrects, jails, statsSent, healthSet = {}, {}, {}, {}, {}, {}, {}
    T.fresh(settings or T.copy(T.DEFAULT_SETTINGS))
    myTes3mpDowned = nil
    if before then before() end
    D = T.load("downed")
    T.postInit()
end
local function player(pid, name)
    local p = T.player(pid, name)
    p.ProcessDeath, p.Resurrect = Base.ProcessDeath, Base.Resurrect
    p.data.shapeshift = { isWerewolf = false }
    p.data.spellsActive = { x = 1 }
    hp[pid], hpBase[pid] = 100, 100
    return p
end
local function die(pid) hp[pid] = 0; death(pid) end
local function tick() T.fire(T.timerNamed("MyTes3mpDownedTick")) end
local function run(seconds) for _ = 1, seconds do T.time = T.time + 1; tick() end end
local function said(pid, text)
    local n = 0
    for _, m in ipairs(T.msgs) do if m[1] == pid and m[2]:find(text, 1, true) then n = n + 1 end end
    return n
end
local function owed(account)
    local s = T.diskState("myTes3mpDowned.json")
    return s ~= nil and s.owed ~= nil and s.owed[account] == true
end
local function stockDeaths() return timers("OnDeathTimeExpiration") end
local function two()
    setup(); player(1, "Alice"); player(2, "Bob"); cellOf[1] = "Balmora, Guild of Mages"
end

------------------------------------------------------------ the engine facts the design rests on
local es = T.csSource("eventHandler.lua")
report("E1 the stock death is the OnPlayerDeath validator + Players[pid]:ProcessDeath() when the default handler is valid",
    es:find('eventHandler.OnPlayerDeath = function(pid)\n    if Players[pid] ~= nil and Players[pid]:IsLoggedIn() then\n        local eventStatus = customEventHooks.triggerValidators("OnPlayerDeath", {pid})\n        if eventStatus.validDefaultHandler then\n            Players[pid]:ProcessDeath()', 1, true) ~= nil)
report("E2 the respawn is OnDeathTimeExpiration -> Players[pid]:Resurrect()",
    es:find('eventHandler.OnDeathTimeExpiration', 1, true) ~= nil and es:find("Players[pid]:Resurrect()", 1, true) ~= nil)
report("E3 an activated player arrives in targetPlayers, the activator as pid",
    T.csSource("packetReader.lua"):find("packetTables.players[pid] = player", 1, true) ~= nil
    and es:find('triggerValidators("On" .. packetType,\n                {pid, cellDescription, objects, targetPlayers})', 1, true) ~= nil)
report("E4 tes3mp.Resurrect type REGULAR is 0 (no teleport)", RES.REGULAR == 0 and RES.IMPERIAL_SHRINE == 1)
report("E5 the server raises OnPlayerResurrect when the client reports it is alive (serverCore.lua)",
    T.csSource("serverCore.lua"):find('triggerHandlers("OnPlayerResurrect"', 1, true) ~= nil)

------------------------------------------------------------ alone: stock death
setup(); player(1, "Alice")
die(1)
report("A1 alone: no downed state, the stock death starts (death timer set once)", not D.IsDowned(1) and stockDeaths() == 1)
report("A1b and nobody was told anything about being down", said(1, "You are down") == 0)
setup(); player(1, "Alice"); player(2, "Bob"); hp[2] = 0
die(1)
report("A2 the only other player is dead too: stock death", not D.IsDowned(1) and stockDeaths() == 1)
setup(); player(1, "Alice"); T.player(2, "Bob", { loggedIn = false })
die(1)
report("A3 the other player has not finished logging in: stock death", stockDeaths() == 1)

------------------------------------------------------------ downed
two()
die(1)
report("B1 with company: downed, the stock death is held back", D.IsDowned(1) and stockDeaths() == 0)
report("B1b the global for other scripts says so", myTes3mpDowned ~= nil and myTes3mpDowned.IsDowned(1) == true and myTes3mpDowned.IsDowned(2) == false)
report("B2 the downed player is told the time and about /giveup", said(1, "60 seconds") == 1 and said(1, "/giveup") == 1)
report("B3 the others are told who and where", said(2, "p1 is down in Balmora, Guild of Mages") == 1)
report("B4 the debt is written down at once (so quitting cannot dodge it)", owed("alice"))

-- revived
local before = #T.msgs
activate(2, "Balmora, Guild of Mages", 1)
report("V1 a mate activating the body: resurrected in place, once", #resurrects == 1 and resurrects[1].pid == 1 and resurrects[1].kind == RES.REGULAR)
report("V1b no penalty: no death timer, no jail, no shrine", stockDeaths() == 0 and #jails == 0 and not D.IsDowned(1))
report("V1c the debt is cleared", not owed("alice"))
report("V1d both are told", said(1, "p2 helps you up") == 1 and said(2, "You help p1 up") == 1)
tick()
report("V2 health is not touched before the server has heard that he is alive", #healthSet == 0)
hp[1] = 100 -- the client resurrects with full health and reports it
T.time = T.time + 3
tick()
report("V3 then it is set to a quarter of the maximum and sent", #healthSet == 1 and healthSet[1].value == 25 and statsSent[1] == 1, healthSet[1] and healthSet[1].value)
tick(); tick()
report("V3b only once", #healthSet == 1)
customEventHooks.triggerHandlers("OnPlayerResurrect", { validDefaultHandler = true }, { 1 })
activate(2, "Balmora, Guild of Mages", 1)
report("V4 activating him now that he is up does nothing more", #resurrects == 1)

two(); die(1)
activate(1, "Balmora, Guild of Mages", 1)
report("V5 activating your own body does not count", D.IsDowned(1) and #resurrects == 0)
activate(1, "Balmora, Guild of Mages", 2)
report("V6 activating a player who is not downed does nothing", #resurrects == 0 and D.IsDowned(1))
Players[2].loggedIn = false
activate(2, "Balmora, Guild of Mages", 1)
report("V7 a helper who is not logged in does not count", D.IsDowned(1) and #resurrects == 0)
Players[2].loggedIn = true; hp[2] = 0
activate(2, "Balmora, Guild of Mages", 1)
report("V8 nor does a dead one", D.IsDowned(1) and #resurrects == 0)

-- the real activation event with no player in it
two(); die(1)
customEventHooks.triggerHandlers("OnObjectActivate", { validDefaultHandler = true }, { 2, "Balmora", { ["1-0"] = { refId = "door" } }, {} })
report("V9 activating an ordinary object is ignored", D.IsDowned(1) and #resurrects == 0)
customEventHooks.triggerHandlers("OnObjectActivate", { validDefaultHandler = true }, { 2, "Balmora", {}, nil })
report("V10 a missing targetPlayers table is tolerated", D.IsDowned(1))
customEventHooks.triggerHandlers("OnObjectActivate", { validDefaultHandler = false }, { 2, "Balmora", {}, { [1] = Players[1] } })
report("V11 an activation another script has vetoed is not acted on", D.IsDowned(1) and #resurrects == 0)

------------------------------------------------------------ nobody comes: the stock death, unchanged
two(); die(1)
local told = said(1, "seconds left")
run(29)
report("T1 29 seconds in: still downed, no reminder yet", D.IsDowned(1) and stockDeaths() == 0 and said(1, "seconds left") == 0)
run(1)
report("T2 at 30 seconds left: one reminder", said(1, "30 seconds left") == 1, said(1, "seconds left"))
run(19)
run(1)
report("T3 at 10 seconds left: one more", said(1, "10 seconds left") == 1 and said(1, "seconds left") == 2)
run(9)
report("T4 one second short: still downed", D.IsDowned(1) and stockDeaths() == 0)
run(1)
report("T5 time is up: the stock ProcessDeath ran exactly once (one death timer, spells cleared)",
    not D.IsDowned(1) and stockDeaths() == 1 and next(Players[1].data.spellsActive) == nil)
report("T5b the stock death message went to everybody, naming the killer", T.messageContains("p1 was killed by a Dremora"))
run(10)
report("T6 later ticks do not repeat it", stockDeaths() == 1 and said(1, "Nobody came") == 1)
report("T6b still owes until the respawn", owed("alice"))
-- the stock timer fires: the real Resurrect (shrine + jail)
T.fire(T.timerNamed("OnDeathTimeExpiration"))
report("T7 stock respawn: Imperial shrine and 5 days in jail, as without this script",
    #resurrects == 1 and resurrects[1].kind == RES.IMPERIAL_SHRINE and #jails == 1 and jails[1].days == config.deathPenaltyJailDays)
customEventHooks.triggerHandlers("OnPlayerResurrect", { validDefaultHandler = true }, { 1 })
report("T8 the client's resurrection report clears the debt", not owed("alice"))
die(1)
report("T9 and the next death with company is a downed state again", D.IsDowned(1))

-- /giveup
two(); die(1)
customCommandHooks.getCallback("giveup")(1, { "giveup" })
report("G1 /giveup: stock death at once, once", not D.IsDowned(1) and stockDeaths() == 1 and said(1, "You give up") == 1)
customCommandHooks.getCallback("giveup")(1, { "giveup" })
run(70)
report("G2 a second /giveup and the old countdown do nothing more", stockDeaths() == 1 and said(1, "You are not down") == 1)
two()
customCommandHooks.getCallback("giveup")(2, { "giveup" })
report("G3 /giveup when not down only says so", stockDeaths() == 0 and said(2, "You are not down") == 1)

-- reported twice
two(); die(1); local n = #T.msgs
death(1)
report("H1 a second death report while downed changes nothing", D.IsDowned(1) and #T.msgs == n and stockDeaths() == 0)

-- other handlers still hear of the death, and see that the default was stopped
local seen
two()
customEventHooks.registerHandler("OnPlayerDeath", function(status, pid) seen = status.validDefaultHandler end)
die(1)
report("H2 other OnPlayerDeath handlers still run and see validDefaultHandler=false", seen == false)

-- somebody else's veto comes first
setup(nil, function()
    customEventHooks.registerValidator("OnPlayerDeath", function() return customEventHooks.makeEventStatus(false, nil) end)
end)
player(1, "Alice"); player(2, "Bob")
die(1)
report("H3 a death another script has already vetoed does not become a downed state", not D.IsDowned(1) and stockDeaths() == 0)

------------------------------------------------------------ leaving
two(); die(1)
customEventHooks.triggerHandlers("OnPlayerDisconnect", { validDefaultHandler = true }, { 1 })
Players[1] = nil
run(70)
report("X1 disconnect while downed: nothing stuck, no death run for a player who is gone", not D.IsDowned(1) and stockDeaths() == 0)
report("X1b the debt stays on the account", owed("alice"))
player(1, "Alice") -- logs in again; his client dies again because his saved health is 0
die(1)
report("X2 coming back: the stock death, no second chance though Bob is online", not D.IsDowned(1) and stockDeaths() == 1)
T.fire(T.timerNamed("OnDeathTimeExpiration"))
customEventHooks.triggerHandlers("OnPlayerResurrect", { validDefaultHandler = true }, { 1 })
report("X3 after the respawn and jail he is clear", not owed("alice") and #jails == 1)
die(1)
report("X4 and may be downed again", D.IsDowned(1))

-- the debt survives a server restart
two(); die(1)
local disk = T.copy(T.disk)
setup(nil, function() T.disk = disk end)
player(1, "Alice"); player(2, "Bob")
die(1)
report("X5 the debt survives a restart: stock death", not D.IsDowned(1) and stockDeaths() == 1)
setup(nil, function() T.disk["custom/myTes3mpDowned.json"] = "this is not json {" end)
player(1, "Alice"); player(2, "Bob")
die(1)
report("X6 an unreadable state file is tolerated", D.IsDowned(1))
setup(nil, function() T.disk["custom/myTes3mpDowned.json"] = '{"owed":{"alice":"yes","bob":true},"junk":1}' end)
player(1, "Alice"); player(2, "Bob")
die(1); die(2)
report("X7 odd entries in the state file are ignored; a real one is honoured",
    D.IsDowned(1) and not D.IsDowned(2) and stockDeaths() == 1)

-- the last helper goes
two(); die(1)
customEventHooks.triggerHandlers("OnPlayerDisconnect", { validDefaultHandler = true }, { 2 })
Players[2] = nil
tick()
report("Y1 the only helper leaves: no point waiting, stock death for the downed player", not D.IsDowned(1) and stockDeaths() == 1 and said(1, "nobody left") == 1)

-- the pid is reused by somebody else
two(); die(1)
Players[1] = nil
player(1, "Carol")
tick()
report("Y2 a new player on a downed player's pid is not touched", not D.IsDowned(1) and stockDeaths() == 0)

------------------------------------------------------------ two at once
setup(); player(1, "Alice"); player(2, "Bob"); player(3, "Carol")
die(1); die(2)
report("M1 two downed at once with a third standing", D.IsDowned(1) and D.IsDowned(2) and stockDeaths() == 0)
activate(1, "Balmora", 2)
report("M2 a downed player cannot revive the other", D.IsDowned(2) and #resurrects == 0)
activate(3, "Balmora", 1)
report("M3 the standing one gets one up; the other stays down", not D.IsDowned(1) and D.IsDowned(2) and #resurrects == 1 and resurrects[1].pid == 1)
run(60)
report("M4 the other times out on his own clock, once", not D.IsDowned(2) and stockDeaths() == 1)

-- wipe: two players, both fall
two(); die(1)
die(2)
report("W1 the helper dies while the other is down: he has nobody, stock death", not D.IsDowned(2) and stockDeaths() == 1)
tick()
report("W2 and the downed one is released at the next tick (nobody left to help)", not D.IsDowned(1) and stockDeaths() == 2)

------------------------------------------------------------ settings and tolerance
local s = T.copy(T.DEFAULT_SETTINGS); s.downedSeconds = 0
setup(s); player(1, "Alice"); player(2, "Bob")
die(1)
report("Z1 switched off: stock death with company, no timer, no command, no global",
    stockDeaths() == 1 and T.timerNamed("MyTes3mpDownedTick") == nil and customCommandHooks.getCallback("giveup") == nil
    and myTes3mpDowned == nil and not D.IsDowned(1))
activate(2, "Balmora", 1)
report("Z1b and activation does nothing", #resurrects == 0)
s = T.copy(T.DEFAULT_SETTINGS); s.downedSeconds = nil
setup(s); player(1, "Alice"); player(2, "Bob"); die(1)
report("Z2 a missing setting means 60 seconds", D.IsDowned(1) and said(1, "60 seconds") == 1)
s = T.copy(T.DEFAULT_SETTINGS); s.downedSeconds = 20
setup(s); player(1, "Alice"); player(2, "Bob"); die(1)
run(9)
report("Z3 20 seconds: told 20, and no 30-second reminder", said(1, "20 seconds") == 1 and said(1, "30 seconds left") == 0)
run(1)
report("Z3b reminder at 10 left", said(1, "10 seconds left") == 1)
run(10)
report("Z3c and the stock death at 20", stockDeaths() == 1)
s = T.copy(T.DEFAULT_SETTINGS); s.downedSeconds = "30"
setup(s); player(1, "Alice"); player(2, "Bob"); die(1)
report("Z4 a numeric string is accepted", said(1, "30 seconds") == 1)

setup(); player(1, "Alice"); player(2, "Bob"); die(1)
local id, tm = T.timerNamed("MyTes3mpDownedTick")
report("Z5 a timer with a global callback is started", id ~= nil and tm.started == true and type(_G.MyTes3mpDownedTick) == "function")
local restarts = tm.restarts
tes3mp.GetHealthCurrent = function() error("boom") end
tick()
tes3mp.GetHealthCurrent = function(pid) return hp[pid] or 0 end
report("Z6 a failing tick is logged and the timer restarted", T.logContains("Check failed") and tm.restarts == restarts + 1)
Players[1].ProcessDeath = function() error("kaput") end
run(61)
report("Z7 if the stock call itself fails it is logged, once, and the player is not left downed", T.logContains("ProcessDeath failed") and not D.IsDowned(1))

T.summary()
