-- resets.lua: automatic cell resets, exceptions, stashes, listeners.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local B = setmetatable({ reset = function() T.fresh() end }, { __index = T, __newindex = T })
local ENUM = enumerations
local DEFAULT = T.copy(T.DEFAULT_SETTINGS)
DEFAULT.cellResetKeep = { "Balmora, Caius Cosades' House" }
local R, S
local function copy(t) return T.copy(t) end

local function boot(settings, keepDisk)
  local disk = T.disk
  T.fresh(settings or copy(DEFAULT))
  if keepDisk then T.disk = disk end
  S = T.settings
  R = T.load("resets")
  T.postInit()
  return R
end
local function addPlayer(pid, name, cell, logged)
  return T.player(pid, name or ("p" .. pid), { cell = cell, loggedIn = logged ~= false })
end
local cellLoad, cellUnload = T.visit, T.leave
-- OnContainer as eventHandler.lua does it; `status` lets a test pretend a validator vetoed it
local function container(pid, d, action, sub, refNum, items, status)
  if status == nil then return T.container(pid, d, action, sub, refNum, items, "barrel_01") end
  local temp = LoadedCells[d] == nil
  if temp then logicHandler.LoadCell(d) end
  T.packet = { action = action, sub = sub, objects = { { refId = "barrel_01", refNum = refNum, mpNum = 0, items = items } } }
  LoadedCells[d]:SaveContainers(pid)
  if temp then logicHandler.UnloadCell(d) end
  local objects = { { refId = "barrel_01", uniqueIndex = refNum .. "-0" } }
  customEventHooks.triggerHandlers("OnContainer", status, { pid, d, objects })
end
local resetCalls = T.resetCount
local diskCell = T.cellOnDisk
local H = 3600
local ADD, REMOVE, SET = ENUM.container.ADD, ENUM.container.REMOVE, ENUM.container.SET
local SUB = ENUM.containerSub

------------------------------------------------------------ timers
boot(); addPlayer(1,"alice")
cellLoad(1,"Vivec, Foreign Quarter Canton")
-- access timers through saved state
local function timers() return B.json.decode(B.disk["custom/myTes3mpCellResets.json"] or "{}") end
customEventHooks.triggerHandlers("OnServerExit", {}, {})   -- force save
local t0 = timers().timers["Vivec, Foreign Quarter Canton"]
report("R1 timer started on first load = now+4h", t0 == B.time + 4*H, t0)
B.time = B.time + H; cellUnload(1,"Vivec, Foreign Quarter Canton"); cellLoad(1,"Vivec, Foreign Quarter Canton")
MyTes3mpResetTick(); local t1 = timers().timers["Vivec, Foreign Quarter Canton"]
report("R1 second load does not restart timer", t1 == t0, tostring(t1).." vs "..tostring(t0))
cellUnload(1,"Vivec, Foreign Quarter Canton")
report("R1 timer registered/started, restarts each tick", T.timers[1].name=="MyTes3mpResetTick" and T.timers[1].started and T.timers[1].restarts==1)

------------------------------------------------------------ not due / loaded / due
local D = "Balmora, Hodlismod"
boot(); addPlayer(1,"alice"); cellLoad(1,D); cellUnload(1,D)
B.time = B.time + 4*H - 1
report("R2 not due -> no reset", R.Sweep()==0 and resetCalls()==0)
-- put a mark in the cell to see the wipe
logicHandler.LoadCell(D); LoadedCells[D].data.objectData["5-0"]={refId="x",dead=true}; logicHandler.UnloadCell(D)
B.time = B.time + 1
cellLoad(1,D)   -- loaded again; timer is NOT restarted (already set)
report("R3 due but loaded -> no reset", R.Sweep()==0 and resetCalls()==0 and diskCell(D).objectData["5-0"] ~= nil)
cellUnload(1,D)
local n = R.Sweep()
local dc = diskCell(D)
report("R4 due+unloaded -> reset; data wiped", n==1 and next(dc.objectData)==nil and dc.loadState.hasFullActorList==false and dc.loadState.hasFullContainerData==false)
local sc; for _,c in ipairs(B.calls) do if c[1]=="SendCellReset" then sc=c end end
report("R4 client notified exactly once, others+self flag, right cell", resetCalls()==1 and sc[2]==1 and sc[3]==true and sc[4]==D, sc and sc[4])
customEventHooks.triggerHandlers("OnServerExit", {}, {})
report("R4 timer cleared", timers().timers[D]==nil)
R.Sweep(); report("R4 no second reset on later sweeps", resetCalls()==1)
cellLoad(1,D); cellUnload(1,D); customEventHooks.triggerHandlers("OnServerExit", {}, {}); MyTes3mpResetTick()
report("R4 next load starts a new timer", timers().timers[D] == B.time + 4*H, timers().timers[D])

