-- bosses.lua: roaming world bosses with personal loot.
--
-- harness.lua knows nothing of creature records, spawning or deleting objects,
-- so this file stubs them, copying the behaviour of CoreScripts'
-- logicHandler.CreateObjects / DeleteObject (cells are the REAL cell classes
-- over the in-memory disk, so what is written into a cell is what the real
-- code would write, and the real LoadObjectsSpawned reads it back). The
-- travel points are a stand-in module, except for one check against the real
-- travelPoints.lua.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local H = 3600

------------------------------------------------------------ stubs
local B
local store, created, deleted, broadcasts, sentObjects, recordLoads
local mp = 0
local received = {}   -- what the "received actor list" holds, for OnActorCellChange

-- Facts read from the game's data files with esmtool (Morrowind, Tribunal, Bloodmoon):
-- base creature -> base health. None carries "immune to normal weapons"; all
-- walk; none has a script.
local VERIFIED_BASES = { kagouti = 45, clannfear = 113, BM_bear_black = 150, ["winged twilight"] = 220,
  fabricant_hulking = 500 }
-- Every reward id exists in the game's potion/misc/ingredient/lockpick/probe/repair records.
local VERIFIED_ITEMS = {}
for _, id in ipairs({ "gold_001", "Misc_SoulGem_Lesser", "Misc_SoulGem_Common", "Misc_SoulGem_Greater",
  "Misc_SoulGem_Grand", "p_restore_health_s", "p_restore_magicka_s", "p_restore_health_q", "p_restore_magicka_q",
  "p_restore_health_e", "p_restore_magicka_e", "p_fortify_health_e", "p_spell_absorption_e", "p_fortify_attack_e",
  "ingred_fire_salts_01", "ingred_frost_salts_01", "ingred_pearl_01", "ingred_ruby_01", "ingred_emerald_01",
  "ingred_diamond_01", "ingred_daedras_heart_01", "ingred_raw_ebony_01", "repair_master_01",
  "repair_grandmaster_01", "pick_master", "probe_master" }) do VERIFIED_ITEMS[id] = true end

