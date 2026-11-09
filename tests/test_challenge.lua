-- challenge.lua: enemy health through a polling timer, difficulty by player level.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report

local CELL = "Vivec, Arena"
local Ch
local function setup(preset)
  local s = T.copy(T.DEFAULT_SETTINGS); s.challenge = preset
  T.fresh(s)
  Ch = T.load("challenge")
  T.postInit()
end
-- An enemy as the game and the server know it: an object in the cell's data, and
-- the stats the controlling client last reported (held by the C++ server).
local function enemy(ui, base, cur, extra)
  local n = tonumber(ui:match("^(%d+)-"))
  LoadedCells[CELL].data.objectData[ui] = { refId = "scamp" }
  for k, v in pairs(extra or {}) do LoadedCells[CELL].data.objectData[ui][k] = v end
  T.actors[CELL] = T.actors[CELL] or {}
  table.insert(T.actors[CELL], { refNum = n, mpNum = 0, base = base, current = cur })
end
local function report_stats(ui, base, cur)
  for _, a in ipairs(T.actors[CELL]) do if a.refNum == tonumber(ui:match("^(%d+)-")) then a.base, a.current = base, cur end end
end
local function tick() MyTes3mpChallengeTick() end
local function commandsFor(ui) local n = 0 for _, c in ipairs(T.cmds) do if c.ids[1] == ui then n = n + 1 end end return n end

