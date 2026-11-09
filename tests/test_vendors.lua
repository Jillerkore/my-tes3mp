-- vendors.lua: merchant stock put back when a barter screen opens, merchant gold timing.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local C = T
local B = T
local ADD, REMOVE, SUB = T.ADD, T.REMOVE, T.SUB
local uitems = dofile(T.scriptsDir .. "/uniqueItems.lua")
local ids = {} for k in pairs(uitems) do ids[#ids+1]=k end table.sort(ids)
local X = ids[1]
local V
local CELL, MID = "Balmora, Merchant", "300-0"
local function inv(...) local t={} for _,a in ipairs{...} do t[#t+1]={refId=a[1],count=a[2],charge=-1,enchantmentCharge=-1,soul=""} end return t end
local function setup(settings, opts)
  C.fresh(settings, opts); V = C.load("vendors"); C.postInit()
  C.player(1,"Alice"); C.player(2,"Bob")
  C.visit(1,CELL)
  LoadedCells[CELL].data.objectData[MID] = { refId="merchant", inventory = inv({"potion_a",5},{"ring_b",1},{"dagger_c",2}) }
  LoadedCells[CELL].data.packets.container = {MID}
  T.containerSets = {}
end
local function counts(cell) local t={} for _,i in ipairs(LoadedCells[CELL].data.objectData[MID].inventory) do t[i.refId]=(t[i.refId] or 0)+i.count end return t end
local function sentTo() local t={} for _,s in ipairs(T.containerSets) do t[#t+1]=s.pid end return table.concat(t,",") end
local function sell(pid, id, n) C.container(pid,CELL,ADD,SUB.NONE,300,{{refId=id,count=n or 1,actionCount=0}},"merchant") end
local function buy(pid, id, n) C.container(pid,CELL,REMOVE,SUB.NONE,300,{{refId=id,count=100,actionCount=n or 1}},"merchant") end

------------------------------------------------------------ restock logic
setup()
C.barter(1,CELL,MID)
local st = C.diskState("myTes3mpVendors.json")
report("V1 first barter snapshots the stock and sends nothing", st and st.stock[CELL][MID] and #st.stock[CELL][MID]==3 and #T.containerSets==0)
buy(1,"potion_a",5); sell(1,"junk_x",3); buy(1,"dagger_c",1)
B.time = B.time + 5
C.barter(1,CELL,MID)
report("V2 < 15 s later: nothing happens", #T.containerSets==0 and counts().potion_a==nil and counts().junk_x==3)
B.time = B.time + 20
C.barter(1,CELL,MID)
local c = counts()
report("V3 >= 15 s: bought wares restored, sold junk removed", c.potion_a==5 and c.dagger_c==2 and c.junk_x==nil and c.ring_b==1, B.json.encode(c))
report("V3b the barterer got the SET container first (validator, before echo)", sentTo()=="1", sentTo())
report("V3c server cell data saved", true)
-- repeat: nothing to do -> no packet
local n0=#T.containerSets; B.time=B.time+20; C.barter(1,CELL,MID)
report("V4 already in order: no packet", #T.containerSets==n0)
-- other player's recent open blocks
setup()
C.barter(1,CELL,MID); buy(1,"potion_a",5); B.time=B.time+20
C.barter(2,CELL,MID)       -- Bob opens: Alice opened it <120 s ago -> blocked? (first open by pid1 at t0; refresh by 2 at t+20)
report("V5 another player's recent open (<600 s) blocks the restock", #T.containerSets==0 and counts().potion_a==nil, sentTo())
B.time=B.time+200
C.barter(2,CELL,MID)
-- Regression: each player's last opening is remembered separately, so Bob opening the screen a second
-- time must not make the server forget that Alice may still have hers open.
report("V5a Alice opened 220 s ago, Bob (blocked once) opens again: still blocked (busySeconds is 600)", #T.containerSets==0 and counts().potion_a==nil)
B.time=B.time+500
C.barter(2,CELL,MID)
report("V5b after 600 s it goes ahead; visitors all get the inventory", counts().potion_a==5 and sentTo():find("2")~=nil, sentTo())
-- visitors loop
setup(); C.visit(2,CELL)
C.barter(1,CELL,MID); buy(1,"potion_a",5); B.time=B.time+20; C.barter(1,CELL,MID)
local got={} for _,s in ipairs(T.containerSets) do got[s.pid]=true end
report("V6 every visitor of the cell gets the new inventory", got[1] and got[2], sentTo())
-- bought unique not restored; still present kept
setup()
LoadedCells[CELL].data.objectData[MID].inventory = inv({"potion_a",5},{X,1},{ids[2],1})
C.barter(1,CELL,MID)
buy(1,X,1); buy(1,"potion_a",5)
B.time=B.time+20; C.barter(1,CELL,MID); c=counts()
report("V7 a bought unique is NOT restored; one still present is kept; potions restored", c[X]==nil and c[ids[2]]==1 and c.potion_a==5, B.json.encode(c))
-- unique sold to the merchant by a player: removed with the junk
sell(1,X,1); B.time=B.time+20; C.barter(1,CELL,MID); c=counts()
report("V7b a unique that was in his original stock and is sold back is kept (count = original)", c[X]==1, c[X])
sell(1,ids[3],1); B.time=B.time+20; C.barter(1,CELL,MID); c=counts()
-- Accepted (vendors.lua header: "what was sold to him is gone"): this applies to artifacts too.
report("V7c a unique NOT in his original stock that a player sells to him is removed with the other sold goods", c[ids[3]]==nil)
-- merchant with no stored inventory
setup()
LoadedCells[CELL].data.objectData[MID].inventory=nil
local okb = pcall(C.barter,1,CELL,MID)
report("V8 merchant with no stored inventory ignored", okb and #T.containerSets==0 and C.diskState("myTes3mpVendors.json")==nil)
okb = pcall(C.barter,1,CELL,"999-0")
report("V8b unknown object ignored", okb)
okb = pcall(C.barter,1,"Nowhere",MID)
report("V8c unloaded cell ignored", okb)
-- non-barter choices ignored
setup()
local objs={[MID]={refId="merchant",dialogueChoiceType=C.B and enumerations.dialogueChoice.TOPIC}}
customEventHooks.triggerValidators("OnObjectDialogueChoice",{1,CELL,objs,{}})
report("V9 TOPIC choice ignored", C.diskState("myTes3mpVendors.json")==nil)
-- error inside is caught
setup(); LoadedCells[CELL].data.objectData[MID].inventory = {{refId=5,count="x"}}
local ok2 = pcall(C.barter,1,CELL,MID); B.time=B.time+20; local ok3 = pcall(C.barter,1,CELL,MID)
report("V10 junk inventory entries do not raise out of the validator", ok2 and ok3)
-- restart persistence
setup(); C.barter(1,CELL,MID); buy(1,"potion_a",5)
local disk={} for k,v in pairs(B.disk) do disk[k]=v end
setup(); B.disk=disk; C.postInit()
LoadedCells[CELL]=nil; C.visit(1,CELL)
LoadedCells[CELL].data.objectData[MID] = { refId="merchant", inventory = inv({"ring_b",1},{"dagger_c",2}) }
B.time=B.time+20; C.barter(1,CELL,MID)
report("V11 stored stock survives a restart; the first barter after a restart may restock at once", counts().potion_a==5)
-- corrupt state
for i,sh in ipairs{"[]","5","{broken",'{"stock":5}','{"stock":{"c":5}}','{"stock":{"'..CELL..'":{"300-0":5}}}'} do
  local okc, err = pcall(function() setup(); B.disk["custom/myTes3mpVendors.json"]=sh; C.postInit(); C.barter(1,CELL,MID); B.time=B.time+20; C.barter(1,CELL,MID) end)
  report("V12."..i.." corrupt state tolerated: "..sh, okc, okc and nil or err)
end
------------------------------------------------------------ switches
local s=C.copy(T.DEFAULT_SETTINGS); s.vendorStockSeconds=0
setup(s); buy(1,"potion_a",5); C.barter(1,CELL,MID); B.time=B.time+100; C.barter(1,CELL,MID)
report("V15 stock seconds 0: no validator, nothing stored", #T.containerSets==0 and C.diskState("myTes3mpVendors.json")==nil)

------------------------------------------------------------ GMST
local function gm() return C.gmst.data.permanentRecords["fBarterGoldResetDelay"] end
setup(nil,{day=144,night=144})
report("G1 scale 144, 1 min -> 2.4 in-game hours", gm() and math.abs(gm().floatVar-2.4)<1e-9 and C.gmst.saves==1, gm() and gm().floatVar)
setup(nil,{day=30,night=40})
report("G2 stock 30/40, 1 min -> min scale 30 -> 0.5 h", gm() and math.abs(gm().floatVar-0.5)<1e-9, gm() and gm().floatVar)
s=C.copy(T.DEFAULT_SETTINGS); s.vendorGoldMinutes=0
setup(s)
report("G3 goldMinutes 0 -> no record written", gm()==nil and C.gmst.saves==0)
s=C.copy(T.DEFAULT_SETTINGS); s.vendorGoldMinutes=10
setup(s,{day=144,night=144}); report("G4 10 min -> 24 h (a stock day)", math.abs(gm().floatVar-24)<1e-9, gm().floatVar)
-- idempotent
setup(nil,{day=144,night=144}); C.postInit(); report("G5 second PostInit with same value: no second save", C.gmst.saves==1)
-- time table missing fields
C.fresh(); WorldInstance.data.time = {}; V=C.load("vendors"); local okg = pcall(C.postInit)
report("G6 missing scales fall back to 30", okg and gm() and math.abs(gm().floatVar-0.5)<1e-9)
T.summary()
