-- Party: everybody on the server is on the same side.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Switch it off with TES3MP_PARTY=false.
--
-- TES3MP has an ally system that players normally set up by hand with
-- /invite and /join. Between allies the game does not keep track of who hit
-- whom, so a stray swing or spell is not held against you, and allies do not
-- break each other's sneaking. With per-player kill counts an ally who is
-- online is also credited with your kills - so a quest that says "kill X"
-- completes for both of you when you do it together.
--
-- (Hitting another player is never a crime in TES3MP, allied or not, and
-- never turns guards or bystanders on you; that needs no help from here.)
--
-- On a server for friends there is no reason to make anybody type /invite:
-- here every player is allied with every other player as soon as he logs in.

local party = {}

local function allyOneWay(player, other)
    if type(player.data.alliedPlayers) ~= "table" then
        player.data.alliedPlayers = {}
    end
    if not tableHelper.containsCaseInsensitiveString(player.data.alliedPlayers, other.accountName) then
        table.insert(player.data.alliedPlayers, other.accountName)
        player:QuicksaveToDrive()
        return true
    end
    return false
end

customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
    local player = Players[pid]
    if player == nil or not player:IsLoggedIn() then
        return
    end

    for otherPid, other in pairs(Players) do
        if otherPid ~= pid and other ~= nil and other:IsLoggedIn() then
            local new = allyOneWay(player, other)
            new = allyOneWay(other, player) or new
            -- Sent even when nothing is new: who is online has changed, and
            -- a client is only told about allies who are.
            other:LoadAllies()
            if new then
                tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp party] " .. player.accountName ..
                    " and " .. other.accountName .. " are now allies")
            end
        end
    end
    player:LoadAllies()
end)

return party
