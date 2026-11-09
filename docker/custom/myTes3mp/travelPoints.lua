-- The places /travel can take you to: one arrival point for each town, port and
-- guild hall of Vvardenfell, for Mournhold and for Solstheim.
--
-- This file is managed by my-tes3mp: it is copied from the server image on
-- every start, so edits here are lost. Do not edit it by hand - it is generated
-- from the game's own data files (Morrowind.esm, Tribunal.esm, Bloodmoon.esm).
--
-- Where the points come from. Every silt strider, boat, gondola and Mages Guild
-- guide in the game carries a list of destinations, each with the exact spot
-- where the traveller is put down. Those spots are known to be safe (the game
-- uses them every time someone pays for a ride), so they are used as they are.
-- Destinations that land in the same place were merged into one point; the
-- names are the settlement's. Mournhold has a single arrival point, the one
-- the game's own transport script (MHTransportScript) uses.
--
--   name      what the player sees in the list
--   cell      the cell, as TES3MP describes it: "x, y" for the open world, the
--             cell's name for an interior
--   exterior  true for an "x, y" cell
--   pos, rot  where to put the player; rot is { 0, 0, rz } in radians. An open-
--             world destination is in world units: cell = floor(x / 8192), floor(y / 8192)
--
-- Player-facing use: travel.lua. Order here is the order of the list.

