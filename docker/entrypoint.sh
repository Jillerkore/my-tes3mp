#!/usr/bin/env bash
#
# Entrypoint of the my-tes3mp server image.
#
#   entrypoint.sh server        (default) prepare /data, then run the server
#   entrypoint.sh healthcheck   exit 0 if the server answers on its UDP port
#   entrypoint.sh CMD [ARG...]  run something else, e.g. `bash`
#
# All state lives in the /data volume:
#
#   /data/tes3mp-server.cfg   server config (see "Config" below)
#   /data/data/               the world: players, cells, world state, ban list,
#                             requiredDataFiles.json
#   /data/scripts/            CoreScripts Lua; edit scripts/config.lua for game
#                             rules, drop your own scripts into scripts/custom/
#   /data/lib/                Lua libraries used by the scripts
#   /data/scripts/custom/myTes3mp/
#                             managed by this script: replaced from the image
#                             and regenerated from the environment on every
#                             start (see "Game rules" below)
#   /data/.tes3mp-version     TES3MP version and CoreScripts revision that
#                             scripts/ was seeded from
#
# Seeding. Each of data/, scripts/, lib/ and the cfg is copied from the
# pristine copy inside the image only if it does not exist yet. Nothing that
# already exists is ever overwritten, so edits survive restarts and upgrades.
#
# Upgrades. For the same reason a newer image does NOT update the scripts in
# an existing volume; the entrypoint only warns when the versions differ. To
# take the new image's scripts, move the old ones away and restart:
#
#   docker compose exec server mv scripts scripts.old
#   docker compose exec server mv lib lib.old
#   docker compose restart server
#
# then re-apply your changes (scripts/config.lua, scripts/customScripts.lua,
# scripts/custom/) from scripts.old. The world in data/ is never touched.
#
# Config. These settings are rewritten in /data/tes3mp-server.cfg from the
# environment on every start; everything else in that file - including your
# comments - is left exactly as it is:
#
#   TES3MP_SERVER_NAME     -> [General] hostname           (default: my-tes3mp)
#   TES3MP_MAX_PLAYERS     -> [General] maximumPlayers     (default: 16)
#   TES3MP_PASSWORD        -> [General] password           (default: none)
#   TES3MP_LOG_LEVEL       -> [General] logLevel           (default: 1)
#   TES3MP_MASTER_ENABLED  -> [MasterServer] enabled       (default: false)
#   (fixed)                -> [General] port = 25565, [Plugins] home = /data
#
# Game rules. CoreScripts keeps its rules in scripts/config.lua, which is
# yours to edit. Two things are layered on top without touching that file, as
# a small script in scripts/custom/myTes3mp/ that is loaded after it:
#
#   TES3MP_PROGRESSION        separate (default): every player has his own
#                             journal, quests, faction ranks, reputation,
#                             dialogue topics, bounty, map and kill counts.
#                             shared: quests and factions progress for the
#                             whole party at once (CoreScripts' stock values).
#                             custom: leave scripts/config.lua in charge.
#   TES3MP_STRONGHOLD_HELPER  true (default): let every player build his own
#                             Great House stronghold; see
#                             docker/custom/myTes3mp/strongholds.lua.
#   TES3MP_CELL_RESET_HOURS   real hours after its first visit at which a cell
#                             is put back to its original state (default 4,
#                             0 = never). Strongholds and cells where players
#                             keep things in containers are skipped; see
#                             docker/custom/myTes3mp/resets.lua.
#   TES3MP_CELL_RESET_KEEP    more cells that must never reset: names or parts
#                             of names, separated by semicolons.
#   TES3MP_DAY_MINUTES        real minutes per in-game day (default 10,
#                             0 = leave the world's own time scale alone).

set -Eeuo pipefail

readonly INSTALL_DIR=/opt/tes3mp
readonly DATA_DIR=/data
readonly CFG_FILE=$DATA_DIR/tes3mp-server.cfg
readonly VERSION_STAMP=$DATA_DIR/.tes3mp-version
readonly SERVER_PORT=25565
readonly IMAGE_VERSION=${TES3MP_VERSION:-unknown}
# What scripts/ is seeded from: the TES3MP release plus the CoreScripts commit.
readonly SCRIPTS_VERSION="$IMAGE_VERSION+${CORESCRIPTS_COMMIT:-bundled}"
readonly MANAGED_SRC=$INSTALL_DIR/my-tes3mp/custom/myTes3mp
readonly MANAGED_DIR=$DATA_DIR/scripts/custom/myTes3mp
readonly MANAGED_REQUIRE='require("custom/myTes3mp/init")'