------------------------------------------------------------ the old defect: an event that does not exist
do
  local known = {}
  for _, file in ipairs{ "eventHandler.lua", "logicHandler.lua", "serverCore.lua", "player/base.lua", "cell/base.lua" } do
    local src = T.csSource(file)
    for name in src:gmatch('triggerHandlers%("(On%w+)"') do known[name] = true end
    for kind, name in src:gmatch('OnGeneric(%w+)Event%([^\n]-"(%w+)"%)') do known["On" .. name] = true end
  end
  setup("hard")
  local unknown = {}
  for event in pairs(customEventHooks.handlers) do if not known[event] then unknown[#unknown + 1] = event end end
  report("E0 challenge.lua registers handlers only for events CoreScripts really raises", #unknown == 0, table.concat(unknown, ","))
  report("E0b specifically: no OnActorStatsDynamic handler (the server has no such Lua event)", customEventHooks.handlers.OnActorStatsDynamic == nil)
end

------------------------------------------------------------ presets and multiplier
for name, want in pairs{ normal = 1.25, hard = 1.5, brutal = 2.0 } do
  setup(name); T.player(1, "Alice", { level = 1 })
  report("P1 preset " .. name .. " level 1 multiplier " .. want, math.abs(Ch.HealthMultiplier() - want) < 1e-9, Ch.HealthMultiplier())
end
setup("off"); report("P2 'off': no preset, no handlers, no timer", Ch.preset == nil and customEventHooks.handlers.OnPlayerLevel == nil and #T.timers == 0)
setup("bogus"); report("P2b unknown preset behaves like off", Ch.preset == nil and customEventHooks.handlers.OnPlayerLevel == nil and #T.timers == 0)
setup("hard"); T.player(1, "A", { level = 1 }); T.player(2, "B", { level = 10 }); T.player(3, "C", { level = 40, loggedIn = false })
report("P3 multiplier from the highest ONLINE level (10): 1.5 + 0.05 * 9", math.abs(Ch.HealthMultiplier() - 1.95) < 1e-9, Ch.HealthMultiplier())
Players[2].data.stats.level = 200
report("P3b capped at 5x", Ch.HealthMultiplier() == 5)
Players[2].data.stats = nil
report("P3c a player without a stats table counts as level 1", pcall(Ch.HealthMultiplier))
setup("hard"); report("P3d nobody online: level 1", math.abs(Ch.HealthMultiplier() - 1.5) < 1e-9)

------------------------------------------------------------ the polling tick
setup("hard")
local id, timer = T.timerNamed("MyTes3mpChallengeTick")
report("C1 a 5 s timer is created and started", id ~= nil and timer.ms == 5000 and timer.started == true)
tick(); tick()
report("C1b every tick restarts the timer", T.timers[id].restarts == 2)

setup("hard"); T.player(1, "Alice"); T.player(2, "Bob"); T.visit(1, CELL); T.visit(2, CELL)
enemy("10-0", 100, 100)
tick()
report("C2 a healthy enemy gets exactly one 'SetHealth 150' for exactly that actor, in its cell",
  #T.cmds == 1 and T.cmds[1].cmd == "SetHealth 150" and #T.cmds[1].ids == 1 and T.cmds[1].ids[1] == "10-0" and T.cmds[1].cell == CELL)
report("C3 sent to the cell's authority (the first visitor), not to the other player", T.cmds[1].pid == 1)
tick(); tick()
report("C4 further ticks do not command the same enemy again", #T.cmds == 1)
report("C5 the marker is stored in the cell data and the cell saved", LoadedCells[CELL].data.objectData["10-0"].myTes3mpChallenge == 1.5
  and T.cellOnDisk(CELL).objectData["10-0"].myTes3mpChallenge == 1.5)
report_stats("10-0", 150, 150); tick()
report("C6 the report that follows SetHealth (base 150) is ignored", #T.cmds == 1)
-- authority changes: still once
T.leave(1, CELL); LoadedCells[CELL]:SetAuthority(2); tick()
report("C7 a new authority does not cause a second command", #T.cmds == 1)

-- skipped kinds
setup("hard"); T.player(1, "Alice"); T.visit(1, CELL)
enemy("11-0", 100, 100, { summon = {} }); enemy("12-0", 100, 40); enemy("13-0", 0, 0); enemy("14-0", 100, 100)
LoadedCells[CELL].data.objectData["15-0"] = { refId = "scamp" }     -- no stats reported at all
tick()
report("C8 only the healthy one is commanded; summon, damaged, dead and never-reported are skipped",
  #T.cmds == 1 and T.cmds[1].ids[1] == "14-0")
report_stats("12-0", 100, 100); tick()
report("C9 the damaged one is picked up later, when it is seen at full health", commandsFor("12-0") == 1 and #T.cmds == 2)
report_stats("13-0", 80, 80); tick()
report("C9b (a resurrected / healed corpse is treated like any enemy)", commandsFor("13-0") == 1)

-- multiplier at the time of the look
setup("hard"); T.player(1, "Alice", { level = 11 }); T.visit(1, CELL); enemy("20-0", 80, 80); tick()
report("C10 level 11 -> multiplier 2.0 -> 'SetHealth 160'", T.cmds[1] and T.cmds[1].cmd == "SetHealth 160", T.cmds[1] and T.cmds[1].cmd)

-- cells without a usable authority
setup("hard"); T.player(1, "Alice"); T.visit(1, CELL); enemy("30-0", 100, 100)
LoadedCells[CELL].authority = nil
tick()
report("C11 a cell with no authority is skipped (nothing sent, nothing marked)", #T.cmds == 0 and LoadedCells[CELL].data.objectData["30-0"].myTes3mpChallenge == nil)
LoadedCells[CELL]:SetAuthority(1); tick()
report("C11b ... and dealt with as soon as somebody has authority", #T.cmds == 1)
setup("hard"); T.player(1, "Alice"); T.visit(1, CELL); enemy("31-0", 100, 100); Players[1].loggedIn = false; tick()
report("C12 authority that is logged out / gone: skipped", #T.cmds == 0)
Players[1] = nil; tick()
report("C12b authority pid with no player object: skipped, no error", #T.cmds == 0)

-- several cells; one throws
setup("hard"); T.player(1, "Alice"); T.player(2, "Bob")
local CELL2 = "Vivec, Palace"
T.visit(1, CELL); enemy("40-0", 100, 100)
T.visit(2, CELL2)
LoadedCells[CELL2].data.objectData["41-0"] = { refId = "scamp" }
T.actors[CELL2] = { { refNum = 41, mpNum = 0, base = 50, current = 50 } }
local boom = LoadedCells[CELL].SaveActorStatsDynamic
LoadedCells[CELL].SaveActorStatsDynamic = function() error("boom in the first cell") end
local before = T.timers[1].restarts
local ok = pcall(MyTes3mpChallengeTick)
report("C13 one cell throwing: the tick does not propagate, the other cell is dealt with, error logged, timer restarted",
  ok and #T.cmds == 1 and T.cmds[1].cell == CELL2 and T.logContains("boom in the first cell") and T.timers[1].restarts == before + 1)
LoadedCells[CELL].SaveActorStatsDynamic = boom; tick()
report("C13b the cell that threw is handled on the next tick once it works", commandsFor("40-0") == 1)

-- a cell reset wipes the markers
setup("hard"); T.player(1, "Alice"); T.visit(1, CELL); enemy("50-0", 100, 100); tick()
LoadedCells[CELL].data.objectData = {}; T.actors[CELL] = nil; enemy("50-0", 100, 100); tick()
report("C14 after a cell reset (data wiped) the enemy is toughened again", commandsFor("50-0") == 2)

-- junk
setup("hard"); T.player(1, "Alice"); T.visit(1, CELL)
LoadedCells[CELL].data.packets.statsDynamic = 5
report("C15 junk statsDynamic list tolerated", pcall(MyTes3mpChallengeTick))
setup("hard"); T.player(1, "Alice"); T.visit(1, CELL); enemy("60-0", 100, 100)
LoadedCells[CELL].data.objectData["60-0"].stats = nil
LoadedCells[CELL].data.packets.statsDynamic = { "60-0", "999-0" }
T.actors[CELL] = nil
report("C15b stat entries without object data or stats are skipped", pcall(MyTes3mpChallengeTick) and #T.cmds == 0)

------------------------------------------------------------ difficulty
setup("hard")
report("D1 DifficultyFor hard: L1=5, L2=7, L33=69, L34=70 (cap)", Ch.DifficultyFor(1) == 5 and Ch.DifficultyFor(2) == 7 and Ch.DifficultyFor(33) == 69 and Ch.DifficultyFor(34) == 70 and Ch.DifficultyFor(100) == 70)
setup("normal"); report("D1b normal: L1=0, L41=40, cap 40", Ch.DifficultyFor(1) == 0 and Ch.DifficultyFor(41) == 40 and Ch.DifficultyFor(80) == 40)
setup("brutal"); report("D1c brutal: L1=20, L28=100, cap 100", Ch.DifficultyFor(1) == 20 and Ch.DifficultyFor(28) == 100 and Ch.DifficultyFor(50) == 100)
setup("hard"); local p = T.player(1, "Alice", { level = 3 }); T.auth(1)
report("D2 login: difficulty 5 + 2*2 = 9 is saved and sent (LoadSettings)", p.data.settings.difficulty == 9 and p.loadedDifficulty == 9)
local calls0 = #p.calls; T.auth(1)
report("D2b a second look at the same level does nothing", #p.calls == calls0)
p.data.stats.level = 8; customEventHooks.triggerHandlers("OnPlayerLevel", { validDefaultHandler = true }, { 1, { stats = { level = 8 } } })
report("D3 OnPlayerLevel: the level is read from data.stats.level -> 5 + 2*7 = 19", p.data.settings.difficulty == 19)
report("D3b source: CoreScripts saves the packet before the handlers run",
  T.csSource("eventHandler.lua"):find('SaveDataByPacketType%(packetType, playerPacket%)%s*end%s*customEventHooks%.triggerHandlers%("On" %.%. packetType') ~= nil)
local q = T.player(2, "Bob", { level = 1 }); q.data.settings.difficulty = "default"; T.auth(2)
report("D4 the 'default' string is replaced by a number", q.data.settings.difficulty == 5)
T.player(3, "Carl", { loggedIn = false })
report("D5 logged-out and unknown pids are ignored", pcall(Ch.ApplyDifficulty, 3) and pcall(Ch.ApplyDifficulty, 99))
local t = T.player(4, "Dan"); t.data.stats = nil
report("D6 a player without stats counts as level 1", pcall(Ch.ApplyDifficulty, 4) and t.data.settings.difficulty == 5)
local bp = T.csSource("player/base.lua")
report("D7 source: LoadSettings -> SetDifficulty -> tes3mp.SetDifficulty, and SendSettings at the end",
  bp:find("tes3mp.SetDifficulty%(self.pid, difficulty%)") ~= nil and bp:find("tes3mp.SendSettings%(self.pid%)\nend") ~= nil)

T.summary()