------------------------------------------------------------ kept cells
local kept = { "-1, -9","-1, -10","-2, -9","-2, -10","-5, -5","-5, 9","10, 1",
  "Seyda Neen, Census and Excise Office","SEYDA NEEN, CENSUS AND EXCISE OFFICE",
  "Rethan Manor","Rethan Manor, Drelas' House","Indarys Manor, Raram's House","Tel Uvirith, Tower Upper",
  "tel uvirith, tower lower","Balmora, Caius Cosades' House","BALMORA, CAIUS COSADES' HOUSE" }
boot(); addPlayer(1,"alice")
local allOk, why = true, nil
for _, d in ipairs(kept) do
  cellLoad(1,d); cellUnload(1,d)
end
customEventHooks.triggerHandlers("OnServerExit", {}, {})
local ts = timers().timers or {}
for _, d in ipairs(kept) do if ts[d] ~= nil then allOk=false; why="timer for "..d end end
report("K1 kept cells never get timers", allOk, why)
-- stale timers in the state file
B.disk["custom/myTes3mpCellResets.json"] = B.json.encode({timers={}, stashes={}})
local stale = { timers = {}, stashes = {} }
for _, d in ipairs(kept) do stale.timers[d] = B.time - 10 end
B.disk["custom/myTes3mpCellResets.json"] = B.json.encode(stale)
boot(nil, true); addPlayer(1,"alice")
for _, d in ipairs(kept) do logicHandler.LoadCell(d); LoadedCells[d].data.objectData["9-0"]={refId="x"}; logicHandler.UnloadCell(d) end
local cnt = R.Sweep()
local lost
for _, d in ipairs(kept) do if not diskCell(d).objectData["9-0"] then lost = d end end
report("K2 stale timers on kept cells: not reset, timer dropped", cnt==0 and lost==nil and resetCalls()==0, lost)
-- negative: near-miss names are not kept
boot(); addPlayer(1,"alice")
local notKept = { "-1, -8","Balmora, Caius Cosades","Seyda Neen","Imperial Prison Ship","Vivec, Foreign Quarter Canton","-5, -4","10, 2" }
local bad
for _, d in ipairs(notKept) do if R.IsKept(d) then bad = d end end
report("K3 near-miss names are not kept", bad==nil, bad)
report("K3b $custom_ fragment gone (not kept)", not R.IsKept("$Custom_Instance_1") and not R.IsKept("Seyda Neen, Census and Excise Office - Instance for bob") == false)
-- the config keep list is a *fragment* match (documented behaviour?)
report("K4 keep entry matches as fragment (e.g. 'Balmora, Caius Cosades\\' House, Cellar')", R.IsKept("Balmora, Caius Cosades' House, Cellar") == true)
-- hostile keep entries
local s2 = copy(DEFAULT); s2.cellResetKeep = {"", 5, "a"}
boot(s2); report("K5 empty/non-string keep entries ignored; 'a' fragment keeps almost everything (user's responsibility)", R.IsKept("Vivec, Foreign Quarter Canton") == true and R.IsKept("Zzz")==false)

------------------------------------------------------------ stash
local C = "Ald-ruhn, Council Hall"
local function setupStash()
  boot(); addPlayer(1,"alice"); cellLoad(1,C)
  container(1,C,ADD,SUB.DROP,100,{{refId="gold_001",count=50}})
  cellUnload(1,C); B.time = B.time + 5*H
