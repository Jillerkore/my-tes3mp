-- sharequest.lua: share single quests while journals stay separate.
--
-- The journal packets the server sends, the boxes it shows and the answers it
-- gets are recorded by stubs defined here (harness.lua knows none of them). A
-- player's saved journal is changed by the REAL BasePlayer:SaveJournal logic
-- (stateHelper.lua), as eventHandler.OnPlayerJournal does it.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local ENTRY, INDEX = enumerations.journal.ENTRY, enumerations.journal.INDEX
local StateHelper = require("stateHelper")

local S
local rec

local function install()
  rec = { sent = {}, boxes = {}, lists = {}, cur = {} }
  tes3mp.ClearJournalChanges = function(pid) rec.cur[pid] = {} end
  tes3mp.AddJournalEntry = function(pid, q, i, a)
    table.insert(rec.cur[pid], { type = ENTRY, quest = q, index = i, actor = a })
  end
  tes3mp.AddJournalEntryWithTimestamp = function(pid, q, i, a, d, m, day)
    table.insert(rec.cur[pid], { type = ENTRY, quest = q, index = i, actor = a, ts = { d, m, day } })
  end
  tes3mp.AddJournalIndex = function(pid, q, i) table.insert(rec.cur[pid], { type = INDEX, quest = q, index = i }) end
  tes3mp.SendJournalChanges = function(pid)
    table.insert(rec.sent, { pid = pid, items = rec.cur[pid] }); rec.cur[pid] = nil
  end
  tes3mp.CustomMessageBox = function(pid, id, label, buttons)
    table.insert(rec.boxes, { pid = pid, id = id, label = label, buttons = buttons })
  end
  tes3mp.ListBox = function(pid, id, label, items)
    table.insert(rec.lists, { pid = pid, id = id, label = label, items = items })
  end
end

local function boot(settings, keepDisk)
  local disk = T.disk
  T.fresh(settings or (function() local s = T.copy(T.DEFAULT_SETTINGS); s.shareQuests = true; return s end)())
  if keepDisk then T.disk = disk end
  config.shareJournal = false   -- this project's setting (CoreScripts' default is true)
  config.shareKills = false
  install()
  S = T.load("sharequest")
  T.postInit()
end

local function player(pid, name, journal, loggedIn)
  local p = T.player(pid, name, { journal = journal or {}, loggedIn = loggedIn })
  function p:SaveJournal(packet) StateHelper:SaveJournal(self, packet) end
  return p
end

local function entry(quest, index, day)
  return { type = ENTRY, quest = quest, index = index, actorRefId = "fargoth",
    timestamp = { daysPassed = day or 1, month = 2, day = day or 1 } }
end
local function idx(quest, index) return { type = INDEX, quest = quest, index = index } end

-- A journal report from a player's game, as eventHandler.OnPlayerJournal handles it.
local function client(pid, items)
  local packet = { journal = {} }
  for _, it in ipairs(items) do
    local c = {}
    for k, v in pairs(it) do c[k] = v end
    if c.timestamp == nil and c.type == ENTRY then c.timestamp = { daysPassed = 9, month = 3, day = 9 } end
    table.insert(packet.journal, c)
  end
  local status = customEventHooks.triggerValidators("OnPlayerJournal", { pid, packet })
  if status.validDefaultHandler and config.shareJournal ~= true then Players[pid]:SaveJournal(packet) end
  customEventHooks.triggerHandlers("OnPlayerJournal", status, { pid, packet })
end

local function gui(pid, id, data)
  local status = customEventHooks.triggerValidators("OnGUIAction", { pid, id, tostring(data) })
  customEventHooks.triggerHandlers("OnGUIAction", status, { pid, id, tostring(data) })
