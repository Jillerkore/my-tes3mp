# Maintaining my-tes3mp

This project is a thin layer on top of two upstream projects. Keeping that
layer thin is what keeps it maintainable, so the rules below matter more than
any single feature.

## How it is put together

| Layer | Where it comes from | Where it is pinned |
| --- | --- | --- |
| TES3MP server binary | upstream release tarball | `docker/Dockerfile` (`TES3MP_VERSION`, URL, checksum) |
| TES3MP game client | upstream release tarball | `scripts/lib.sh` (version, URL, checksum) |
| CoreScripts (the server's game rules, in Lua) | upstream git, branch `0.8.1` | `docker/Dockerfile` (`CORESCRIPTS_COMMIT`) |
| my-tes3mp's own rules | `docker/custom/myTes3mp/*.lua` in this repository | — |

**Nothing upstream is ever edited.** There is no patched copy of CoreScripts
in this repository and no fork of it to rebase. Everything my-tes3mp adds is a
set of ordinary CoreScripts custom scripts, loaded through the one extension
point upstream provides (`customScripts.lua`), that react to events and set
`config` values at load time. An upstream update is therefore a one-line
change of a pin, not a merge.

Each feature is one file with a header that explains what it does and why,
and one switch in `.env` that turns it off:

| File | Feature | Switch |
| --- | --- | --- |
| `settings.lua` (generated at start) | progression mode and every other setting | `TES3MP_*` |
| `world.lua` | day length, first-login world setup | `TES3MP_DAY_MINUTES` |
| `party.lua` | everybody is allied | `TES3MP_PARTY` |
| `strongholds.lua` | Great House strongholds for every player | `TES3MP_STRONGHOLD_HELPER` |
| `resets.lua` | the world heals, with exceptions | `TES3MP_CELL_RESET_HOURS`, `TES3MP_CELL_RESET_KEEP` |
| `challenge.lua` | tougher enemies that keep up with the party | `TES3MP_CHALLENGE` |
| `vendors.lua` | merchant gold and stock come back | `TES3MP_VENDOR_GOLD_MINUTES`, `TES3MP_VENDOR_STOCK_SECONDS` |
| `uniques.lua` | artifacts once per player | `TES3MP_UNIQUE_CLAIMS`, `TES3MP_UNIQUE_RESPAWN_MINUTES` |
| `startupRefs.lua`, `uniqueItems.lua` | data generated from the game files | — |

When adding a feature, keep to that shape: a new file, a header, a switch, a
test. If a feature seems to need a change inside CoreScripts, look for an
event hook or a validator first; there has always been one so far.

## Taking an upstream CoreScripts update

A weekly GitHub Actions job (`.github/workflows/upstream.yml`) does this by
itself: when upstream's `0.8.1` branch has moved, it runs the tests and boots
the server against the new commit, and opens a pull request that moves the
pin. Read the linked upstream changes, merge, release.

By hand:

```bash
scripts/bump-corescripts.sh --check   # has upstream moved?
scripts/bump-corescripts.sh           # move the pin, print the upstream diff link
make test                             # unit tests against the new scripts
docker compose up -d --build --wait   # does the server still boot cleanly?
```

What to look for in the upstream diff: changes to the events and functions
the scripts here lean on. Each script's header names the mechanism it uses;
the test suite in `tests/` exercises them against the real CoreScripts code,
so a breaking change normally shows up as a failing test.

## Taking a new TES3MP release

A new TES3MP release changes the binary, the client and usually the script
API together:

1. `docker/Dockerfile`: `TES3MP_VERSION`, the tarball URL and checksum, and
   `CORESCRIPTS_COMMIT` from the matching upstream branch.
2. `scripts/bump-corescripts.sh`: `BRANCH`.
3. `scripts/lib.sh`: the client version, URL and checksum.
4. `docker-compose.yml` and `my-tes3mp`: the default image tag.
5. Run the tests and play a session before releasing. This is a major
   version: old clients cannot join a new server.

## How updates reach servers that are already running

`./my-tes3mp update` (or `docker compose pull && docker compose up -d` with a
published image) replaces the image. On the next start the container:

- always replaces `scripts/custom/myTes3mp/` in the data volume with the
  image's copy and regenerates `settings.lua` from the environment, so
  my-tes3mp's own rules are never stale;
- replaces the CoreScripts in the volume too, if they are still exactly what
  was seeded (it keeps checksums to know). The admin's own additions —
  `scripts/custom/` and `scripts/customScripts.lua` — are carried over and
  the old scripts are kept as `scripts.previous/`;
- leaves hand-edited CoreScripts alone and says so in the log on every start.

The world and characters in `data/` are never touched by an update. State
that my-tes3mp keeps for itself lives in `data/custom/myTes3mp*.json`.

## Tests

```bash
make lint    # shellcheck
make test    # Lua unit tests: the scripts here against the real CoreScripts
```

The Lua tests load the pinned CoreScripts and the scripts in
`docker/custom/myTes3mp/` into a plain LuaJIT with the game server's API
stubbed out, and play through scenarios: a stronghold being built by two
players, a cell coming due while someone stands in it, an artifact being
taken twice. They cannot tell you what a real game client does on screen —
play a session for that — but they catch logic errors and upstream API drift.

## Releasing

1. Update `VERSION` and add a section to `CHANGELOG.md`.
2. Commit, then `git tag "v$(cat VERSION)"`.
3. `git push origin main --tags`.

The tag makes GitHub Actions publish the server image as
`ghcr.io/<owner>/my-tes3mp:<version>` and create a GitHub Release whose notes
are that version's changelog section.
