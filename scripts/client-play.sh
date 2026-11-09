#!/usr/bin/env bash
#
# client-play.sh — launch TES3MP and connect to a server.
#
#   client-play.sh                      connect to localhost
#   client-play.sh example.org:25570    connect somewhere else
#
# Runs client-setup.sh first (a quick no-op once everything is installed),
# then starts the game. See --help for options.

set -euo pipefail

# --- locate this script (works from any cwd and through symlinks) ------------
SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do
  DIR=$(cd -P "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE
done
SCRIPT_DIR=$(cd -P "$(dirname "$SOURCE")" && pwd)
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage: client-play.sh [HOST[:PORT]] [--password PW] [-- GAME_OPTIONS...]

Starts the TES3MP $TES3MP_VERSION client and connects it to a server. The client is
installed and configured first if it is not already (see client-setup.sh).

Arguments:
  HOST[:PORT]       Server to join. Default: localhost. PORT defaults to
                    TES3MP_PORT from the environment or $MY_TES3MP_ROOT/.env,
                    else 25565.
  --password PW     Password for a protected server. Note that it is visible
                    to other local users in the process list while you play.
  -- GAME_OPTIONS   Everything after -- is passed to the game unchanged,
                    e.g. -- --no-sound (run the game with --help for the list).
  -h, --help        Show this help.

Environment: TES3MP_PORT, plus everything client-setup.sh understands
(MORROWIND_DATA, MY_TES3MP_RUNTIME, ...).

Exit codes:
  0 you quit the game normally
  $EX_USAGE bad usage   $EX_NO_DISPLAY no graphical session
  $EX_CONNECT the game ran but could not reach the server
  $EX_DEPENDENCY-$EX_CONFIG setup failed (see client-setup.sh --help)
  anything else is the game's own exit status (128+N: killed by signal N)
EOF
}

# The game needs a desktop session to open its window in. Catch the common
# "ran it over SSH / from a bare console" case with a clear message instead
# of a cryptic SDL error.
check_display() {
  if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    die_with "$EX_NO_DISPLAY" "no graphical session found (neither DISPLAY nor WAYLAND_DISPLAY is set).
Run this from a terminal inside your desktop session. If you are logged in
over SSH and want the game on that machine's own screen, try: DISPLAY=:0 $0"
  fi
  # When X tools are around, also make sure the display really answers.
  if [ -n "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ] &&
    command -v xdpyinfo >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    timeout 5 xdpyinfo >/dev/null 2>&1 ||
      die_with "$EX_NO_DISPLAY" "cannot open the X display '$DISPLAY'.
Run this from a terminal inside your desktop session (or fix DISPLAY / X authorisation)."
  fi
}

# newest_client_log STAMP — print the newest TES3MP client log written after
# the file STAMP was created. The client starts a fresh
# tes3mp-client-<date>-<time>.log in the OpenMW config directory on each run.
newest_client_log() {
  find "$(openmw_config_dir)" -maxdepth 1 -name 'tes3mp-client-*.log' -newer "$1" 2>/dev/null |
    sort | tail -n 1
}

# The game exits with status 0 even when it never reached the server: it
# shows a "Connection failed" dialog and quits once that is dismissed. Its
# log is the only place that says so. Print the reason if LOG has one.
connection_error() {
  # The message is the "[ERR]: Connection ..." line plus any continuation
  # lines up to the next timestamped entry.
  awk '
    /^\[[^]]*\] \[ERR\]: (Connection|The server is full|You have been banned)/ {
      sub(/^\[[^]]*\] \[ERR\]: /, ""); found = 1; printing = 1; print; next
    }
    printing && /^\[[^]]*\] \[/ { printing = 0 }
    printing && NF { print }
    END { exit !found }
  ' "$1"
}

# Empty marker file whose timestamp records when the game was started;
# removed again on exit.
STAMP=''
cleanup() {
  # shellcheck disable=SC2317  # reached through the EXIT trap below
  [ -z "$STAMP" ] || rm -f -- "$STAMP"
}
trap cleanup EXIT

main() {
  local target='' password='' have_password=0
  local extra=()

  while [ $# -gt 0 ]; do
    case $1 in
      -h | --help)
        usage
        exit 0
        ;;
      --password)
        [ $# -ge 2 ] || die_with "$EX_USAGE" "--password needs a value"
        password=$2
        have_password=1
        shift
        ;;
      --password=*)
        password=${1#--password=}
        have_password=1
        ;;
      --)
        shift
        extra=("$@")
        break
        ;;
      -*) die_with "$EX_USAGE" "unknown option '$1' — see --help (game options go after --)" ;;
      *)
        [ -z "$target" ] || die_with "$EX_USAGE" "expected a single HOST[:PORT], got '$target' and '$1'"
        target=$1
        ;;
    esac
    shift
  done

  # Split HOST[:PORT].
  local host port
  if [[ $target =~ ^(.*):([0-9]+)$ ]]; then
    host=${BASH_REMATCH[1]}
    port=${BASH_REMATCH[2]}
  else
    host=$target
    port=$(setting TES3MP_PORT 25565)
  fi
  host=${host:-localhost}
  [[ $host != *[[:space:]]* ]] || die_with "$EX_USAGE" "invalid host '$host'"
  if ! [[ $port =~ ^[0-9]{1,5}$ ]] || [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
    die_with "$EX_USAGE" "invalid port '$port' (expected 1-65535)"
  fi
  port=$((10#$port))

  check_display

  # Silent no-op when already set up; otherwise installs and configures,
  # saying what it does.
  "$SCRIPT_DIR/client-setup.sh" --quiet

  local dir
  dir=$(client_dir)
  local args=("--connect=$host:$port")
  if [ "$have_password" = 1 ] && [ -n "$password" ]; then
    args+=("--password=$password")
  fi

  # Remember "now" so the log of this run can be told from older ones.
  STAMP=$(mktemp "${TMPDIR:-/tmp}/my-tes3mp-play.XXXXXX")

  info "Starting TES3MP — connecting to $host:$port"

  # Run the real binary the same way the release's own wrapper script does
  # (from its directory, with its bundled libraries first) but without that
  # wrapper, which breaks when the install path contains spaces. The game
  # resolves ./resources and its default configs relative to the cwd.
  cd "$dir"
  local pid status=0 signalled=0
  LD_LIBRARY_PATH="$dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    ./tes3mp.x86_64 "${args[@]}" ${extra[@]+"${extra[@]}"} &
  pid=$!
  # Ctrl-C or a `kill` aimed at this script should end the game too, not
  # leave it running in the background.
  trap 'signalled=1; kill -TERM "$pid" 2>/dev/null || true' INT TERM HUP
  while :; do
    status=0
    wait "$pid" || status=$?
    # wait also returns when one of the traps above fires; keep waiting
    # until the game itself is gone.
    kill -0 "$pid" 2>/dev/null || break
  done
  trap - INT TERM HUP

  local log reason
  log=$(newest_client_log "$STAMP")
  if [ "$signalled" = 0 ] && [ -n "$log" ] && reason=$(connection_error "$log"); then
    warn "the game could not connect to $host:$port:"
    printf '%s\n' "$reason" | sed 's/^/    /' >&2
    printf '%s\n' \
      "  Check that the server is running and reachable, that the address and" \
      "  port are right, and that UDP port $port is open in any firewall between you." \
      "  Client log: $log" >&2
    exit "$EX_CONNECT"
  fi
  if [ "$status" -ne 0 ] && [ "$signalled" = 0 ]; then
    warn "the game exited with status $status${log:+ — its log is $log}"
  fi
  exit "$status"
}

main "$@"
