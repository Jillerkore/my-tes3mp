-- Entry point of the scripts my-tes3mp adds to the server.
--
-- This directory (scripts/custom/myTes3mp/) is managed: the container
-- replaces it from the image on every start, and writes settings.lua from the
-- TES3MP_* environment variables. Do not edit files here - change .env
-- instead. Every part can be switched off there:
--
--   TES3MP_PROGRESSION=custom        leave the sharing rules to config.lua
--   TES3MP_STRONGHOLD_HELPER=false   strongholds.lua
--   TES3MP_CELL_RESET_HOURS=0        resets.lua
--   TES3MP_DAY_MINUTES=0             the day length in world.lua
--   TES3MP_PARTY=false               party.lua
--   TES3MP_CHALLENGE=off             challenge.lua
--   TES3MP_VENDOR_GOLD_MINUTES=0     merchant gold in vendors.lua
--   TES3MP_VENDOR_STOCK_SECONDS=0    merchant stock in vendors.lua
--   TES3MP_UNIQUE_CLAIMS=false       uniques.lua
--   TES3MP_REGEN=false               regen.lua
--   TES3MP_DOWNED_SECONDS=0          downed.lua
--   TES3MP_TRAVEL=false              travel.lua
--   TES3MP_BANK=false                bank.lua
--   TES3MP_SHARE_QUESTS=false        sharequest.lua
--   TES3MP_WORLD_BOSS_HOURS=0        bosses.lua
--
-- It is loaded by this line in scripts/customScripts.lua, which the container
-- adds if it is missing:
--
--   require("custom/myTes3mp/init")

local settings = require("custom/myTes3mp/settings")

local function number(value)
    return tonumber(value) or 0
end

require("custom/myTes3mp/world")

if settings.party then
    require("custom/myTes3mp/party")
end

-- Knows who is in a fight; several of the features below ask it.
if settings.regen or settings.travel or settings.bank or number(settings.downedSeconds) > 0 then
    require("custom/myTes3mp/combat")
end

if settings.strongholdHelper then
    require("custom/myTes3mp/strongholds")
end

-- Before uniques, bank and bosses: they hook into this one.
if number(settings.cellResetHours) > 0 then
    require("custom/myTes3mp/resets")
end

if settings.challenge ~= "off" then
    require("custom/myTes3mp/challenge")
end

require("custom/myTes3mp/vendors")

if settings.uniqueClaims then
    require("custom/myTes3mp/uniques")
end

if settings.regen then
    require("custom/myTes3mp/regen")
end

if number(settings.downedSeconds) > 0 then
    require("custom/myTes3mp/downed")
end

if settings.travel then
    require("custom/myTes3mp/travel")
end

if settings.bank then
    require("custom/myTes3mp/bank")
end

if settings.shareQuests then
    require("custom/myTes3mp/sharequest")
end

if number(settings.worldBossHours) > 0 then
    require("custom/myTes3mp/bosses")
end

return settings
