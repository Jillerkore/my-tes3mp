-- strongholds.lua: waiting on the Great House stronghold timers on the server.
--
-- The "client" is simulated here: a `Journal X N` command comes back as a
-- PlayerJournal packet for that player, a `set Stronghold to N` as a
-- ClientScriptGlobal packet, each followed by the handlers - in the order
-- eventHandler.lua raises them (default handler saves first).
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report

local H -- state of the current scenario

local function newWorld(opts)
  opts = opts or {}
  T.fresh()
  config.shareJournal = opts.shareJournal or false
  WorldInstance.data.clientVariables = opts.clientVariables
  T.worldSaves = 0
  H = { sent = {}, pending = {}, auto = true }
  logicHandler.RunConsoleCommandOnPlayer = function(pid, cmd)
    assert(Players[pid], "command to nonexistent player")
    H.sent[#H.sent + 1] = { pid = pid, cmd = cmd, day = WorldInstance.data.time.daysPassed }
    table.insert(Players[pid].consoleCommandsQueued, cmd)
    H.pending[#H.pending + 1] = { pid = pid, cmd = cmd }
  end
  H.S = T.load("strongholds")
  T.postInit()
end

local function addPlayer(pid, name, loggedIn)
  local p = T.player(pid, name, { loggedIn = loggedIn ~= false })
  p.consoleCommandsQueued = {}
  return p
end
local function savesCount()
  local n = 0
  for _, p in pairs(Players) do for _, c in ipairs(p.calls) do if c == "save" then n = n + 1 end end end
  return n
end

local function logout(pid) Players[pid].loggedIn = false end

-- client -> server packets, following eventHandler.lua ordering: default save, then handlers
local function journalPacket(pid, quest, index)
  if Players[pid] == nil or not Players[pid]:IsLoggedIn() then return end
  local packet = { journal = { { type = 0, index = index, quest = quest:lower(), actorRefId = "x",
     timestamp = {daysPassed = WorldInstance.data.time.daysPassed} } } }
  local target = (config.shareJournal == true) and WorldInstance.data or Players[pid].data
  target.journal = target.journal or {}
  for _, it in ipairs(packet.journal) do table.insert(target.journal, it) end
  customEventHooks.triggerHandlers("OnPlayerJournal", {validDefaultHandler=true}, {pid, packet})
end

local function globalPacket(pid, id, value)
  if Players[pid] == nil or not Players[pid]:IsLoggedIn() then return end
  local variables = { [id] = { variableType = 0, intValue = value } }
  local cv = WorldInstance.data.clientVariables
  if cv == nil then cv = {}; WorldInstance.data.clientVariables = cv end
  cv.globals = cv.globals or {}
  cv.globals[id] = variables[id]
  customEventHooks.triggerHandlers("OnClientScriptGlobal", {validDefaultHandler=true}, {pid, variables})
end

local function deliver(item)
  local pid, cmd = item.pid, item.cmd
  if Players[pid] == nil or not Players[pid]:IsLoggedIn() then return end
  local q, i = cmd:match("^Journal (%S+) (%d+)$")
  if q then return journalPacket(pid, q, tonumber(i)) end
  local v = cmd:match("^set Stronghold to (%d+)$")
  if v then
    H.worldWrites = H.worldWrites or {}
    table.insert(H.worldWrites, tonumber(v))
    return globalPacket(pid, "stronghold", tonumber(v))
  end
  error("unknown command " .. cmd)
end

local function settle()
  local guard = 0
  while #H.pending > 0 do
    guard = guard + 1; assert(guard < 500, "command storm")
    deliver(table.remove(H.pending, 1))
  end
end

local function tick() T.time = T.time + 60; MyTes3mpStrongholdTick(); if H.auto then settle() end end
local function setDay(d) WorldInstance.data.time.daysPassed = d end
local function stage()
  local cv = WorldInstance.data.clientVariables
  return cv and cv.globals and cv.globals.stronghold and cv.globals.stronghold.intValue or 0
end
local function idx(pid, quest)
  local hi
  local j = (config.shareJournal and WorldInstance.data.journal) or Players[pid].data.journal
  for _, it in ipairs(j) do if it.quest == quest:lower() and (hi == nil or it.index > hi) then hi = it.index end end
  return hi
end
local function count(pid, quest, index)
  local n = 0
  local j = (config.shareJournal and WorldInstance.data.journal) or Players[pid].data.journal
  for _, it in ipairs(j) do if it.quest == quest:lower() and it.index == index then n = n + 1 end end
  return n
end
local function cmds() local t = {} for _, s in ipairs(H.sent) do t[#t+1] = s.pid .. ":" .. s.cmd end return table.concat(t, " | ") end

---------------------------------------------------------------- (a)
do
  newWorld(); addPlayer(1, "alice")
  local ok, why = true, nil
  local function chk(c, m) if not c and ok then ok = false; why = m end end
  local plan = { {50,55,1},{90,100,2},{170,200,4},{270,300,6} }
  local day = 1
  for _, st in ipairs(plan) do
    journalPacket(1, "HH_Stronghold", st[1]); settle()
    local start = WorldInstance.data.time.daysPassed
    chk(idx(1, "HH_Stronghold") == st[1], "nothing instant at "..st[1])
    for d = 1, 4 do setDay(start + d); tick(); chk(idx(1,"HH_Stronghold") == st[1] and stage() < st[3], "early grant on day +"..d.." stage "..st[1]) end
    setDay(start + 5); tick()
    chk(idx(1,"HH_Stronghold") == st[2], "no grant at day +5 for "..st[1].." idx="..tostring(idx(1,"HH_Stronghold")))
    chk(stage() == st[3], "stage "..stage().." want "..st[3])
    chk(H.sent and true, "") ; chk(count(1,"HH_Stronghold",st[2]) >= 1, "missing")
    tick(); tick()
    chk(count(1,"HH_Stronghold",st[2]) == 1, "dup after extra ticks")
    chk(Players[1].data.customVariables.myTes3mpStrongholds.hh_stronghold == nil, "note not cleared"); chk(count(1,"HH_Stronghold",st[2])==1,"dup entries")
  end
  report("a solo Hlaalu 50->300, day4 no / day5 yes", ok, why)
  for _, q in ipairs{"HR_Stronghold","HT_Stronghold"} do
    newWorld(); addPlayer(1,"a"); local o2=true
    for _, st in ipairs(plan) do
      journalPacket(1,q,st[1]); settle(); local s=WorldInstance.data.time.daysPassed
      setDay(s+4); tick(); if idx(1,q)~=st[1] then o2=false end
      setDay(s+5); tick(); if idx(1,q)~=st[2] or stage()~=st[3] then o2=false end
    end
    report("a' solo "..q, o2)
  end
end

---------------------------------------------------------------- (b)
do
  newWorld(); addPlayer(1,"alice"); addPlayer(2,"bob")
  -- alice builds fully
  for _, st in ipairs({{50,55,1},{90,100,2},{170,200,4},{270,300,6}}) do
    journalPacket(1,"HH_Stronghold",st[1]); settle(); setDay(WorldInstance.data.time.daysPassed+5); tick()
  end
  local ok, why = (stage()==6), nil
  local writes0 = H.worldWrites and #H.worldWrites or 0
  for _, st in ipairs({{50,55},{90,100},{170,200},{270,300}}) do
    journalPacket(2,"HR_Stronghold",st[1]); settle()
    if idx(2,"HR_Stronghold") ~= st[2] then ok=false; why="bob stuck at "..tostring(idx(2,"HR_Stronghold")).." after "..st[1] end
  end
  if stage()~=6 then ok=false; why="stage changed" end
  if (H.worldWrites and #H.worldWrites or 0) ~= writes0 then ok=false; why="extra world writes" end
  report("b later player gets entries immediately, no stage change", ok, why)
end

---------------------------------------------------------------- (c)
do
  newWorld(); addPlayer(1,"a"); addPlayer(2,"b")
  local ok, why = true, nil
  local last = 0
  local function watch() if stage() < last then ok=false; why="stage decreased "..last.."->"..stage() end; last = stage() end
  -- A: Hlaalu. B: Redoran, offset by 3 days and different pace.
  journalPacket(1,"HH_Stronghold",50); settle()
  setDay(4); journalPacket(2,"HR_Stronghold",50); settle()
  for d = 5, 60 do
    setDay(d); tick(); watch()
    for _, p in ipairs{ {1,"HH_Stronghold"},{2,"HR_Stronghold"} } do
      local i = idx(p[1],p[2])
      -- player advances through dialogue some days after each grant: 55->70->90 etc
      if i == 55 and (d % 3 == 0) then journalPacket(p[1],p[2],90); settle() end
      if i == 100 and (d % 2 == 0) then journalPacket(p[1],p[2],170); settle() end
      if i == 200 and (d % 4 == 0) then journalPacket(p[1],p[2],270); settle() end
    end
    watch()
  end
  if idx(1,"HH_Stronghold")~=300 or idx(2,"HR_Stronghold")~=300 then ok=false; why=(why or "").." stuck: "..tostring(idx(1,"HH_Stronghold"))..","..tostring(idx(2,"HR_Stronghold")) end
  if stage()~=6 then ok=false; why=(why or "").." final stage "..stage() end
  report("c two concurrent builders, monotonic world stage, both finish", ok, why)
end

---------------------------------------------------------------- (d)
do
  newWorld(); local p = addPlayer(1,"a")
  journalPacket(1,"HT_Stronghold",90); settle()
  setDay(3); tick(); logout(1)
  -- simulate server saving/reloading data: serialize customVariables only
  local saved = p.data.customVariables.myTes3mpStrongholds
  setDay(10); tick() -- nobody online: no cmds
  local before = #H.sent
  Players[1] = nil
  local p2 = addPlayer(1,"a"); p2.data.journal = p.data.journal; p2.data.customVariables = { myTes3mpStrongholds = saved }
  local n = #H.sent
  tick()
  local ok = (before==n) and idx(1,"HT_Stronghold")==100 and stage()==2
  report("d logout mid-wait, login days later -> granted on next tick", ok, ok and nil or cmds())
  -- and: note lost (e.g. brand new install on existing world): counts from login day
  newWorld(); addPlayer(1,"a"); Players[1].data.journal = {{quest="ht_stronghold",index=90}}
  setDay(50); tick(); local i1 = idx(1,"HT_Stronghold"); setDay(55); tick()
  report("d' no note: wait restarts from first sight (day 50 -> grant day 55)", i1==90 and idx(1,"HT_Stronghold")==100)
  -- not-logged-in player with stale note during a tick
end

---------------------------------------------------------------- (e)
do
  newWorld(); addPlayer(1,"a")
  journalPacket(1,"HH_Stronghold",50); settle()
  setDay(3); tick()
  -- game's own timer fires on the client: Journal 55 then set Stronghold 1 (sends in this order)
  journalPacket(1,"HH_Stronghold",55); settle()
  local noteGone = Players[1].data.customVariables.myTes3mpStrongholds.hh_stronghold == nil
  globalPacket(1,"stronghold",1)
  setDay(6); tick(); setDay(9); tick()
  report("e game timer wins: helper silent, note cleared", #H.sent==0 and noteGone and count(1,"HH_Stronghold",55)==1, cmds())
end

---------------------------------------------------------------- (f)
do
  newWorld(); addPlayer(1,"a"); H.auto = false
  journalPacket(1,"HH_Stronghold",50)
  setDay(6); tick(); tick(); tick()
  local n = #H.sent
  report("f in-flight: no resend while the answer is awaited (3 ticks send one set + one Journal)", n==2, "sent "..n..": "..cmds())
  -- queue growth
  report("f' consoleCommandsQueued growth", #Players[1].consoleCommandsQueued==2, "queue len "..#Players[1].consoleCommandsQueued)
  -- now client answers all stale copies: how many journal entries / writes
  settle()
  report("f'' after delayed replies, duplicate entries", count(1,"HH_Stronghold",55)==1, "55 entries: "..count(1,"HH_Stronghold",55))
end

---------------------------------------------------------------- (g)
do
  newWorld(); addPlayer(1,"a",false); addPlayer(2,"b"); Players[1].data.journal={{quest="hh_stronghold",index=50}}
  setDay(10)
  local ok = pcall(tick)
  report("g logged-out player skipped, no error", ok and #H.sent==0 and next(Players[1].data.customVariables)==nil, cmds())
  -- Players[pid] present but table lacks data fields
  local ok2 = pcall(function() Players[3]=nil; H.S.Check(99) end)
  report("g unknown pid Check", ok2)
end

---------------------------------------------------------------- (h)
do
  newWorld{shareJournal=true}; addPlayer(1,"a"); addPlayer(2,"b"); addPlayer(3,"c")
  journalPacket(1,"HH_Stronghold",50); settle()
  setDay(6); tick()
  local ok = idx(1,"HH_Stronghold")==55 and stage()==1
  report("h shared: quest progresses", ok, cmds())
  local tgt={} for _,x in ipairs(H.sent) do tgt[x.pid]=true end local nt=0 for _ in pairs(tgt) do nt=nt+1 end
  report("h shared: all commands to exactly one player", nt==1 and #H.sent==2, "sent "..#H.sent..": "..cmds())
  report("h shared: no duplicate journal entries", count(1,"HH_Stronghold",55)==1, "55 entries: "..count(1,"HH_Stronghold",55))
  report("h shared: note stored in world, not players", WorldInstance.data.customVariables.myTes3mpStrongholds ~= nil and (Players[1].data.customVariables.myTes3mpStrongholds==nil) and (T.worldSaves or 0)>=1)
  -- late login in shared mode
  newWorld{shareJournal=true}; addPlayer(1,"a"); journalPacket(1,"HH_Stronghold",50); settle(); setDay(4); tick(); addPlayer(2,"b"); setDay(6); tick()
  report("h' shared, late joiner doesn't delay owner", idx(1,"HH_Stronghold")==55)
end

---------------------------------------------------------------- (i)
do
  local cases = {
    {"clientVariables nil", function() newWorld(); addPlayer(1,"a"); Players[1].data.journal={{quest="hh_stronghold",index=50}}; setDay(6) end},
    {"globals not table", function() newWorld{clientVariables={globals=5}}; addPlayer(1,"a"); setDay(6) end},
    {"globals value not table", function() newWorld{clientVariables={globals={stronghold=3}}}; addPlayer(1,"a") end},
    {"globals mixed case id", function() newWorld{clientVariables={globals={Stronghold={variableType=0,intValue=2}}}}; addPlayer(1,"a"); Players[1].data.journal={{quest="HH_Stronghold",index=50}} end},
    {"journal nil", function() newWorld(); addPlayer(1,"a"); Players[1].data.journal=nil end},
    {"journal junk items", function() newWorld(); addPlayer(1,"a"); Players[1].data.journal={5,"x",{},{quest=5,index="a"},{quest="hh_stronghold"},{quest="hh_stronghold",index="50"},{quest="hh_stronghold",index=50.0}} end},
    {"customVariables nil", function() newWorld(); addPlayer(1,"a"); Players[1].data.customVariables=nil; Players[1].data.journal={{quest="hh_stronghold",index=50}} end},
    {"world journal nil share", function() newWorld{shareJournal=true}; addPlayer(1,"a"); WorldInstance.data.journal=nil end},
    {"intValue missing", function() newWorld{clientVariables={globals={stronghold={}}}}; addPlayer(1,"a"); Players[1].data.journal={{quest="hh_stronghold",index=50}} end},
    {"daysPassed nil", function() newWorld(); WorldInstance.data.time.daysPassed=nil; addPlayer(1,"a"); Players[1].data.journal={{quest="hh_stronghold",index=50}} end},
    {"notes corrupt (non-table)", function() newWorld(); addPlayer(1,"a"); Players[1].data.journal={{quest="hh_stronghold",index=50}}; Players[1].data.customVariables.myTes3mpStrongholds="bad" end},
    {"note entry corrupt", function() newWorld(); addPlayer(1,"a"); Players[1].data.journal={{quest="hh_stronghold",index=50}}; Players[1].data.customVariables.myTes3mpStrongholds={hh_stronghold="bad"} end},
    {"note missing day", function() newWorld(); addPlayer(1,"a"); Players[1].data.journal={{quest="hh_stronghold",index=50}}; Players[1].data.customVariables.myTes3mpStrongholds={hh_stronghold={index=50}} end},
  }
  for _, c in ipairs(cases) do
    local ok, err = pcall(function() c[2](); tick() end)
    report("i "..c[1], ok, ok and nil or tostring(err))
  end
  -- handler robustness
  newWorld(); addPlayer(1,"a")
  local ok = pcall(function()
    customEventHooks.triggerHandlers("OnPlayerJournal",{}, {1,nil})
    customEventHooks.triggerHandlers("OnPlayerJournal",{}, {1,{journal=5}})
    customEventHooks.triggerHandlers("OnPlayerJournal",{}, {1,{journal={5,{quest=1}}}})
    customEventHooks.triggerHandlers("OnClientScriptGlobal",{}, {1,nil})
    customEventHooks.triggerHandlers("OnClientScriptGlobal",{}, {1,{}})
  end)
  report("i handlers tolerate junk packets", ok)
end

---------------------------------------------------------------- extra
do
  -- startup
  newWorld()
  report("x timer created+started with global callback name", T.timers[1] and T.timers[1].name=="MyTes3mpStrongholdTick" and T.timers[1].started and type(_G.MyTes3mpStrongholdTick)=="function")
  tick(); tick()
  report("x tick restarts timer", T.timers[1].restarts==2)
  -- multiple stronghold quests in one pass / order independence
  newWorld(); addPlayer(1,"a"); Players[1].data.journal={{quest="hh_stronghold",index=270},{quest="hr_stronghold",index=50}}
  setDay(7); tick(); setDay(12); tick()
  report("x same player two quests: world ends at 6, both granted", stage()==6 and idx(1,"HR_Stronghold")==55 and idx(1,"HH_Stronghold")==300, cmds())
  -- case: PC reaches index 50 higher journal like 55 present -> ignores
  newWorld(); addPlayer(1,"a"); Players[1].data.journal={{quest="HH_Stronghold",index=50},{quest="HH_Stronghold",index=55}}
  tick(); report("x 50 then 55 in journal -> nothing", #H.sent==0)
  -- player QuicksaveToDrive counts
  newWorld(); addPlayer(1,"a"); journalPacket(1,"HH_Stronghold",50); settle()
  report("x save on note creation", savesCount()>=1)
  -- journal id quest case from client mixed
  newWorld(); addPlayer(1,"a"); journalPacket(1,"hh_stronghold",50); settle(); setDay(6); tick()
  report("x lower-case quest id works", idx(1,"HH_Stronghold")==55)
end


---------------------------------------------------------------- new
do
  -- retry window: client never answers
  newWorld(); addPlayer(1,"a"); H.auto=false
  journalPacket(1,"HH_Stronghold",50); setDay(6)
  local sendTicks = {}
  local t0 = T.time
  for i=1,12 do local n=#H.sent; tick(); if #H.sent>n then sendTicks[#sendTicks+1]=(T.time-t0)/60 .. "m(+" .. (#H.sent-n) .. ")" end end
  report("n retry: one send per 300s window, none between (12 min ticks)", table.concat(sendTicks,",")=="1m(+2),6m(+2),11m(+2)", table.concat(sendTicks,","))
  -- same with retrySeconds changed at run time
  newWorld(); addPlayer(1,"a"); H.auto=false; H.S.retrySeconds=120
  journalPacket(1,"HH_Stronghold",50); setDay(6); local c={} for i=1,6 do local n=#H.sent; tick(); c[#c+1]=#H.sent-n end
  report("n retry: retrySeconds=120 -> every 2nd tick", table.concat(c,",")=="2,0,2,0,2,0", table.concat(c,","))

  -- answered -> inFlight cleared; next stage sends promptly
  newWorld(); addPlayer(1,"a")
  journalPacket(1,"HH_Stronghold",50); settle(); setDay(6); tick()
  journalPacket(1,"HH_Stronghold",90); settle(); local n=#H.sent; setDay(11); tick()
  report("n next stage after answer not blocked by old pending", idx(1,"HH_Stronghold")==100 and #H.sent==n+2, cmds())
  -- same index re-reached (journal says 90 again after pending 90 answered?) no
  -- partial answer: set arrives, Journal lost; retry resends only Journal
  newWorld(); addPlayer(1,"a"); H.auto=false
  journalPacket(1,"HH_Stronghold",50); setDay(6); tick()
  deliver(H.pending[1]); H.pending={}   -- set delivered (also echo), Journal lost
  local n0=#H.sent
  for i=1,5 do tick() end
  report("n partial answer: resend only Journal after window", #H.sent==n0+1 and H.sent[#H.sent].cmd=="Journal HH_Stronghold 55", cmds())

  -- stale set: original (first-copy) set delayed beyond world raise
  newWorld(); addPlayer(1,"a"); addPlayer(2,"b"); H.auto=false
  journalPacket(1,"HH_Stronghold",50); setDay(6); tick()
  local stale = H.pending[1]
  H.pending = {}
  globalPacket(2,"stronghold",4)
  for i=1,6 do tick() end    -- retry after window: world already 4 -> must not resend set
  local resentSet=false for _,x in ipairs(H.sent) do if x.cmd=="Journal HH_Stronghold 55" and false then end end
  local sets=0 for _,x in ipairs(H.sent) do if x.cmd:match("^set") then sets=sets+1 end end
  report("s retry after world raised sends no new 'set'", sets==1, "sets sent="..sets)
  -- Accepted: the very first `set` can still lower the global if the client runs it after
  -- another player has already raised it; that needs one command held for a whole build phase.

  -- shared, three players
  newWorld{shareJournal=true}; addPlayer(1,"a"); addPlayer(2,"b"); addPlayer(3,"c"); H.auto=false
  journalPacket(1,"HH_Stronghold",50); setDay(6); tick(); tick()
  local who={} for _,x in ipairs(H.sent) do who[x.pid]=(who[x.pid] or 0)+1 end
  local owner; local cntp=0 for p,c in pairs(who) do owner=p; cntp=cntp+1 end
  report("t shared x3: exactly one player gets commands (2 cmds), none on 2nd tick", cntp==1 and #H.sent==2, cmds())
  logout(owner); H.pending={}
  local n=#H.sent; for i=1,3 do tick() end
  report("t owner logs out: nobody takes over inside window", #H.sent==n)
  for i=1,3 do tick() end
  local who2={} for i=n+1,#H.sent do who2[H.sent[i].pid]=true end
  local k=0 local other for p in pairs(who2) do k=k+1; other=p end
  report("t after window a different online player takes over, exactly one", k==1 and other~=owner and #H.sent==n+2, cmds())
  settle()
  report("t takeover completes quest", idx(1,"HH_Stronghold")==55 and stage()==1)
  -- shared: all offline
  newWorld{shareJournal=true}; addPlayer(1,"a",false); WorldInstance.data.journal={{quest="hh_stronghold",index=50}}; setDay(9)
  local ok=pcall(tick); report("t shared nobody online", ok and #H.sent==0)
  -- shared note persisted per world, player data untouched
  -- accounts
  newWorld(); addPlayer(1,"Alice"); H.auto=false
  journalPacket(1,"HH_Stronghold",50); setDay(6); tick()
  local nA=#H.sent
  addPlayer(2,"Bob"); journalPacket(2,"HH_Stronghold",50); tick()
  local bobGot=0 for _,x in ipairs(H.sent) do if x.pid==2 then bobGot=bobGot+1 end end
  -- Bob's note starts day 6; day 6 -> not due. Advance:
  setDay(11); tick()
  bobGot=0 for _,x in ipairs(H.sent) do if x.pid==2 then bobGot=bobGot+1 end end
  report("u second account not blocked by first account's in-flight", bobGot==2, "bob cmds="..bobGot)
  -- pid reused by another account
  H.pending={}; local before=#H.sent
  Players[1]=nil; addPlayer(1,"Carol"); journalPacket(1,"HH_Stronghold",50)
  setDay(16); tick()
  local carol=0 for i=before+1,#H.sent do if H.sent[i].pid==1 then carol=carol+1 end end
  report("u pid reuse by a new account does not inherit old in-flight", carol==2, "carol cmds="..carol)
  -- same account relogs: in-flight inherited (by design) -> delay
  newWorld(); addPlayer(1,"Dave"); H.auto=false
  journalPacket(1,"HH_Stronghold",50); setDay(6); tick(); H.pending={}
  Players[1]=nil; addPlayer(1,"Dave"); Players[1].data.journal={{quest="hh_stronghold",index=50}}
  Players[1].data.customVariables={myTes3mpStrongholds={hh_stronghold={index=50,day=1}}}
  local n=#H.sent; tick(); tick()
  report("u same account relog while command lost: resend delayed until window ends (INFO)", #H.sent==n, "sent="..(#H.sent-n))
  -- case-variant account name
  newWorld(); addPlayer(1,"Eve"); H.auto=false; journalPacket(1,"HH_Stronghold",50); setDay(6); tick(); H.pending={}
  Players[1]=nil; addPlayer(1,"eve"); Players[1].data.journal={{quest="hh_stronghold",index=50}}; local m=#H.sent; tick()
  report("u 'Eve' vs 'eve' treated as one account", #H.sent==m)
end

---------------------------------------------------------------- pcall tick
do
  newWorld(); addPlayer(1,"a"); journalPacket(1,"HH_Stronghold",50); settle(); setDay(7)
  local orig = logicHandler.RunConsoleCommandOnPlayer
  logicHandler.RunConsoleCommandOnPlayer = function() error("boom") end
  local before = T.timers[1].restarts or 0
  local ok = pcall(MyTes3mpStrongholdTick)
  local errlog = false for _,m in ipairs(T.log) do if m:find("Check failed") then errlog=true end end
  report("p tick survives an error, logs it, restarts the timer", ok and errlog and (T.timers[1].restarts or 0)==before+1)
  logicHandler.RunConsoleCommandOnPlayer = orig
  T.time = T.time + 400
  tick()
  report("p next tick works again (retry window passed, in-flight record from the failed send)", idx(1,"HH_Stronghold")==55, cmds())
end

T.summary()
