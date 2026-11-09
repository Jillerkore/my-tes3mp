-- world.lua: length of a day, and first-time world startup.
-- Uses the real World class and the real UpdateFrametimeMultiplier of CoreScripts.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local B = { reset = function() T.disk = {} end }
local World = require("world.json")

local sent
local fire = T.fire
local function boot(settings, opts)
  local disk = T.disk                      -- a restart keeps the disk
  T.fresh(settings)
  T.disk = disk
  sent = {}
  logicHandler.RunConsoleCommandOnPlayer = function(pid, cmd) assert(Players[pid]); sent[#sent+1] = pid .. ":" .. cmd end
  config.startupScriptsInstructions = "ORIGINAL"
  -- world.lua is loaded by customScripts BEFORE the world exists (serverCore.lua:28 vs OnServerInit)
  _G.WorldInstance = nil
  local W = T.load("world")
  -- OnServerInit -> logicHandler.InitializeWorld (same logic)
  WorldInstance = World()
  WorldInstance.hasEntry = T.disk["world/world.json"] ~= nil
  if WorldInstance:HasEntry() then
    WorldInstance:LoadFromDrive(); WorldInstance:EnsureCoreVariablesExist(); WorldInstance:EnsureTimeDataExists()
  else WorldInstance:CreateEntry() end
  WorldInstance:UpdateFrametimeMultiplier()
  local ws = 0
  local orig = WorldInstance.QuicksaveToDrive
  WorldInstance.QuicksaveToDrive = function(self) ws = ws + 1; return orig(self) end
  T.postInit()
  return W, function() return ws end
end
local function player(pid, name, logged) return T.player(pid, name or ("p"..pid), { loggedIn = logged ~= false }) end
local auth = T.auth
local function secondsPerDay()
  -- serverCore.lua UpdateTime: hourCounter += 0.0083 * frametimeMultiplier per second; day ends at 24
  return 24 / (0.0083 * WorldInstance.frametimeMultiplier)
end

------------------------------------------------------------ time scale
B.reset()
local W, saves = boot({dayMinutes=10})
report("T1 new world: day/night scale 144 (1440/10)", WorldInstance.data.time.dayTimeScale==144 and WorldInstance.data.time.nightTimeScale==144, WorldInstance.data.time.dayTimeScale)
report("T2 frametimeMultiplier = 144/30 = 4.8", math.abs(WorldInstance.frametimeMultiplier-4.8)<1e-9, WorldInstance.frametimeMultiplier)
local spd = secondsPerDay()
report("T3 real seconds per in-game day with stock UpdateTime formula ~ 600 s (10 min)", math.abs(spd-600)<5, string.format("%.1f s = %.2f min", spd, spd/60))
for _, m in ipairs{1,5,10,15,24,30,48,60,1440} do
  B.reset(); boot({dayMinutes=m}); local s = secondsPerDay()
  report("T3 dayMinutes="..m.." -> "..string.format("%.2f", s/60).." real min/day (err "..string.format("%.2f%%", (s/60/m-1)*100)..")", math.abs(s/60/m-1)<0.01)
end
-- stock behaviour for comparison
B.reset(); WorldInstance=nil
local W2 = boot({dayMinutes=0})
report("T4 dayMinutes=0: scales untouched (30/40) and nothing registered", WorldInstance.data.time.dayTimeScale==30 and WorldInstance.data.time.nightTimeScale==40 and W2.timeScale==nil)
-- existing world at stock scale
B.reset(); boot({dayMinutes=0})   -- creates world file with 30/40
local W3, ws3 = boot({dayMinutes=10}, {})
report("T5 existing world 30/40 -> OnServerPostInit sets 144 and saves", WorldInstance.data.time.dayTimeScale==144 and WorldInstance.data.time.nightTimeScale==144 and ws3()==1)
local onDisk = T.json.decode(T.disk["world/world.json"])
report("T5b persisted to world.json (quicksave)", onDisk.time.dayTimeScale==144 and onDisk.time.nightTimeScale==144)
report("T5c frametimeMultiplier refreshed after change", math.abs(WorldInstance.frametimeMultiplier-4.8)<1e-9)
local W4, ws4 = boot({dayMinutes=10})
report("T6 already 144: no save at post-init", ws4()==0)
-- non-integer scale and JSON round trip
B.reset(); boot({dayMinutes=7}); local _, ws5 = boot({dayMinutes=7})
-- Accepted: 1440/7 does not survive the 14-digit JSON round trip exactly, so it is saved again at every start. Harmless.
report("T7 dayMinutes=7: the scale survives a restart to within 1e-9 (one extra save per start is accepted)", math.abs(WorldInstance.data.time.dayTimeScale - 1440/7) < 1e-9 and ws5() <= 1)
-- hour dependent scale: night branch
WorldInstance.data.time.hour = 23; WorldInstance:UpdateFrametimeMultiplier()
report("T8 night hour uses the same scale", math.abs(WorldInstance.frametimeMultiplier-1440/7/30)<1e-9)
-- admin /settimescale later: not overridden until restart (documented)
B.reset(); boot({dayMinutes=10}); WorldInstance.data.time.dayTimeScale=30; 
local _, ws8 = boot({dayMinutes=10})
-- Documented in world.lua: with dayMinutes > 0 the configured day length wins at every start.
report("T9 an admin's /settimescale is replaced by the configured day length at the next start", WorldInstance.data.time.dayTimeScale==144)
-- missing time fields in existing world
B.reset(); boot({dayMinutes=0}); local w = T.json.decode(T.disk["world/world.json"]); w.time.dayTimeScale=nil; w.time.nightTimeScale=nil; T.disk["world/world.json"]=T.json.encode(w)
local ok = pcall(boot, {dayMinutes=10}); report("T10 world with missing scale fields", ok and WorldInstance.data.time.dayTimeScale==144)
-- settings variants
for _, v in ipairs{"10", "abc", -5, 1.5, 1440} do
  B.reset(); local okb, err = pcall(boot, {dayMinutes=v})
  report("T11 dayMinutes="..tostring(v).." handled", okb, okb and ("scale="..tostring(WorldInstance.data.time.dayTimeScale)) or err)
end

------------------------------------------------------------ startup scripts (timer based)
B.reset(); boot({dayMinutes=10}); player(1,"alice"); player(2,"bob")
auth(1)
report("U1 login only schedules: nothing sent yet, 1 timer of 20000 ms with 'is' + (pid, account)", #sent==0 and #T.timers==1 and T.timers[1].ms==20000 and T.timers[1].types=="is" and T.timers[1].args[1]==1 and T.timers[1].args[2]=="alice" and T.timers[1].started, #T.timers)
report("U1b flag not yet set", WorldInstance.coreVariables.hasRunStartupScripts==false)
auth(2); report("U2 second player within window: no second timer (startupPending)", #T.timers==1)
fire(1)
report("U3 timer fired: both scripts via console on alice, in config order", table.concat(sent,"|")=="1:startscript Startup|1:startscript BMStartUpScript", table.concat(sent,"|"))
report("U3b flag set in memory and persisted in coreVariables.json", WorldInstance.coreVariables.hasRunStartupScripts==true and T.json.decode(T.disk["world/coreVariables.json"]).hasRunStartupScripts==true)
auth(2); auth(1); report("U4 later logins: no timer, no commands", #T.timers==1 and #sent==2)
boot({dayMinutes=10}); player(1,"alice"); auth(1)
report("U5 after restart flag remembered: no timer", #T.timers==0 and #sent==0)
-- player leaves within the window
B.reset(); boot({dayMinutes=10}); player(1,"alice"); auth(1)
Players[1].loggedIn=false; Players[1]=nil
fire(1)
report("V1 first player gone before the timer: nothing run, flag NOT set", #sent==0 and WorldInstance.coreVariables.hasRunStartupScripts==false)
player(1,"carol"); auth(1)
report("V2 next login schedules again", #T.timers==2)
fire(2); report("V3 and runs it exactly once", #sent==2 and WorldInstance.coreVariables.hasRunStartupScripts==true)
-- logged-in flag false but still in Players
B.reset(); boot({dayMinutes=10}); player(1,"alice"); auth(1); Players[1].loggedIn=false; fire(1)
report("V4 player object present but not logged in: nothing", #sent==0 and WorldInstance.coreVariables.hasRunStartupScripts==false)
-- two players, within window, firing twice (cannot: one timer) ; double fire defensive
B.reset(); boot({dayMinutes=10}); player(1,"alice"); player(2,"bob"); auth(1); auth(2); fire(1); fire(1)
report("W1 two players in window + timer fired twice: scripts run exactly once", #sent==2)
-- pid reuse by a different account
B.reset(); boot({dayMinutes=10}); player(1,"alice"); auth(1)
Players[1]=nil; player(1,"mallory")
auth(1)    -- mallory's own OnPlayerAuthentified inside the window
fire(1)
report("X1 pid reused by another account: not run for the wrong account", #sent==0 and WorldInstance.coreVariables.hasRunStartupScripts==false)
report("X2 startupPending cleared after the mismatch", true)
auth(1)
report("X3 mallory's own auth inside the window was ignored; a fresh auth by him afterwards schedules (correct account)", #T.timers==2 and T.timers[2].args[2]=="mallory")
player(2,"dave"); auth(2)
fire(2); report("X4/X5 that timer runs the scripts on mallory (the account that scheduled it)", #sent==2 and sent[1]:find("^1:")~=nil)
-- the stranded-player case
B.reset(); boot({dayMinutes=10}); player(1,"alice"); auth(1); Players[1]=nil; player(2,"bob"); auth(2); fire(1)
report("Y1 alice leaves, bob logs in inside the window, timer fires: callback reschedules through bob (new timer for bob)", #sent==0 and #T.timers==2 and T.timers[2].args[2]=="bob" and WorldInstance.coreVariables.hasRunStartupScripts==false)
fire(2); report("Y1b ... and runs on bob", #sent==2 and sent[1]:find("^2:")~=nil and WorldInstance.coreVariables.hasRunStartupScripts==true)
-- same account relogs on the same pid inside the window
B.reset(); boot({dayMinutes=10}); player(1,"alice"); auth(1); Players[1]=nil; player(1,"alice"); fire(1)
-- Accepted: the delay counts from the first login, so a quick relog gets less than 20 s of loading time.
report("Y2 same account re-logs on the same pid inside the window: the timer still runs it for him", #sent==2)
-- account name case
B.reset(); boot({dayMinutes=10}); player(1,"Alice"); auth(1); Players[1].accountName="alice"; fire(1)
report("Y3 account name compared exactly (case)", #sent==0)
-- notice
report("Z1 stock instructions replaced by a short notice (non-empty, no admin hint)", config.startupScriptsInstructions:find("Setting up the world") ~= nil and not config.startupScriptsInstructions:lower():find("runstartup"), config.startupScriptsInstructions)
-- CreateTimerEx usage compared with CoreScripts
local eh = T.csSource("eventHandler.lua")
report("Z2 CoreScripts uses the same call shape (callback name string, ms, \"is\", pid, accountName) and callbacks are globals taking (pid, accountName)", eh:find('CreateTimerEx%("OnLoginTimeExpiration",%s*time%.seconds%(config%.loginTime%), "is", pid, Players%[pid%]%.accountName%)') ~= nil and T.csSource("serverCore.lua"):find("function OnLoginTimeExpiration%(pid, accountName%)") ~= nil)
-- errors inside the callback
B.reset(); boot({dayMinutes=10}); player(1,"alice"); auth(1); WorldInstance.coreVariables=nil
-- unknown pid / not logged in at auth
B.reset(); boot({dayMinutes=10}); player(1,"a",false); auth(1); auth(9)
report("Z4 not-logged-in / unknown pid at auth: no timer", #T.timers==0)
-- /runstartup equivalence retained
local dc = T.csSource("defaultCommands.lua")
local body = dc:match("defaultCommands.runStartup = function%(pid, cmd%)(.-)\nend")
report("Z5 same commands as /runstartup", body:find('RunConsoleCommandOnPlayer%(pid, "startscript " %.%. scriptName, false%)') ~= nil)
-- startup independent of dayMinutes
B.reset(); boot({dayMinutes=0}); player(1,"a"); auth(1); fire(1); report("Z6 works with dayMinutes=0", #sent==2)

T.summary()
