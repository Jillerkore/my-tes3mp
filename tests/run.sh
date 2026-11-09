#!/usr/bin/env bash
# Run the my-tes3mp test suite: every tests/test_*.lua, under LuaJIT, against
# the CoreScripts commit that docker/Dockerfile pins. Works from any directory.
#
#   tests/run.sh                  one summary line per suite, details only for failures
#   tests/run.sh -v               also print every check
#   tests/run.sh [-v] uniques     only the named suite(s): "uniques" or "test_uniques"
#
# Uses the luajit and git on PATH; if either is missing the same thing is run
# inside a throwaway debian container (needs docker). See tests/README.md.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")
verbose=0
if [[ ${1:-} == "-v" ]]; then
    verbose=1
    shift
fi
only=("$@")

# Inside the container the repository is mounted at /repo and the cache at /cache.
cache_root=${MYT_CACHE_ROOT:-$here/.cache}

dockerfile=$repo/docker/Dockerfile
arg() {
    sed -n "s/^ARG $1=\(.*\)$/\1/p" "$dockerfile" | head -n 1
}
corescripts_repo=$(arg CORESCRIPTS_REPO)
corescripts_commit=$(arg CORESCRIPTS_COMMIT)
if [[ -z $corescripts_repo || -z $corescripts_commit ]]; then
    echo "run.sh: cannot read CORESCRIPTS_REPO / CORESCRIPTS_COMMIT from $dockerfile" >&2
    exit 2
fi
cache=$cache_root/corescripts-$corescripts_commit

fetch_corescripts() {
    [[ -f $cache/.fetched ]] && return 0
    echo "Fetching CoreScripts $corescripts_commit ..."
    mkdir -p "$cache_root"
    local tmp
    tmp=$(mktemp -d "$cache_root/.fetch.XXXXXX")
    (
        cd "$tmp"
        git init --quiet
        git remote add origin "$corescripts_repo"
        git fetch --quiet --depth 1 origin "$corescripts_commit"
        git checkout --quiet FETCH_HEAD
        test "$(git rev-parse HEAD)" = "$corescripts_commit"
        touch .fetched
    )
    rm -rf "$cache"
    mv "$tmp" "$cache"
}

run_suites() {
    export MYT_REPO=$repo
    export MYT_CORESCRIPTS=$cache
    local total_checks=0 total_fail=0 suites=0 broken=0
    local out suite name status checks fails w wanted

    shopt -s nullglob
    for suite in "$here"/test_*.lua; do
        name=$(basename "$suite" .lua)
        if [[ ${#only[@]} -gt 0 ]]; then
            wanted=0
            for w in "${only[@]}"; do
                [[ $w == "$name" || test_$w == "$name" ]] && wanted=1
            done
            [[ $wanted -eq 1 ]] || continue
        fi
        suites=$((suites + 1))
        status=0
        out=$(luajit "$suite" 2>&1) || status=$?
        checks=$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) checks, \([0-9][0-9]*\) fail$/\1/p' | tail -n 1)
        fails=$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) checks, \([0-9][0-9]*\) fail$/\2/p' | tail -n 1)
        if [[ -z $checks ]]; then
            printf '%-22s ERROR (exit %s, no summary line)\n' "$name" "$status"
            printf '%s\n' "$out" | grep -v -E '^(PASS|FAIL) ' | tail -n 25 | sed 's/^/    /'
            broken=$((broken + 1))
            continue
        fi
        total_checks=$((total_checks + checks))
        total_fail=$((total_fail + fails))
        if [[ $fails -ne 0 || $status -ne 0 ]]; then
            printf '%-22s %4s checks  %s FAILED\n' "$name" "$checks" "$fails"
            printf '%s\n' "$out" | grep -E '^FAIL ' | sed 's/^/    /' || true
        else
            printf '%-22s %4s checks  ok\n' "$name" "$checks"
        fi
        if [[ $verbose -eq 1 ]]; then
            printf '%s\n' "$out" | sed 's/^/    /'
        fi
    done

    if [[ $suites -eq 0 ]]; then
        echo "run.sh: no test_*.lua found in $here" >&2
        return 2
    fi
    printf '%-22s %4s checks  %s failed, %s suite(s) broken\n' "TOTAL" "$total_checks" "$total_fail" "$broken"
    [[ $total_fail -eq 0 && $broken -eq 0 ]]
}

if [[ ${MYT_INSIDE_CONTAINER:-0} == 1 ]]; then
    fetch_corescripts
    run_suites
    exit $?
fi

if command -v luajit >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    fetch_corescripts
    run_suites
    exit $?
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "run.sh: need luajit and git on PATH, or docker to run them in a container" >&2
    exit 2
fi

mkdir -p "$cache_root"
uid=$(id -u)
gid=$(id -g)
docker_args=()
[[ $verbose -eq 1 ]] && docker_args+=(-v)
docker_args+=("${only[@]}")
status=0
docker run --rm \
    -v "$repo":/repo:ro \
    -v "$cache_root":/cache \
    -e MYT_INSIDE_CONTAINER=1 \
    -e MYT_CACHE_ROOT=/cache \
    -e HOST_UID="$uid" -e HOST_GID="$gid" \
    debian:trixie-slim bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        if ! apt_out=$(apt-get update -qq 2>&1 && apt-get install -y -qq --no-install-recommends luajit git ca-certificates 2>&1); then
            echo "$apt_out" >&2
            exit 2
        fi
        status=0
        bash /repo/tests/run.sh "$@" || status=$?
        chown -R "$HOST_UID:$HOST_GID" /cache
        exit "$status"
    ' bash "${docker_args[@]}" || status=$?
exit "$status"
