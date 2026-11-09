-- uniques.lua: one fresh copy of each artifact per player, no farming.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local C, B = T, T
local ADD, REMOVE, SUB = T.ADD, T.REMOVE, T.SUB
local H = 3600; local ENUM = enumerations
local U, R
local X, Y
local items = dofile(T.scriptsDir .. "/uniqueItems.lua")
local ids = {} for k in pairs(items) do ids[#ids+1]=k end table.sort(ids)
X, Y = ids[1], ids[2]
local function setup(settings, withResets)
  C.fresh(settings)
  if withResets ~= false then R = C.load("resets") end
  U = C.load("uniques")
  C.postInit()
end
local function take(pid, cell, ref, id, n) return C.container(pid, cell, REMOVE, SUB.DRAG, ref, {{refId=id, count=n or 1, actionCount=n or 1}}) end
local function claims(id) local s=C.diskState("myTes3mpUniques.json"); return s and s.claims and s.claims[id] end

------------------------------------------------------------ data file
local n=0 local bad
for k,v in pairs(items) do n=n+1 if k~=k:lower() or type(v)~="string" or v=="" then bad=k end end
report("D1 uniqueItems.lua: 271 entries, lower-case keys, non-empty names", n==271 and bad==nil, n.." bad="..tostring(bad))

------------------------------------------------------------ container takes
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.visit(1,"Vivec, Temple"); C.auth(1); C.auth(2)
local ok = take(1,"Vivec, Temple",100,X)
report("U1 first fresh take claims and is allowed", ok and claims(X) and claims(X).alice==true)
report("U1b player told", (function() for _,m in ipairs(B.msgs) do if m[2]:find("is yours") then return true end end end)())
ok = take(1,"Vivec, Temple",100,X)
report("U2 second fresh take by same account refused (validator false)", ok==false)
ok = take(2,"Vivec, Temple",100,X)
report("U2b by another account allowed and claimed", ok and claims(X).bob==true)
report("U2c account name case-insensitive ('ALICE' still refused)", (function() Players[1].accountName="ALICE"; local r=take(1,"Vivec, Temple",100,X); Players[1].accountName="Alice"; return r==false end)())

-- refusal leaves server data untouched
setup(); C.player(1,"Alice"); C.visit(1,"Vivec, Temple"); C.auth(1)
LoadedCells["Vivec, Temple"].data.objectData["100-0"]={refId="chest_small_01", inventory={{refId=X,count=1,charge=-1,enchantmentCharge=-1,soul=""}}}
take(1,"Vivec, Temple",100,X)   -- claim
LoadedCells["Vivec, Temple"].data.objectData["100-0"].inventory={{refId=X,count=1,charge=-1,enchantmentCharge=-1,soul=""}} -- container shows fresh again
local before = B.json.encode(LoadedCells["Vivec, Temple"].data.objectData["100-0"].inventory)
local sent0 = #B.calls
ok = take(1,"Vivec, Temple",100,X)
report("U3 refused take: container inventory untouched on the server", ok==false and B.json.encode(LoadedCells["Vivec, Temple"].data.objectData["100-0"].inventory)==before)

-- deposit then withdraw
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.visit(1,"Vivec, Temple"); C.auth(1); C.auth(2)
take(1,"Vivec, Temple",100,X)                                       -- Alice claims
C.container(1,"Vivec, Temple",ADD,SUB.DROP,200,{{refId=X,count=1,actionCount=0}})   -- she deposits it elsewhere
ok = take(1,"Vivec, Temple",200,X)
report("U4 depositor can take own deposit back", ok)
C.container(1,"Vivec, Temple",ADD,SUB.DROP,200,{{refId=X,count=1,actionCount=0}})
ok = take(2,"Vivec, Temple",200,X)
report("U4b another player can take the deposit, and it is NOT a claim for him", ok and claims(X).bob==nil)
local s=C.diskState("myTes3mpUniques.json")
report("U4c deposit books back to zero", next(s.deposits or {})==nil, B.json.encode(s.deposits))
-- Bob later takes a fresh copy: still allowed (he never claimed)
report("U4d Bob's first fresh take afterwards still works", take(2,"Vivec, Temple",100,X))

-- Take All
setup(); C.player(1,"Alice"); C.visit(1,"Vivec, Temple"); C.auth(1)
take(1,"Vivec, Temple",100,X)
ok = C.container(1,"Vivec, Temple",REMOVE,SUB.TAKE_ALL,101,{{refId="gold_001",count=50,actionCount=50},{refId=X,count=1,actionCount=1}})
report("U5 Take All containing a claimed unique refused as a whole", ok==false)
ok = C.container(1,"Vivec, Temple",REMOVE,SUB.TAKE_ALL,101,{{refId="gold_001",count=50,actionCount=50}})
report("U5b Take All without it fine", ok)
-- fresh in Take All claims
setup(); C.player(1,"Alice"); C.visit(1,"Vivec, Temple"); C.auth(1)
ok = C.container(1,"Vivec, Temple",REMOVE,SUB.TAKE_ALL,101,{{refId="gold_001",count=50,actionCount=50},{refId=Y,count=1,actionCount=1}})
report("U5c Take All with a fresh unique claims it", ok and claims(Y) and claims(Y).alice==true)
-- two uniques in one Take All, one claimed
setup(); C.player(1,"Alice"); C.visit(1,"Vivec, Temple"); C.auth(1); take(1,"Vivec, Temple",100,Y)
ok = C.container(1,"Vivec, Temple",REMOVE,SUB.TAKE_ALL,102,{{refId=X,count=1,actionCount=1},{refId=Y,count=1,actionCount=1}})
report("U5d refused whole -> the fresh one (X) is NOT claimed either", ok==false and claims(X)==nil)

-- counts
setup(); C.player(1,"Alice"); C.visit(1,"Vivec, Temple"); C.auth(1)
C.container(1,"Vivec, Temple",ADD,SUB.DROP,200,{{refId=X,count=3,actionCount=0}})
local d = C.diskState("myTes3mpUniques.json").deposits["Vivec, Temple"]["200-0"][X]
report("U6 ADD+DROP of 3 books 3 (count field)", d==3, d)
take(1,"Vivec, Temple",200,X,2)
d = C.diskState("myTes3mpUniques.json").deposits["Vivec, Temple"]["200-0"][X]
report("U6b REMOVE+DRAG of 2 from a stack of 3 uses actionCount (2) -> 1 left", d==1, d)
-- REMOVE: count is the stack total, actionCount the number moved
B.packet = { action=REMOVE, sub=SUB.DRAG, objects={{refId="c",refNum=1,mpNum=0,items={{refId=X,count=5,actionCount=1}}}} }

-- non unique
setup(); C.player(1,"Alice"); C.visit(1,"Vivec, Temple"); C.auth(1)
for i=1,3 do ok = C.container(1,"Vivec, Temple",REMOVE,SUB.DRAG,100,{{refId="gold_001",count=100,actionCount=100}}) end
local st = C.diskState("myTes3mpUniques.json")
report("U7 non-unique items never touched, nothing booked", ok and next(st and st.claims or {})==nil and next(st and st.deposits or {})==nil)

------------------------------------------------------------ barter (ADD+NONE = sale, REMOVE+NONE = purchase)
local SHOP, MERCH = "Balmora, Merchant", 300
local function merchantBuy(pid, id) return C.container(pid, SHOP, REMOVE, SUB.NONE, MERCH, {{refId=id, count=1, actionCount=1}}, "merchant") end
local function merchantSell(pid, id) return C.container(pid, SHOP, ADD, SUB.NONE, MERCH, {{refId=id, count=1, actionCount=0}}, "merchant") end
local function shopTimer() customEventHooks.triggerHandlers("OnServerExit", {}, {}); local f = C.diskState("myTes3mpCellResets.json"); return f and f.timers and f.timers[SHOP] end

setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.visit(1,SHOP); C.auth(1); C.auth(2)
local regular = shopTimer()
ok = merchantBuy(1,X)
report("B1 buying a unique from a merchant is allowed", ok)
report("B1b ... and records NO claim", claims(X) == nil)
report("B1c ... and does not hasten the shop's reset", shopTimer() == regular)
report("B1d ... and tells the player nothing about claims", not C.messageContains("is yours"))
report("B5 so a fresh take elsewhere afterwards is still allowed (it is his first)", take(1,SHOP,301,X) and claims(X).alice == true)
ok = merchantBuy(1,X)
report("B6 buying yet another copy after a claim is never refused (purchases are not restricted)", ok)
-- selling and buying back
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.visit(1,SHOP); C.auth(1); C.auth(2)
take(1,SHOP,301,X)
merchantSell(1,X)
local dep = C.diskState("myTes3mpUniques.json").deposits[SHOP]
report("B2 selling a unique to a merchant books a deposit", dep and dep["300-0"] and dep["300-0"][X] == 1)
merchantBuy(2,X)
report("B3 another player buying it back: the deposit is used up, he has no claim", claims(X).bob == nil and next(C.diskState("myTes3mpUniques.json").deposits or {}) == nil)
report("B4 a claimed player buying again is never refused", merchantBuy(1,X))
-- the old B7 sequence: deposit notes must not outlive a cell reset
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.visit(1,SHOP); C.auth(1); C.auth(2)
take(1,SHOP,301,X)                                   -- Alice claims a fresh copy
merchantSell(1,X)                                    -- and sells it: deposit 1 at the merchant
C.leave(1,SHOP)
B.time = B.time + 5*H; C.player(3,"Carol"); R.Sweep() -- the shop cell resets
report("B7a the reset cleared the deposit notes of that cell", C.diskState("myTes3mpUniques.json").deposits == nil
  or C.diskState("myTes3mpUniques.json").deposits[SHOP] == nil)
C.visit(1,SHOP)
LoadedCells[SHOP].data.objectData["300-0"] = {refId="merchant", inventory={{refId=X,count=1,charge=-1,enchantmentCharge=-1,soul=""}}}
ok = C.container(2,SHOP,REMOVE,SUB.DRAG,300,{{refId=X,count=1,actionCount=1}},"merchant")
report("B7 Bob's take of the restored copy is a FRESH take: it records his claim", ok and claims(X).bob == true)
report("B7b ... so a second fresh copy elsewhere is refused for him", take(2,SHOP,400,X) == false)
-- notes of other cells survive
setup(); C.player(1,"Alice"); C.visit(1,SHOP); C.auth(1)
take(1,SHOP,301,X); merchantSell(1,X)
C.container(1,"Vivec, Temple",ADD,SUB.DROP,200,{{refId=Y,count=1,actionCount=0}})
R.Sweep(); B.time = B.time + 5*H; C.leave(1,SHOP); C.player(3,"Carol")
-- reset only the shop
local cleared
for _, l in ipairs(myTes3mpResets.listeners) do l(SHOP) end
local d = C.diskState("myTes3mpUniques.json").deposits
report("B8 the listener drops only the reset cell's notes, other cells keep theirs", d[SHOP] == nil and d["Vivec, Temple"] and d["Vivec, Temple"]["200-0"][Y] == 1)
-- the listener is registered only when resets.lua is loaded; no error otherwise
setup(nil,false)
report("B9 without resets.lua nothing is registered and nothing breaks", myTes3mpResets == nil)
setup(); report("B10 with resets.lua exactly one uniques listener is registered at post-init", #myTes3mpResets.listeners == 1)
-- a throwing listener elsewhere does not stop the uniques one (resets pcall's each)
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.visit(1,SHOP); C.auth(1); C.auth(2)
table.insert(myTes3mpResets.listeners, 1, function() error("someone else's listener") end)
take(1,SHOP,301,X); merchantSell(1,X); C.leave(1,SHOP); B.time = B.time + 5*H; C.player(3,"Carol")
local okr = pcall(R.Sweep)
report("B11 another listener throwing does not stop the deposit notes being cleared", okr and (C.diskState("myTes3mpUniques.json").deposits or {})[SHOP] == nil)

------------------------------------------------------------ world pickups
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.visit(1,"Seyda Neen, Arrille's Tradehouse"); C.auth(1); C.auth(2)
ok = C.objectDelete(1,"Seyda Neen, Arrille's Tradehouse","5000-0",X)
report("W1 fresh game-placed pick-up claims", ok and claims(X).alice==true)
ok = C.objectDelete(1,"Seyda Neen, Arrille's Tradehouse","5000-0",X)
report("W2 claimed pick-up refused (validator false)", ok==false)
local stripId, strip = T.timerNamed("MyTes3mpUniqueStrip")
report("W2b one strip timer 'iss' (pid, account, refId) at 2000 ms", strip and strip.types=="iss" and strip.ms==2000 and strip.args[1]==1 and strip.args[2]=="Alice" and strip.args[3]==X)
Players[1].data.inventory = {{refId=X,count=1,charge=-1,enchantmentCharge=-1,soul=""}}
T.fire(stripId)
local ch; for _,c in ipairs(Players[1].calls) do if type(c)=="table" then ch=c end end
report("W2c strip removes it from server data and sends REMOVE inventory change", next(Players[1].data.inventory)==nil and ch and ch[3]==ENUM.inventory.REMOVE and ch[2][1].refId==X and ch[2][1].count==1)
ok = C.objectDelete(1,"Seyda Neen, Arrille's Tradehouse","0-77",X)
report("W3 player-dropped (mpNum 77) ignored", ok)
ok = C.objectDelete(1,"Seyda Neen, Arrille's Tradehouse","0-10",X)
report("W3b 'mpNum 10' is not mistaken for '-0'", ok)
ok = C.objectDelete(2,"Seyda Neen, Arrille's Tradehouse","5000-0",X)
report("W4 another account picks it up fresh", ok and claims(X).bob==true)
-- other items ignored; other object kinds
ok = C.objectDelete(1,"Seyda Neen, Arrille's Tradehouse","5001-0","ingred_bread_01")
report("W5 non-unique pick-up ignored", ok)
-- corpse disposal / summon despawn deletes (refIds of creatures)
ok = C.objectDelete(1,"Seyda Neen, Arrille's Tradehouse","5002-0","dremora")
report("W6 summon / corpse deletes are ignored", ok)
-- strip after logout / account changed
setup(); C.player(1,"Alice"); C.visit(1,"Seyda Neen, Arrille's Tradehouse"); C.auth(1)
C.objectDelete(1,"Seyda Neen, Arrille's Tradehouse","5000-0",X); C.objectDelete(1,"Seyda Neen, Arrille's Tradehouse","5000-0",X)
Players[1].accountName="Mallory"; T.fire(T.timerNamed("MyTes3mpUniqueStrip"))
local any=false for _,c in ipairs(Players[1].calls) do if type(c)=="table" then any=true end end
report("W7 strip skipped when the pid now belongs to another account", not any)
-- purchase of an owned world item sends ObjectDelete of a game-placed unique (containeritemmodel.cpp)
setup(); C.player(1,"Alice"); C.visit(1,"Balmora, Shop"); C.auth(1)
C.objectDelete(1,"Balmora, Shop","6000-0",X)      -- she claims X earlier
ok = C.objectDelete(1,"Balmora, Shop","6001-0",X) -- later PURCHASES an owned world copy (containeritemmodel.cpp:226 sends ObjectDelete)
-- Accepted (uniques.lua header, "rough edges"): buying a unique that lies on a shelf sends the same packet as a pick-up.
report("W8 buying a claimed unique off a shop shelf is undone like a pick-up", ok==false)

------------------------------------------------------------ claims hasten the reset
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.auth(1); C.auth(2)
C.visit(1,"Vivec, Temple"); take(1,"Vivec, Temple",100,X)
local function dueOf(cell) R.Sweep(); local f=C.diskState("myTes3mpCellResets.json"); return f and f.timers and f.timers[cell] end
customEventHooks.triggerHandlers("OnServerExit", {}, {})
local t = C.diskState("myTes3mpCellResets.json").timers["Vivec, Temple"]
report("H1 claim with somebody still lacking it hastens the cell to now+30min", t == B.time + 1800, tostring(t).." vs "..(B.time+1800))
-- nobody else needs: single account
setup(); C.player(1,"Alice"); C.auth(1); C.visit(1,"Vivec, Temple"); local before=B.time+4*H
take(1,"Vivec, Temple",100,X); customEventHooks.triggerHandlers("OnServerExit", {}, {})
t = C.diskState("myTes3mpCellResets.json").timers["Vivec, Temple"]
report("H2 nobody else lacks it -> normal 4h schedule untouched", t == before, tostring(t))
-- kept cells
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.auth(1); C.auth(2); C.visit(1,"Rethan Manor, Gols' House")
take(1,"Rethan Manor, Gols' House",100,X); customEventHooks.triggerHandlers("OnServerExit", {}, {})
local f = C.diskState("myTes3mpCellResets.json")
report("H3 never for kept cells", f==nil or (f.timers or {})["Rethan Manor, Gols' House"]==nil)
-- earlier schedule not pushed back
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.auth(1); C.auth(2); C.visit(1,"Vivec, Temple"); B.time=B.time+3*H+50*60
take(1,"Vivec, Temple",100,X); customEventHooks.triggerHandlers("OnServerExit", {}, {})
t = C.diskState("myTes3mpCellResets.json").timers["Vivec, Temple"]
report("H4 an earlier regular due time is kept (min of both)", t == (B.time - (3*H+50*60)) + 4*H, tostring(t))
-- respawn minutes = 0
local s0=C.copy(T.DEFAULT_SETTINGS); s0.uniqueRespawnMinutes=0
setup(s0); C.player(1,"Alice"); C.player(2,"Bob"); C.auth(1); C.auth(2); C.visit(1,"Vivec, Temple"); take(1,"Vivec, Temple",100,X); customEventHooks.triggerHandlers("OnServerExit", {}, {})
t = C.diskState("myTes3mpCellResets.json").timers["Vivec, Temple"]
report("H5 uniqueRespawnMinutes=0: no hasten", t == B.time + 4*H)
-- actual reset happens and the item comes back for Bob; Alice still refused
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.auth(1); C.auth(2); C.visit(1,"Vivec, Temple")
LoadedCells["Vivec, Temple"].data.objectData["100-0"]={refId="chest_small_01", inventory={{refId=X,count=1,charge=-1,enchantmentCharge=-1,soul=""}}}
take(1,"Vivec, Temple",100,X); C.leave(1,"Vivec, Temple"); B.time=B.time+31*60; R.Sweep()
report("H6 after 30 min the cell is reset", (function() local n=0 for _,c in ipairs(B.calls) do if c[1]=="SendCellReset" then n=n+1 end end return n==1 end)())
C.visit(2,"Vivec, Temple")
LoadedCells["Vivec, Temple"].data.objectData["100-0"]={refId="chest_small_01", inventory={{refId=X,count=1,charge=-1,enchantmentCharge=-1,soul=""}}}
report("H7 Bob takes the restored copy, Alice's second is still refused", take(2,"Vivec, Temple",100,X)==true and take(1,"Vivec, Temple",100,X)==false)
-- without resets loaded
setup(nil,false); C.player(1,"Alice"); C.player(2,"Bob"); C.auth(1); C.auth(2); C.visit(1,"Vivec, Temple")
local okp = pcall(take,1,"Vivec, Temple",100,X)
report("H8 uniques without resets.lua: no error, claim still recorded", okp and claims(X) and claims(X).alice==true)

------------------------------------------------------------ state, restart, corrupt
setup(); C.player(1,"Alice"); C.player(2,"Bob"); C.auth(1); C.auth(2); C.visit(1,"Vivec, Temple"); take(1,"Vivec, Temple",100,X)
C.container(1,"Vivec, Temple",ADD,SUB.DROP,200,{{refId=Y,count=1,actionCount=0}})
local disk = {} for k,v in pairs(B.disk) do disk[k]=v end
setup(); B.disk = disk; C.player(1,"Alice"); C.player(2,"Bob"); C.visit(1,"Vivec, Temple")
U.reload = nil
C.postInit()
report("R1 state survives a restart: Alice still refused", take(1,"Vivec, Temple",100,X)==false)
report("R1b deposit survives a restart (withdraw by Bob not a claim)", take(2,"Vivec, Temple",200,Y) and claims(Y)==nil)
local shapes = { "[]", "5", '"x"', "{broken", "", '{"claims":5,"deposits":[],"accounts":"x"}', '{"claims":{"a":5},"deposits":{"c":5},"accounts":[1,2]}',
  '{"claims":{"'..X..'":{"alice":"yes"}},"deposits":{"Vivec, Temple":{"200-0":5}}}', '{"claims":null,"deposits":null,"accounts":null}',
  '{"claims":{"'..X..'":[1]}, "deposits":{"Vivec, Temple":{"200-0":{"'..X..'":"many"}}}}' }
for i,sh in ipairs(shapes) do
  local okc, err = pcall(function()
    setup(); B.disk["custom/myTes3mpUniques.json"]=sh
    C.postInit(); C.player(1,"Alice"); C.player(2,"Bob"); C.visit(1,"Vivec, Temple"); C.auth(1)
    take(1,"Vivec, Temple",100,X); take(1,"Vivec, Temple",100,X); take(2,"Vivec, Temple",200,X)
    C.container(1,"Vivec, Temple",ADD,SUB.DROP,200,{{refId=X,count=1,actionCount=0}})
    C.objectDelete(1,"Vivec, Temple","9-0",X); C.objectDelete(1,"Vivec, Temple","9-0",X)
  end)
  report("S"..i.." corrupt state tolerated: "..sh:sub(1,40), okc, okc and nil or err)
end
-- /uniques command
setup(); C.player(1,"Alice"); C.auth(1); C.visit(1,"Vivec, Temple"); take(1,"Vivec, Temple",100,X)
B.msgs={}; customCommandHooks.commands.uniques(1,{})
report("C1 /uniques lists claimed names", B.msgs[1] and B.msgs[1][2]:find(items[X],1,true) ~= nil, B.msgs[1] and B.msgs[1][2])

-- handlers tolerate junk
setup(); C.player(1,"Alice")
local oj = pcall(function()
  customEventHooks.triggerHandlers("OnObjectDelete",{validDefaultHandler=true},{1,"x",nil,{}})
  customEventHooks.triggerHandlers("OnObjectDelete",{validDefaultHandler=true},{1,"x",{["1-0"]=5},{}})
  customEventHooks.triggerValidators("OnObjectDelete",{1,"x",{["1-0"]={}},{}})
  customEventHooks.triggerValidators("OnObjectDelete",{99,"x",{},{}})
end)
report("J1 junk object-delete arguments tolerated", oj)
T.summary()