log()  { printf '[my-tes3mp] %s\n' "$*"; }
warn() { printf '[my-tes3mp] WARNING: %s\n' "$*" >&2; }
die()  { printf '[my-tes3mp] ERROR: %s\n' "$*" >&2; exit 1; }

# Print $1 without leading and trailing whitespace.
trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# ---- Settings from the environment -------------------------------------------

# Values end up as `key = value` lines in an INI-style file. That format has
# no quoting or escaping: the value is simply the rest of the line, so spaces,
# quotes, '#', '=', '$' and non-ASCII text are all safe as they are. The one
# thing that must never get through is a line break (or another control
# character), because it would let a value add settings of its own.
require_printable() {
    local name=$1 value=$2
    if [[ $value == *[[:cntrl:]]* ]]; then
        die "$name must not contain line breaks or other control characters"
    fi
}

load_settings() {
    # The server trims whitespace around values when it reads them; do the
    # same here so the cfg shows exactly what is in effect.
    SERVER_NAME=$(trim "${TES3MP_SERVER_NAME:-}")
    SERVER_NAME=${SERVER_NAME:-my-tes3mp}
    PASSWORD=$(trim "${TES3MP_PASSWORD:-}")
    MAX_PLAYERS=$(trim "${TES3MP_MAX_PLAYERS:-}")
    MAX_PLAYERS=${MAX_PLAYERS:-16}
    LOG_LEVEL=$(trim "${TES3MP_LOG_LEVEL:-}")
    LOG_LEVEL=${LOG_LEVEL:-1}
    local master
    master=$(trim "${TES3MP_MASTER_ENABLED:-}")

    require_printable TES3MP_SERVER_NAME "$SERVER_NAME"
    require_printable TES3MP_PASSWORD "$PASSWORD"

    [[ $MAX_PLAYERS =~ ^[1-9][0-9]{0,3}$ ]] ||
        die "TES3MP_MAX_PLAYERS must be a whole number from 1 to 9999 (got '$MAX_PLAYERS')"
    [[ $LOG_LEVEL =~ ^[0-4]$ ]] ||
        die "TES3MP_LOG_LEVEL must be 0 (verbose), 1 (info), 2 (warnings), 3 (errors) or 4 (fatal) (got '$LOG_LEVEL')"

    case ${master,,} in
        true | yes | on | 1) MASTER_ENABLED=true ;;
        false | no | off | 0 | '') MASTER_ENABLED=false ;;
        *) die "TES3MP_MASTER_ENABLED must be true or false (got '$master')" ;;
    esac

    PROGRESSION=$(trim "${TES3MP_PROGRESSION:-}")
    PROGRESSION=${PROGRESSION,,}
    PROGRESSION=${PROGRESSION:-separate}
    case $PROGRESSION in
        separate | shared | custom) ;;
        *) die "TES3MP_PROGRESSION must be separate, shared or custom (got '$PROGRESSION')" ;;
    esac

    local helper
    helper=$(trim "${TES3MP_STRONGHOLD_HELPER:-}")
    case ${helper,,} in
        true | yes | on | 1 | '') STRONGHOLD_HELPER=true ;;
        false | no | off | 0) STRONGHOLD_HELPER=false ;;
        *) die "TES3MP_STRONGHOLD_HELPER must be true or false (got '$helper')" ;;
    esac

    CELL_RESET_HOURS=$(trim "${TES3MP_CELL_RESET_HOURS:-}")
    CELL_RESET_HOURS=${CELL_RESET_HOURS:-4}
    [[ $CELL_RESET_HOURS =~ ^(0|[1-9][0-9]{0,3})$ ]] ||
        die "TES3MP_CELL_RESET_HOURS must be a whole number of hours from 0 (off) to 9999 (got '$CELL_RESET_HOURS')"

    CELL_RESET_KEEP=${TES3MP_CELL_RESET_KEEP:-}
    require_printable TES3MP_CELL_RESET_KEEP "$CELL_RESET_KEEP"

    DAY_MINUTES=$(trim "${TES3MP_DAY_MINUTES:-}")
    DAY_MINUTES=${DAY_MINUTES:-10}
    if ! [[ $DAY_MINUTES =~ ^(0|[1-9][0-9]{0,3})$ ]] || ((DAY_MINUTES > 1440)); then
        die "TES3MP_DAY_MINUTES must be a whole number of minutes from 1 to 1440, or 0 to leave it alone (got '$DAY_MINUTES')"
    fi
}