end
local function cmd(pid, line)
  local words = {}
  for w in line:gmatch("%S+") do words[#words + 1] = w end
  customCommandHooks.getCallback(words[1])(pid, words)
end
local function disconnect(pid)
  customEventHooks.triggerHandlers("OnPlayerDisconnect", { validDefaultHandler = true }, { pid })
  Players[pid] = nil
end

local function sentTo(pid)
  local list = {}
  for _, p in ipairs(rec.sent) do if p.pid == pid then list[#list + 1] = p end end
  return list
end
local function count(pid, quest, kind)
  local n = 0
  for _, it in ipairs(Players[pid].data.journal) do
    if it.quest:lower() == quest:lower() and (kind == nil or it.type == kind) then n = n + 1 end
  end
  return n
end
local function has(pid, quest, index, kind)
  for _, it in ipairs(Players[pid].data.journal) do
    if it.quest:lower() == quest:lower() and it.index == index and (kind == nil or it.type == kind) then return true end
  end
  return false
end
local function say(text)
  for _, m in ipairs(T.msgs) do if m[2]:find(text, 1, true) then return true end end
  return false
end
local function links() local d = T.diskState("myTes3mpShareQuest.json"); return d and d.links or {} end
local function queue() local d = T.diskState("myTes3mpShareQuest.json"); return d and d.queue or {} end

local function aliceJournal()
  return {
    entry("A1_1_FindSpymaster", 10, 1),
    entry("MS_FargothRing", 10, 3),
    idx("HH_Stronghold", 50),
    entry("MS_FargothRing", 20, 4),
  }
end

-- share MS_FargothRing between Alice (1) and Bob (2, journal given) and return
local function paired(bobJournal)
  boot()
  player(1, "Alice", aliceJournal()); player(2, "Bob", bobJournal or {})
  T.auth(1); T.auth(2)
  cmd(1, "sharequest MS_FargothRing")
  gui(2, S.ASK_ID, 0)
end

------------------------------------------------------------ the list
boot()
player(1, "Alice", aliceJournal()); player(2, "Bob")
T.auth(1); T.auth(2)
cmd(1, "sharequest")
local list = rec.lists[1]
report("L1 /sharequest shows a list box to the player", list ~= nil and list.pid == 1 and list.id == S.PICK_ID)
local lines = {}
for l in (list and list.items or ""):gmatch("[^\n]+") do lines[#lines + 1] = l end
report("L2 most recently updated first, id and latest index shown",
  #lines == 2 and lines[1]:find("MS_FargothRing", 1, true) and lines[1]:find("index 20", 1, true)
  and lines[2]:find("A1_1_FindSpymaster", 1, true) and lines[2]:find("index 10", 1, true), table.concat(lines, " | "))
report("L3 stronghold quests are not offered", not (list.items:find("Stronghold", 1, true)))
report("L4 nothing sent to anyone yet", #rec.boxes == 0 and #rec.sent == 0)

gui(1, S.PICK_ID, 0)
report("L5 choosing line 0 offers that quest: the other player gets a yes/no box",
  #rec.boxes == 1 and rec.boxes[1].pid == 2 and rec.boxes[1].id == S.ASK_ID and rec.boxes[1].buttons == "Yes;No"
  and rec.boxes[1].label:find("MS_FargothRing", 1, true) ~= nil, rec.boxes[1] and rec.boxes[1].label)
report("L6 the box names the offerer", rec.boxes[1].label:find("Alice", 1, true) ~= nil)
report("L7 nothing copied before an answer", #Players[2].data.journal == 0 and #rec.sent == 0 and next(links()) == nil)

gui(1, S.PICK_ID, 4294967295)  -- no choice
report("L8 a list closed without a choice does nothing", #rec.boxes == 1)
gui(1, S.PICK_ID, 7)           -- stale / out of range
report("L9 an answer without a list shown does nothing", #rec.boxes == 1)

-- the three ids are distinct and clear of CoreScripts' own
local ids = { S.PICK_ID, S.ASK_ID, S.UNPICK_ID }
local clash = false
for _, a in ipairs(ids) do
  for _, b in pairs(config.customMenuIds) do if a == b then clash = true end end
end
report("L10 gui ids are distinct and do not collide with config.customMenuIds",
  not clash and S.PICK_ID ~= S.ASK_ID and S.ASK_ID ~= S.UNPICK_ID and S.PICK_ID ~= S.UNPICK_ID)

------------------------------------------------------------ accept: backlog
paired()
report("A1 accepting copies the quest's entries to the acceptor, in order",
  count(2, "MS_FargothRing", ENTRY) == 2 and Players[2].data.journal[1].index == 10
  and Players[2].data.journal[2].index == 20)
report("A2 other quests are not copied", count(2, "A1_1_FindSpymaster") == 0 and count(2, "HH_Stronghold") == 0)
local pk = sentTo(2)
report("A3 one journal packet to the acceptor with both entries and their dates",
  #pk == 1 and #pk[1].items == 2 and pk[1].items[1].quest == "MS_FargothRing" and pk[1].items[1].ts
  and pk[1].items[1].ts[1] == 3 and pk[1].items[2].ts[1] == 4 and pk[1].items[1].actor == "fargoth",
  pk[1] and #pk[1].items)
local l = links()
report("A4 link saved: quest id (lower case) -> account names",
  l.ms_fargothring and l.ms_fargothring.alice == true and l.ms_fargothring.bob == true)
report("A5 offerer's journal untouched, nothing sent to him", #Players[1].data.journal == 4 and #sentTo(1) == 0)
report("A6 both players are told", say("accepted MS_FargothRing") and say("You now share MS_FargothRing"))

-- partly present: only the missing entry arrives
paired({ entry("MS_FargothRing", 10, 3) })
report("A7 entries the acceptor already has are not duplicated",
  count(2, "MS_FargothRing", ENTRY) == 2 and sentTo(2)[1] and #sentTo(2)[1].items == 1
  and sentTo(2)[1].items[1].index == 20)
-- everything already present: no packet at all
paired({ entry("MS_FargothRing", 10, 3), entry("MS_FargothRing", 20, 4) })
report("A8 acceptor has all of it: no packet, no duplicates", #sentTo(2) == 0 and count(2, "MS_FargothRing") == 2)
-- accepting the same offer again (stale box)
paired()
gui(2, S.ASK_ID, 0)
report("A9 an answer with no open offer is ignored", count(2, "MS_FargothRing") == 2 and #sentTo(2) == 1)

-- real CoreScripts bookkeeping is kept: SaveJournal sets the Caius flag
boot()
-- (CoreScripts compares this quest id in lower case only)
player(1, "Alice", { entry("a1_1_findspymaster", 10, 1), entry("a1_1_findspymaster", 14, 2) }); player(2, "Bob")
T.auth(1); T.auth(2)
cmd(1, "sharequest a1_1_findspymaster"); gui(2, S.ASK_ID, 0)
report("A10 items go through BasePlayer:SaveJournal (CoreScripts' own delivered-package note is set)",
  Players[2].data.customVariables.deliveredCaiusPackage == true and Players[2].calls[#Players[2].calls] == "save")

------------------------------------------------------------ decline, direct id, edges
boot()
player(1, "Alice", aliceJournal()); player(2, "Bob")
T.auth(1); T.auth(2)
cmd(1, "sharequest ms_fargothring")
report("D1 /sharequest <id> works with any capitals and asks the other player",
  #rec.boxes == 1 and rec.boxes[1].pid == 2)
gui(2, S.ASK_ID, 1)
report("D2 declining copies nothing, creates no link, and tells the offerer",
  #Players[2].data.journal == 0 and #rec.sent == 0 and next(links()) == nil and say("does not want to share"))
cmd(1, "sharequest No_Such_Quest")
report("D3 an unknown quest id is refused", say("no quest called") and #rec.boxes == 1)
cmd(1, "sharequest HH_Stronghold"); cmd(1, "sharequest hr_stronghold"); cmd(1, "sharequest HT_STRONGHOLD")
report("D4 stronghold quests are refused (any house, any capitals) and nobody is asked",
  #rec.boxes == 1 and say("stronghold quests"))
player(3, "Carol", {}, true); T.auth(3)
disconnect(2); disconnect(3)
cmd(1, "sharequest MS_FargothRing")
report("D5 nobody else online: says so, no box", say("Nobody else is online") and #rec.boxes == 1)

-- offerer leaves before the answer
boot()
player(1, "Alice", aliceJournal()); player(2, "Bob")
T.auth(1); T.auth(2)
cmd(1, "sharequest MS_FargothRing")
disconnect(1)
gui(2, S.ASK_ID, 0)
report("D6 offerer gone before the answer: nothing copied, no link", #Players[2].data.journal == 0 and next(links()) == nil)

-- three players: only the one who says yes is linked
boot()
player(1, "Alice", aliceJournal()); player(2, "Bob"); player(3, "Carol")
T.auth(1); T.auth(2); T.auth(3)
cmd(1, "sharequest MS_FargothRing")
local asked = {}
for _, b in ipairs(rec.boxes) do asked[b.pid] = true end
gui(2, S.ASK_ID, 0); gui(3, S.ASK_ID, 1)
local l3 = links().ms_fargothring
report("D7 offer goes to every other online player; only acceptors are linked",
  asked[2] and asked[3] and not asked[1] and l3 and l3.bob and not l3.carol and #Players[3].data.journal == 0)

------------------------------------------------------------ relay
paired()
rec.sent = {}
client(1, { entry("MS_FargothRing", 30, 9) })
report("R1 Alice's new entry reaches Bob at once",
  has(2, "MS_FargothRing", 30, ENTRY) and #sentTo(2) == 1 and sentTo(2)[1].items[1].index == 30)
report("R1b it is stored once in his journal and he got the sender's date",
  count(2, "MS_FargothRing") == 3 and sentTo(2)[1].items[1].ts[1] == 9)
report("R2 nothing goes back to the sender", #sentTo(1) == 0 and count(1, "MS_FargothRing", ENTRY) == 3)
rec.sent = {}
client(2, { entry("MS_FargothRing", 40) })
report("R3 Bob's new entry reaches Alice (both directions)",
  has(1, "MS_FargothRing", 40, ENTRY) and #sentTo(1) == 1 and #sentTo(2) == 0)
report("R4 each journal holds each entry exactly once", count(1, "MS_FargothRing", ENTRY) == 4
  and count(2, "MS_FargothRing", ENTRY) == 4)

-- no loop, even if a game DID report what it was sent
rec.sent = {}
client(2, { entry("MS_FargothRing", 30) })    -- hypothetical echo of the relayed entry
client(1, { entry("MS_FargothRing", 40) })
report("R5 a hypothetical echo of a relayed entry is not passed on again (no ping-pong)",
  #sentTo(1) == 0 and #sentTo(2) == 0)
-- the same report twice
rec.sent = {}
local bobBefore = count(2, "MS_FargothRing", ENTRY)
client(1, { entry("MS_FargothRing", 50) }); client(1, { entry("MS_FargothRing", 50) })
report("R6 the same entry reported twice reaches Bob once",
  count(2, "MS_FargothRing", ENTRY) == bobBefore + 1 and #sentTo(2) == 1)

-- index items
rec.sent = {}
client(1, { idx("MS_FargothRing", 100) })
report("R7 a journal index is relayed too", has(2, "MS_FargothRing", 100, INDEX) and sentTo(2)[1]
  and sentTo(2)[1].items[1].type == INDEX)
rec.sent = {}
client(1, { idx("MS_FargothRing", 60) })
report("R8 an index below the receiver's current one is not passed on (it would move his quest back)",
  #sentTo(2) == 0 and not has(2, "MS_FargothRing", 60, INDEX))

-- several quests in one report; only the shared one is relayed
rec.sent = {}
client(1, { entry("A1_1_FindSpymaster", 12), entry("MS_FargothRing", 70), idx("HH_Stronghold", 55) })
report("R9 only the shared quest travels",
  has(2, "MS_FargothRing", 70, ENTRY) and count(2, "A1_1_FindSpymaster") == 0 and count(2, "HH_Stronghold") == 0
  and #sentTo(2) == 1 and #sentTo(2)[1].items == 1)

-- the quest id of a relayed item may use other capitals than the stored link key
rec.sent = {}
client(2, { entry("ms_fargothring", 80) })
report("R10 quest ids are matched without regard to capitals", has(1, "MS_FargothRing", 80, ENTRY))

-- a vetoed report (another script refused to save it) is not relayed
rec.sent = {}
do
  local packet = { journal = { entry("MS_FargothRing", 90) } }
  customEventHooks.triggerHandlers("OnPlayerJournal", customEventHooks.makeEventStatus(false, false), { 1, packet })
end
report("R11 a report that was not saved is not relayed", #sentTo(2) == 0)

------------------------------------------------------------ offline queue
paired()
disconnect(2)
rec.sent = {}
client(1, { entry("MS_FargothRing", 30) })
client(1, { entry("MS_FargothRing", 30) })    -- duplicate while he is away
client(1, { entry("MS_FargothRing", 35), idx("MS_FargothRing", 36) })
local q = queue().bob
report("Q1 items for an offline player wait in the state file, once each", q and #q == 3, q and #q)
report("Q2 nothing is sent while he is away", #rec.sent == 0)
-- restart of the server while he is away
boot(nil, true)
player(1, "Alice", aliceJournal())
report("Q3 queue and link survive a restart", queue().bob and #queue().bob == 3 and links().ms_fargothring.bob == true)
local bob = player(2, "Bob", { entry("MS_FargothRing", 10, 3), entry("MS_FargothRing", 20, 4) })
T.auth(1); T.auth(2)
report("Q4 at login the waiting items are delivered to his journal and game",
  has(2, "MS_FargothRing", 30, ENTRY) and has(2, "MS_FargothRing", 35, ENTRY) and has(2, "MS_FargothRing", 36, INDEX)
  and #sentTo(2) == 1 and #sentTo(2)[1].items == 3)
report("Q5 the queue is empty afterwards (also on disk) and he is told",
  queue().bob == nil and say("moved a shared quest on"))
T.auth(2)
report("Q6 a second login delivers nothing again", #sentTo(2) == 1 and count(2, "MS_FargothRing", ENTRY) == 4)

-- already has it at login
paired()
disconnect(2)
client(1, { entry("MS_FargothRing", 30) })
player(2, "Bob", { entry("MS_FargothRing", 10, 3), entry("MS_FargothRing", 20, 4), entry("MS_FargothRing", 30, 9) })
rec.sent = {}
T.auth(2)
report("Q7 an item he already has at login is dropped, not duplicated", count(2, "MS_FargothRing", ENTRY) == 3 and #sentTo(2) == 0)

------------------------------------------------------------ unshare
paired()
disconnect(2)
client(1, { entry("MS_FargothRing", 30) })
player(2, "Bob", {})
cmd(1, "unsharequest ms_fargothring")
report("U1 unsharing removes the link", links().ms_fargothring == nil and say("You stopped sharing"))
report("U2 what was waiting for the quest is dropped", queue().bob == nil)
T.auth(2)
report("U3 nothing is delivered after unsharing", #Players[2].data.journal == 0)
client(1, { entry("MS_FargothRing", 31) })
client(2, { entry("MS_FargothRing", 32) })
report("U4 later entries are not passed on", count(1, "MS_FargothRing", ENTRY) == 4 and count(2, "MS_FargothRing") == 1)
cmd(1, "unsharequest ms_fargothring")
report("U5 unsharing something not shared is refused", say("not sharing a quest called"))

paired()
rec.lists = {}
cmd(2, "unsharequest")
report("U6 /unsharequest without argument lists the player's shared quests",
  rec.lists[1] and rec.lists[1].pid == 2 and rec.lists[1].id == S.UNPICK_ID and rec.lists[1].items == "ms_fargothring")
gui(2, S.UNPICK_ID, 0)
report("U7 choosing from that list unshares it; the other player is told",
  links().ms_fargothring == nil and say("Bob stopped sharing"))
cmd(2, "unsharequest")
report("U8 nothing to unshare: says so", say("not sharing any quest"))
-- the list in /sharequest marks shared quests
paired()
rec.lists = {}
cmd(1, "sharequest")
report("U9 the share list marks quests already shared", rec.lists[1].items:find("[shared]", 1, true) ~= nil)

------------------------------------------------------------ modes
boot()
config.shareJournal = true
player(1, "Alice", aliceJournal()); player(2, "Bob")
T.auth(1); T.auth(2)
cmd(1, "sharequest"); cmd(1, "sharequest MS_FargothRing")
report("M1 with shared journals /sharequest does nothing but explain",
  #rec.lists == 0 and #rec.boxes == 0 and say("Journals are shared"))
-- even a link that exists from before is not relayed in this mode
boot()
player(1, "Alice", aliceJournal()); player(2, "Bob")
T.auth(1); T.auth(2)
cmd(1, "sharequest MS_FargothRing"); gui(2, S.ASK_ID, 0)
config.shareJournal = true
rec.sent = {}
client(1, { entry("MS_FargothRing", 30) })
report("M2 with shared journals nothing is relayed (CoreScripts shares everything)", #sentTo(2) == 0)
config.shareJournal = true
cmd(1, "unsharequest ms_fargothring")
config.shareJournal = false

local off = T.copy(T.DEFAULT_SETTINGS); off.shareQuests = false
boot(off)
player(1, "Alice", aliceJournal()); player(2, "Bob")
T.auth(1); T.auth(2)
cmd(1, "sharequest MS_FargothRing")
report("M3 shareQuests=false: commands refuse politely, no box", #rec.boxes == 0 and say("switched off"))

local nilset = T.copy(T.DEFAULT_SETTINGS); nilset.shareQuests = nil
boot(nilset)
player(1, "Alice", aliceJournal()); player(2, "Bob")
T.auth(1); T.auth(2)
cmd(1, "sharequest MS_FargothRing")
report("M4 setting missing (nil): module still works (it is only loaded when switched on)", #rec.boxes == 1)

------------------------------------------------------------ damaged state
for _, junk in ipairs({ "not json at all {", "[1,2,3]", '{"links":5,"queue":"x"}',
  '{"links":{"ms_x":{"alice":true}},"queue":{"bob":[{"quest":5},{"type":0,"quest":"Q","index":"z"},null,3]}}',
  '{"links":{"ms_fargothring":{"alice":true,"bob":true}},"queue":{"bob":[{"type":0,"quest":"MS_FargothRing","index":30,"timestamp":"junk"}]}}' }) do
  T.fresh(); config.shareJournal = false; install()
  T.disk["custom/myTes3mpShareQuest.json"] = junk
  S = T.load("sharequest")
  local ok, problem = pcall(T.postInit)
  local st = S.State()
  local sane = ok and type(st.links) == "table" and type(st.queue) == "table"
  report("X1 damaged state file loads without error: " .. junk:sub(1, 30), sane, problem)
  if junk:find("ms_x", 1, true) then
    report("X2 a link with a single member and queue items of the wrong shape are dropped",
      next(st.links) == nil and next(st.queue) == nil)
  end
  if junk:find("junk", 1, true) then
    player(2, "Bob", {}); T.auth(2)
    report("X3 a queued item with a bad timestamp is delivered without one",
      has(2, "MS_FargothRing", 30, ENTRY) and rec.sent[1] and rec.sent[1].items[1].ts == nil)
  end
end
-- a state file never written
T.fresh(); config.shareJournal = false; install(); S = T.load("sharequest"); T.postInit()
report("X4 no state file: starts empty", next(S.State().links) == nil)

------------------------------------------------------------ events and source facts
for _, ev in ipairs({ "OnPlayerJournal", "OnGUIAction", "OnPlayerAuthentified" }) do
  local src = T.csSource("eventHandler.lua") .. T.csSource("player/base.lua")
  report("E1 CoreScripts raises " .. ev, src:find('triggerHandlers("' .. ev .. '"', 1, true) ~= nil)
end
report("E2 CoreScripts raises OnPlayerDisconnect",
  T.csSource("eventHandler.lua"):find('triggerHandlers("OnPlayerDisconnect"', 1, true) ~= nil)
report("E3 the quest-id guard matches exactly the three stronghold ids strongholds.lua reads",
  S.IsProtected("HH_Stronghold") and S.IsProtected("hr_STRONGHOLD") and S.IsProtected("HT_Stronghold")
  and not S.IsProtected("MS_FargothRing") and not S.IsProtected("HF_Stronghold"))
do
  local text = T.scriptSource("strongholds.lua")
  report("E4 strongholds.lua still names those quests", text:find('hh_stronghold = "HH_Stronghold"', 1, true) ~= nil
    and text:find('hr_stronghold = "HR_Stronghold"', 1, true) ~= nil and text:find('ht_stronghold = "HT_Stronghold"', 1, true) ~= nil)
end

T.summary()
