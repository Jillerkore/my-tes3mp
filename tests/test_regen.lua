-- regen.lua: out-of-combat health and magicka regeneration through ability spell records.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report
local ADD, REMOVE = enumerations.spellbook.ADD, enumerations.spellbook.REMOVE

------------------------------------------------------------ a fake game: stats, spellbook packets, a fake client
local hp, hpBase, mp, mpBase, sign = {}, {}, {}, {}, {}
local packets, building = {}, nil
local client = {} -- client[pid] = { [spellId] = true }: the abilities the fake client has
local store

tes3mp.GetHealthCurrent = function(pid) return hp[pid] or 0 end
tes3mp.GetHealthBase = function(pid) return hpBase[pid] or 0 end
tes3mp.GetMagickaCurrent = function(pid) return mp[pid] or 0 end
tes3mp.GetMagickaBase = function(pid) return mpBase[pid] or 0 end
tes3mp.GetBirthsign = function(pid) return sign[pid] or "" end
tes3mp.ClearSpellbookChanges = function(pid) building = { pid = pid, ids = {} } end
tes3mp.SetSpellbookChangesAction = function(pid, action) building.action = action end
tes3mp.AddSpell = function(pid, id) building.ids[#building.ids + 1] = id end
tes3mp.SendSpellbookChanges = function(pid)
    packets[#packets + 1] = building
    client[pid] = client[pid] or {}
    for _, id in ipairs(building.ids) do
        if building.action == ADD then client[pid][id] = true else client[pid][id] = nil end
    end
end

-- What the fake client would add per second, worked out from the real record contents.
local function perSecond(pid)
    local total = { health = 0, magicka = 0 }
    for id in pairs(client[pid] or {}) do
        local record = store.data.permanentRecords[id]
        local effect = record.effects[1]
        if record.subtype == 1 and effect.rangeType == 0 then
            if effect.id == 75 then total.health = total.health + effect.magnitudeMin end
            if effect.id == 76 then total.magicka = total.magicka + effect.magnitudeMin end
        end
    end
    return total
end
local function count(pid) local n = 0 for _ in pairs(client[pid] or {}) do n = n + 1 end return n end

local R
local function setup(settings, opts)
    opts = opts or {}
    hp, hpBase, mp, mpBase, sign, packets, client = {}, {}, {}, {}, {}, {}, {}
    T.fresh(settings or T.copy(T.DEFAULT_SETTINGS))
    store = { data = { permanentRecords = opts.records or {} }, saves = 0 }
    function store:QuicksaveToDrive() self.saves = self.saves + 1 end
    if opts.noStore then store = nil end
    RecordStores.spell = store
    myTes3mpCombat, myTes3mpDowned = nil, opts.downed
    if not opts.noCombat then T.load("combat") end
    R = T.load("regen")
    T.postInit()
end
local function player(pid, name, h, hb, m, mb)
    local p = T.player(pid, name)
    p.data.spellbook = { "fireball" }
    p.data.character = { birthsign = "" }
    hp[pid], hpBase[pid], mp[pid], mpBase[pid] = h, hb, m, mb
    return p
end
local function tick()
    local id = T.timerNamed("MyTes3mpRegenTick")
    T.fire(id)
end
local function wait(s) T.time = T.time + s end

------------------------------------------------------------ the engine facts the design rests on
report("E1 effect ids: Restore Health is 75 and Restore Magicka is 76 (components/esm/loadmgef.hpp)",
    enumerations.effects.RESTORE_HEALTH == 75 and enumerations.effects.RESTORE_MAGICKA == 76)
local cs = T.csSource
report("E2 CoreScripts still sends permanent spell records to a player at login",
    cs("player/base.lua"):find("LoadRecords(self.pid, recordStore.data.permanentRecords", 1, true) ~= nil)
report("E3 CoreScripts still loads the spell record store at start-up",
    cs("config.lua"):find('"spell"', 1, true) ~= nil)
report("E4 CoreScripts still has the spellbook ADD/REMOVE actions",
    ADD == 1 and REMOVE == 2)

------------------------------------------------------------ records
setup(nil, { records = { myt_regen_old_3 = { name = "old" }, other_thing = { name = "keep me" } } })
local ids = {}
for id in pairs(store.data.permanentRecords) do if id:find("^myt_regen_") then ids[#ids + 1] = id end end
table.sort(ids)
report("R1 ten ability records are created", #ids == 10, table.concat(ids, ","))
local rec = store.data.permanentRecords.myt_regen_health_4
report("R1b a record is an ability with one self Restore Health effect of 4 points",
    rec and rec.subtype == 1 and rec.cost == 0 and #rec.effects == 1 and rec.effects[1].id == 75
    and rec.effects[1].magnitudeMin == 4 and rec.effects[1].magnitudeMax == 4 and rec.effects[1].rangeType == 0)
local mrec = store.data.permanentRecords.myt_regen_magicka_16
report("R1c the magicka records restore magicka", mrec and mrec.effects[1].id == 76 and mrec.effects[1].magnitudeMin == 16)
report("R1d records of an older version are removed, other records untouched",
    store.data.permanentRecords.myt_regen_old_3 == nil and store.data.permanentRecords.other_thing ~= nil)
report("R1e the record store was saved once", store.saves == 1, store.saves)
R.EnsureRecords()
report("R1f records already right: no further save", store.saves == 1)

-- the records go through the real packet builder into the same calls the server API has
local sent = {}
local saved = {}
for _, n in ipairs({ "SetRecordId", "SetRecordBaseId", "SetRecordName", "SetRecordSubtype", "SetRecordCost", "SetRecordFlags",
    "SetRecordEffectId", "SetRecordEffectAttribute", "SetRecordEffectSkill", "SetRecordEffectRangeType", "SetRecordEffectArea",
    "SetRecordEffectDuration", "SetRecordEffectMagnitudeMin", "SetRecordEffectMagnitudeMax", "AddRecordEffect", "AddRecord" }) do
    saved[n] = tes3mp[n]
    tes3mp[n] = function(...) sent[#sent + 1] = { n, ... } end
end
packetBuilder.AddRecordByType("myt_regen_health_4", rec, "spell")
for n, f in pairs(saved) do tes3mp[n] = f end
local function sentValue(n) for _, s in ipairs(sent) do if s[1] == n then return s[2] end end end
report("R1g the real packet builder passes id, ability type, effect 75, magnitude 4 and self range on",
    sentValue("SetRecordId") == "myt_regen_health_4" and sentValue("SetRecordSubtype") == 1
    and sentValue("SetRecordEffectId") == 75 and sentValue("SetRecordEffectMagnitudeMin") == 4
    and sentValue("SetRecordEffectMagnitudeMax") == 4 and sentValue("SetRecordEffectRangeType") == 0
    and sent[#sent - 1][1] == "AddRecordEffect" and sent[#sent][1] == "AddRecord")

------------------------------------------------------------ the timer
local id, t = T.timerNamed("MyTes3mpRegenTick")
report("T1 a timer with a global callback is created and started", id ~= nil and t.started == true and type(_G.MyTes3mpRegenTick) == "function")
local before = t.restarts
tes3mp.GetHealthCurrent = function() error("boom") end
player(1, "Alice", 50, 100, 50, 100)
tick()
report("T2 a failing tick is logged and the timer is still restarted", T.logContains("Check failed") and t.restarts == before + 1)
tes3mp.GetHealthCurrent = function(pid) return hp[pid] or 0 end

------------------------------------------------------------ giving the abilities
setup()
player(1, "Alice", 50, 100, 50, 100)
tick()
local ps = perSecond(1)
report("G1 out of combat and hurt: health and magicka abilities are given", ps.health == 1 and ps.magicka == 1, ps.health .. "/" .. ps.magicka)
local n = #packets
tick()
report("G2 the next tick sends nothing new", #packets == n)
report("G3 they are never written to the saved spellbook", #Players[1].data.spellbook == 1 and Players[1].data.spellbook[1] == "fireball")

-- tiers: time to full stays near 90 s / 180 s
local bad = {}
for _, max in ipairs({ 90, 100, 130, 140, 200, 275, 400, 640, 900, 1500, 2700 }) do
    local r = R.RateFor(max, 90)
    local seconds = max / r
    if seconds < 60 or seconds > 135 then bad[#bad + 1] = max .. "->" .. seconds end
end
for _, max in ipairs({ 180, 200, 260, 300, 540, 1000, 2000, 5000 }) do
    local r = R.RateFor(max, 180)
    local seconds = max / r
    if seconds < 120 or seconds > 270 then bad[#bad + 1] = "mp" .. max .. "->" .. seconds end
end
report("G4 tier choice keeps time-to-full roughly at the targets", #bad == 0, table.concat(bad, " "))
report("G4b a very weak character gets 1 point/s (faster than the target, never slower) and a huge one is capped at 31",
    R.RateFor(30, 90) == 1 and R.RateFor(0, 90) == 1 and R.RateFor(99999, 90) == 31)

setup()
player(1, "Alice", 100, 900, 100, 1800)
tick()
ps = perSecond(1)
report("G5 900 health / 1800 magicka: 10 points/s each, from several abilities", ps.health == 10 and ps.magicka == 10, ps.health .. "/" .. ps.magicka)
hpBase[1] = 2700; mpBase[1] = 5400
local p0 = #packets
tick()
ps = perSecond(1)
report("G6 after a level-up the rate follows", ps.health == 30 and ps.magicka == 30, ps.health .. "/" .. ps.magicka)
local changes, removals = 0, 0
for i = p0 + 1, #packets do
    changes = changes + #packets[i].ids
    if packets[i].action == REMOVE then removals = removals + #packets[i].ids end
end
report("G6b only the differing abilities are sent: 10 (=2+8) to 30 (=2+4+8+16) adds 4 and 16, per kind, removes none",
    changes == 4 and removals == 0, changes .. "/" .. removals)

------------------------------------------------------------ combat
setup()
player(1, "Alice", 50, 100, 50, 100)
tick()
report("C1 abilities given", count(1) == 2)
myTes3mpCombat.Mark(1)
report("C2 entering combat takes them away at once (listener), without waiting for a tick", count(1) == 0 and R.Rates(1).health == 0)
tick()
report("C3 nothing is given while in combat", count(1) == 0)
wait(myTes3mpCombat.quietSeconds - 1)
tick()
report("C4 one second short of quiet: still nothing", count(1) == 0)
wait(1)
tick()
report("C5 quiet long enough: given again", count(1) == 2)
-- a hit on the player from OnObjectHit
customEventHooks.triggerHandlers("OnObjectHit", { validDefaultHandler = true }, { 2, "Balmora", {}, { [1] = {} } })
report("C6 being hit (OnObjectHit with the player as target) also stops it", count(1) == 0)

------------------------------------------------------------ full health
setup()
player(1, "Alice", 50, 100, 100, 100)
tick()
report("F1 only the pool that is low gets an ability", perSecond(1).health == 1 and perSecond(1).magicka == 0)
hp[1] = 99
tick()
report("F2 the server sees health within 2 of full: ability stays for the grace period", perSecond(1).health == 1)
wait(R.graceSeconds)
tick()
report("F3 and goes after it", perSecond(1).health == 0 and count(1) == 0)
hp[1] = 60
tick()
report("F4 hurt again: given again", perSecond(1).health == 1)
mp[1] = 96; mpBase[1] = 100
tick(); wait(R.graceSeconds); tick()
report("F5 magicka within 4 of full counts as full", perSecond(1).magicka == 0)

------------------------------------------------------------ Atronach
setup()
player(1, "Alice", 50, 100, 10, 100)
sign[1] = "Atronach"
tick()
report("A1 Atronach birthsign: health yes, magicka never", perSecond(1).health == 1 and perSecond(1).magicka == 0)
-- The game data's id for the sign is "Wombburned"; "The Atronach" is only what it is called on screen.
setup()
player(1, "Alice", 50, 100, 10, 100)
sign[1] = "Wombburned"
tick()
report("A1b the sign's real record id, Wombburned: health yes, magicka never", perSecond(1).health == 1 and perSecond(1).magicka == 0)
setup()
player(1, "Alice", 50, 100, 10, 100)
sign[1] = "Elfborn"
tick()
report("A1c any other sign gets both", perSecond(1).health == 1 and perSecond(1).magicka >= 1)
sign[1] = ""
Players[1].data.character.birthsign = "atronach"
tick()
report("A2 the saved birthsign is used when the live one is empty", perSecond(1).magicka == 0)
Players[1].data.character.birthsign = "lady's favor"
tick()
report("A3 another sign gets magicka", perSecond(1).magicka == 1)
sign[1] = "Atronach"
tick()
report("A4 changing to Atronach removes a magicka ability that was given", perSecond(1).magicka == 0)

------------------------------------------------------------ dead and downed
setup(nil, { downed = { IsDowned = function(pid) return pid == 1 end } })
player(1, "Alice", 50, 100, 50, 100)
player(2, "Bob", 50, 100, 50, 100)
tick()
report("D1 a downed player gets nothing, the other does", count(1) == 0 and count(2) == 2)
setup()
player(1, "Alice", 50, 100, 50, 100)
tick()
hp[1] = 0
customEventHooks.triggerHandlers("OnPlayerDeath", { validDefaultHandler = true }, { 1 })
report("D2 death takes the abilities away at once", count(1) == 0)
tick()
report("D3 and a dead player (no health) gets none", count(1) == 0)
hp[1] = 25
tick()
report("D4 alive again: given again", count(1) == 2)
setup()
player(1, "Alice", 50, 100, 50, 100)
tick()
-- downed.lua may be loaded later than the first tick: the check is made every time
myTes3mpDowned = { IsDowned = function() return true end }
tick()
report("D5 a downed player has them taken away", count(1) == 0)
myTes3mpDowned = nil
tick()
report("D6 without downed.lua (global nil) it carries on", count(1) == 2)

------------------------------------------------------------ logging in and out
setup()
player(1, "Alice", 50, 100, 50, 100)
-- an earlier session / a crash left the abilities in the client and the saved spellbook
client[1] = { myt_regen_health_8 = true, myt_regen_magicka_1 = true }
Players[1].data.spellbook = { "fireball", "myt_regen_health_8", "heal", "myt_regen_magicka_1" }
local p1 = #packets
T.auth(1)
report("L1 on login every ability is removed from the client", count(1) == 0 and #packets == p1 + 1 and packets[#packets].action == REMOVE and #packets[#packets].ids == 10)
report("L2 and from the saved spellbook, leaving the real spells in order",
    table.concat(Players[1].data.spellbook, ",") == "fireball,heal", table.concat(Players[1].data.spellbook, ","))
tick()
report("L3 then they are given afresh, one each", perSecond(1).health == 1 and perSecond(1).magicka == 1)
Players[1].data.spellbook = { "fireball", "myt_regen_health_1" }
customEventHooks.triggerValidators("OnPlayerDisconnect", { 1 })
report("L4 at logout (before the save) the saved spellbook is cleaned", #Players[1].data.spellbook == 1)
Players[1] = nil
tick()
report("L5 a player who left is forgotten", R.Rates(1).health == 0)
-- a new player takes the same pid
player(1, "Carol", 50, 100, 50, 100)
client[1] = nil
T.auth(1)
tick()
report("L6 a new player on the same pid starts clean and gets exactly one set", perSecond(1).health == 1 and count(1) == 2)
local q = T.player(5, "Dora", { loggedIn = false })
tick()
report("L7 a player who is not logged in yet is left alone", count(5) == 0)

------------------------------------------------------------ switches and missing parts
local s = T.copy(T.DEFAULT_SETTINGS); s.regen = false
setup(s)
report("S1 switched off: no records, no timer, no combat listener, no tick function",
    store.saves == 0 and T.timerNamed("MyTes3mpRegenTick") == nil and #myTes3mpCombat.listeners == 0 and _G.MyTes3mpRegenTick == nil)
player(1, "Alice", 50, 100, 50, 100)
T.auth(1)
report("S1b and a login does nothing", #packets == 0)
s = T.copy(T.DEFAULT_SETTINGS); s.regen = nil
setup(s)
report("S2 a missing setting counts as on", R.enabled and T.timerNamed("MyTes3mpRegenTick") ~= nil)
setup(nil, { noCombat = true })
report("S3 without combat.lua: logged, no timer", T.logContains("combat.lua is not loaded") and T.timerNamed("MyTes3mpRegenTick") == nil)
setup(nil, { noStore = true })
report("S4 without a spell record store: logged, no timer", T.logContains("no spell record store") and T.timerNamed("MyTes3mpRegenTick") == nil)

T.summary()