# ---- Seeding /data -------------------------------------------------------------

# Copy one pristine CoreScripts directory into the volume unless it is already
# there. The copy goes to a temporary name first and is renamed into place, so
# an interrupted first start cannot leave a half-seeded directory behind.
seed_dir() {
    local name=$1
    local target=$DATA_DIR/$name staging=$DATA_DIR/.$name.seeding
    if [[ -e $target ]]; then
        return 1
    fi
    log "Seeding $target from the image (TES3MP $IMAGE_VERSION)"
    rm -rf "$staging"
    cp -a "$INSTALL_DIR/server/$name" "$staging"
    mv "$staging" "$target"
}

seed_cfg() {
    if [[ -e $CFG_FILE ]]; then
        return 0
    fi
    log "Creating $CFG_FILE from the stock config"
    local staging
    staging=$(mktemp "$CFG_FILE.XXXXXX")
    {
        printf '%s\n' \
            "# TES3MP server configuration, created by my-tes3mp from the stock" \
            "# tes3mp-server-default.cfg of TES3MP $IMAGE_VERSION." \
            "#" \
            "# The container rewrites the settings below from its environment on every" \
            "# start, so change them in .env (or with 'docker run -e'), not here:" \
            "#" \
            "#   [General]       hostname         <- TES3MP_SERVER_NAME" \
            "#                   maximumPlayers   <- TES3MP_MAX_PLAYERS" \
            "#                   password         <- TES3MP_PASSWORD" \
            "#                   logLevel         <- TES3MP_LOG_LEVEL" \
            "#                   port             always $SERVER_PORT inside the container;" \
            "#                                    TES3MP_PORT picks the port on the host" \
            "#   [Plugins]       home             always $DATA_DIR" \
            "#   [MasterServer]  enabled          <- TES3MP_MASTER_ENABLED" \
            "#" \
            "# Every other line is yours and is never touched." \
            ""
        cat "$INSTALL_DIR/tes3mp-server-default.cfg"
    } >"$staging"
    mv "$staging" "$CFG_FILE"
}

seed_data() {
    if [[ ! -w $DATA_DIR ]]; then
        die "$DATA_DIR is not writable by uid $(id -u). If it is a bind mount, run on the host: sudo chown -R $(id -u):$(id -g) <that directory>"
    fi

    seed_dir data || true
    seed_dir lib || true
    if seed_dir scripts; then
        printf '%s\n' "$SCRIPTS_VERSION" >"$VERSION_STAMP"
    fi
    seed_cfg

    # Scripts written for one TES3MP version generally do not work with the
    # server binary of another. Never fix that silently - the scripts may
    # carry the admin's changes - but say clearly what to do.
    local seeded_version=''
    if [[ -r $VERSION_STAMP ]]; then
        seeded_version=$(<"$VERSION_STAMP")
    fi
    if [[ -n $seeded_version && $seeded_version != "$SCRIPTS_VERSION" ]]; then
        warn "$DATA_DIR/scripts was seeded from $seeded_version but this image carries $SCRIPTS_VERSION."
        warn "Existing scripts are never overwritten. To take the new ones, move $DATA_DIR/scripts and"
        warn "$DATA_DIR/lib away (e.g. to scripts.old, lib.old), restart, then re-apply your changes."
    fi
}

# ---- Game rules ---------------------------------------------------------------

# One `config.<name> = <value>` line per sharing option, for settings.lua.
# The option names are CoreScripts' own (scripts/config.lua).
sharing_lines() {
    local value=$1 option
    for option in shareJournal shareFactionRanks shareFactionExpulsion \
        shareFactionReputation shareTopics shareBounty shareReputation \
        shareMapExploration shareVideos shareKills; do
        printf 'config.%s = %s\n' "$option" "$value"
    done
}

# Print $1 as a Lua string literal. Backslashes and double quotes are the only
# characters that need escaping: control characters, line breaks included,
# were already rejected by require_printable.
lua_string() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# TES3MP_CELL_RESET_KEEP ("Name one; name two") as the inside of a Lua list.
keep_list() {
    local entry first=1
    local -a entries=()
    IFS=';' read -r -a entries <<<"$CELL_RESET_KEEP"
    for entry in "${entries[@]}"; do
        entry=$(trim "$entry")
        [[ -n $entry ]] || continue
        ((first)) || printf ', '
        lua_string "$entry"
        first=0
    done
}

