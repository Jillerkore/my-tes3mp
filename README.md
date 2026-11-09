# my-tes3mp

Morrowind multiplayer in one command.

`my-tes3mp` wraps [TES3MP](https://github.com/TES3MP/TES3MP) 0.8.1 — the
multiplayer fork of OpenMW — so that hosting a server, joining it, and moving
it to another machine are each a single command. The server runs in Docker;
the game client is downloaded and configured for you from your existing
Morrowind install.

```console
$ ./my-tes3mp
==> Starting the TES3MP server
==> Launching Morrowind — connecting to localhost:25565
```

## What you need

- **Linux, x86_64.** Developed on Pop!_OS 24.04; anything recent with glibc
  should do.
- **Docker** with the compose plugin, for the server.
- **Your own copy of Morrowind** (Steam or GOG, with Tribunal and Bloodmoon),
  installed anywhere, for the client. No game data ships with this repository.

A machine that only hosts needs only Docker — not the game.

## Play

```bash
git clone https://github.com/Jillerkore/my-tes3mp.git
cd my-tes3mp
./my-tes3mp
```

The first run takes a minute or two. It:

1. downloads the TES3MP client into `.runtime/` and verifies its checksum,
2. finds Morrowind through your Steam libraries and writes an OpenMW config
   that points at it,
3. builds the server image and starts the server in the background,
4. launches the game, already connected.

Every run after that goes straight to step 4. When you quit the game the
server keeps running for your friends; `./my-tes3mp stop` shuts it down.

The game takes over the mouse and keyboard while it is open, like any
fullscreen game. Quit from its menu (Esc, then Exit). To keep the cursor free
while you try things out, run `./my-tes3mp play -- --no-grab`.

If Morrowind is somewhere the script does not look, tell it:

```bash
MORROWIND_DATA="/path/to/Morrowind/Data Files" ./my-tes3mp
```

or put that line in `.env`.

### Friends joining you

They clone this repository too, then:

```bash
./my-tes3mp join YOUR.IP.ADDRESS            # add :PORT if you changed it
./my-tes3mp join YOUR.IP.ADDRESS --password hunter2
```

`./my-tes3mp status` prints the addresses to hand out. On the same network
that is all it takes. Over the internet, forward **UDP port 25565** on your
router to the hosting machine — or skip the router and
[put the server on a VPS](#host-it-somewhere-else).

Players on Windows or macOS can connect with the stock
[TES3MP 0.8.1 release](https://github.com/TES3MP/TES3MP/releases/tag/tes3mp-0.8.1);
they need the same three game files (Morrowind, Tribunal, Bloodmoon), with
no other plugins enabled.

## Commands

| Command | What it does |
| --- | --- |
| `./my-tes3mp` | Start the server if needed, then launch the game connected to it |
| `./my-tes3mp join HOST[:PORT]` | Connect to a server somewhere else |
| `./my-tes3mp host` | Start the server only |
| `./my-tes3mp stop` | Stop the server; the world and characters are kept |
| `./my-tes3mp status` | Is it running, and at which addresses |
| `./my-tes3mp logs -f` | Follow the server log |
| `./my-tes3mp backup` | Save everything to `backups/` on this machine |
| `./my-tes3mp backups` | List the backups the server makes by itself, daily |
| `./my-tes3mp restore FILE` | Bring a backup back: a file, or a name from `backups` |
| `./my-tes3mp update` | Rebuild the image and restart |
| `./my-tes3mp deploy USER@HOST` | Run the server on another machine over SSH |
| `./my-tes3mp help` | Everything else |

`make play`, `make host`, `make stop` and friends are aliases for the same.

## Settings

Copy `.env.example` to `.env` and edit. Run `./my-tes3mp host` afterwards to
apply.

| Variable | Default | |
| --- | --- | --- |
| `TES3MP_SERVER_NAME` | `my-tes3mp` | Name shown to players |
| `TES3MP_PORT` | `25565` | UDP port on the host |
| `TES3MP_MAX_PLAYERS` | `16` | |
| `TES3MP_PASSWORD` | *(none)* | Players must pass `--password` to join |
| `TES3MP_MASTER_ENABLED` | `false` | `true` lists the server in the public TES3MP browser |
| `TES3MP_PROGRESSION` | `separate` | `separate`, `shared` or `custom` — see [Playing together, separately](#playing-together-separately) |
| `TES3MP_STRONGHOLD_HELPER` | `true` | Lets every player build his own Great House stronghold |
| `TES3MP_CELL_RESET_HOURS` | `4` | Real hours until a visited cell is put back to its original state; `0` = never — see [The world heals](#the-world-heals) |
| `TES3MP_CELL_RESET_KEEP` | *(none)* | More cells that never reset: names or parts of names, separated by `;` |
| `TES3MP_DAY_MINUTES` | `10` | Real minutes per in-game day (stock TES3MP: about 45); `0` = leave alone |
| `TES3MP_PARTY` | `true` | All players are allies automatically |
| `TES3MP_CHALLENGE` | `hard` | `off`, `normal`, `hard` or `brutal` — see [Tougher together](#tougher-together) |
| `TES3MP_VENDOR_GOLD_MINUTES` | `1` | Real minutes until a merchant's gold is back; `0` = the game's own 24 in-game hours |
| `TES3MP_VENDOR_STOCK_SECONDS` | `15` | Seconds until a merchant's wares are back; `0` = never |
| `TES3MP_UNIQUE_CLAIMS` | `true` | Artifacts and unique items can be taken once per player |
| `TES3MP_UNIQUE_RESPAWN_MINUTES` | `30` | How soon a claimed item's cell resets for the players still missing it |
| `TES3MP_SHARE_MAP` | `true` | What one player explores shows on everyone's map |
| `TES3MP_REGEN` | `true` | Health and magicka return by themselves out of combat |
| `TES3MP_DOWNED_SECONDS` | `60` | How long a fallen player can be revived by another; `0` = no downed state |
| `TES3MP_TRAVEL` | `true` | Travel network, `/goto`, `/party` |
| `TES3MP_BANK` | `true` | `/bank` and `/vault` |
| `TES3MP_SHARE_QUESTS` | `true` | `/sharequest` |
| `TES3MP_WORLD_BOSS_HOURS` | `3` | Real hours between world bosses; `0` = none |
| `TES3MP_BACKUP_HOURS` | `24` | Hours between the server's own backups; `0` = none |
| `TES3MP_BACKUP_KEEP` | `7` | How many of those to keep |
| `TES3MP_LOG_LEVEL` | `1` | 0 verbose … 4 fatal only |
| `TES3MP_IMAGE` | `my-tes3mp-server:0.8.1` | A registry image to run instead of building; fetch it with `docker compose pull` |
| `MORROWIND_DATA` | *(auto-detected)* | Path to Morrowind's `Data Files` (client only) |

## Playing together, separately

Stock TES3MP treats everyone on a server as one party: a quest one player
finishes is finished for all, and joining a faction joins everybody. This
server defaults to the opposite, `TES3MP_PROGRESSION=separate`:

| Each player's own | One world for everyone |
| --- | --- |
| Journal and quest progress, including the main quest | Who is alive and who is dead |
| Faction membership, ranks and reputation (so different Great Houses) | What is in a container or lying on the floor |
| Dialogue topics, reputation, bounty, map | Doors, levers, buildings |
| Kill counts | Time and weather |
| Inventory, gold, skills, level (always, in every mode) | |

The right-hand column would make separate playthroughs awkward — your
brother kills a quest-giver and he is dead in your game too — so the world
also heals itself.

### The world heals

Four real hours (`TES3MP_CELL_RESET_HOURS`) after a cell is first visited, and
once nobody is in it, the server puts it back the way the game shipped: its
people alive, its loot back, its doors locked. A cell is one interior, or one
square of the outdoor map. The next visit starts the clock again.

Some places never reset:

- **The three Great House strongholds**, inside and out.
- **Wherever you keep things.** Put items into any container by hand and the
  whole cell around it is left alone for as long as that container holds
  anything at all. Empty it completely and the cell goes back to resetting.
- **Anything you name** in `TES3MP_CELL_RESET_KEEP`, for example
  `Balmora, Caius Cosades' House; Vivec, Arena`.

What a reset does remove is anything left lying on the floor of a cell that is
not on that list. Store things in a container, not on a table.

In game, `/resetinfo` says what will happen to the cell you are standing in. A
moderator can reset a cell immediately with `/resetcell "Cell Name"`; to make
yourselves moderators, see [Admin rights](#admin-rights).

### Artifacts and unique items

There is one Umbra in the world. With the world healing itself he comes back,
which lets the second of you have the sword too — and would let the first of
you collect another one every few hours. So each of the 271 artifacts and
unique items of Morrowind, Tribunal and Bloodmoon can be taken from its
original place **once per player**:

- The first time you take one, it is yours, and the server tells you so.
- You cannot take a fresh copy again; it is left for the next player. (Out
  of a container the server simply refuses. Off the ground the game lets you
  pick it up first, so it is taken back out of your pack a moment later.)
- While another player still lacks it, the cell it came from resets after
  half an hour instead of four, so nobody waits long for his turn.
- Your own copy is never restricted. Drop it, store it, hand it to your
  brother.

`/uniques` in game lists what you have claimed.

Set `TES3MP_PROGRESSION=shared` for stock party-style play, or `custom` to
control every `config.share*` option yourself in `scripts/config.lua`.

### Tougher together

Morrowind gets easier the further you get, and two players make it easier
still. `TES3MP_CHALLENGE` pushes back:

| Preset | Enemy health | With a second player there | Damage you take | Meant for |
| --- | --- | --- | --- | --- |
| `off` | unchanged | unchanged | unchanged | the original game |
| `normal` | ×1.25, +3% per level | a quarter more | unchanged at first, growing slowly | a relaxed pair |
| `hard` | ×1.5, +5% per level | half as much again | clearly more, growing with your level | two people fighting side by side |
| `brutal` | ×2, +8% per level | three quarters more | a lot more | people who want to plan every fight |

Health follows the highest-level player online, and how many of you are in
the cell when an enemy is first met — an errand alone is lighter than a
dungeon together. The damage you take follows your own level. TES3MP cannot change an existing NPC's level or skills over
the network, so this is done with health and with the game's own difficulty
setting, which amounts to the same thing in a fight.

Everybody on the server is also in one party (`TES3MP_PARTY`): a stray swing
or spell between you is not held against anyone, you do not break each
other's sneaking, and kills you make together count for both of your quests.
(Hitting another player is never a crime in TES3MP and never turns guards on
you, party or not.)

### Merchants

A merchant's gold is back within a minute and his wares within fifteen
seconds of your last visit — things you sold him are gone again by then.
Artifacts are the exception: one that has been bought is not put back on the
shelf.

### Co-op comforts

Borrowed from how Elder Scrolls Online plays, each with its own switch:

- **Regeneration.** Out of combat your health is back in about a minute and a
  half and your magicka in about three. In a fight, nothing. (Characters born
  under the Atronach still get no magicka back — that is the sign's bargain.)
- **Downed, not dead.** If you fall while your brother is online you lie
  where you fell for a minute. If he reaches you and activates you, you get
  up on the spot with a quarter of your health and no penalty. If he does
  not — or you type `/giveup` — you die the ordinary way: temple or shrine,
  and the usual days in recovery.
- **Travel network.** Every silt strider port, harbour and Mages Guild hall
  is a travel point; come near one once and it is yours. `/travel` lists
  them and takes you to the one you pick — free when you are at a travel
  point, 10 gold per level (at least 25) from anywhere else.
- **Finding each other.** `/goto NAME` takes you to another player for free,
  once a minute; `/party` shows everyone's level, health and whereabouts.
  Going to a brother who is down always works, even mid-fight.
- **Bank and family vault.** `/bank` opens a chest only you can use, `/vault`
  one you all share, from anywhere. Handing your brother an artifact through
  the vault does not use up his claim.
- **Shared quests.** Journals stay separate, but `/sharequest` offers one of
  your quests to the others. Whoever says yes gets your entries for it, and
  from then on that quest moves forward for all of you.
- **World bosses.** Once one of you is level 5, every three hours something
  large turns up at one of the travel points and everyone is told where
  (`/boss` reminds you). Everyone who fought it gets his own gold and an item
  when it falls; nobody fights over a corpse. Unclaimed after two hours, it
  wanders off.
- **Shared map.** What one of you explores appears on both maps.

Travel, the bank and the vault wait until you have been out of combat for
ten seconds — the one exception being a `/goto` to rescue someone.

| In game | |
| --- | --- |
| `/travel` | Travel to a point you have discovered |
| `/goto NAME` | Go to another player |
| `/party` | Everyone's level, health and location |
| `/bank`, `/vault` | Your own store; the shared one |
| `/sharequest`, `/unsharequest` | Share one quest; stop sharing it |
| `/boss` | Is a world boss about, and where |
| `/giveup` | Stop waiting to be revived |
| `/uniques` | The artifacts you have claimed |
| `/resetinfo` | What a reset will do to the cell you are in |

### Strongholds

With separate progression each player can join a different Great House and
earn its stronghold. Two things about how the game builds them are worth
knowing:

- Morrowind raises all three strongholds together. When the first of you
  builds, the other two sites go up too, held by rival nobles — that is the
  original game's behaviour, not a bug.
- The original construction timers only work for the first builder and die
  when their owner logs out. The bundled helper
  ([`strongholds.lua`](docker/custom/myTes3mp/strongholds.lua)) keeps the wait
  on the server instead: five in-game days per phase (under an hour at the
  default day length), or no wait at all for a phase the world has already
  reached.

One character can still only join one Great House, as in the original game.

### Admin rights

Staff rank lives in each character's save file. Once a character exists and
is logged out, set `"staffRank"` to `2` (admin) or `1` (moderator) in its
file, then restart:

```bash
./my-tes3mp shell nano data/player/yourname.json
./my-tes3mp restart
```

Useful once you have it: `/tpto <name>` to join your brother, `/resetcell`,
`/setdifficulty`, and `/help` for the rest.

## Host it somewhere else

Three ways, all one command. The target machine needs Docker and an open
**UDP 25565**; it does not need Morrowind.

**From your own machine, over SSH.** Nothing is cloned on the server; your
local `.env` is applied there.

```bash
./my-tes3mp deploy user@my-server
```

`./my-tes3mp deploy user@my-server logs`, `status` and `down` manage it
afterwards.

**On the server itself.**

```bash
curl -fsSL https://raw.githubusercontent.com/Jillerkore/my-tes3mp/main/install.sh | bash
```

Settings can ride along:
`curl ... | TES3MP_SERVER_NAME="Balmora nights" TES3MP_PASSWORD=secret bash`.

**Plain Docker, no checkout.** Once the
[publish workflow](.github/workflows/publish.yml) has pushed an image:

```bash
docker run -d --name my-tes3mp-server --restart unless-stopped \
  -p 25565:25565/udp -v tes3mp-data:/data \
  -e TES3MP_SERVER_NAME="Balmora nights" \
  ghcr.io/jillerkore/my-tes3mp:latest
```

Then everyone joins with `./my-tes3mp join my-server`.

## Where things live

| | |
| --- | --- |
| World, characters, server scripts | Docker volume `my-tes3mp_tes3mp-data`, mounted at `/data` in the container |
| Server settings | `.env` |
| Game client | `.runtime/` in this checkout (delete it to reinstall) |
| Client config, saves, logs | `~/.config/openmw/` |
| Backups you make with `./my-tes3mp backup` | `backups/` in this checkout |
| Backups the server makes by itself | `backups/` inside the data volume (`./my-tes3mp backups`) |

The server is stock TES3MP with the stock
[CoreScripts](https://github.com/TES3MP/CoreScripts). To change game rules
(difficulty, what is shared between players, death penalties, and so on)
edit the server's `config.lua`, then restart:

```bash
./my-tes3mp shell nano scripts/config.lua
./my-tes3mp restart
```

Extra server scripts go in `/data/scripts/custom/` and are switched on in
`/data/scripts/customScripts.lua`. Your edits survive restarts and image
rebuilds; the server never overwrites files that already exist in the volume.
The one exception is `scripts/custom/myTes3mp/`, which holds this project's
own scripts and is rewritten from `.env` on every start.

The game rules come from the maintained `0.8.1` branch of CoreScripts, pinned
to a commit in `docker/Dockerfile`, rather than the 2022 snapshot inside the
TES3MP release.

## Troubleshooting

**"Morrowind was not found."** Set `MORROWIND_DATA` to the folder that
contains `Morrowind.esm`. If Steam says the game is installed but the folder
is empty, start the original game once from Steam so it finishes installing.

**The client says it cannot connect.** Check `./my-tes3mp status` on the
host. From another machine, confirm UDP 25565 reaches the host: firewalls
(`sudo ufw allow 25565/udp`) and cloud security groups block it by default.

**"Your current plugins don't match the server's."** The server requires
exactly Morrowind.esm, Tribunal.esm and Bloodmoon.esm, in that order, with
unmodified files. `./my-tes3mp setup` writes that list; mods enabled through
another OpenMW install on the same account will break it.

**You already use OpenMW.** TES3MP shares `~/.config/openmw/openmw.cfg` with
regular OpenMW. Setup will not touch a config it did not write: it stops and
shows what would have to change. `./my-tes3mp setup --force` replaces the
file and keeps the old one next to it as a timestamped backup. The two cannot
share one config, because TES3MP 0.8.1 is based on OpenMW 0.47 and needs the
plain three-file load order.

**The download from GitHub fails.** Release downloads from github.com
sometimes answer 504 for a while. Both the client setup and the image build
retry and then fall back to GitHub's API for the same file, checking the
checksum either way, so this normally only costs half a minute.

## Development

```bash
make lint    # shellcheck over every script
make test    # Lua unit tests against the pinned CoreScripts
make bump    # move to the newest upstream CoreScripts commit
```

This project never edits upstream code: its game rules are ordinary
CoreScripts custom scripts in [`docker/custom/myTes3mp/`](docker/custom/myTes3mp),
one file and one `.env` switch per feature. That is what makes upstream
updates a one-line change. [docs/MAINTAINING.md](docs/MAINTAINING.md) has the
whole picture: how the layers fit, how upstream updates and releases are
made, and how updates reach servers that are already running.

CI lints, runs the unit tests, builds the image, boots the server and checks
that data survives a restart on every push. A weekly job tests against
upstream's newest CoreScripts and opens a pull request when there is
something to take. Pushing a `v*` tag publishes the image to
`ghcr.io/<owner>/my-tes3mp` and creates a GitHub Release from
[CHANGELOG.md](CHANGELOG.md).

If you fork this, replace `Jillerkore/my-tes3mp` in this README, in
`install.sh` and in the image label in `docker/Dockerfile`.

## License

The scripts and configuration here are [MIT](LICENSE) licensed.

TES3MP and OpenMW are GPLv3 projects by their respective authors; this
repository downloads their official release and does not modify it. The Elder
Scrolls III: Morrowind belongs to Bethesda Softworks — you need to own the
game, and none of its data is distributed here.
