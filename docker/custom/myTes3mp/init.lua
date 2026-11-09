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
--
-- It is loaded by this line in scripts/customScripts.lua, which the container
-- adds if it is missing:
--
--   require("custom/myTes3mp/init")

local settings = require("custom/myTes3mp/settings")

require("custom/myTes3mp/world")

if settings.party then
    require("custom/myTes3mp/party")
end

if settings.strongholdHelper then
    require("custom/myTes3mp/strongholds")
end

-- Before uniques: it brings resets forward through this one.
if (tonumber(settings.cellResetHours) or 0) > 0 then
    require("custom/myTes3mp/resets")
end

if settings.challenge ~= "off" then
    require("custom/myTes3mp/challenge")
end

require("custom/myTes3mp/vendors")

if settings.uniqueClaims then
    require("custom/myTes3mp/uniques")
end

return settings