# Install the managed scripts into the volume and point CoreScripts at them.
# Everything under MANAGED_DIR is replaced on every start, so it always
# matches the image and the environment; nothing else in scripts/ is touched
# except for one `require` line appended to customScripts.lua if it is absent.
install_managed_scripts() {
    local custom_dir=$DATA_DIR/scripts/custom
    local loader=$DATA_DIR/scripts/customScripts.lua
    local staging=$custom_dir/.myTes3mp.staging

    mkdir -p "$custom_dir"
    rm -rf "$staging"
    cp -r "$MANAGED_SRC" "$staging"

    {
        printf '%s\n' \
            "-- Generated by my-tes3mp on every start from the container's environment." \
            "-- Do not edit: change the TES3MP_* settings in .env instead." \
            "--" \
            "-- This runs after scripts/config.lua, so the values here win." \
            ""
        case $PROGRESSION in
            separate)
                printf '%s\n' "-- TES3MP_PROGRESSION=separate: nothing about a character is shared."
                sharing_lines false
                ;;
            shared)
                printf '%s\n' "-- TES3MP_PROGRESSION=shared: CoreScripts' stock party-style sharing."
                printf '%s\n' \
                    "config.shareJournal = true" \
                    "config.shareFactionRanks = true" \
                    "config.shareFactionExpulsion = false" \
                    "config.shareFactionReputation = true" \
                    "config.shareTopics = true" \
                    "config.shareBounty = false" \
                    "config.shareReputation = true" \
                    "config.shareMapExploration = false" \
                    "config.shareVideos = true" \
                    "config.shareKills = true"
                ;;
            custom)
                printf '%s\n' "-- TES3MP_PROGRESSION=custom: scripts/config.lua decides."
                ;;
        esac
        printf '\nreturn {\n    progression = "%s",\n    strongholdHelper = %s,\n' \
            "$PROGRESSION" "$STRONGHOLD_HELPER"
        printf '    cellResetHours = %s,\n    cellResetKeep = { %s },\n    dayMinutes = %s\n}\n' \
            "$CELL_RESET_HOURS" "$(keep_list)" "$DAY_MINUTES"
    } >"$staging/settings.lua"

    rm -rf "$MANAGED_DIR"
    mv "$staging" "$MANAGED_DIR"

    if [[ ! -e $loader ]]; then
        printf '%s\n' "$MANAGED_REQUIRE" >"$loader"
    elif ! grep -qF -- "$MANAGED_REQUIRE" "$loader"; then
        printf '\n-- Added by my-tes3mp: game rules from the environment (see custom/myTes3mp/init.lua).\n%s\n' \
            "$MANAGED_REQUIRE" >>"$loader"
        log "Added the my-tes3mp loader line to $loader"
    fi

    # Per-player kill counts need a CoreScripts new enough to know the option.
    if [[ $PROGRESSION == separate ]] &&
        ! grep -q 'shareKills' "$DATA_DIR/scripts/config.lua" 2>/dev/null; then
        warn "The scripts in $DATA_DIR/scripts predate per-player kill counts (config.shareKills),"
        warn "so kills stay shared between players. See 'Upgrades' at the top of this script."
    fi
}

# ---- Rendering the cfg -----------------------------------------------------------

# Settings this script owns, as "Section|key" -> value, in the order given.
declare -A MANAGED=()
declare -a MANAGED_ORDER=()

manage() {
    local id="$1|$2"
    MANAGED[$id]=$3
    MANAGED_ORDER+=("$id")
}

