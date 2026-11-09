#!/usr/bin/env bash
#
# Deploy the TES3MP server to another machine over SSH.
#
# The remote machine only needs the Docker engine. Compose runs here and
# talks to the remote daemon through DOCKER_HOST=ssh://, so nothing has to be
# cloned or installed over there. The image is built on the remote, the world
# lives in a Docker volume on the remote, and settings come from your local
# .env.

set -euo pipefail

SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do
  DIR=$(cd -P "$(dirname "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE
done
ROOT=$(cd -P "$(dirname "$SOURCE")/.." && pwd)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: my-tes3mp deploy [USER@]HOST[:SSH_PORT] [ACTION]

Runs the TES3MP server on a remote machine over SSH.

Actions:
  up        Build and start the server (default)
  down      Stop it (the world is kept)
  logs      Follow the server logs
  status    Show the container state

Requirements:
  - you can `ssh USER@HOST` without a password prompt (key-based login)
  - Docker is installed on HOST and USER may run it
    (install: curl -fsSL https://get.docker.com | sh
     then:    sudo usermod -aG docker USER)
  - UDP port 25565 (or TES3MP_PORT from .env) is open in HOST's firewall

Settings are taken from the .env next to this repo, so the remote server
gets the same name, password and port you configured locally.
EOF
}

target=''
action=up
while [ $# -gt 0 ]; do
  case $1 in
    -h | --help) usage; exit 0 ;;
    up | down | logs | status) action=$1 ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *)
      [ -z "$target" ] || die "unexpected argument '$1' (see --help)"
      target=$1
      ;;
  esac
  shift
done
[ -n "$target" ] || { usage >&2; exit 2; }

command -v docker >/dev/null 2>&1 || die "docker is needed locally as the client"
command -v ssh >/dev/null 2>&1 || die "ssh is not installed"

ssh_host=${target%%:*}
ssh_port=''
[[ $target == *:* ]] && ssh_port=${target##*:}
ssh_args=(-o BatchMode=yes -o ConnectTimeout=10)
[ -n "$ssh_port" ] && ssh_args+=(-p "$ssh_port")

echo "==> Checking $target"
# shellcheck disable=SC2029  # the command is meant to run remotely
ssh "${ssh_args[@]}" "$ssh_host" 'docker info >/dev/null 2>&1' ||
  die "could not run docker on $target over SSH.
  Check that 'ssh $target docker info' works: key-based login set up,
  Docker installed, and the user in the 'docker' group."

export DOCKER_HOST="ssh://$target"
compose() {
  docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml" "$@"
}

port=${TES3MP_PORT:-}
if [ -z "$port" ] && [ -f "$ROOT/.env" ]; then
  port=$(sed -n 's/^[[:space:]]*TES3MP_PORT=//p' "$ROOT/.env" | tail -n 1 | tr -d "\"'\r")
fi
port=${port:-25565}

case $action in
  up)
    echo "==> Building and starting the server on $target"
    if ! compose up -d --build --wait; then
      compose logs --tail 40 || true
      die "the server did not come up on $target — logs above"
    fi
    address=${ssh_host#*@}
    cat <<EOF

Server is up on $target.
Players connect with:   ./my-tes3mp join $address:$port
Make sure UDP port $port is open in that machine's firewall / security group.

Manage it from here:
  ./my-tes3mp deploy $target logs
  ./my-tes3mp deploy $target status
  ./my-tes3mp deploy $target down
EOF
    ;;
  down) compose down ;;
  logs) compose logs -f --tail 100 ;;
  status) compose ps ;;
esac
