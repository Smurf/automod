#!/usr/bin/env bash
# Common helpers shared by all automod build scripts. Do not execute directly.
set -euo pipefail

AUTOMOD_PREFIX="${AUTOMOD_PREFIX:-/opt/automod}"
AUTOMOD_MODULEFILES="$AUTOMOD_PREFIX/modulefiles"

log()    { printf '\n\033[1;36m==> %s\033[0m\n' "$*" >&2; }
info()   { printf '    %s\n' "$*" >&2; }
stamp()  { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >&2; }

# Repo root (directory containing build/).
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AUTOMOD_ROOT="$_here/.."
export ARCHIVE_BASE="${AUTOMOD_DL:-$AUTOMOD_ROOT/downloads}"
ARCHIVE_BASE="${AUTOMOD_DL:-$AUTOMOD_ROOT/downloads}"
# shellcheck source=versions.env
. "$_here/versions.env"

need_var() {
    local v
    for v in "$@"; do
        if [ -z "${!v:-}" ]; then
            echo "ERROR: required variable $v is empty" >&2
            exit 1
        fi
    done
}

# fetch <URL> [<fallback URL>] -> writes into $ARCHIVE_BASE, echoes local path
fetch() {
    local url="$1" alt="${2:-}" dest name
    name="$(basename "$url")"
    mkdir -p "$ARCHIVE_BASE"
    dest="$ARCHIVE_BASE/$name"
    if [ -s "$dest" ]; then
        info "archive cached: $dest"
        echo "$dest"
        return 0
    fi
    log "downloading $name"
    if curl --fail --retry 3 --retry-delay 2 --location --output "$dest" --show-error --silent "$url"; then
        echo "$dest"
        return 0
    fi
    if [ -n "$alt" ]; then
        info "primary URL failed, trying fallback: $alt"
        curl --fail --retry 3 --retry-delay 2 --location --output "$dest" --show-error --silent "$alt"
        echo "$dest"
        return 0
    fi
    echo "ERROR: download failed: $url" >&2
    exit 1
}

# build_done <path> -> 0 if <path> (a marker file such as bin/mpicc) exists.
# Callers pass the artifact that indicates a completed install.
build_done() {
    [ -e "$1" ]
}

# write_module <target file> ... sed-style: read template markers %%FOO%% from stdin
write_module() {
    local target="$1"
    shift
    mkdir -p "$(dirname "$target")"
    # Remaining args are KEY=VAL replacements.
    local raw
    raw="$(cat)"
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        raw="${raw//%%$k%%/$v}"
    done
    printf '%s\n' "$raw" > "$target"
    info "wrote modulefile $target"
}

# Where build step logs are written; override with LOGDIR env var.
export LOGDIR="${LOGDIR:-/tmp}"
mkdir -p "$LOGDIR" 2>/dev/null || true

nproc_avail() { nproc; }

# Portable Lmod bash init path: Ubuntu ships /usr/share/lmod/lmod/init/bash,
# EPEL (Rocky/EL) a versioned /usr/share/lmod/<ver>/init/bash.
lmod_init() {
    local p
    for p in /usr/share/lmod/lmod/init/bash /usr/share/lmod/*/init/bash; do
        if [ -f "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    echo "ERROR: lmod init script not found under /usr/share/lmod" >&2
    return 1
}

# sl: run <label> <logfile> <dir|-> <cmd...>; on failure dump the log tail and exit.
sl() {
    local label="$1" lf="$2" dir="$3"; shift 3
    log "$label"
    local rc=0
    if [ "$dir" = "-" ]; then
        "$@" > "$lf" 2>&1 || rc=$?
    else
        ( cd "$dir" && "$@" ) > "$lf" 2>&1 || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: step '$label' failed (rc=$rc), log tail:" >&2
        tail -n 60 "$lf" >&2 || true
        exit "$rc"
    fi
}