print_setting() {
    local id=$1
    local key=${id#*|} value=${MANAGED[$id]}
    printf '%s =%s\n' "$key" "${value:+ $value}"
}

# Rewrite the managed settings in CFG_FILE and leave every other line alone.
#
# Plain bash on purpose: `read -r` and printf '%s' move values around byte for
# byte, so there is nothing to escape - unlike sed (where '&', '/' and '\' in a
# password would need quoting) or awk -v (which expands backslash escapes).
render_cfg() {
    local section_re='^[[:space:]]*\[([^]]*)\]'
    local setting_re='^[[:space:]]*([^=#[:space:]][^=]*)='
    local line section id
    local -A present=() written=()

    # Pass 1: which managed settings does the file already have?
    section=''
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ $section_re ]]; then
            section=$(trim "${BASH_REMATCH[1]}")
        elif [[ $line =~ $setting_re ]]; then
            id="$section|$(trim "${BASH_REMATCH[1]}")"
            if [[ -v MANAGED[$id] ]]; then
                present[$id]=1
            fi
        fi
    done <"$CFG_FILE"

    # Pass 2: copy the file, replacing managed settings where they stand and
    # adding missing ones right under their section header. The result is
    # written next to the original and renamed over it, so the server never
    # sees a half-written config.
    local staging
    staging=$(mktemp "$CFG_FILE.XXXXXX")
    {
        section=''
        while IFS= read -r line || [[ -n $line ]]; do
            if [[ $line =~ $section_re ]]; then
                section=$(trim "${BASH_REMATCH[1]}")
                printf '%s\n' "$line"
                for id in "${MANAGED_ORDER[@]}"; do
                    if [[ ${id%%|*} == "$section" && ! -v present[$id] && ! -v written[$id] ]]; then
                        print_setting "$id"
                        written[$id]=1
                    fi
                done
                continue
            fi
            if [[ $line =~ $setting_re ]]; then
                id="$section|$(trim "${BASH_REMATCH[1]}")"
                if [[ -v MANAGED[$id] ]]; then
                    # The server refuses to start on a duplicated setting, so
                    # write each managed one once and drop any repeats.
                    if [[ ! -v written[$id] ]]; then
                        print_setting "$id"
                        written[$id]=1
                    fi
                    continue
                fi
            fi
            printf '%s\n' "$line"
        done <"$CFG_FILE"

        # Sections that are missing from the file altogether.
        section=''
        for id in "${MANAGED_ORDER[@]}"; do
            if [[ ! -v written[$id] ]]; then
                if [[ ${id%%|*} != "$section" ]]; then
                    section=${id%%|*}
                    printf '\n[%s]\n' "$section"
                fi
                print_setting "$id"
                written[$id]=1
            fi
        done
    } >"$staging"
    # mktemp creates the file 0600, which suits a file holding the password.
    mv "$staging" "$CFG_FILE"
}

# ---- Commands -------------------------------------------------------------------

run_server() {
    load_settings
    seed_data

    manage General hostname "$SERVER_NAME"
    manage General port "$SERVER_PORT"
    manage General maximumPlayers "$MAX_PLAYERS"
    manage General password "$PASSWORD"
    manage General logLevel "$LOG_LEVEL"
    manage Plugins home "$DATA_DIR"
    manage MasterServer enabled "$MASTER_ENABLED"
    render_cfg
    install_managed_scripts

    local password_state='no password'
    if [[ -n $PASSWORD ]]; then
        password_state='password set'
    fi
    log "Starting TES3MP $IMAGE_VERSION: name \"$SERVER_NAME\", up to $MAX_PLAYERS players, $password_state, public listing $MASTER_ENABLED, $PROGRESSION progression, cell resets ${CELL_RESET_HOURS}h, day ${DAY_MINUTES}min"

    # The release bundles the Boost version it was built against.
    export LD_LIBRARY_PATH=$INSTALL_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

    # --no-logs: log to stdout only (for `docker logs`) instead of also
    #   writing a new log file into the container on every start.
    # </dev/null: the server polls stdin and quits when it reads a newline;
    #   never let a stray Enter in an attached terminal do that.
    # exec: the server takes over this process, so tini hands it SIGTERM
    #   directly and `docker stop` gets the server's own clean shutdown.
    exec "$INSTALL_DIR/tes3mp-server.x86_64" --no-logs </dev/null
}

# Ask the server what a game client asks first: a RakNet "unconnected ping".
# RakNet answers it with an "unconnected pong" (first byte 0x1c) only once the
# server has bound its UDP port and its network thread is running.
#
#   ping = 0x01 | 8-byte timestamp | 16-byte RakNet offline magic | 8-byte client id
healthcheck() {
    local reply=''
    {
        printf '\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\x00\xfe\xfe\xfe\xfe\xfd\xfd\xfd\xfd\x12\x34\x56\x78\x6d\x79\x74\x65\x73\x33\x6d\x70' >&3
        # One byte is enough; a refused or silent port fails or times out here.
        LC_ALL=C IFS= read -r -N 1 -t 3 -u 3 reply
    } 3<>"/dev/udp/127.0.0.1/$SERVER_PORT" 2>/dev/null || true

    if [[ $reply == $'\x1c' ]]; then
        echo "healthy: server answered a ping on UDP $SERVER_PORT"
        return 0
    fi
    echo "unhealthy: no answer to a ping on UDP $SERVER_PORT"
    return 1
}

main() {
    case ${1:-server} in
        server) run_server ;;
        healthcheck) healthcheck ;;
        *) exec "$@" ;;
    esac
}

main "$@"
