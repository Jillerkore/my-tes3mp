#!/usr/bin/env bash
#
# One-command server install. Run this ON the machine that should host:
#
#   curl -fsSL https://raw.githubusercontent.com/Jillerkore/my-tes3mp/main/install.sh | bash
#
# It fetches this repository into ~/my-tes3mp and starts the TES3MP server
# with Docker. Re-running it updates the checkout and restarts the server;
# the world and characters live in a Docker volume and are left alone.
#
# Optional environment:
#   MY_TES3MP_REPO   owner/name on GitHub        (default Jillerkore/my-tes3mp)
#   MY_TES3MP_REF    branch or tag to install    (default main)
#   MY_TES3MP_DIR    where to put it             (default ~/my-tes3mp)
#   TES3MP_*         any setting from .env.example, e.g.
#                    TES3MP_SERVER_NAME="Balmora nights" TES3MP_PASSWORD=secret

set -euo pipefail

REPO=${MY_TES3MP_REPO:-Jillerkore/my-tes3mp}
REF=${MY_TES3MP_REF:-main}
DEST=${MY_TES3MP_DIR:-$HOME/my-tes3mp}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 ||
  die "Docker is not installed. Install it with:
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker \$USER   # then log out and back in"
docker compose version >/dev/null 2>&1 ||
  die "the 'docker compose' plugin is missing — see https://docs.docker.com/compose/install/"
docker info >/dev/null 2>&1 ||
  die "cannot talk to the Docker daemon. Is it running, and is $USER in the 'docker' group?"

echo "==> Fetching $REPO@$REF into $DEST"
if [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch --depth 1 origin "$REF"
  git -C "$DEST" checkout -q FETCH_HEAD
elif command -v git >/dev/null 2>&1; then
  [ ! -e "$DEST" ] || die "$DEST already exists and is not a git checkout — set MY_TES3MP_DIR to another path"
  git clone --depth 1 --branch "$REF" "https://github.com/$REPO.git" "$DEST"
else
  # No git: unpack a source tarball instead. .env and backups/ in an existing
  # directory are untouched because the archive does not contain them.
  command -v curl >/dev/null 2>&1 || die "need either git or curl"
  mkdir -p "$DEST"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" |
    tar -xz --strip-components=1 -C "$DEST"
fi

cd "$DEST"
if [ ! -f .env ]; then
  cp .env.example .env
  echo "==> Created $DEST/.env (edit it to change the server name, password, port)"
fi

echo "==> Starting the server (the first run builds the image, ~1 min)"
if ! docker compose up -d --build --wait; then
  docker compose logs --tail 40 || true
  die "the server did not come up — logs above"
fi

port=${TES3MP_PORT:-$(sed -n 's/^[[:space:]]*TES3MP_PORT=//p' .env | tail -n 1 | tr -d "\"'\r")}
port=${port:-25565}
cat <<EOF

TES3MP server is running.
  Players connect to:  <this machine's address>:$port  (UDP — open it in the firewall)
  Logs:                cd $DEST && docker compose logs -f
  Stop:                cd $DEST && docker compose down
  Settings:            edit $DEST/.env, then: docker compose up -d
EOF
