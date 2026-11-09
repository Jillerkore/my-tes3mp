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
--
-- It is loaded by this line in scripts/customScripts.lua, which the container
-- adds if it is missing:
--
--   require("custom/myTes3mp/init")

local settings = require("custom/myTes3mp/settings")

require("custom/myTes3mp/world")

if settings.strongholdHelper then
    require("custom/myTes3mp/strongholds")
end

if (tonumber(settings.cellResetHours) or 0) > 0 then
    require("custom/myTes3mp/resets")
end

return settings