return {
    { name = "Ald-ruhn", cell = "-3, 6", exterior = true,  pos = { -17641.51, 54701.18, 2863.45 }, rot = { 0, 0, 1.5708 } },
    { name = "Balmora", cell = "-3, -3", exterior = true,  pos = { -21320.67, -18233.11, 1179.03 }, rot = { 0, 0, 0 } },
    { name = "Dagon Fel", cell = "7, 22", exterior = true,  pos = { 62677.8, 184289.77, 186.24 }, rot = { 0, 0, 3.1416 } },
    { name = "Ebonheart", cell = "2, -13", exterior = true,  pos = { 20380.3, -102414.15, 183.51 }, rot = { 0, 0, 0 } },
    { name = "Gnaar Mok", cell = "-8, 3", exterior = true,  pos = { -58674.82, 26485.35, 185.77 }, rot = { 0, 0, 4.7124 } },
    { name = "Gnisis", cell = "-11, 10", exterior = true,  pos = { -86782.37, 89454.35, 1124.33 }, rot = { 0, 0, 0 } },
    { name = "Hla Oad", cell = "-6, -5", exterior = true,  pos = { -48493.73, -39754.04, 187.78 }, rot = { 0, 0, 1.4 } },
    { name = "Khuul", cell = "-9, 16", exterior = true,  pos = { -65872.72, 135522.27, 1101.98 }, rot = { 0, 0, 1.4 } },
    { name = "Khuul, Docks", cell = "-9, 17", exterior = true,  pos = { -69427.67, 142115.75, 192.25 }, rot = { 0, 0, 3.0416 } },
    { name = "Maar Gan", cell = "-3, 12", exterior = true,  pos = { -22371.02, 100115.59, 2519.4 }, rot = { 0, 0, 0 } },
    { name = "Molag Mar", cell = "12, -8", exterior = true,  pos = { 103449.02, -58402.79, 1545.54 }, rot = { 0, 0, 1.2 } },
    { name = "Molag Mar, Docks", cell = "13, -8", exterior = true,  pos = { 113960.16, -61257.71, 761.31 }, rot = { 0, 0, 4.7124 } },
    { name = "Sadrith Mora", cell = "17, 4", exterior = true,  pos = { 141877.86, 38637.31, 337.97 }, rot = { 0, 0, 3.0832 } },
    { name = "Seyda Neen", cell = "-2, -9", exterior = true,  pos = { -8680.87, -70138.66, 923.3 }, rot = { 0, 0, 0.4 } },
    { name = "Suran", cell = "6, -6", exterior = true,  pos = { 53158.79, -48228.83, 984.14 }, rot = { 0, 0, 3.1416 } },
    { name = "Tel Aruhn", cell = "15, 5", exterior = true,  pos = { 123304.72, 41165.22, 178.4 }, rot = { 0, 0, 0.9 } },
    { name = "Tel Branora", cell = "14, -13", exterior = true,  pos = { 119148.26, -102117.84, 151.49 }, rot = { 0, 0, 2.8416 } },
    { name = "Tel Mora", cell = "13, 14", exterior = true,  pos = { 106924.68, 117168.76, 263.7 }, rot = { 0, 0, 0.6 } },
    { name = "Vivec", cell = "3, -9", exterior = true,  pos = { 32206.38, -72225.12, 1006.66 }, rot = { 0, 0, 4.7124 } },
    { name = "Vivec, Arena Canton", cell = "4, -11", exterior = true,  pos = { 33022.46, -88001.45, 132.44 }, rot = { 0, 0, 3.1416 } },
    { name = "Vivec, Foreign Quarter Canal", cell = "3, -10", exterior = true,  pos = { 28829.27, -76725.49, 157.25 }, rot = { 0, 0, 4.7124 } },
    { name = "Vivec, Foreign Quarter Harbor", cell = "4, -10", exterior = true,  pos = { 35749, -74467.49, 189.11 }, rot = { 0, 0, 4.2832 } },
    { name = "Vivec, Hlaalu Canton", cell = "2, -11", exterior = true,  pos = { 22611.47, -87935.92, 107.38 }, rot = { 0, 0, 1.5708 } },
    { name = "Vivec, Telvanni Canton", cell = "5, -11", exterior = true,  pos = { 42594.23, -87906.08, 145.75 }, rot = { 0, 0, 1.5708 } },
    { name = "Vivec, Temple Canton", cell = "3, -13", exterior = true,  pos = { 30127.57, -98356.55, 172.54 }, rot = { 0, 0, 3.1416 } },
    { name = "Vos", cell = "12, 13", exterior = true,  pos = { 100663.22, 114038.51, 254.09 }, rot = { 0, 0, 3.8832 } },
    { name = "Ald-ruhn, Guild of Mages", cell = "Ald-ruhn, Guild of Mages", exterior = false,  pos = { 2597.47, -511.15, -265.33 }, rot = { 0, 0, 4.7124 } },
    { name = "Balmora, Guild of Mages", cell = "Balmora, Guild of Mages", exterior = false,  pos = { -755.9, -1002.73, -644.63 }, rot = { 0, 0, 0.7854 } },
    { name = "Caldera, Guild of Mages", cell = "Caldera, Guild of Mages", exterior = false,  pos = { 521.44, 335.16, 489.77 }, rot = { 0, 0, 1.5708 } },
    { name = "Sadrith Mora, Mages Guild", cell = "Sadrith Mora, Wolverine Hall: Mage's Guild", exterior = false,  pos = { -30.28, 212.14, 158.24 }, rot = { 0, 0, 0.7854 } },
    { name = "Vivec, Guild of Mages", cell = "Vivec, Guild of Mages", exterior = false,  pos = { 3.56, 1393.26, -390.2 }, rot = { 0, 0, 3.1416 } },
    { name = "Mournhold, Royal Palace", cell = "Mournhold, Royal Palace: Reception Area", exterior = false,  pos = { 2.73, 959.27, -105.82 }, rot = { 0, 0, 3.1416 } },
    { name = "Fort Frostmoth (Solstheim)", cell = "-22, 16", exterior = true,  pos = { -174024.39, 136823.95, 457.67 }, rot = { 0, 0, 4.6832 } },
    { name = "Raven Rock (Solstheim)", cell = "-25, 19", exterior = true,  pos = { -199408.56, 157218.91, 435.13 }, rot = { 0, 0, 5.7664 } },
}
