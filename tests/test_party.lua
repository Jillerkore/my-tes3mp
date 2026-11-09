-- party.lua: every player is allied with every other player.
package.path = ((arg and arg[0] or ""):match("^(.*)/") or ".") .. "/?.lua;" .. package.path
local T = require("harness")
local report = T.report

local function count(t, v) local n = 0 for _, x in ipairs(t or {}) do if x == v then n = n + 1 end end return n end
local function allies(p) return p.data.alliedPlayers or {} end
local function nCalls(p, c) local n = 0 for _, x in ipairs(p.calls) do if x == c then n = n + 1 end end return n end
local function setup() T.fresh(); T.load("party") end

setup(); local a = T.player(1, "Alice"); T.auth(1)
report("Y1 single player: no allies, own LoadAllies sent", #allies(a) == 0 and nCalls(a, "allies") == 1)
local b = T.player(2, "Bob"); T.auth(2)
report("Y2 two players become mutual allies", count(allies(a), "Bob") == 1 and count(allies(b), "Alice") == 1)
report("Y2b both clients are told (the earlier player is re-sent, the newcomer gets his own)", nCalls(a, "allies") >= 2 and nCalls(b, "allies") >= 1)
local c = T.player(3, "Carol"); T.auth(3)
report("Y3 a third player is allied with both, and both with her",
  count(allies(c), "Alice") == 1 and count(allies(c), "Bob") == 1 and count(allies(a), "Carol") == 1 and count(allies(b), "Carol") == 1)

-- relog
Players[2] = nil
local b2 = T.player(2, "Bob"); b2.data.alliedPlayers = { "Alice", "Carol" }; T.auth(2)
report("Y4 a relog does not duplicate entries", count(allies(b2), "Alice") == 1 and count(allies(b2), "Carol") == 1 and count(allies(a), "Bob") == 1)
Players[2] = nil
local b3 = T.player(2, "bob"); b3.data.alliedPlayers = { "alice", "carol" }; T.auth(2)
report("Y5 the check ignores case: 'bob' is not added next to 'Bob', 'Alice' not next to 'alice'",
  #allies(a) == 2 and count(allies(a), "bob") == 0 and #allies(b3) == 2, T.json.encode(allies(a)))

setup(); local d = T.player(1, "D"); T.player(2, "E", { loggedIn = false }); T.auth(1)
report("Y6 players who are not logged in are skipped", #allies(d) == 0)
setup(); local f = T.player(1, "F"); f.data.alliedPlayers = nil; local g = T.player(2, "G"); g.data.alliedPlayers = nil; T.auth(2)
report("Y7 missing alliedPlayers tables are created", #allies(f) == 1 and #allies(g) == 1)
setup()
report("Y8 an unknown or logged-out pid is tolerated", pcall(T.auth, 9) and (function() T.player(5, "H", { loggedIn = false }); return pcall(T.auth, 5) end)())
local real = T.csSource("player/base.lua")
report("Y9 source: LoadAllies lists only allies who are online and sends with sendToOtherPlayers",
  real:find("IsPlayerNameLoggedIn%(otherAccountName%)") ~= nil and real:find("tes3mp.SendAlliedPlayers%(self.pid, true%)") ~= nil)
setup(); local p1 = T.player(1, "P1"); T.auth(1); local p2 = T.player(2, "P2"); T.auth(2)
report("Y10 the earlier player's list is re-sent when the second logs in (his client learns the ally is online)", nCalls(p1, "allies") == 2)
report("Y11 the allies are saved (QuicksaveToDrive) when entries are added", nCalls(p1, "save") >= 1 and nCalls(p2, "save") >= 1)

-- the header must only claim what the client does
local header = T.scriptSource("party.lua"):match("^(.-)\nlocal party")
report("Y12 header does not promise that followers or summons forgive allies", not header:lower():find("followers") and not header:lower():find("summons"))
report("Y13 header states hits between players are never a crime", header:find("never a crime", 1, true) ~= nil)

T.summary()
