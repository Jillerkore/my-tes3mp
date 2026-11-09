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
| `./my-tes3mp backup` | Save the world and characters to `backups/` |
| `./my-tes3mp restore FILE` | Bring a backup back |
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

The right-hand column is what you still have to be considerate about. If your
brother kills a quest-giver, he is dead in your game too until that cell is
reset. A moderator can reset a cell by name from the in-game chat, which
brings its inhabitants and loot back:

```
/resetcell "Balmora, Caius Cosades' House"
```

Resetting a cell also removes anything players left lying in it, so do not
reset somewhere you store things. To make yourselves moderators, see
[Admin rights](#admin-rights).

Set `TES3MP_PROGRESSION=shared` for stock party-style play, or `custom` to
control every `config.share*` option yourself in `scripts/config.lua`.

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
  on the server instead: five in-game days per phase, or no wait at all for a
  phase the world has already reached.

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
| Backups | `backups/` |

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
make lint                      # shellcheck over every script
docker compose up -d --build --wait && docker compose logs
```

CI runs the same on every push: it lints, builds the image, boots the server
and checks that data survives a restart. Pushes to `main` and `v*` tags also
publish the image to `ghcr.io/<owner>/my-tes3mp`.

To move to a newer TES3MP release, update the version, URL and checksum at
the top of `docker/Dockerfile` (server, plus the CoreScripts commit) and
`scripts/lib.sh` (client).

If you fork this, replace `Jillerkore/my-tes3mp` in this README, in
`install.sh` and in the image label in `docker/Dockerfile`.

## License

The scripts and configuration here are [MIT](LICENSE) licensed.

TES3MP and OpenMW are GPLv3 projects by their respective authors; this
repository downloads their official release and does not modify it. The Elder
Scrolls III: Morrowind belongs to Bethesda Softworks — you need to own the
game, and none of its data is distributed here.