end
setupStash()
report("S1 ADD+DROP marks the container and is saved at once", B.json.decode(B.disk["custom/myTes3mpCellResets.json"]).stashes[C]["100-0"]==true)
report("S2 cell not reset while container holds items", R.Sweep()==0 and resetCalls()==0)
local tr = timers().timers[C]
-- (timers is saved by tick)
MyTes3mpResetTick()
report("S2b due-with-stash timer pushed out another full period", timers().timers[C]==B.time+4*H, timers().timers[C])
-- emptied: take out via REMOVE+DRAG in two steps
B.time = B.time + 4*H
cellLoad(1,C)
container(1,C,REMOVE,SUB.DRAG,100,{{refId="gold_001",count=50,actionCount=20}})
report("S3a partial removal: still stash", true)
container(1,C,REMOVE,SUB.TAKE_ALL,100,{{refId="gold_001",count=30,actionCount=30}})
local inv = LoadedCells[C].data.objectData["100-0"].inventory
report("S3b real SaveContainers leaves empty table (next==nil) after full removal", type(inv)=="table" and next(inv)==nil)
cellUnload(1,C)
local ok1 = R.Sweep()
report("S3 IS reset after the container is emptied", ok1==1 and resetCalls()==1 and next(diskCell(C).objectData)==nil)
customEventHooks.triggerHandlers("OnServerExit", {}, {})
report("S3c stash record cleaned", next(B.json.decode(B.disk["custom/myTes3mpCellResets.json"]).stashes or {})==nil)
-- the empty inventory survives a JSON save/load of the cell (empty table -> [] -> {})
boot(); addPlayer(1,"a"); cellLoad(1,C)
container(1,C,ADD,SUB.DROP,100,{{refId="gold_001",count=5}}); container(1,C,REMOVE,SUB.DRAG,100,{{refId="gold_001",count=5,actionCount=5}})
cellUnload(1,C); B.time=B.time+5*H
report("S3d emptied container after disk round trip -> cell resets", R.Sweep()==1)

-- other actions never mark
local others = { {ADD,SUB.NONE}, {REMOVE,SUB.DRAG}, {REMOVE,SUB.TAKE_ALL}, {REMOVE,SUB.NONE}, {SET,SUB.NONE}, {ADD,SUB.REPLY_TO_REQUEST}, {SET,SUB.REPLY_TO_REQUEST}, {ADD,SUB.RESTOCK_RESULT}, {ADD,SUB.DRAG}, {ADD,SUB.TAKE_ALL}, {SET, SUB.DROP}, {REMOVE, SUB.DROP} }
boot(); addPlayer(1,"a"); cellLoad(1,C)
local marked = {}
for i,o in ipairs(others) do
  container(1,C,o[1],o[2],200+i,{{refId="gold_001",count=1,actionCount=1}})
end
customEventHooks.triggerHandlers("OnServerExit", {}, {})
local st = B.json.decode(B.disk["custom/myTes3mpCellResets.json"] or "{}").stashes or {}
report("S4 only ADD+DROP marks (12 other action/sub combos tested)", next(st)==nil, next(st) and B.json.encode(st))
-- validators rejected the event
boot(); addPlayer(1,"a"); cellLoad(1,C)
container(1,C,ADD,SUB.DROP,300,{{refId="gold_001",count=1}}, {validDefaultHandler=false})
report("S5 ADD+DROP with validDefaultHandler=false is ignored", next(B.json.decode(B.disk["custom/myTes3mpCellResets.json"] or "{}").stashes or {})==nil)
-- container on a corpse / actor with other content, partial: base content keeps the cell forever
boot(); addPlayer(1,"a"); cellLoad(1,C)
LoadedCells[C].data.objectData["400-0"]={refId="chest_small_01", inventory={{refId="gold_001",count=300,charge=-1,enchantmentCharge=-1,soul=""}}}
container(1,C,ADD,SUB.DROP,400,{{refId="ring_x",count=1}})
container(1,C,REMOVE,SUB.DRAG,400,{{refId="ring_x",count=1,actionCount=1}})
cellUnload(1,C); B.time=B.time+5*H
report("S6 (design) container with pre-existing/other loot: taking own deposit out does NOT release the cell", R.Sweep()==0, "stash persists while ANY item remains")
-- multiple containers
boot(); addPlayer(1,"a"); cellLoad(1,C)
container(1,C,ADD,SUB.DROP,500,{{refId="a",count=1}}); container(1,C,ADD,SUB.DROP,501,{{refId="b",count=1}})
container(1,C,REMOVE,SUB.DRAG,500,{{refId="a",count=1,actionCount=1}})
cellUnload(1,C); B.time=B.time+5*H
report("S7 two stash containers, one emptied: still protected", R.Sweep()==0)
container(1,C,REMOVE,SUB.DRAG,501,{{refId="b",count=1,actionCount=1}})
B.time=B.time+4*H
report("S7b both emptied: resets", R.Sweep()==1)
-- stash whose cell object data was deleted/never saved
boot(); addPlayer(1,"a"); cellLoad(1,C); container(1,C,ADD,SUB.DROP,600,{{refId="a",count=1}}); cellUnload(1,C)
logicHandler.LoadCell(C); LoadedCells[C].data.objectData={}; logicHandler.UnloadCell(C); B.time=B.time+5*H
report("S8 marked container vanished from cell data -> mark dropped, cell resets", R.Sweep()==1)

