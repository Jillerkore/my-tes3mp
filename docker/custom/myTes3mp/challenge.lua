-- Challenge: enemies that keep up with the party.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Choose a preset with TES3MP_CHALLENGE
-- (off, normal, hard, brutal).
--
-- Morrowind gets easier the further you get, and two players make it easier
-- still. This pushes back in the two ways a TES3MP server can:
--
--   * Health. Everything that is not a player or a summon gets more health:
--     more the higher the highest-level player online, and more again for
--     every extra player who is in the cell when the enemy is first met. An
--     errand on your own stays doable; a dungeon together needs both of you.
--   * Damage. Each player's difficulty setting rises with his own level. The
--     game uses it to scale up the damage he takes, which is the closest
--     thing the engine has to giving every enemy better skills. (It also
--     scales down the damage he deals, but in multiplayer only against
--     enemies his own game client happens to control.)
--
-- What it cannot do: TES3MP has no way to change an existing NPC's level or
-- skills over the network, so those numbers stay what the game data says.
--
-- How the health part works. A game client reports the health of the enemies
-- it controls to the server, but the server tells its scripts nothing about
-- it; the numbers can only be read out of the cell. So every few seconds the
-- script reads them for every cell somebody is in, and for each enemy it has
-- not dealt with yet sends a console command for exactly that enemy
-- ("SetHealth N") to the client that controls it. The enemy is marked as done
-- in the cell's data, so it happens once per enemy until the cell is reset -
-- an enemy first met alone stays as it is if your brother walks in later.
-- Sending health values directly would not work: a client ignores them for
-- enemies it controls itself.

local settings = require("custom/myTes3mp/settings")

local challenge = {}

-- health:     multiplier at level 1, and how much it grows per player level
-- group:      how much more for each player in the cell beyond the first
--             (0.5 = half as much again with two players there)
-- difficulty: the game's difficulty slider (-100..100) at level 1, growth per
--             level, and where it stops. At 50 a player takes 3.5 times the
--             damage and deals 0.9 times; at 100, 6 times and 0.8 times.
challenge.presets = {
    normal = { health = 1.25, healthPerLevel = 0.03, group = 0.25,
               difficulty = 0,  difficultyPerLevel = 1, difficultyMax = 40 },
    hard   = { health = 1.5,  healthPerLevel = 0.05, group = 0.5,
               difficulty = 5,  difficultyPerLevel = 2, difficultyMax = 70 },
    brutal = { health = 2.0,  healthPerLevel = 0.08, group = 0.75,
               difficulty = 20, difficultyPerLevel = 3, difficultyMax = 100 }
}

-- No enemy gets more than this many times its normal health.
challenge.healthCap = 5

challenge.preset = challenge.presets[settings.challenge]

local function log(message)
    tes3mp.LogMessage(enumerations.log.INFO, "[my-tes3mp challenge] " .. message)
end

local function levelOf(player)
    if type(player.data.stats) == "table" then
        return tonumber(player.data.stats.level) or 1
    end
    return 1
end

-- Health multiplier for enemies met right now. The level part is set by the
-- highest-level player online, so nobody can keep a low-level character
-- around to make the world soft. playersInCell is how many players have the
-- enemy's cell loaded (1 when left out).
challenge.HealthMultiplier = function(playersInCell)
    local preset = challenge.preset
    local highest = 1
    for _, player in pairs(Players) do
        if player ~= nil and player:IsLoggedIn() then
            highest = math.max(highest, levelOf(player))
        end
    end
    local others = math.max(0, (tonumber(playersInCell) or 1) - 1)
    local multiplier = (preset.health + preset.healthPerLevel * (highest - 1)) * (1 + preset.group * others)
    return math.min(challenge.healthCap, multiplier)
end

challenge.DifficultyFor = function(level)
    local preset = challenge.preset
    return math.min(preset.difficultyMax, preset.difficulty + preset.difficultyPerLevel * (level - 1))
end

-- Give one player the difficulty that goes with his level.
challenge.ApplyDifficulty = function(pid)
    local player = Players[pid]
    if player == nil or not player:IsLoggedIn() then
        return
    end
    local wanted = challenge.DifficultyFor(levelOf(player))
    if player.data.settings.difficulty ~= wanted then
        player.data.settings.difficulty = wanted
        player:LoadSettings()
        player:QuicksaveToDrive()
        log(player.accountName .. " (level " .. levelOf(player) .. ") now plays at difficulty " .. wanted)
    end
end

if challenge.preset ~= nil then

    customEventHooks.registerHandler("OnPlayerAuthentified", function(eventStatus, pid)
        challenge.ApplyDifficulty(pid)
    end)

    customEventHooks.registerHandler("OnPlayerLevel", function(eventStatus, pid)
        challenge.ApplyDifficulty(pid)
    end)

    -- Deal with the enemies of one cell that have not been dealt with yet.
    challenge.ToughenCell = function(cellDescription, cell)
        local authority = cell:GetAuthority()
        if authority == nil or Players[authority] == nil or not Players[authority]:IsLoggedIn() then
            return
        end

        -- Copies what the controlling client last reported into the cell's
        -- data (objectData[...].stats, listed in packets.statsDynamic).
        cell:SaveActorStatsDynamic()
        if type(cell.data.packets) ~= "table" or type(cell.data.packets.statsDynamic) ~= "table" then
            return
        end

        local multiplier = challenge.HealthMultiplier(cell:GetVisitorCount())
        local changed = false

        for _, uniqueIndex in pairs(cell.data.packets.statsDynamic) do
            local object = cell.data.objectData[uniqueIndex]

            if type(object) == "table" and type(object.stats) == "table" and
                object.myTes3mpChallenge == nil and object.summon == nil then

                local base = tonumber(object.stats.healthBase) or 0
                local current = tonumber(object.stats.healthCurrent) or 0

                -- Leave the dead alone, and anything not at full health:
                -- SetHealth also heals, and an enemy must not get its health
                -- back in the middle of a fight. It is picked up on a later
                -- look if it is ever at full strength again.
                if base > 0 and current >= base then
                    object.myTes3mpChallenge = multiplier
                    changed = true
                    if multiplier > 1 then
                        local health = math.floor(base * multiplier + 0.5)
                        logicHandler.RunConsoleCommandOnObjects(authority, "SetHealth " .. health,
                            cellDescription, { uniqueIndex }, false)
                    end
                end
            end
        end

        if changed then
            cell:QuicksaveToDrive()
        end
    end

    -- How often to look, in seconds. Short enough that enemies are dealt
    -- with between walking into a cell and reaching them.
    challenge.checkSeconds = 5

    local checkTimerId

    function MyTes3mpChallengeTick()
        for cellDescription, cell in pairs(LoadedCells) do
            -- One cell's trouble must not stop the others, or the next look.
            local ok, problem = pcall(challenge.ToughenCell, cellDescription, cell)
            if not ok then
                tes3mp.LogMessage(enumerations.log.ERROR, "[my-tes3mp challenge] " .. cellDescription ..
                    ": " .. tostring(problem))
            end
        end
        tes3mp.RestartTimer(checkTimerId, time.seconds(challenge.checkSeconds))
    end

    customEventHooks.registerHandler("OnServerPostInit", function(eventStatus)
        checkTimerId = tes3mp.CreateTimer("MyTes3mpChallengeTick", time.seconds(challenge.checkSeconds))
        tes3mp.StartTimer(checkTimerId)
        log("Loaded: preset '" .. settings.challenge .. "' - enemy health x" .. challenge.preset.health ..
            " and difficulty " .. challenge.preset.difficulty .. " at level 1, rising with player level")
    end)
end

return challenge
