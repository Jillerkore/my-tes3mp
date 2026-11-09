-- Entry point of the scripts my-tes3mp adds to the server.
--
-- This directory (scripts/custom/myTes3mp/) is managed: the container
-- replaces it from the image on every start, and writes settings.lua from the
-- TES3MP_* environment variables. Do not edit files here - change .env
-- instead, or set TES3MP_PROGRESSION=custom and TES3MP_STRONGHOLD_HELPER=false
-- to switch all of it off and run scripts/config.lua exactly as you wrote it.
--
-- It is loaded by this line in scripts/customScripts.lua, which the container
-- adds if it is missing:
--
--   require("custom/myTes3mp/init")

local settings = require("custom/myTes3mp/settings")

if settings.strongholdHelper then
    require("custom/myTes3mp/strongholds")
end

return settings
