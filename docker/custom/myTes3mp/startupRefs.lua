-- Objects that Morrowind's "Startup" script hides when a new game begins:
-- people and things that only appear once a quest brings them into the world.
--
-- Generated from Morrowind.esm (the Startup script and the cell records); do
-- not edit by hand. A cell reset puts a cell back into the state the data
-- files describe, in which these objects are visible, so resets.lua hides
-- them again for the cells it resets.
--
--   [cell description] = { [uniqueIndex] = refId, ... }
--
-- One id, misc_com_metal_plate_07_UNI2, exists twice in the game; only the
-- copy that belongs to the scene the script sets up (Balyn Omarel's house) is
-- listed.
--
-- Cell descriptions and unique indexes ("<refNum>-0") are in the form TES3MP
-- uses in its cell files.

return {
    ["-11, 15"] = {
        ["76990-0"] = "slaughterfish_hr_sfavd",
    },
    ["-11, 9"] = {
        ["465767-0"] = "fedris tharen",
    },
    ["-12, 11"] = {
        ["297845-0"] = "Dreamer_Talker09",
    },
    ["-2, -3"] = {
        ["297839-0"] = "Dreamer_Talker01",
    },
    ["-2, -8"] = {
        ["297840-0"] = "Dreamer_Talker05",
    },
    ["-2, 5"] = {
        ["297838-0"] = "Dreamer_Talker03",
    },
    ["-2, 6"] = {
        ["440215-0"] = "ano vando",
    },
    ["-3, -8"] = {
        ["474443-0"] = "agronian guy",
    },
    ["-4, 12"] = {
        ["297841-0"] = "Dreamer_Talker08",
    },
    ["-5, -5"] = {
        ["408977-0"] = "Fjorgeir",
    },
    ["-5, 9"] = {
        ["450955-0"] = "Assimusa Samsi",
    },
    ["-6, -5"] = {
        ["297842-0"] = "Dreamer_Talker07",
    },
    ["-8, 16"] = {
        ["297843-0"] = "Dreamer_Talker10",
    },
    ["-8, 2"] = {
        ["288983-0"] = "dreynis nothro",
        ["288984-0"] = "vala herennius",
        ["288985-0"] = "farvyn oreyn",
        ["482626-0"] = "netch_bull_dead_2",
    },
    ["-8, 3"] = {
        ["297844-0"] = "Dreamer_Talker06",
    },
    ["-9, 2"] = {
        ["288982-0"] = "netch_bull_dead",
    },
    ["-9, 4"] = {
        ["320831-0"] = "Ex_DAE_Boethiah_fixed",
        ["320832-0"] = "Ex_DAE_r_platform_01_boe",
        ["335099-0"] = "misc_com_bucket_boe_UNI",
        ["335100-0"] = "misc_com_bucket_boe_UNIa",
        ["335101-0"] = "ex_de_scaffold_01a_Boe",
        ["335102-0"] = "ex_de_scaffold_02_boe",
        ["335103-0"] = "ex_de_scaffold_02b_boe",
        ["335104-0"] = "ex_de_scaffold_03a_boe",
        ["335105-0"] = "ex_de_scaffold_03_boe",
        ["335106-0"] = "ex_de_scaffold_01_Boe",
        ["335107-0"] = "ex_de_scaffold_02a_boe",
        ["363119-0"] = "duma gro-lag2",
        ["390570-0"] = "dumburz gro-bulfish",
        ["390571-0"] = "shulonk gro-azorku",
        ["390572-0"] = "ugdumph gro-lumbuk",
        ["390573-0"] = "lazgar gra-durog",
        ["390574-0"] = "misc_com_bucket_boe_UNIb",
        ["390575-0"] = "ex_de_scaffold_02c_boe",
    },
    ["0, -9"] = {
        ["297837-0"] = "Dreamer_Talker04",
    },
    ["0, 22"] = {
        ["84465-0"] = "ulyne henim",
    },
    ["1, 24"] = {
        ["288976-0"] = "Netch_Giant_UNIQUE",
    },
    ["15, 5"] = {
        ["192881-0"] = "falura llervu",
    },
    ["17, -6"] = {
        ["369110-0"] = "Larienna Macrina",
    },
    ["2, 23"] = {
        ["480888-0"] = "ogrim_az",
    },
    ["2, 4"] = {
        ["369112-0"] = "assantushansar",
    },
    ["3, -9"] = {
        ["399159-0"] = "tarvyn faren",
    },
    ["3, 23"] = {
        ["480883-0"] = "daedroth_az",
        ["480884-0"] = "hunger_az_01",
        ["480885-0"] = "hunger_az_02",
        ["480886-0"] = "atronach_storm_az",
        ["480887-0"] = "atronach_flame_az",
    },
    ["3, 24"] = {
        ["330023-0"] = "golden saint_staada",
    },
    ["4, -9"] = {
        ["297836-0"] = "Dreamer_Talker11",
    },
    ["6, -7"] = {
        ["297835-0"] = "Dreamer_Talker12",
    },
    ["8, 15"] = {
        ["288951-0"] = "ashamanu",
    },
    ["9, -7"] = {
        ["111086-0"] = "bk_notefromsondaale",
    },
    ["9, 15"] = {
        ["289083-0"] = "guar_white_unique",
    },
    ["Ald-ruhn, Gindrala Hleran's House"] = {
        ["297846-0"] = "Dreamer_Talker02",
    },
    ["Ald-ruhn, Sarethi Manor"] = {
        ["108969-0"] = "redoran guard sarethi1",
        ["108970-0"] = "redoran guard sarethi2",
        ["281645-0"] = "arsyn salas",
        ["281646-0"] = "gragus lleran",
    },
    ["Ald-ruhn, The Rat In The Pot"] = {
        ["232005-0"] = "centurion_spider_tga1",
        ["232006-0"] = "centurion_spider_tga2",
    },
    ["Balmora, Balyn Omarel's House"] = {
        ["363128-0"] = "misc_com_wood_fork_UNI2",
        ["363129-0"] = "misc_com_wood_spoon_01_UNI2",
        ["363130-0"] = "misc_com_wood_knife_UNI2",
        ["363131-0"] = "misc_com_metal_plate_07_UNI2",
        ["363183-0"] = "furn_de_p_chair_02_UNI2",
        ["390587-0"] = "balyn omavel-DEAD",
        ["390592-0"] = "ingred_bread_01_UNI2",
    },
    ["Balmora, Eight Plates"] = {
        ["377937-0"] = "itermerel",
    },
    ["Bthuand"] = {
        ["440254-0"] = "spell_breaker_unique",
    },
    ["Cavern of the Incarnate"] = {
        ["251173-0"] = "ghost_npc_peakstar",
        ["251174-0"] = "ghost_npc_ane teria",
        ["251175-0"] = "ghost_npc_erur-dan",
        ["251176-0"] = "ghost_npc_idrenie nerot",
        ["251177-0"] = "ghost_npc_hort_ledd",
        ["251178-0"] = "ghost_npc_conoon chodal",
    },
    ["Ghostgate, Tower of Dusk"] = {
        ["468996-0"] = "wulf",
    },
    ["Gnaar Mok, Nadene Rotheran's Shack"] = {
        ["113442-0"] = "daren adryn",
    },
    ["Ilunibi, Soul's Rattle"] = {
        ["470765-0"] = "dagoth gares",
    },
    ["Indarys Manor, Berendas' House"] = {
        ["450963-0"] = "Heniele Milielle",
    },
    ["Kora-Dur"] = {
        ["365408-0"] = "daedroth_menta_unique",
    },
    ["Mamaea, Sanctum of Black Hope"] = {
        ["382941-0"] = "hannat zainsubani",
    },
    ["Nchurdamz, Interior"] = {
        ["469375-0"] = "daedroth_fg_nchur",
    },
    ["Rothan Ancestral Tomb"] = {
        ["270595-0"] = "mathis dalobar",
    },
    ["Sadrith Mora, Dirty Muriel's Cornerclub"] = {
        ["288320-0"] = "natalinus flavonius",
        ["377941-0"] = "tenyeminwe",
    },
    ["Sadrith Mora, Tel Naga Great Hall"] = {
        ["273970-0"] = "galmir",
        ["470833-0"] = "nartise arobar",
    },
    ["Sadrith Mora, Telvanni Council House"] = {
        ["465939-0"] = "enar releth",
    },
    ["Telasero, Lower Level"] = {
        ["127655-0"] = "sondaale of shimmerene",
    },
    ["Vivec, Arena Storage"] = {
        ["297921-0"] = "saprius entius",
    },
    ["Vivec, Foreign Quarter Underworks"] = {
        ["283175-0"] = "dreamer prophet",
    },
    ["Vivec, Hall of Wisdom"] = {
        ["482632-0"] = "key_Private Quarters",
    },
    ["Vivec, Hlaalu Prison Cells"] = {
        ["341055-0"] = "frelene acques",
    },
    ["Vivec, Jeanne: Trader"] = {
        ["440484-0"] = "dwarven ghost_jeanne_U",
    },
    ["Vivec, Milo's Quarters"] = {
        ["470785-0"] = "bk_NoteToAmaya",
    },
    ["Vivec, Ralen Tilvur: Smith"] = {
        ["408978-0"] = "drarel andus",
    },
    ["Vivec, St. Olms Underworks"] = {
        ["440486-0"] = "corprus_stalker_danar",
    },
    ["Vivec, Telvanni Enchanter"] = {
        ["440489-0"] = "hunger_audenian",
        ["440490-0"] = "bk_clientlist",
    },
}