local function install()
  created, deleted, broadcasts, sentObjects, recordLoads = {}, {}, {}, {}, {}
  store = { data = { permanentRecords = {}, generatedRecords = {} }, saves = 0 }
  function store:QuicksaveToDrive() self.saves = self.saves + 1 end
  function store:LoadRecords(pid, list, ids, everyone)
    recordLoads[#recordLoads + 1] = { pid = pid, ids = ids, everyone = everyone }
  end
  RecordStores.creature = store

  tes3mp.SendMessage = function(pid, msg, everyone) T.msgs[#T.msgs + 1] = { pid, msg, everyone } end
  tes3mp.ReadReceivedActorList = function() end
  tes3mp.GetActorListSize = function() return #received end
  tes3mp.GetActorRefNum = function(i) return received[i + 1].ref end
  tes3mp.GetActorMpNum = function(i) return received[i + 1].mp end
  tes3mp.GetActorCell = function(i) return received[i + 1].cell end
  tes3mp.SendObjectSpawn = function() sentObjects[#sentObjects + 1] = true end

  -- logicHandler.CreateObjects, reduced to one object (logicHandler.lua:426-563)
  logicHandler.CreateObjectAtLocation = function(cellDescription, location, objectData, packetType)
    local temporary = LoadedCells[cellDescription] == nil
    if temporary then logicHandler.LoadCell(cellDescription) end
    local cell = LoadedCells[cellDescription]
    mp = mp + 1
    local uniqueIndex = "0-" .. mp
    cell:EnsurePacketTables()
    cell:InitializeObjectData(uniqueIndex, objectData.refId)
    cell.data.objectData[uniqueIndex].location = location
    if packetType == "spawn" then
      table.insert(cell.data.packets.spawn, uniqueIndex)
      table.insert(cell.data.packets.actorList, uniqueIndex)
    end
    created[#created + 1] = { cell = cellDescription, location = location, refId = objectData.refId,
      type = packetType, uniqueIndex = uniqueIndex, playersOnline = next(Players) ~= nil }
    cell:QuicksaveToDrive()
    if temporary then logicHandler.UnloadCell(cellDescription) end
    return uniqueIndex
  end
  -- logicHandler.DeleteObject with forEveryone (logicHandler.lua:596-629);
  -- like the real one it fails when no player is connected.
  logicHandler.DeleteObjectForEveryone = function(cellDescription, uniqueIndex)
    local pid = tableHelper.getAnyValue(Players).pid
    deleted[#deleted + 1] = { cell = cellDescription, uniqueIndex = uniqueIndex, pid = pid }
    local temporary = LoadedCells[cellDescription] == nil
    if temporary then logicHandler.LoadCell(cellDescription) end
    LoadedCells[cellDescription]:DeleteObjectData(uniqueIndex)
    if temporary then logicHandler.UnloadCell(cellDescription) end
  end
end

local function setHubs(list)
  package.loaded["custom/myTes3mp/travelPoints"] = nil
  package.preload["custom/myTes3mp/travelPoints"] = function()
    if list == "missing" then error("module 'custom/myTes3mp/travelPoints' not found") end
    return list
  end
end

local function hub(name, cell, x, y, z, exterior)
  return { name = name, cell = cell, exterior = exterior ~= false, pos = { x, y, z }, rot = { 0, 0, 1.5 } }
end
local BALMORA = hub("Balmora", "-3, -3", -21320.67, -18233.11, 1179.03)
local SUARAN = hub("Suran", "6, -6", 53158.79, -48228.83, 984.14)
local VIVEC = hub("Vivec, Foreign Quarter", "Vivec, Foreign Quarter", 0, 0, 0, false)

local rolls
local function fixedRandom(a, b)
  if a == nil then return 0 end                                -- an angle of 0
  return math.min(b, (rolls and table.remove(rolls, 1)) or a)  -- first choice unless told
end

local function boot(opts)
  opts = opts or {}
  local disk, now = T.disk, T.time
  local s = T.copy(T.DEFAULT_SETTINGS)
  s.worldBossHours = opts.hours == nil and 3 or opts.hours
  if opts.hours == false then s.worldBossHours = nil end
  for k, v in pairs(opts.settings or {}) do s[k] = v end
  T.fresh(s)
  if opts.keepDisk then T.disk = disk; T.time = now end   -- a restart: same disk, same clock
  config.shareKills = false
  install()
  setHubs(opts.hubs or { BALMORA, SUARAN })
  rolls = opts.rolls
  myTes3mpCombat = nil          -- combat.lua is only there when a test asks for it
  if opts.combat then T.load("combat") end
  if opts.resets then B.resets = T.load("resets") end
  if opts.challenge then T.load("challenge") end
  B = T.load("bosses")
  B.random = fixedRandom
  T.postInit()
  return B
end

local function tick()
  local id = T.timerNamed("MyTes3mpBossTick")
  return T.fire(id), id
end
local function advance(seconds) T.time = T.time + seconds end
local function state() return T.diskState("myTes3mpBosses.json") end
local function say(text)
  for _, m in ipairs(T.msgs) do if m[2]:find(text, 1, true) then return m end end
  return nil
end
local function clearMsgs() T.msgs = {} end
local function items(player)
  local n = {}
  for _, it in ipairs(player.data.inventory) do n[it.refId] = (n[it.refId] or 0) + it.count end
  return n
end
local function lootCount(player)
  local n = 0
  for id, c in pairs(items(player)) do if id ~= "gold_001" then n = n + c end end
  return n
end
local function dies(pid, cell, uniqueIndex, refId)
  local actors = { [uniqueIndex] = { uniqueIndex = uniqueIndex, refId = refId, deathState = 0,
    killer = { pid = pid, playerName = "x" } } }
  local status = customEventHooks.triggerValidators("OnActorDeath", { pid, cell, actors })
  customEventHooks.triggerHandlers("OnActorDeath", status, { pid, cell, actors })
end
local function cellHas(cell, uniqueIndex)
  local c = T.cellOnDisk(cell)
  if LoadedCells[cell] ~= nil then return LoadedCells[cell].data.objectData[uniqueIndex] ~= nil end
  return c ~= nil and c.objectData ~= nil and c.objectData[uniqueIndex] ~= nil
end

-- A server with Alice (level 10) at Seyda Neen, due for a boss.
local function due(opts)
  opts = opts or {}
  boot(opts)
  T.player(1, "Alice", { level = opts.level or 15, cell = "-2, -9" })
  T.auth(1)
  tick()                                   -- notes when the first boss is due
  advance(3 * H + 1)
end

------------------------------------------------------------ the tiers
boot()
report("D1 five tiers, five record ids", #B.tiers == 5 and B.RecordId(1) == "myt_boss_1" and B.RecordId(5) == "myt_boss_5")
local numbers_ok, bases_ok, last = true, true, { 0, 0, 0 }
for n, tier in ipairs(B.tiers) do
  local rec = B.Record(tier)
  numbers_ok = numbers_ok and rec.level == tier.refLevel + 4 and rec.health == 100 + 40 * tier.refLevel
    and rec.damageChop.max == 3 * rec.level and rec.damageChop.min == rec.level
    and rec.damageSlash.max == rec.damageChop.max and rec.damageThrust.min == rec.damageChop.min
    and rec.level > last[1] and rec.health > last[2] and rec.damageChop.max > last[3]
    and rec.scale > 1 and rec.aiFight == 100 and rec.aiFlee == 0 and type(rec.name) == "string" and rec.name ~= ""
  last = { rec.level, rec.health, rec.damageChop.max }
  bases_ok = bases_ok and VERIFIED_BASES[tier.base] ~= nil and rec.baseId == tier.base
    and rec.health >= 2 * VERIFIED_BASES[tier.base]
end
report("D2 level, health and damage follow the formula and rise with the tier; hostile, never flee", numbers_ok)
report("D3 every base creature is one verified in the game data, and the boss has at least twice its health", bases_ok)
local bandOk = B.TierFor(5) == 1 and B.TierFor(9) == 1 and B.TierFor(10) == 2 and B.TierFor(14) == 2
  and B.TierFor(15) == 3 and B.TierFor(21) == 3 and B.TierFor(22) == 4 and B.TierFor(29) == 4
  and B.TierFor(30) == 5 and B.TierFor(80) == 5
  and B.tiers[1].minLevel == 5 and B.tiers[2].minLevel == 10 and B.tiers[3].minLevel == 15
  and B.tiers[4].minLevel == 22 and B.tiers[5].minLevel == 30
report("D4 level bands start at 5, 10, 15, 22, 30 (nothing below 5)", bandOk)

local unique = dofile(T.scriptsDir .. "/uniqueItems.lua")
local lootOk, goldUp, prevGold = true, true, 0
for _, tier in ipairs(B.tiers) do
  goldUp = goldUp and tier.gold > prevGold; prevGold = tier.gold
  lootOk = lootOk and #tier.loot >= 4
  for _, e in ipairs(tier.loot) do
    lootOk = lootOk and VERIFIED_ITEMS[e[1]] == true and unique[e[1]:lower()] == nil and e[2] >= 1 and type(e[3]) == "string"
  end
end
report("D5 reward items: verified vanilla ids, none in uniqueItems.lua, gold rises with the tier", lootOk and goldUp)

------------------------------------------------------------ records
boot()
report("R1 the five records are defined at start-up as permanent records and saved",
  store.data.permanentRecords.myt_boss_1 ~= nil and store.data.permanentRecords.myt_boss_5 ~= nil and store.saves == 1)
report("R2 the stored record has the builder's fields (baseId, name, scale, level, health, damage, ai)",
  (function() local r = store.data.permanentRecords.myt_boss_3
    return r.baseId == "BM_bear_black" and r.scale == 2.3 and r.level == 16 and r.health == 580
      and r.damageChop.max == 48 and r.aiFight == 100 end)())
report("R3 nobody online at start: nothing sent (players get permanent records at login)", #recordLoads == 0)
T.player(1, "Alice", {}); T.auth(1)
B.DefineRecords()
report("R4 unchanged records are neither saved nor sent again", store.saves == 1 and #recordLoads == 0)
store.data.permanentRecords.myt_boss_2.health = 1
B.DefineRecords()
report("R5 a changed record is rewritten, saved, and sent to everybody online",
  store.data.permanentRecords.myt_boss_2.health == 380 and store.saves == 2 and #recordLoads == 1
  and recordLoads[1].everyone == true and #recordLoads[1].ids == 1 and recordLoads[1].ids[1] == "myt_boss_2")
RecordStores.creature = nil
local ok = B.DefineRecords()
report("R6 no creature record store: reported, no error", ok == false and T.logContains("creature record store is not available"))

------------------------------------------------------------ schedule
boot()
T.player(1, "Alice", { level = 15 }); T.auth(1)
tick()
report("S1 first look only notes when the first boss is due (hours later), nothing spawns",
  #created == 0 and state().nextAt == T.time + 3 * H)
advance(3 * H - 1); tick()
report("S2 not yet due: nothing", #created == 0)
advance(2); tick()
report("S3 due with a player online: one boss is spawned as a 'spawn' packet in a hub's cell",
  #created == 1 and created[1].type == "spawn" and created[1].cell == "-3, -3" and created[1].refId == "myt_boss_3",
  created[1] and created[1].refId)
local st = state()
report("S4 state records the boss (cell, object number, record, expiry) and the next due time",
  st.boss and st.boss.cell == "-3, -3" and st.boss.uniqueIndex == created[1].uniqueIndex and st.boss.refId == "myt_boss_3"
  and st.boss.expiresAt == T.time + 2 * H and st.nextAt == T.time + 3 * H and st.boss.hub == "Balmora")
report("S5 everybody is told, as a broadcast, where",
  (function() local m = say("A world boss has appeared at Balmora") return m ~= nil and m[3] == true end)())
report("S6 the boss is placed exactly at the travel point (offset 0), inside its cell",
  (function() local l = created[1].location
    local dx, dy = l.posX - BALMORA.pos[1], l.posY - BALMORA.pos[2]
    return B.spawnOffset == 0 and dx == 0 and dy == 0 and math.floor(l.posX / 8192) == -3
      and math.floor(l.posY / 8192) == -3 and l.posZ == BALMORA.pos[3] end)())
report("S7 the unloaded cell now holds the actor as a server-spawned actor",
  (function() local c = T.cellOnDisk("-3, -3")
    return c and c.objectData[created[1].uniqueIndex] and c.objectData[created[1].uniqueIndex].refId == "myt_boss_3"
      and tableHelper.containsValue(c.packets.spawn, created[1].uniqueIndex)
      and tableHelper.containsValue(c.packets.actorList, created[1].uniqueIndex) end)())
advance(1 * H); tick()
report("S8 only one boss at a time / not again before the next period", #created == 1)

-- a player entering the cell later is sent the boss with the cell's contents
T.player(2, "Bob", { level = 15, cell = "-3, -3" })
sentObjects = {}
T.visit(2, "-3, -3")
local spawnSent = false
spawnSent = #sentObjects > 0
report("S9 the real cell code sends the stored spawn (location accepted) when a player first loads the cell", spawnSent)

-- no one online when due
due({ hours = 3 })
disconnectAll = nil
Players[1] = nil
tick()
report("S10 due but nobody online: no boss, put off by the grace period",
  #created == 0 and state().nextAt == T.time + B.graceSeconds)
T.player(1, "Alice", { level = 15 }); T.auth(1)
advance(B.graceSeconds + 1); tick()
report("S11 after somebody logs in and the grace has passed: the boss comes", #created == 1)

-- tier by the highest level online
due({ level = 3 })
T.player(2, "Bob", { level = 30 }); T.auth(2)
tick()
report("S12 tier is chosen by the highest-level player online (30 -> tier 5)",
  #created == 1 and created[1].refId == "myt_boss_5")
-- below the first band there is no boss at all
for _, low in ipairs({ 1, 4 }) do
  due({ level = low, hubs = { BALMORA } })
  local logBefore = #T.log
  local okLow = pcall(tick)
  local noisy = false
  for i = logBefore + 1, #T.log do
    if T.log[i]:find("Could not", 1, true) or T.log[i]:find("failed", 1, true) then noisy = true end
  end
  report("S12b level " .. low .. " online: no boss, no error, retried after the grace period",
    okLow and #created == 0 and not noisy and state().boss == nil and state().nextAt == T.time + B.graceSeconds)
  if low == 4 then
    Players[1].data.stats.level = 5
    advance(B.graceSeconds + 1); tick()
    report("S12c the same party at level 5 gets tier 1", #created == 1 and created[1].refId == "myt_boss_1")
  end
end
for level, want in pairs({ [5] = 1, [9] = 1, [10] = 2, [14] = 2, [15] = 3, [21] = 3, [22] = 4, [29] = 4 }) do
  due({ level = level }); tick()
  report("S13 level " .. level .. " -> tier " .. want, created[1] and created[1].refId == "myt_boss_" .. want)
end

-- places
due({ hubs = { VIVEC, BALMORA, SUARAN }, rolls = { 3 } }); tick()
report("S14 interior entries are never used (random pick among the 2 outdoor ones)",
  created[1] and created[1].cell ~= "Vivec, Foreign Quarter")
due({ hubs = { VIVEC, BALMORA, SUARAN } }); tick()
local first = created[1].cell
advance(3 * H + 1)
T.player(2, "Bob", { level = 15 }); tick()
-- the first boss expired in the meantime (2 h) -> Depart; the second period spawns another
tick()
report("S15 the next boss is not at the same place as the one before", #created == 2 and created[2].cell ~= first,
  created[2] and created[2].cell)
-- an offset that would leave the cell falls back to the exact point
due({ hubs = { hub("Edge", "0, 0", 8191.5, 4000, 100) } })
B.spawnOffset = 300; B.random = function(a, b) if a == nil then return 0 end return 1 end
tick()
report("S16 an offset that would leave the cell is dropped: the exact point is used",
  created[1] and created[1].location.posX == 8191.5)
-- a point whose coordinates are not in its cell is ignored
due({ hubs = { hub("Wrong", "5, 5", 0, 0, 0), BALMORA } }); tick()
report("S17 a travel point outside its own cell is skipped", created[1] and created[1].cell == "-3, -3")

------------------------------------------------------------ no places
for name, list in pairs({ missing = "missing", empty = {}, onlyInterior = { VIVEC }, notATable = 5 }) do
  due({ hubs = list })
  local errs = #T.log
  tick(); advance(10 * H); tick(); tick()
  local logged = 0
  for _, m in ipairs(T.log) do if m:find("bosses stay idle", 1, true) then logged = logged + 1 end end
  report("N1 travel points " .. name .. ": idle, no boss, one note in the log", #created == 0 and logged == 1,
    "logged " .. logged)
  local before = #T.msgs
  customCommandHooks.getCallback("boss")(1, { "boss" })
  report("N2 travel points " .. name .. ": /boss says none can appear", T.msgs[#T.msgs][2]:find("no place", 1, true) ~= nil)
end

------------------------------------------------------------ off
boot({ hours = 0 })
T.player(1, "Alice", {}); T.auth(1)
report("O1 hours = 0: no timer, no records, no state", T.timerNamed("MyTes3mpBossTick") == nil and store.saves == 0)
customCommandHooks.getCallback("boss")(1, { "boss" })
report("O2 /boss then says it is off", T.msgs[#T.msgs][2]:find("switched off", 1, true) ~= nil)
boot({ hours = false })
report("O3 setting missing: default of 3 hours", B.hours == 3 and T.timerNamed("MyTes3mpBossTick") ~= nil)

------------------------------------------------------------ the kill
local function fight(opts)
  opts = opts or {}
  due({ level = 15, hubs = { BALMORA }, resets = opts.resets, combat = opts.combat })
  T.player(2, "Bob", { level = 15, cell = "-3, -3" })
  T.auth(2)
  tick()
  local boss = B.State().boss
  T.visit(1, "-3, -3"); T.visit(2, "-3, -3")
  return boss
end

local boss = fight()
report("K0 a boss is abroad at Balmora", boss ~= nil and boss.cell == "-3, -3")
T.player(3, "Carol", { level = 15, cell = "Vivec, Temple" }); T.auth(3); T.visit(3, "Vivec, Temple")
T.player(4, "Dave", { level = 15, cell = "-3, -3" }, false)
Players[4].loggedIn = false; LoadedCells["-3, -3"]:AddVisitor(4)   -- a stale visitor entry of somebody not logged in
clearMsgs()
dies(1, "-3, -3", boss.uniqueIndex, "myt_boss_3")
local a, b, c = Players[1], Players[2], Players[3]
report("K1 everybody who is in the boss's cell gets gold and one item",
  items(a).gold_001 == B.tiers[3].gold and items(b).gold_001 == B.tiers[3].gold and lootCount(a) >= 1 and lootCount(b) >= 1)
report("K2 exactly one loot item each (stack of the table's count)",
  (function()
    for _, p in ipairs({ a, b }) do
      local kinds = 0
      for id, n in pairs(items(p)) do
        if id ~= "gold_001" then
          kinds = kinds + 1
          local found
          for _, e in ipairs(B.tiers[3].loot) do if e[1] == id and e[2] == n then found = true end end
          if not found then return false end
        end
      end
      if kinds ~= 1 then return false end
    end
    return true end)())
report("K3 the client is told with an ADD item change and the data is saved",
  (function() local last = a.calls[#a.calls - 1]
    return type(last) == "table" and last[1] == "items" and last[3] == enumerations.inventory.ADD and #last[2] == 2
      and a.calls[#a.calls] == "save" end)())
report("K4 a player in another cell, a player not logged in, get nothing",
  next(c.data.inventory) == nil and Players[4].data.inventory[1] == nil)
report("K5 each rewarded player is told", (function() local n = 0
  for _, m in ipairs(T.msgs) do if m[2]:find("Your reward", 1, true) then n = n + 1 end end return n == 2 end)())
report("K6 the kill is announced to everybody", (function() local m = say("has been slain") return m ~= nil and m[3] == true
  and m[2]:find("Alice", 1, true) and m[2]:find("Bob", 1, true) and not m[2]:find("Carol", 1, true) end)())
report("K7 the boss is gone from the state; the next one is still due at the old time",
  state().boss == nil and state().nextAt ~= nil and #state().corpses == 1)
local goldBefore = items(a).gold_001
dies(1, "-3, -3", boss.uniqueIndex, "myt_boss_3")
dies(2, "-3, -3", boss.uniqueIndex, "myt_boss_3")
report("K8 a repeated death report rewards nobody twice", items(a).gold_001 == goldBefore and items(b).gold_001 == goldBefore)
dies(1, "-3, -3", "0-9999", "rat")
report("K9 the death of any other creature is ignored", items(a).gold_001 == goldBefore)

-- the corpse
tick()
report("K10 the body stays for a while", #deleted == 0 and cellHas("-3, -3", boss.uniqueIndex))
advance(B.corpseSeconds + 1); tick()
report("K11 then it is removed for everybody and from the cell's data",
  #deleted == 1 and deleted[1].uniqueIndex == boss.uniqueIndex and not cellHas("-3, -3", boss.uniqueIndex)
  and #state().corpses == 0)

-- a refId mismatch with the right number
boss = fight()
dies(1, "-3, -3", boss.uniqueIndex, "kagouti")
report("K12 an actor with the boss's number but another record is not the boss", state().boss ~= nil)
-- death is vetoed by another script: not counted
do
  local actors = { [boss.uniqueIndex] = { refId = "myt_boss_3", killer = { pid = 1 } } }
  customEventHooks.triggerHandlers("OnActorDeath", customEventHooks.makeEventStatus(false, false), { 1, "-3, -3", actors })
end
report("K13 a death another script vetoed is not counted", state().boss ~= nil)
-- the one who reports the death is rewarded even if the cell list missed him
LoadedCells["-3, -3"].visitors = { 2 }
dies(1, "-3, -3", boss.uniqueIndex, "myt_boss_3")
report("K14 the reporting player counts as there; Bob too", items(Players[1]).gold_001 ~= nil and items(Players[2]).gold_001 ~= nil)

-- wandered into the next cell
boss = fight()
LoadedCells["-3, -2"] = nil
T.visit(2, "-3, -2"); LoadedCells["-3, -3"]:RemoveVisitor(2)
received = { { ref = 0, mp = tonumber(boss.uniqueIndex:match("%-(%d+)$")), cell = "-3, -2" } }
customEventHooks.triggerHandlers("OnActorCellChange", { validDefaultHandler = true }, { 1, "-3, -3" })
report("K15 when the boss walks into another cell the state follows it", state().boss.cell == "-3, -2")
received = { { ref = 0, mp = 987654, cell = "5, 5" } }
customEventHooks.triggerHandlers("OnActorCellChange", { validDefaultHandler = true }, { 1, "-3, -2" })
report("K16 another actor's cell change does not matter", state().boss.cell == "-3, -2")
received = {}
dies(2, "-3, -2", boss.uniqueIndex, "myt_boss_3")
report("K17 death in the new cell rewards that cell's visitors only",
  items(Players[2]).gold_001 ~= nil and items(Players[1]).gold_001 == nil)

------------------------------------------------------------ time runs out
boss = fight()
clearMsgs()
advance(2 * H - 5); tick()
report("T1 still there before two hours are up", state().boss ~= nil and #deleted == 0)
advance(10); tick()
report("T2 after two hours the boss leaves: removed from the world and the cell, everybody told",
  state().boss == nil and #deleted == 1 and not cellHas("-3, -3", boss.uniqueIndex) and say("has left Balmora") ~= nil)
report("T3 the next boss is still on the old schedule (3 h after the first spawned)",
  state().nextAt == boss.spawnedAt + 3 * H)
advance(H); tick()
report("T4 and then a new one comes", #created == 2)

-- left while nobody is online: removed without a packet to anyone
due({ hubs = { BALMORA } }); tick()
local gone = created[1]
Players[1] = nil
advance(2 * H + 5)
local okTick = pcall(tick)
report("T5 timeout with nobody online: removed from the cell data directly, no error",
  okTick and state().boss == nil and #deleted == 0 and not cellHas("-3, -3", gone.uniqueIndex))

------------------------------------------------------------ restart
due({ hubs = { BALMORA } }); tick()
local abroad = state().boss
boot({ keepDisk = true, hubs = { BALMORA } })
report("P1 a boss and the schedule survive a restart", B.State().boss and B.State().boss.uniqueIndex == abroad.uniqueIndex
  and B.State().nextAt == state().nextAt)
T.player(1, "Alice", { level = 15 }); T.auth(1)
report("P2 a player logging in is told a boss is abroad", say("Balmora") ~= nil)
advance(2 * H + 1); tick()
report("P3 it still expires on time afterwards", B.State().boss == nil and #deleted == 1)

-- boss recorded but its object is gone
due({ hubs = { BALMORA } }); tick()
local lost = state().boss
LoadedCells = {}
local cellFile = T.cellOnDisk("-3, -3")
cellFile.objectData[lost.uniqueIndex] = nil
T.disk["cell/-3, -3.json"] = T.json.encode(cellFile)
boot({ keepDisk = true, hubs = { BALMORA } })
report("P4 a recorded boss whose object no longer exists is forgotten at start", B.State().boss == nil
  and T.logContains("no longer exists"))
T.player(1, "Alice", { level = 15 }); T.auth(1)
advance(3 * H); tick()
report("P5 ... and does not keep the next one from coming", #created == 1, #created)
-- dead according to the cell
due({ hubs = { BALMORA } }); tick()
lost = state().boss
local cf = T.cellOnDisk("-3, -3")
cf.packets.death = { lost.uniqueIndex }
T.disk["cell/-3, -3.json"] = T.json.encode(cf)
boot({ keepDisk = true, hubs = { BALMORA } })
report("P6 a recorded boss that the cell says is dead is forgotten at start too", B.State().boss == nil)

-- damaged state
for _, junk in ipairs({ "garbage {", "[]", '{"nextAt":"soon","boss":5,"corpses":"x"}',
  '{"boss":{"tier":99,"cell":"-3, -3","uniqueIndex":"0-1","refId":"x","name":"n","expiresAt":1}}',
  '{"boss":{"tier":1,"cell":"-3, -3"},"corpses":[{"cell":1},3,{"cell":"a","uniqueIndex":"0-2","removeAt":"x"}]}' }) do
  boot()
  T.disk["custom/myTes3mpBosses.json"] = junk
  local B2 = T.load("bosses"); B2.random = fixedRandom
  local ok2, problem = pcall(T.postInit)
  local s2 = B2.State()
  report("X1 damaged state loads without error and holds no boss: " .. junk:sub(1, 28),
    ok2 and s2.boss == nil and type(s2.corpses) == "table" and #s2.corpses == 0, problem)
end
due({ hubs = { BALMORA } })
T.disk["custom/myTes3mpBosses.json"] = "garbage"
boot({ hubs = { BALMORA } })
T.player(1, "Alice", { level = 15 }); T.auth(1)
tick(); advance(3 * H + 1); tick()
report("X2 after a damaged file the schedule starts afresh and a boss still comes", #created == 1)

------------------------------------------------------------ resets
-- No resets module: nothing to hook, no error.
boot()
report("Z1 without resets.lua nothing is registered (myTes3mpResets is nil)", myTes3mpResets == nil)

-- With resets: a reset of the boss's cell makes the boss leave.
boot({ resets = true, hubs = { BALMORA } })
report("Z2 a reset listener is registered when resets.lua is loaded", #myTes3mpResets.listeners == 1)
T.player(1, "Alice", { level = 15, cell = "-2, -9" }); T.auth(1)
tick(); advance(3 * H + 1); tick()
boss = state().boss
clearMsgs()
for _, listener in ipairs(myTes3mpResets.listeners) do listener("5, 5") end
report("Z3 a reset of another cell changes nothing", state().boss ~= nil)
for _, listener in ipairs(myTes3mpResets.listeners) do listener("-3, -3") end
report("Z4 a reset of the boss's cell counts as the boss leaving: state cleared, everybody told",
  state().boss == nil and say("has left Balmora") ~= nil and #deleted == 0)
advance(3 * H); tick()
report("Z5 the next boss is not blocked", #created == 2)

-- the real resets code, end to end
boot({ resets = true, hubs = { BALMORA } })
T.player(1, "Alice", { level = 15, cell = "-2, -9" }); T.auth(1)
T.player(2, "Bob", { level = 15, cell = "-3, -3" })
T.visit(2, "-3, -3"); T.leave(2, "-3, -3")        -- starts the cell's reset clock
tick(); advance(5 * H); tick()
boss = state().boss
report("Z6 (set-up) a boss is abroad in a cell with a running reset clock", boss ~= nil and cellHas("-3, -3", boss.uniqueIndex))
local resetId = T.timerNamed("MyTes3mpResetTick")
report("Z6b bosses.lua registered a holder with resets.lua", #myTes3mpResets.holders == 1)
T.fire(resetId)
report("Z7 the real reset sweep does NOT reset the cell while the boss lives",
  T.resetCount() == 0 and B.State().boss ~= nil and cellHas("-3, -3", boss.uniqueIndex))
T.fire(resetId); T.fire(resetId)
report("Z7b ... however often it looks", T.resetCount() == 0 and B.State().boss ~= nil)
advance(2 * H); tick()
report("Z8 the boss leaves at its time (removed, not reset)", B.State().boss == nil and #deleted == 1)
T.fire(resetId)
report("Z9 afterwards the cell resets normally on the next sweep", T.resetCount() == 1)

-- killed: the cell is let go as well
boot({ resets = true, hubs = { BALMORA } })
T.player(1, "Alice", { level = 15, cell = "-2, -9" }); T.auth(1)
T.player(2, "Bob", { level = 15, cell = "-3, -3" })
T.visit(2, "-3, -3"); T.leave(2, "-3, -3")
tick(); advance(5 * H); tick()
boss = state().boss
T.visit(2, "-3, -3")
dies(2, "-3, -3", boss.uniqueIndex, "myt_boss_3")
advance(B.corpseSeconds + 1); tick()
T.leave(2, "-3, -3")
resetId = T.timerNamed("MyTes3mpResetTick")
T.fire(resetId)
report("Z10 after the boss was killed the cell resets normally", T.resetCount() == 1 and not cellHas("-3, -3", boss.uniqueIndex))

-- a boss that changes cell holds the new cell and releases the old one
boot({ resets = true, hubs = { BALMORA } })
T.player(1, "Alice", { level = 15, cell = "-2, -9" }); T.auth(1)
tick(); advance(3 * H + 1); tick()
boss = state().boss
local function held(cell)
  for _, f in ipairs(myTes3mpResets.holders) do if f(cell) then return true end end
  return false
end
report("Z11 the boss's cell is held, others are not", held("-3, -3") and not held("-3, -2"))
received = { { ref = 0, mp = tonumber(boss.uniqueIndex:match("%-(%d+)$")), cell = "-3, -2" } }
customEventHooks.triggerHandlers("OnActorCellChange", { validDefaultHandler = true }, { 1, "-3, -3" })
received = {}
report("Z12 after it walks into the next cell that one is held and the old one is released",
  held("-3, -2") and not held("-3, -3"))
bosses_depart = B.Depart("test", false)
report("Z13 with no boss nothing is held", not held("-3, -2") and not held("-3, -3"))

-- an old resets.lua without holders: bosses.lua still loads
boot({ hubs = { BALMORA } })
myTes3mpResets = { listeners = {} }
local okOld = pcall(T.postInit)
report("Z14 resets without a holders list: no error, listener still registered", okOld and #myTes3mpResets.listeners >= 1)

------------------------------------------------------------ who took part
-- (the real combat.lua; K1-K17 above run without it: everybody in the cell is paid)
report("W0 without combat.lua (myTes3mpCombat nil) every visitor is paid - see K1", myTes3mpCombat == nil)

local function partyFight(setup)
  boss = fight({ combat = true })
  T.player(3, "Eve", { level = 15, cell = "-3, -3" }); T.auth(3); T.visit(3, "-3, -3")
  setup()
  dies(1, "-3, -3", boss.uniqueIndex, "myt_boss_3")
end
partyFight(function() myTes3mpCombat.Mark(2) end)
-- Reporting the death is only a matter of whose game controls the cell, so it earns nothing by itself.
report("W1 a visitor who never fought gets nothing; the one who fought is paid; the reporter only if he fought",
  items(Players[3]).gold_001 == nil and items(Players[2]).gold_001 == B.tiers[3].gold
  and items(Players[1]).gold_001 == nil)
report("W1b the announcement names only those paid", (function() local m = say("has been slain")
  return m and m[2]:find("Bob", 1, true) and not m[2]:find("Alice", 1, true) and not m[2]:find("Eve", 1, true) end)())
partyFight(function() myTes3mpCombat.Mark(1) end)
report("W1c a reporter who did fight is paid like anybody else",
  items(Players[1]).gold_001 == B.tiers[3].gold and items(Players[2]).gold_001 == nil)
local goldBob = items(Players[2]).gold_001
dies(1, "-3, -3", boss.uniqueIndex, "myt_boss_3")
report("W2 nobody is paid twice", items(Players[2]).gold_001 == goldBob and items(Players[1]).gold_001 == B.tiers[3].gold)

partyFight(function() myTes3mpCombat.Mark(2); advance(119) end)
report("W3 fought 119 s ago: paid", items(Players[2]).gold_001 == B.tiers[3].gold)
partyFight(function() myTes3mpCombat.Mark(2); advance(120) end)
report("W3b fought exactly 120 s ago: paid", items(Players[2]).gold_001 == B.tiers[3].gold)
partyFight(function() myTes3mpCombat.Mark(2); advance(121) end)
report("W4 fought 121 s ago: not paid", items(Players[2]).gold_001 == nil and items(Players[1]).gold_001 == nil)
partyFight(function() myTes3mpCombat.Mark(2); myTes3mpCombat.Calm(2) end)
report("W4b a player who fought, went down and was helped up (calmed) still counts as having fought",
  items(Players[2]).gold_001 == B.tiers[3].gold)
partyFight(function() myTes3mpCombat.Mark(2); myTes3mpCombat.Mark(3) end)
report("W5 everyone who fought is paid, once", items(Players[2]).gold_001 == B.tiers[3].gold
  and items(Players[3]).gold_001 == B.tiers[3].gold)

-- the nil case once more, with a visitor who never fought
boss = fight()
T.player(3, "Eve", { level = 15, cell = "-3, -3" }); T.auth(3); T.visit(3, "-3, -3")
dies(1, "-3, -3", boss.uniqueIndex, "myt_boss_3")
report("W6 myTes3mpCombat = nil: every visitor is paid", myTes3mpCombat == nil
  and items(Players[2]).gold_001 == B.tiers[3].gold and items(Players[3]).gold_001 == B.tiers[3].gold)

------------------------------------------------------------ /boss
boot({ hubs = { BALMORA } })
T.player(1, "Alice", { level = 15 }); T.auth(1)
tick()
clearMsgs()
customCommandHooks.getCallback("boss")(1, { "boss" })
report("I1 no boss abroad: says when the next is expected", T.msgs[1][2]:find("No world boss is abroad", 1, true)
  and T.msgs[1][2]:find("about", 1, true))
advance(3 * H + 1); tick()
clearMsgs()
customCommandHooks.getCallback("boss")(1, { "boss" })
report("I2 boss abroad: name, place and time left", T.msgs[1][2]:find("Old Ashmaw", 1, true) ~= nil
  and T.msgs[1][2]:find("Balmora", 1, true) ~= nil and T.msgs[1][2]:find("120 minutes", 1, true) ~= nil, T.msgs[1][2])

------------------------------------------------------------ challenge.lua
-- The real challenge.lua multiplies health; bosses.EffectiveHealth must agree with it.
boot({ challenge = true })
local challenge = package.loaded["custom/myTes3mp/challenge"]
local agree = true
for n, tier in ipairs(B.tiers) do
  for _, level in ipairs({ tier.minLevel, tier.refLevel, 30 }) do
    for _, others in ipairs({ 1, 2 }) do
      Players = {}
      T.player(1, "Alice", { level = level }); if others == 2 then T.player(2, "Bob", { level = 1 }) end
      local expected = math.floor(B.RecordHealth(tier) * challenge.HealthMultiplier(others) + 0.5)
      if B.EffectiveHealth(n, level, others) ~= expected then agree = false end
    end
  end
end
report("C1 EffectiveHealth equals record health x challenge.HealthMultiplier(players in cell) for every tier", agree)
local prev, strict = 0, true
for n = 1, 5 do
  local e = B.EffectiveHealth(n, B.tiers[n].minLevel, 2)
  strict = strict and e > prev; prev = e
end
report("C2 effective health with two players at the band's lowest level rises with every tier", strict)
report("C3 default 'hard' preset (printed): tier 3 at level 10, two players",
  B.EffectiveHealth(3, 10, 2) == math.floor(580 * (1.5 + 0.05 * 9) * 1.5 + 0.5), B.EffectiveHealth(3, 10, 2))
for _, line in ipairs(B.Describe()) do print("     " .. line) end

------------------------------------------------------------ real travelPoints.lua
setHubs(dofile(T.scriptsDir .. "/travelPoints.lua"))
boot({ hubs = dofile(T.scriptsDir .. "/travelPoints.lua") })
local hubsLoaded = B.LoadHubs()
local allIn = #hubsLoaded >= 10
for _, h in ipairs(hubsLoaded) do allIn = allIn and h.exterior == true end
report("W1 the real travelPoints.lua yields at least 10 usable open-world places", allIn, #hubsLoaded)

------------------------------------------------------------ robustness
boot()
T.player(1, "Alice", {}); T.auth(1)
local _, timerId = tick()
local restarts = T.timers[timerId].restarts
B.Tick = function() error("boom") end
tick()
report("Y1 a failing look is logged and the timer is restarted", T.timers[timerId].restarts == restarts + 2
  or T.timers[timerId].restarts == restarts + 1, T.timers[timerId].restarts)
report("Y2 the failure is in the log", T.logContains("Check failed: ") )
-- spawning fails (the engine refuses): no state change, retried later, not every look
due({ hubs = { BALMORA } })
logicHandler.CreateObjectAtLocation = function() error("cell unreadable") end
tick()
report("Y3 a failed spawn leaves no boss behind and is not retried at every look",
  state().boss == nil and state().nextAt == T.time + B.graceSeconds and T.logContains("Could not place"))
logicHandler.CreateObjectAtLocation = function() return nil end
advance(B.graceSeconds + 1); tick()
report("Y4 an engine that returns no object number is handled too", state().boss == nil)

for _, ev in ipairs({ "OnActorDeath", "OnActorCellChange", "OnPlayerAuthentified", "OnServerPostInit" }) do
  local src = T.csSource("eventHandler.lua") .. T.csSource("player/base.lua") .. T.csSource("serverCore.lua")
  report("Y5 CoreScripts raises " .. ev, src:find('triggerHandlers("' .. ev .. '"', 1, true) ~= nil)
end

T.summary()
