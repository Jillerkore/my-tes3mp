#!/usr/bin/env bash
#
# Move the pinned CoreScripts commit in docker/Dockerfile to the newest commit
# on upstream's branch for this TES3MP version, or to a commit you name.
#
#   scripts/bump-corescripts.sh            newest commit on the tracked branch
#   scripts/bump-corescripts.sh COMMIT     that commit (full 40-character hash)
#   scripts/bump-corescripts.sh --check    only say whether upstream has moved;
#                                          exit 0 = up to date, 10 = behind
#
# It only edits the Dockerfile. Review the upstream changes it links to, run
# the tests (make test), then commit.

set -euo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCKERFILE=$ROOT/docker/Dockerfile

# The upstream branch that matches the TES3MP release this project ships.
BRANCH=0.8.1

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

repo=$(sed -n 's/^ARG CORESCRIPTS_REPO=//p' "$DOCKERFILE")
current=$(sed -n 's/^ARG CORESCRIPTS_COMMIT=//p' "$DOCKERFILE")
if [ -z "$repo" ] || [ -z "$current" ]; then
  die "could not read the CoreScripts pin from $DOCKERFILE"
fi

check_only=false
target=''
case ${1:-} in
  --check) check_only=true ;;
  -h | --help) sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) target=$1 ;;
esac

if [ -z "$target" ]; then
  target=$(git ls-remote "$repo" "refs/heads/$BRANCH" | cut -f1)
  [ -n "$target" ] || die "could not find branch $BRANCH in $repo"
fi
[[ $target =~ ^[0-9a-f]{40}$ ]] || die "'$target' is not a full commit hash"

web=${repo%.git}
if [ "$target" = "$current" ]; then
  echo "CoreScripts is up to date ($current)"
  exit 0
fi

echo "CoreScripts pin:  $current"
echo "Upstream $BRANCH:   $target"
echo "Changes:          $web/compare/$current...$target"

if $check_only; then
  exit 10
fi

sed -i "s/^ARG CORESCRIPTS_COMMIT=.*/ARG CORESCRIPTS_COMMIT=$target/" "$DOCKERFILE"
echo
echo "Updated $DOCKERFILE. Next: read the changes above, run 'make test', commit."
