-- combat.lua: who is in a fight right now.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report

local health = {}
local combat

local function setup()
  T.fresh()
  health = {}
  tes3mp.GetHealthCurrent = function(pid) return health[pid] end
  combat = T.load("combat")
  T.postInit()
end
local function tick() MyTes3mpCombatTick() end
local function hit(pid, targets)
  customEventHooks.triggerHandlers("OnObjectHit", { validDefaultHandler = true, validCustomHandlers = true },
    { pid, "Balmora", {}, targets or {} })
end

setup()
report("K1 the module publishes itself for the other scripts", myTes3mpCombat == combat)
local id, timer = T.timerNamed("MyTes3mpCombatTick")
report("K2 a timer is created and started at server start", timer ~= nil and timer.started == true)

T.player(1, "Alice"); health[1] = 100
report("K3 a player nobody has seen fight is not in combat", combat.InCombat(1) == false and combat.SecondsQuiet(1) == math.huge)
tick()
report("K4 the first look at a player's health is not a fight", combat.InCombat(1) == false)
health[1] = 100.3; tick(); health[1] = 100; tick()
report("K5 a wobble of less than half a point is not a fight", combat.InCombat(1) == false)

local entered = {}
table.insert(combat.listeners, function(pid) entered[#entered + 1] = pid end)
health[1] = 80; tick()
report("K6 losing health puts the player in combat", combat.InCombat(1) == true and combat.SecondsQuiet(1) == 0)
report("K7 listeners are told once, at the moment combat starts", #entered == 1 and entered[1] == 1)
health[1] = 60; tick()
report("K8 another blow while already fighting does not tell them again", #entered == 1)

T.time = T.time + combat.quietSeconds - 1
report("K9 still in combat just before the quiet time is up", combat.InCombat(1) == true)
T.time = T.time + 1
report("K10 out of combat once it has been quiet long enough", combat.InCombat(1) == false)
health[1] = 100; tick()
report("K11 health going up (healing) is not a fight", combat.InCombat(1) == false)

-- dealing damage counts too
T.player(2, "Bob"); health[2] = 50; tick()
hit(2)
report("K12 striking a blow puts the attacker in combat", combat.InCombat(2) == true and entered[#entered] == 2)
T.time = T.time + combat.quietSeconds
hit(1, { [2] = { hittingPid = 1 } })
report("K13 a hit on another player marks him as well", combat.InCombat(1) == true and combat.InCombat(2) == true)
report("K14 odd target tables and unknown players are tolerated",
  pcall(hit, 9, nil) and pcall(hit, 1, { x = true, [77] = {} }) and pcall(hit, 1, "junk"))

-- a health change the server made itself
do
  local healthBefore = health[1]
  health[1] = 100; tick(); T.time = T.time + combat.quietSeconds + 1
  health[1] = 25; combat.Calm(1); tick()
  report("K14a Calm forgets the last health reading: the drop the server caused is not a blow", combat.InCombat(1) == false)
  health[1] = 20; tick()
  report("K14b a real blow after that still counts", combat.InCombat(1) == true)
  combat.Calm(1)
  report("K14c Calm also ends a fight that was going on", combat.InCombat(1) == false and combat.SecondsQuiet(1) == math.huge)
  report("K14c2 but the record of his last blow is kept (he did take part)", combat.SecondsSinceFight(1) == 0)
  health[1] = 30; tick(); health[1] = 10; tick()
  report("K14c3 and his next blow puts him back in combat", combat.InCombat(1) == true and combat.SecondsQuiet(1) == 0)
  combat.Calm(1)
  report("K14d Calm on a player nobody has seen is tolerated", pcall(combat.Calm, 99))
  health[1] = healthBefore; tick()
end

-- leaving
customEventHooks.triggerHandlers("OnPlayerDisconnect", { validDefaultHandler = true, validCustomHandlers = true }, { 2 })
report("K15 a player who leaves is forgotten", combat.InCombat(2) == false and combat.SecondsQuiet(2) == math.huge)
Players[2] = nil
health[2] = 10; T.player(2, "Carol")
tick()
report("K16 the next player on that pid does not inherit his health as a loss", combat.InCombat(2) == false)

-- robustness
setup(); T.player(1, "A", { loggedIn = false }); health[1] = 100; tick(); health[1] = 1; tick()
report("K17 players who are not logged in are skipped", combat.InCombat(1) == false)
setup(); T.player(1, "A"); health[1] = nil
report("K18 a missing health value is tolerated", pcall(tick))
setup(); T.player(1, "A"); health[1] = 100; tick()
table.insert(combat.listeners, function() error("boom") end)
local seen = false
table.insert(combat.listeners, function() seen = true end)
health[1] = 50
report("K19 a listener that throws does not stop the others or the check", pcall(tick) and seen and combat.InCombat(1))
local before = select(2, T.timerNamed("MyTes3mpCombatTick")).restarts
tes3mp.GetHealthCurrent = function() error("no stats") end
tick()
report("K20 a failing check is logged and the timer still restarted",
  select(2, T.timerNamed("MyTes3mpCombatTick")).restarts == before + 1 and T.logContains("Check failed"))

T.summary()
