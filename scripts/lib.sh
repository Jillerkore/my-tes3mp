#!/usr/bin/env bash
# shellcheck disable=SC2034  # the variables defined here are used by the scripts that source this file
#
# Shared helpers for the my-tes3mp client scripts.
#
# This file is meant to be sourced, not executed:
#
#   . "$(dirname "$0")/lib.sh"
#
# Sourcing it only defines variables and functions. It never changes shell
# options, never touches the filesystem and never prints anything, so it is
# safe to source from other scripts (including the top-level CLI).

# Sourcing twice is harmless.
if [ -n "${_MY_TES3MP_LIB_LOADED:-}" ]; then
  return 0
fi
_MY_TES3MP_LIB_LOADED=1

# --- pinned TES3MP client release --------------------------------------------
# Bump these together. Changing the version or checksum makes
# client-setup.sh replace an existing install on its next run.
TES3MP_VERSION=0.8.1
TES3MP_TARBALL=tes3mp-GNU+Linux-x86_64-release-0.8.1-68954091c5-6da3fdea59.tar.gz
TES3MP_SHA256=3f033c3d42054ad5ce469664e7d3c513199e18a3fccf88751be3635d13dfc242
# Normal release download ("+" must be URL-encoded as %2B).
TES3MP_URL=https://github.com/TES3MP/TES3MP/releases/download/tes3mp-0.8.1/tes3mp-GNU%2BLinux-x86_64-release-0.8.1-68954091c5-6da3fdea59.tar.gz
# The same file through the GitHub API, used when the URL above is down.
TES3MP_API_URL=https://api.github.com/repos/TES3MP/TES3MP/releases/assets/64397867

# --- exit codes --------------------------------------------------------------
# Shared by client-setup.sh and client-play.sh so callers can tell failures
# apart. Anything else non-zero from client-play.sh is the game's own status.
EX_FAIL=1         # anything not covered below
EX_USAGE=2        # bad command line
EX_DEPENDENCY=3   # a required host tool is missing / unsupported machine
EX_NO_MORROWIND=4 # no usable Morrowind install found
EX_DOWNLOAD=5     # client download or checksum verification failed
EX_CONFIG=6       # a foreign openmw.cfg is in the way (re-run with --force)
EX_NO_DISPLAY=7   # no graphical session to open the game window in
EX_CONNECT=8      # the game started but could not connect to the server

