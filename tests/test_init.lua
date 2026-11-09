-- init.lua: which scripts load for which settings, in which order; settings.lua keys;
-- and a check that no script listens for an event the server never raises.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local ALL = { "world", "party", "combat", "strongholds", "resets", "challenge", "vendors", "uniques",
    "regen", "downed", "travel", "bank", "sharequest", "bosses" }

local function initRun(settings)
  T.fresh(settings)
  local loaded, order = {}, {}
  T.stubModules(loaded, order, ALL)
  package.loaded["custom/myTes3mp/settings"] = settings
  dofile(T.scriptsDir .. "/init.lua")
  return loaded, order
end
local function names(o) return table.concat(o, ",") end

local l, o = initRun(T.copy(T.DEFAULT_SETTINGS))
report("I1 all on: every script loads, in the documented order (combat and resets before the scripts that use them)",
  names(o) == table.concat(ALL, ","), names(o))
for _, sw in ipairs{ { "party", false, "party" }, { "strongholdHelper", false, "strongholds" }, { "cellResetHours", 0, "resets" },
    { "challenge", "off", "challenge" }, { "uniqueClaims", false, "uniques" }, { "regen", false, "regen" },
    { "downedSeconds", 0, "downed" }, { "travel", false, "travel" }, { "bank", false, "bank" },
    { "shareQuests", false, "sharequest" }, { "worldBossHours", 0, "bosses" } } do
  local s = T.copy(T.DEFAULT_SETTINGS); s[sw[1]] = sw[2]
  l, o = initRun(s)
  local others = 0
  for _, n in ipairs(ALL) do if n ~= sw[3] and l[n] then others = others + 1 end end
  report("I2 " .. sw[1] .. "=" .. tostring(sw[2]) .. " -> " .. sw[3] .. " is not loaded, all the others are",
    l[sw[3]] == nil and others == #ALL - 1, names(o))
end
local s = T.copy(T.DEFAULT_SETTINGS); s.vendorGoldMinutes = 0; s.vendorStockSeconds = 0; l = initRun(s)
report("I3 vendors.lua is loaded even when both of its parts are switched off (it then registers nothing)", l.vendors == true)
s = T.copy(T.DEFAULT_SETTINGS); s.party = nil; s.uniqueClaims = nil; s.challenge = nil; l, o = initRun(s)
report("I4 a settings.lua from an older image (keys missing): party and uniques stay off, challenge loads", not l.party and not l.uniques and l.challenge == true, names(o))
s = T.copy(T.DEFAULT_SETTINGS); s.regen = false; s.travel = false; s.bank = false; s.downedSeconds = 0; l = initRun(s)
report("I4a combat.lua is only loaded when something needs it", l.combat == nil)
s = T.copy(T.DEFAULT_SETTINGS); s.regen = false; s.travel = false; s.bank = false; l = initRun(s)
report("I4aa being downed alone is enough to need it", l.combat == true)
s = T.copy(T.DEFAULT_SETTINGS); s.cellResetHours = "12"; l = initRun(s)
report("I4b cellResetHours as a numeric string still switches resets on", l.resets == true)
s = T.copy(T.DEFAULT_SETTINGS); s.cellResetHours = nil; l = initRun(s)
report("I4c cellResetHours missing: resets stay off", l.resets == nil)
s = T.copy(T.DEFAULT_SETTINGS); s.cellResetHours = 0; l = initRun(s)
report("I5 uniques loads without resets", l.uniques and not l.resets)
T.fresh(); T.load("uniques"); T.postInit()
report("I6 the real uniques.lua loads and starts without resets.lua", myTes3mpResets == nil)

-- init.lua returns the settings table
T.fresh(); T.stubModules({}, {}, ALL)
report("I7 init.lua returns the settings", dofile(T.scriptsDir .. "/init.lua") == T.settings)

-- entrypoint.sh must write every settings key init.lua and the scripts read
local f = io.open(T.repo .. "/docker/entrypoint.sh", "r")
local ep = f and f:read("*a"); if f then f:close() end
for _, key in ipairs{ "progression", "strongholdHelper", "cellResetHours", "cellResetKeep", "dayMinutes", "party", "challenge",
    "vendorGoldMinutes", "vendorStockSeconds", "uniqueClaims", "uniqueRespawnMinutes", "regen", "downedSeconds",
    "travel", "bank", "shareQuests", "worldBossHours" } do
  report("I8 entrypoint.sh writes settings key " .. key, ep ~= nil and ep:find(key, 1, true) ~= nil)
end
-- and every settings.<key> the scripts read is one of those
local written = {}
for k in pairs(T.DEFAULT_SETTINGS) do written[k] = true end
local stray = {}
for _, file in ipairs{ "init", "world", "party", "combat", "strongholds", "resets", "challenge", "vendors", "uniques",
    "regen", "downed", "travel", "bank", "sharequest", "bosses" } do
  local code = T.scriptSource(file .. ".lua"):gsub("%-%-[^\n]*", "")
  for key in code:gmatch("%f[%w_.]settings%.(%a+)") do if not written[key] then stray[#stray + 1] = file .. ":" .. key end end
end
report("I9 no script reads a settings key that is not in the list above", #stray == 0, table.concat(stray, ","))

------------------------------------------------------------ events the scripts listen for
-- The server raises: every triggerHandlers("OnX") literal in CoreScripts, and "On"..packetType for
-- the generic player/object/actor events. A handler on any other name is dead code (this is how
-- challenge.lua's OnActorStatsDynamic went unnoticed).
local known = {}
for _, file in ipairs{ "eventHandler.lua", "logicHandler.lua", "serverCore.lua", "player/base.lua", "cell/base.lua" } do
  local src = T.csSource(file)
  for name in src:gmatch('trigger%a+%("(On%w+)"') do known[name] = true end
  for name in src:gmatch('OnGeneric%w+Event%([^\n]-"(%w+)"%)') do known["On" .. name] = true end
end
T.fresh()
local loadedAll = {}
for _, n in ipairs{ "world", "party", "strongholds", "resets", "challenge", "vendors", "uniques" } do T.load(n) end
local unknown = {}
for _, kind in ipairs{ "handlers", "validators" } do
  for event in pairs(customEventHooks[kind]) do if not known[event] then unknown[#unknown + 1] = kind .. ":" .. event end end
end
report("E1 every event the scripts register for is one CoreScripts raises", #unknown == 0, table.concat(unknown, ","))
local count = 0
for _ in pairs(known) do count = count + 1 end
report("E2 (sanity) the scan of CoreScripts found the usual events", known.OnPlayerLevel and known.OnContainer and known.OnObjectDelete
  and known.OnObjectDialogueChoice and known.OnPlayerAuthentified and known.OnServerPostInit and known.OnServerExit and count > 40, count)
local cmds = {}
for c in pairs(customCommandHooks.commands) do cmds[#cmds + 1] = c end
table.sort(cmds)
report("E3 the chat commands the scripts add", table.concat(cmds, ",") == "resetinfo,uniques", table.concat(cmds, ","))

T.summary()
