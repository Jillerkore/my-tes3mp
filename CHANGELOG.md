# Changelog

Notable changes to my-tes3mp. Versions follow [semantic versioning](https://semver.org):
a new major version means an existing server needs attention when upgrading.

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