# --- locations ---------------------------------------------------------------
# Repository root: the parent of the directory this file lives in. Resolved
# through symlinks so it works however the calling script was reached.
if [ -z "${MY_TES3MP_ROOT:-}" ]; then
  _lib_source=${BASH_SOURCE[0]}
  while [ -L "$_lib_source" ]; do
    _lib_dir=$(cd -P "$(dirname "$_lib_source")" && pwd)
    _lib_source=$(readlink "$_lib_source")
    [[ $_lib_source != /* ]] && _lib_source=$_lib_dir/$_lib_source
  done
  MY_TES3MP_ROOT=$(cd -P "$(dirname "$_lib_source")/.." && pwd)
  unset _lib_source _lib_dir
fi

# Where the downloaded client lives (gitignored). Override with
# MY_TES3MP_RUNTIME to keep it outside the checkout.
runtime_dir() {
  printf '%s' "${MY_TES3MP_RUNTIME:-$MY_TES3MP_ROOT/.runtime}"
}

# The extracted client. The release tarball unpacks to a top-level TES3MP/.
client_dir() {
  printf '%s/TES3MP' "$(runtime_dir)"
}

# OpenMW's (and therefore TES3MP's) per-user config directory. openmw.cfg,
# settings.cfg and the client logs all live here.
openmw_config_dir() {
  printf '%s/openmw' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# --- output ------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_green=$'\033[32m' _c_yellow=$'\033[33m' _c_red=$'\033[31m' _c_off=$'\033[0m'
else
  _c_green='' _c_yellow='' _c_red='' _c_off=''
fi

# Progress goes to stdout, problems to stderr.
#   step  announces work that is actually being done (always shown)
#   info  is routine status; MY_TES3MP_QUIET=1 hides it, so that a run with
#         nothing to do prints nothing
step() { printf '%s==>%s %s\n' "$_c_green" "$_c_off" "$*"; }
info() {
  [ -n "${MY_TES3MP_QUIET:-}" ] || step "$@"
}
warn() { printf '%swarning:%s %s\n' "$_c_yellow" "$_c_off" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$_c_red" "$_c_off" "$*" >&2
  exit "$EX_FAIL"
}
# die_with CODE MESSAGE... — like die, with a specific exit code.
die_with() {
  local code=$1
  shift
  printf '%serror:%s %s\n' "$_c_red" "$_c_off" "$*" >&2
  exit "$code"
}

# --- settings ----------------------------------------------------------------
# setting KEY [DEFAULT] — print KEY from the environment, else from the
# repository's .env, else DEFAULT. .env is parsed, never sourced, so it
# cannot run code.
setting() {
  local key=$1 default=${2:-} line value
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
    return 0
  fi
  if [ -f "$MY_TES3MP_ROOT/.env" ]; then
    line=$(grep -E "^[[:space:]]*${key}=" "$MY_TES3MP_ROOT/.env" | tail -n 1 || true)
    if [ -n "$line" ]; then
      value=${line#*=}
      value=${value%$'\r'}
      # Strip one pair of surrounding quotes, as docker compose does.
      if [[ $value == \"*\" || $value == \'*\' ]]; then
        value=${value:1:${#value}-2}
      fi
      if [ -n "$value" ]; then
        printf '%s' "$value"
        return 0
      fi
    fi
  fi
  printf '%s' "$default"
}

# --- host checks -------------------------------------------------------------
# require_cmds CMD... — exit with EX_DEPENDENCY naming every missing command.
require_cmds() {
  local cmd missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die_with "$EX_DEPENDENCY" "missing required tool(s): ${missing[*]} — install them with your package manager and try again"
  fi
}

# The TES3MP project only publishes x86_64 Linux builds.
require_x86_64_linux() {
  local os arch
  os=$(uname -s)
  arch=$(uname -m)
  if [ "$os" != Linux ] || [ "$arch" != x86_64 ]; then
    die_with "$EX_DEPENDENCY" "TES3MP $TES3MP_VERSION is only released for x86_64 Linux (this machine is $os $arch)"
  fi
}

# --- small file helpers ------------------------------------------------------
# find_ci DIR NAME — print the path of the entry in DIR whose name matches
# NAME ignoring case (installs copied from Windows are often lower-case).
# Fails if there is none.
find_ci() {
  local hit
  [ -d "$1" ] || return 1
  hit=$(find "$1" -maxdepth 1 -iname "$2" -print -quit 2>/dev/null)
  [ -n "$hit" ] && printf '%s' "$hit"
}

# sha256_of FILE — print the lower-case hex digest.
sha256_of() {
  local sum
  sum=$(sha256sum "$1") || return 1
  printf '%s' "${sum%% *}"
}

# --- openmw.cfg value quoting ------------------------------------------------
# OpenMW reads path values with boost's quoted-string rules: wrapped in
# double quotes, with '&' as the escape character. Unquoted values end at the
# first space, so "Data Files" always needs quoting.
cfg_quote() {
  # Character by character on purpose: in ${var//pat/repl}, bash 5.2 gives
  # '&' in the replacement a special meaning that older versions do not.
  local value=$1 out='' char i
  for ((i = 0; i < ${#value}; i++)); do
    char=${value:i:1}
    case $char in
      '&' | '"') out+='&' ;;
    esac
    out+=$char
  done
  printf '"%s"' "$out"
}

# Inverse of cfg_quote; values without surrounding quotes pass through.
cfg_unquote() {
  local value=$1 out='' char i
  if [[ $value != \"*\" || ${#value} -lt 2 ]]; then
    printf '%s' "$value"
    return 0
  fi
  value=${value:1:${#value}-2}
  for ((i = 0; i < ${#value}; i++)); do
    char=${value:i:1}
    if [ "$char" = '&' ] && [ $((i + 1)) -lt ${#value} ]; then
      i=$((i + 1))
      char=${value:i:1}
    fi
    out+=$char
  done
  printf '%s' "$out"
}

# cfg_values FILE KEY — print every value of KEY in an openmw.cfg, in file
# order, one per line, exactly as written (still quoted).
cfg_values() {
  local file=$1 key=$2 line
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in
      "$key="*) printf '%s\n' "${line#*=}" ;;
    esac
  done <"$file"
}

# --- finding Morrowind -------------------------------------------------------
# The three official masters in the order TES3MP servers require, and the
# archive that goes with each.
MORROWIND_MASTERS=(Morrowind.esm Tribunal.esm Bloodmoon.esm)
MORROWIND_ARCHIVES=(Morrowind.bsa Tribunal.bsa Bloodmoon.bsa)

# is_morrowind_data DIR — true if DIR looks like a usable "Data Files".
is_morrowind_data() {
  find_ci "$1" Morrowind.esm >/dev/null && find_ci "$1" Morrowind.bsa >/dev/null
}

# steam_vdf_library_paths FILE — print the Steam library roots listed in a
# libraryfolders.vdf. Handles the current format
#     "path"    "/mnt/games/SteamLibrary"
# and the pre-2021 one, where libraries were plain numbered entries:
#     "1"       "/mnt/games/SteamLibrary"
steam_vdf_library_paths() {
  sed -n \
    -e 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' \
    -e 's/^[[:space:]]*"[0-9][0-9]*"[[:space:]]*"\(\/.*\)"[[:space:]]*$/\1/p' \
    "$1" 2>/dev/null | sed 's/\\\\/\\/g'
}

# Print every place a Morrowind "Data Files" directory might be, most likely
# first, one per line. Entries are guesses and need not exist.
morrowind_candidates() {
  local home=${HOME:-/nonexistent}
  local data_home=${XDG_DATA_HOME:-$home/.local/share}
  local root vdf lib dir

  # Steam: the native package, the ~/.steam symlinks, Flatpak and Snap. Each
  # install lists its extra library folders in libraryfolders.vdf.
  for root in \
    "$data_home/Steam" \
    "$home/.local/share/Steam" \
    "$home/.steam/steam" \
    "$home/.steam/root" \
    "$home/.steam/debian-installation" \
    "$home/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
    "$home/.var/app/com.valvesoftware.Steam/data/Steam" \
    "$home/.var/app/com.valvesoftware.Steam/.steam/steam" \
    "$home/snap/steam/common/.local/share/Steam" \
    "$home/snap/steam/common/.steam/steam"; do
    [ -d "$root" ] || continue
    printf '%s\n' "$root/steamapps/common/Morrowind/Data Files"
    for vdf in "$root/steamapps/libraryfolders.vdf" "$root/config/libraryfolders.vdf"; do
      [ -r "$vdf" ] || continue
      while IFS= read -r lib; do
        [ -n "$lib" ] && printf '%s\n' "$lib/steamapps/common/Morrowind/Data Files"
      done < <(steam_vdf_library_paths "$vdf")
    done
  done

  # GOG / retail copies: native unpacks, Wine prefixes, Lutris, Heroic,
  # Bottles, and the directory OpenMW's own install wizard uses. The globs
  # stay literal when nothing matches; callers skip paths that do not exist.
  for dir in \
    "$home/GOG Games/Morrowind/Data Files" \
    "$home/Games/Morrowind/Data Files" \
    "$home/Games/morrowind/Data Files" \
    "$home/Games"/*/"Data Files" \
    "$home/Games/Heroic"/*/"Data Files" \
    "$home/.wine/drive_c/GOG Games/Morrowind/Data Files" \
    "$home/.wine/drive_c/Program Files (x86)/Bethesda Softworks/Morrowind/Data Files" \
    "$home/.wine/drive_c/Program Files/Bethesda Softworks/Morrowind/Data Files" \
    "$home/.wine/drive_c/Program Files (x86)/Steam/steamapps/common/Morrowind/Data Files" \
    "$home/Games"/*/"drive_c/GOG Games/Morrowind/Data Files" \
    "$home/Games"/*/"drive_c/Program Files (x86)/Bethesda Softworks/Morrowind/Data Files" \
    "$data_home/bottles/bottles"/*/"drive_c/GOG Games/Morrowind/Data Files" \
    "$home/.var/app/com.usebottles.bottles/data/bottles/bottles"/*/"drive_c/GOG Games/Morrowind/Data Files" \
    "$data_home/openmw/basedata" \
    "$home/.var/app/org.openmw.OpenMW/data/openmw/basedata"; do
    printf '%s\n' "$dir"
  done
}

# detect_morrowind_data — print the first candidate that really contains
# Morrowind. Fails (printing nothing) if there is none.
detect_morrowind_data() {
  local dir
  while IFS= read -r dir; do
    if is_morrowind_data "$dir"; then
      (cd "$dir" && pwd -P)
      return 0
    fi
  done < <(morrowind_candidates)
  return 1
}

# normalize_morrowind_data PATH — accept either the "Data Files" directory
# or the Morrowind install directory above it; print the absolute path of
# the "Data Files" directory. Fails if neither holds Morrowind.
normalize_morrowind_data() {
  local dir=$1 sub
  # A literal leading ~ survives when the value comes from .env.
  # shellcheck disable=SC2088  # matching the literal characters, not expanding
  case $dir in
    '~') dir=$HOME ;;
    '~/'*) dir=$HOME/${dir#'~/'} ;;
  esac
  if ! is_morrowind_data "$dir"; then
    sub=$(find_ci "$dir" "Data Files") || return 1
    is_morrowind_data "$sub" || return 1
    dir=$sub
  fi
  (cd "$dir" && pwd -P)
}