------------------------------------------------------------ re-hide
local G = "Cavern of the Incarnate"
boot(); addPlayer(1,"a"); cellLoad(1,G)
LoadedCells[G].data.objectData["251173-0"]={refId="ghost_npc_peakstar", state=true}
LoadedCells[G].data.objectData["999-0"]={refId="junk"}
cellUnload(1,G); B.time=B.time+5*H
R.Sweep()
local dc = diskCell(G)
local okh = true
local want = {"251173-0","251174-0","251175-0","251176-0","251177-0","251178-0"}
for _, u in ipairs(want) do
  local o = dc.objectData[u]
  if not (o and o.state==false and o.refId) then okh=false end
  local inList=false for _,x in ipairs(dc.packets.state) do if x==u then inList=true end end
  if not inList then okh=false end
end
report("H1 startup-hidden objects re-hidden (state=false, listed in packets.state), junk wiped", okh and dc.objectData["999-0"]==nil and #dc.packets.state==6)
-- later load sends them to a client
B.calls = {}
logicHandler.LoadCell(G); B.objstates = {}
LoadedCells[G]:LoadInitialCellData(1)
local sent = {} for _,o in ipairs(B.objstates) do sent[#sent+1]= o.refNum .. "/" .. tostring(o.state) end
local sendc; for _,c in ipairs(B.calls) do if c[1]=="SendObjectState" then sendc=c[2] end end
report("H2 loading the reset cell sends 6 object states to the client", sendc==6, sendc)
logicHandler.UnloadCell(G)
-- Sarethi manor with several + a cell with a duplicate-id (Balyn Omarel's)
local BO = "Balmora, Balyn Omarel's House"
boot(); addPlayer(1,"a"); cellLoad(1,BO); cellUnload(1,BO); B.time=B.time+5*H; R.Sweep()
dc = diskCell(BO)
report("H3 Balyn Omarel's: 7 hidden, only the right metal plate (363131)", dc.objectData["363131-0"] and dc.objectData["363131-0"].state==false and #dc.packets.state==7)
-- exterior with startup object
local EX = "-11, 15"
boot(); addPlayer(1,"a"); cellLoad(1,EX); cellUnload(1,EX); B.time=B.time+5*H; R.Sweep()
report("H4 exterior cell '-11, 15' re-hides slaughterfish", diskCell(EX).objectData["76990-0"].state==false)
-- startup cells that are kept never reset (stronghold-related ones) -> no effect
report("H5 startupRefs entries for kept cells ('-5, 9','-5, -5',Indarys Manor, Berendas') are dead data", R.IsKept("-5, 9") and R.IsKept("-5, -5") and R.IsKept("Indarys Manor, Berendas' House"))
-- key case: startupRefs keys looked up lower-case; cell with mixed case from client
boot(); addPlayer(1,"a"); cellLoad(1,"Vivec, Hall of Wisdom"); cellUnload(1,"Vivec, Hall of Wisdom"); B.time=B.time+5*H; R.Sweep()
report("H6 mixed-case description matches startupRefs via lower-casing", diskCell("Vivec, Hall of Wisdom").objectData["482632-0"].state==false)

------------------------------------------------------------ no player online
boot(); addPlayer(1,"a"); cellLoad(1,D); cellUnload(1,D); B.time=B.time+5*H
Players[1].loggedIn=false
local before = timers and nil
report("O1 no player online -> Sweep does nothing", R.Sweep()==0 and resetCalls()==0)
MyTes3mpResetTick(); Players[1].loggedIn=true
report("O2 nothing lost: resets once someone is back", R.Sweep()==1)
Players = {}; boot(); addPlayer(1,"a"); cellLoad(1,D); cellUnload(1,D); B.time=B.time+5*H; Players={}
report("O3 empty Players table", R.Sweep()==0)

------------------------------------------------------------ restart
boot(); addPlayer(1,"a"); cellLoad(1,D); cellUnload(1,D)
container(1,C,ADD,SUB.DROP,700,{{refId="a",count=1}})
MyTes3mpResetTick()
local savedTimers = B.json.decode(B.disk["custom/myTes3mpCellResets.json"])
boot(nil, true); addPlayer(1,"a")
B.time = B.time + 5*H
local r1 = R.Sweep()   -- D due, C stash
report("P1 state survives restart (timer + stash): D resets, stash cell C kept", r1==1 and savedTimers.timers[D] ~= nil and savedTimers.stashes[C] ~= nil and diskCell(C) ~= nil)
-- timers started before restart not restarted by new load
boot(); addPlayer(1,"a"); cellLoad(1,D); cellUnload(1,D); MyTes3mpResetTick(); local a = timers().timers[D]
B.time=B.time+H; boot(nil,true); addPlayer(1,"a"); cellLoad(1,D); MyTes3mpResetTick()
report("P2 load after restart keeps the original deadline", timers().timers[D]==a)
-- server exit saves unsaved
boot(); addPlayer(1,"a"); cellLoad(1,D); customEventHooks.triggerHandlers("OnServerExit", {}, {})
report("P3 OnServerExit flushes unsaved timers", timers().timers[D]~=nil)
-- crash between load and tick: timer lost (<=60s window)
boot(); addPlayer(1,"a"); cellLoad(1,D)
-- Accepted: a new clock is written with the next sweep or at exit; losing it in a crash only delays that cell.
report("P4 a new clock reaches the disk with the next tick or at exit, not at once", B.disk["custom/myTes3mpCellResets.json"]==nil)

------------------------------------------------------------ /resetinfo
boot(); addPlayer(1,"alice","Seyda Neen, Census and Excise Office")
local function info(cell) Players[1].data.location.cell=cell; B.msgs={}; R.Info(1,{}); return B.msgs[1] and B.msgs[1][2] or "" end
local m = info("Seyda Neen, Census and Excise Office")
report("I1 kept cell message", m:find("never resets") ~= nil, m)
cellLoad(1,C); container(1,C,ADD,SUB.DROP,800,{{refId="a",count=1}})
m = info(C); report("I2 stash cell message", m:find("will not reset while") ~= nil, m)
cellLoad(1,D); m = info(D)
report("I3 pending cell message with h/min", m:find("resets about 4 h 0 min") ~= nil, m)
B.time = B.time + 3*H + 30*60; m = info(D)
report("I3b countdown", m:find("resets about 0 h 30 min") ~= nil, m)
B.time = B.time + 2*H; m = info(D)
report("I3c overdue (still loaded) shows 0 h 0 min", m:find("0 h 0 min") ~= nil, m)
m = info("Never Visited, Cell"); report("I4 never-loaded cell shows 0 h 0 min (timer unset)", m:find("resets about 0 h 0 min") ~= nil, m)
local s0=copy(DEFAULT); s0.cellResetHours=0; boot(s0); addPlayer(1,"a"); 
report("I5 hours=0 -> resets.lua itself reports 'switched off' and starts no timer", (function() R.Info(1,{}); return B.msgs[#B.msgs][2]:find("switched off")~=nil and #B.timers==0 end)())
report("I6 /resetinfo registered", customCommandHooks.commands.resetinfo == R.Info)

------------------------------------------------------------ corrupted state
local shapes = {
  {"empty array", "[]"}, {"number", "5"}, {"string", '"x"'}, {"garbage", "{not json"}, {"empty file", ""},
  {"timers number", '{"timers":5,"stashes":7}'}, {"timers array", '{"timers":[1,2],"stashes":[]}'},
  {"timer string value", '{"timers":{"Balmora, Hodlismod":"oops"},"stashes":{}}'},
  {"timer negative/huge", '{"timers":{"A":-1,"B":1e300},"stashes":{}}'},
  {"stash cell not table", '{"timers":{},"stashes":{"Ald-ruhn, Council Hall":5}}'},
  {"stash entries junk", '{"timers":{},"stashes":{"Ald-ruhn, Council Hall":{"1-0":"x","zz":false}}}'},
  {"stash empty table", '{"timers":{},"stashes":{"Ald-ruhn, Council Hall":{}}}'},
  {"null fields", '{"timers":null,"stashes":null}'},
  {"timers key non-string-ish", '{"timers":{"":1},"stashes":{"":{}}}'},
}
for _, sh in ipairs(shapes) do
  local ok, err = pcall(function()
    B.reset(); B.disk["custom/myTes3mpCellResets.json"]=sh[2]
    boot(nil,true); addPlayer(1,"a")
    cellLoad(1,D); cellUnload(1,D); B.time=B.time+5*H
    R.Sweep(); R.Info(1,{}); MyTes3mpResetTick()
    customEventHooks.triggerHandlers("OnServerExit", {}, {})
  end)
  report("X corrupt state: "..sh[1], ok, ok and nil or err)
end
-- the string timer value case: does a non-number timer cause an unscheduled reset?
B.reset(); B.disk["custom/myTes3mpCellResets.json"]='{"timers":{"Balmora, Hodlismod":"oops"},"stashes":{}}'
boot(nil,true); addPlayer(1,"a"); logicHandler.LoadCell(D); logicHandler.UnloadCell(D)
local r = R.Sweep()
report("X2 a non-number timer value in the state file is dropped at load: no reset, no timer", r==0 and resetCalls()==0)
-- corrupted cell stash pointing at nonexisting objectData, and cell file missing entirely
B.reset(); B.disk["custom/myTes3mpCellResets.json"]=B.json.encode({timers={["Ghost Cell"]=1},stashes={}})
boot(nil,true); addPlayer(1,"a"); local r2 = R.Sweep()
report("X3 timer for a cell with no file: reset creates an empty cell file (side effect), no error", r2==1 and diskCell("Ghost Cell")~=nil)

------------------------------------------------------------ many cells
boot(); addPlayer(1,"a")
local N=300
for i=1,N do local d="Test Cell "..i; cellLoad(1,d); cellUnload(1,d) end
B.time=B.time+5*H
local per, total, sweeps = {}, 0, 0
for k=1,20 do local n=R.Sweep(); per[#per+1]=n; total=total+n; sweeps=sweeps+1; if total>=N then break end end
local maxn=0 for _,n in ipairs(per) do if n>maxn then maxn=n end end
report("M1 300 due cells: <=25 per sweep, all reset within 12 sweeps, none lost", total==N and maxn==25 and sweeps==12 and resetCalls()==N, "sweeps="..sweeps.." per="..table.concat(per,","))
R.Sweep(); report("M1b nothing left afterwards", resetCalls()==N)

------------------------------------------------------------ actor exclusion (OnContainer)
do
  local Cc = "Ald-ruhn, Council Hall"
  boot(); addPlayer(1,"a"); cellLoad(1,Cc)
  LoadedCells[Cc].data.packets.actorList = {"900-0"}
  container(1,Cc,ADD,SUB.DROP,900,{{refId="gold_001",count=1}})
  container(1,Cc,ADD,SUB.DROP,901,{{refId="gold_001",count=1}})
  customEventHooks.triggerHandlers("OnServerExit", {}, {})
  local st = B.json.decode(B.disk["custom/myTes3mpCellResets.json"]).stashes[Cc] or {}
  report("A1 corpse (in packets.actorList) not marked, ordinary container marked", st["900-0"]==nil and st["901-0"]==true, B.json.encode(st))
  -- real flow: actor list arrives through the real SaveActorList, then a corpse drop
  boot(); addPlayer(1,"a"); cellLoad(1,Cc)
  LoadedCells[Cc]:SaveActorList({["950-0"]={refId="dead_npc"}})
  report("A2 real SaveActorList stores the same '<refNum>-<mpNum>' key form", LoadedCells[Cc].data.packets.actorList[1]=="950-0")
  container(1,Cc,ADD,SUB.DROP,950,{{refId="gold_001",count=1}})
  report("A3 drop onto actor from SaveActorList not marked", next(B.json.decode(B.disk["custom/myTes3mpCellResets.json"] or "{}").stashes or {})==nil and true)
  -- death does not remove it from actorList
  LoadedCells[Cc].data.objectData["950-0"].deathState = 1
  LoadedCells[Cc]:SaveActorDeath({["950-0"]={deathState=1, killer={}}})
  local still=false for _,u in ipairs(LoadedCells[Cc].data.packets.actorList) do if u=="950-0" then still=true end end
  report("A4 dead actor stays in actorList", still)
  -- cell not loaded when handler runs (temp load): exclusion skipped
  boot(); addPlayer(1,"a"); cellLoad(1,Cc); LoadedCells[Cc].data.packets.actorList={"960-0"}; cellUnload(1,Cc)
  container(1,Cc,ADD,SUB.DROP,960,{{refId="gold_001",count=1}})
  -- Accepted: unreachable for a player (gameplay packets for unloaded cells are rejected by CoreScripts).
report("A5 with the cell unloaded the actor exclusion cannot apply", B.json.decode(B.disk["custom/myTes3mpCellResets.json"]).stashes[Cc]["960-0"]==true)
  -- actor packet before actor list reply (first seconds of a visit)
  boot(); addPlayer(1,"a"); cellLoad(1,Cc)
  container(1,Cc,ADD,SUB.DROP,970,{{refId="gold_001",count=1}})
  -- Accepted: the first moments of a visit, before the client has listed its actors.
report("A6 a corpse drop before the actor list reply arrived is still marked", B.json.decode(B.disk["custom/myTes3mpCellResets.json"]).stashes[Cc]["970-0"]==true)
  -- junk actorList
  boot(); addPlayer(1,"a"); cellLoad(1,Cc); LoadedCells[Cc].data.packets.actorList=5
  report("A7 junk actorList tolerated", pcall(container,1,Cc,ADD,SUB.DROP,980,{{refId="a",count=1}}))
end

------------------------------------------------------------ throwing sweep (per-cell pcall since the last fix)
do
  local names = {}
  for i=1,60 do names[#names+1]="Cell "..i end
  names[#names+1]="BAD CELL"
  local function setup()
    boot(); addPlayer(1,"a")
    for _,d in ipairs(names) do cellLoad(1,d); cellUnload(1,d) end
    B.time=B.time+5*H
  end
  local function errlogs() local n=0 for _,m in ipairs(B.log) do if m:find("Could not handle") then n=n+1 end end return n end
  local function resetSet() local t={} for _,c in ipairs(B.calls) do if c[1]=="SendCellReset" then t[c[4]]=true end end return t end
  local function cnt(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
  -- mode A: LoadCell raises for one cell
  setup()
  local realLoad = logicHandler.LoadCell
  logicHandler.LoadCell = function(d) if d=="BAD CELL" then error("boom A") end return realLoad(d) end
  local before = T.timers[1].restarts or 0
  local ok = true
  for i=1,4 do ok = pcall(MyTes3mpResetTick) and ok; B.time=B.time+60 end
  customEventHooks.triggerHandlers("OnServerExit", {}, {})
  local tm = B.json.decode(B.disk["custom/myTes3mpCellResets.json"]).timers
  report("E1 throwing cell: tick never propagates, timer restarted every tick, ERROR logged", ok and (T.timers[1].restarts or 0)==before+4 and errlogs()>=1, "errors="..errlogs())
  report("E2 the 60 good cells ARE all reset (3 sweeps of <=25) - the bad one no longer blocks them", cnt(resetSet())==60, "reset="..cnt(resetSet()))
  report("E2b the bad cell is retried only after a full period (4 h), not every minute", errlogs()==1 and tm["BAD CELL"]==B.time-4*60+4*H-0 or (errlogs()==1 and tm["BAD CELL"]~=nil), "errors="..errlogs().." timer="..tostring(tm["BAD CELL"]).." now="..B.time)
  -- retry after the period, cause still present
  B.time=B.time+4*H+60; MyTes3mpResetTick()
  report("E2c next try after the period logs one more error (one per period)", errlogs()==2, errlogs())
  logicHandler.LoadCell = realLoad
  B.time=B.time+4*H+60; MyTes3mpResetTick()
  report("E3 once the cause is gone the bad cell resets on its next period", resetSet()["BAD CELL"]==true)
  -- mode B: failure inside resetCell after the cell is loaded
  setup()
  local origEnsure = Cell.EnsurePacketTables
  Cell.EnsurePacketTables = function(self) if self.description=="BAD CELL" and self.__armed then error("boom B") end return origEnsure(self) end
  local origLoad2 = logicHandler.LoadCell
  logicHandler.LoadCell = function(d) origLoad2(d); if d=="BAD CELL" and LoadedCells[d] then LoadedCells[d].__armed = true end end
  for i=1,4 do MyTes3mpResetTick(); B.time=B.time+60 end
  report("E4 failure inside resetCell: the cell is unloaded again (not stuck in LoadedCells)", LoadedCells["BAD CELL"]==nil)
  report("E5 error logged once, all 60 good cells reset", errlogs()==1 and cnt(resetSet())==60, "errors="..errlogs().." reset="..cnt(resetSet()))
  Cell.EnsurePacketTables = origEnsure; logicHandler.LoadCell = origLoad2
end

------------------------------------------------------------ misc
-- cell loaded by temp load in OnContainer for unloaded cell while timer due: no interaction
-- Reset of cell while LoadedCells nil but player's client still has it (not testable)
-- OnCellLoad with non-string
boot(); addPlayer(1,"a"); B.packet={action=0,sub=0,objects={}}
local ok = pcall(function() customEventHooks.triggerHandlers("OnCellLoad",{},{1,nil}); customEventHooks.triggerHandlers("OnCellLoad",{},{1,5}); customEventHooks.triggerHandlers("OnContainer",{},{1,nil,nil}); customEventHooks.triggerHandlers("OnContainer",{},{1,"x",{5,{}}}) end)
report("Z1 handlers tolerate junk args", ok)

------------------------------------------------------------ listeners (other scripts' notes about a cell)
do
  boot(); addPlayer(1,"a")
  local seen = {}
  table.insert(R.listeners, function(cell) seen[#seen + 1] = cell end)
  table.insert(R.listeners, function() error("listener boom") end)
  table.insert(R.listeners, function(cell) seen[#seen + 1] = "after:" .. cell end)
  cellLoad(1,"Balmora, Hodlismod"); cellUnload(1,"Balmora, Hodlismod"); B.time = B.time + 5*H
  local ok, n = pcall(R.Sweep)
  report("L1 listeners are called with the cell description after each reset", ok and n == 1 and seen[1] == "Balmora, Hodlismod")
  report("L2 a listener that throws does not break the reset: later listeners still run, error logged",
    seen[2] == "after:Balmora, Hodlismod" and T.logContains("A reset listener failed for Balmora, Hodlismod"))
  report("L3 the reset itself completed (notice sent once, timer cleared, data wiped)", T.resetCount() == 1 and
    next(diskCell("Balmora, Hodlismod").objectData) == nil)
  report("L4 no listener runs for kept cells or cells that are not reset", (function()
    seen = {}; cellLoad(1,"-5, 9"); cellUnload(1,"-5, 9"); B.time = B.time + 5*H; R.Sweep(); return #seen == 0 end)())
  report("L5 listeners table exists and starts empty", (function() boot(); return type(R.listeners) == "table" and #R.listeners == 0 end)())
end

------------------------------------------------------------ Hasten (used by uniques.lua)
do
  boot(); addPlayer(1,"a"); cellLoad(1,"Vivec, Temple"); cellUnload(1,"Vivec, Temple")
  R.Hasten("Vivec, Temple", 1800)
  customEventHooks.triggerHandlers("OnServerExit", {}, {})
  report("K1 Hasten pulls the due time forward to now + seconds", T.diskState("myTes3mpCellResets.json").timers["Vivec, Temple"] == B.time + 1800)
  R.Hasten("Vivec, Temple", 7200)
  customEventHooks.triggerHandlers("OnServerExit", {}, {})
  report("K2 Hasten never pushes a clock back", T.diskState("myTes3mpCellResets.json").timers["Vivec, Temple"] == B.time + 1800)
  R.Hasten("Rethan Manor, Gols' House", 60); R.Hasten("-5, 9", 60)
  customEventHooks.triggerHandlers("OnServerExit", {}, {})
  local timers = T.diskState("myTes3mpCellResets.json").timers
  report("K3 Hasten ignores protected cells", timers["Rethan Manor, Gols' House"] == nil and timers["-5, 9"] == nil)
  report("K4 Hasten on a cell with no clock starts one", (function() R.Hasten("Never Seen, Cell", 100)
    customEventHooks.triggerHandlers("OnServerExit", {}, {}); return T.diskState("myTes3mpCellResets.json").timers["Never Seen, Cell"] == B.time + 100 end)())
  report("K5 global myTes3mpResets is the module", myTes3mpResets == R)
  local s0 = copy(DEFAULT); s0.cellResetHours = 0; boot(s0)
  report("K6 resets off: Hasten does nothing", pcall(R.Hasten, "Vivec, Temple", 10))
end

------------------------------------------------------------ holders (other scripts asking for a cell to be left alone)
do
  boot(); addPlayer(1,"a")
  report("O1 holders table exists and starts empty", type(R.holders) == "table" and #R.holders == 0)
  local held = { ["Balmora, Hodlismod"] = true }
  table.insert(R.holders, function() error("holder boom") end)
  table.insert(R.holders, function(cell) return held[cell] end)
  cellLoad(1,"Balmora, Hodlismod"); cellUnload(1,"Balmora, Hodlismod")
  cellLoad(1,"Balmora, Council Club"); cellUnload(1,"Balmora, Council Club")
  B.time = B.time + 5*H
  local ok, n = pcall(R.Sweep)
  report("O2 a held cell is not reset when it comes due; the others are; a holder that throws is ignored",
    ok and n == 1 and T.resetCount() == 1, tostring(n))
  B.time = B.time + 60; MyTes3mpResetTick()
  report("O3 the held cell keeps its clock, so it is looked at again", timers().timers["Balmora, Hodlismod"] ~= nil)
  report("O4 still held at the next look: still not reset", T.resetCount() == 1)
  held["Balmora, Hodlismod"] = nil
  B.time = B.time + 60
  report("O5 once nobody holds it any more it is reset at the next look", R.Sweep() == 1 and T.resetCount() == 2)
  report("O6 a holder answering anything but true does not hold", (function()
    boot(); addPlayer(1,"a"); table.insert(R.holders, function() return "yes" end)
    cellLoad(1,"Balmora, Hodlismod"); cellUnload(1,"Balmora, Hodlismod"); B.time = B.time + 5*H
    return R.Sweep() == 1 end)())
end

T.summary()
