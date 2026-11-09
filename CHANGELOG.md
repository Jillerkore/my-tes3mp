# Changelog

Notable changes to my-tes3mp. Versions follow [semantic versioning](https://semver.org):
a new major version means an existing server needs attention when upgrading.

## 1.1.0

Co-op comforts. Every item has its own switch in `.env` and is on by default.

### Added
- **Regeneration** (`TES3MP_REGEN`): out of combat, health returns in about a
  minute and a half and magicka in about three. Nothing in a fight.
- **Downed and revive** (`TES3MP_DOWNED_SECONDS`): a player who falls while
  someone else is online lies there for a minute; another player who reaches
  him and activates him gets him back on his feet with no penalty. Otherwise
  death is what it always was.
- **Travel network** (`TES3MP_TRAVEL`): 34 travel points taken from the game's
  own striders, boats and guild guides. Discover one by going there; `/travel`
  returns you to it — free from another travel point, for a fee from anywhere
  else. `/goto NAME` joins another player; `/party` shows how everyone is.
- **Bank and vault** (`TES3MP_BANK`): `/bank` is a store of your own, `/vault`
  one that all players share, both usable anywhere out of combat.
- **Shared quests** (`TES3MP_SHARE_QUESTS`): `/sharequest` offers one quest to
  the other players; from then on it advances for everyone who accepted.
- **World bosses** (`TES3MP_WORLD_BOSS_HOURS`): every few hours a boss appears
  at a travel point, from level 5 on. Everyone who fought it gets his own
  reward when it falls.
- **Shared map** (`TES3MP_SHARE_MAP`): what one player explores, all see.
- **Automatic backups** (`TES3MP_BACKUP_HOURS`, `TES3MP_BACKUP_KEEP`): the
  server saves the world before it starts and daily after that.
  `./my-tes3mp backups` lists them; `./my-tes3mp restore NAME` brings one back.

### Changed
- **Challenge**: enemies get extra health for each additional player in the
  cell when they are first met, so going alone is lighter than going together.
- `./my-tes3mp restore` now replaces the world completely instead of laying
  the backup over what is there.

## 1.0.0

First release. TES3MP 0.8.1 with CoreScripts from the maintained `0.8.1`
branch.

### One command each
- `./my-tes3mp` starts the server in Docker and launches the game connected
  to it; `join HOST` connects to somebody else's server.
- `./my-tes3mp deploy USER@HOST` runs the server on another machine over SSH;
  `install.sh` does the same on the machine itself.
- The game client is downloaded, verified and configured from an existing
  Morrowind install.
- `backup` and `restore` for the world and characters.

### Two players, two playthroughs
- **Separate progression** (`TES3MP_PROGRESSION`): journal, quests, faction
  ranks, reputation, topics, bounty, map and kill counts are each player's
  own.
- **A world that heals** (`TES3MP_CELL_RESET_HOURS`): cells go back to their
  original state hours after being visited — except the Great House
  strongholds, cells where players keep things in containers, and cells you
  name.
- **Strongholds for everyone** (`TES3MP_STRONGHOLD_HELPER`): each player can
  build his own Great House stronghold, and a build survives logging out.
- **Artifacts once per player** (`TES3MP_UNIQUE_CLAIMS`): 271 artifacts and
  unique items can each be taken from their original place once per player,
  and come back sooner while somebody still needs one.

### Playing together
- **Party** (`TES3MP_PARTY`): all players are allies automatically.
- **Challenge** (`TES3MP_CHALLENGE`): enemies have more health and hit
  harder, and keep up as players level.
- **Vendors** (`TES3MP_VENDOR_GOLD_MINUTES`, `TES3MP_VENDOR_STOCK_SECONDS`):
  merchant gold is back within a minute and wares within seconds.
- **Short days** (`TES3MP_DAY_MINUTES`): an in-game day lasts ten minutes.
- The world's startup scripts run by themselves on first login instead of
  waiting for an admin.

### Staying current
- Existing servers pick up newer server scripts automatically on upgrade,
  unless their scripts were edited by hand.
- A weekly job tests against upstream CoreScripts and proposes the update.
