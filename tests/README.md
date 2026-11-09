# Tests for the my-tes3mp server scripts

Unit-level tests for the Lua scripts in `docker/custom/myTes3mp/` (strongholds,
resets, world, challenge, vendors, uniques, party, and the loader `init.lua`).
They run the **unmodified scripts** under LuaJIT against the **real CoreScripts**
at the commit pinned in `docker/Dockerfile`, with the game server itself faked.

## Running

    tests/run.sh                 # all suites, one line each, then a total
    tests/run.sh -v              # also print every check
    tests/run.sh uniques init    # only some suites ("uniques" or "test_uniques")

Works from any directory. Exit status is non-zero if any check fails or any
suite errors. The first run fetches CoreScripts (`git fetch --depth 1` of the
pinned commit) into `tests/.cache/corescripts-<commit>/`; later runs reuse it.
Bumping `CORESCRIPTS_COMMIT` in the Dockerfile makes the next run fetch the new one.

If `luajit` and `git` are on `PATH` they are used directly (CI: `apt-get install
luajit`). Otherwise `run.sh` runs the same thing in a throwaway
`debian:trixie-slim` container (needs docker; the repo is mounted read-only).

## What is real and what is faked

Real (loaded from the CoreScripts checkout): `customEventHooks`,
`customCommandHooks`, `tableHelper`, `inventoryHelper`, `jsonInterface` (over
dkjson), `packetBuilder`, `config`, `enumerations`, the cell classes
(`cell/base.lua`, `cell/json.lua`: `SaveContainers`, `LoadContainers`,
`SaveObjectStates`, `SaveActorStatsDynamic`, `AddVisitor`, ...), and in
`test_world.lua` the `World` class.

Faked, all in `harness.lua`:

* `tes3mp` - the C++ API. Getters read what a test put in `T.packet` /
  `T.actors`; senders record what they were asked to send. Unknown functions are no-ops.
* The disk - `jsonInterface` writes to an in-memory table (`T.disk`), so a
  "restart" is: keep `T.disk`, call `T.fresh()` again.
* The clock (`os.time` is `T.time`), timers (recorded; `T.fire(id)` runs the
  callback), players (`T.player`), `logicHandler.LoadCell/UnloadCell` (copied
  from CoreScripts), console commands, record stores.
* The client. A test plays the part of the game client by calling the event
  helpers - `T.container`, `T.objectDelete`, `T.barter`, `T.visit`, `T.auth` -
  which raise events in the order `eventHandler.lua` does (validators, default
  handler, custom handlers).

## What it cannot tell you

* How the real client behaves. Facts about it (a pick-up happens before the server
  is asked, a container take only completes on the server's echo, ...) were read
  from the TES3MP client source and are encoded in the helpers; the suite cannot
  check them. Likewise network timing, packet order across channels and server crashes.
* Whether `eventHandler.lua` calls the hooks the way the helpers assume. The suite
  does check that every event name the scripts register for is one CoreScripts
  raises (`test_init.lua`, E1), which catches the commonest mistake.
* That the `tes3mp` functions the scripts call exist with those arguments - the
  stub accepts any. CI's server start-up check is the only guard.
* Real file I/O, cjson encoding, Docker, `entrypoint.sh` behaviour (only that it
  writes the settings keys).

## Adding a test

1. Put checks in the `test_<script>.lua` of the script they concern (or add a new
   `test_<name>.lua`; `run.sh` picks up every `test_*.lua`).
2. Start a file with the three-line prelude used by the others, `local T = require("harness")`,
   call `T.fresh(settings)` for a clean server, `T.load("<script>")` to load a script
   and `T.postInit()` to raise `OnServerPostInit`. Settings default to
   `T.DEFAULT_SETTINGS`; copy and change it with `T.copy`.
3. Report with `T.report(name, ok, detail)`; end with `T.summary()`, which prints
   `N checks, M fail` (run.sh depends on that line) and sets the exit status.
4. A check for behaviour that is wrong must fail, not be rewritten to pass. If a
   limitation is accepted on purpose, assert the actual behaviour and say why in a
   comment next to the check.
