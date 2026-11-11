#!/usr/bin/env bash
# Build SPARTA (DSMC Monte Carlo code, github.com/sparta/sparta) as Lmod
# modules: a serial flavor and hierarchical flavors under EVERY MPI version:
#   apps/sparta/<tag>-gnu.lua                       (serial)
#   mpi/mpich/<mpiver>/sparta/<tag>.lua
#   mpi/openmpi/<mpiver>/sparta/<tag>.lua
# Software flavor directories encode the MPI version: mpich-4.3.2 etc.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

SRCROOT="/tmp/build/sparta"

unpack_once() {
    if [ -d "$SRCROOT/src" ] && [ -f "$SRCROOT/src/sparta.h" ]; then
        return 0
    fi
    log "sparta $SPARTA_TAG: download + unpack"
    tarball="$(fetch "$SPARTA_URL")"
    rm -rf "$SRCROOT"
    mkdir -p "$SRCROOT"
    tar -C "$SRCROOT" -xzf "$tarball" --strip-components=1
}

build_flavor() {
    local flavor="$1"   # gnu | mpich | openmpi
    local OUT="$AUTOMOD_PREFIX/software/sparta/$SPARTA_TAG/$flavor"
    if build_done "$OUT/bin/sparta"; then
        log "sparta [$flavor]: cached"
        return 0
    fi
    unpack_once

    local make_target envs=()
    case "$flavor" in
        gnu)     make_target=serial ;;
        mpich-*) make_target=mpi
                 mv="${flavor#mpich-}"
                 envs=(env "PATH=$AUTOMOD_PREFIX/software/mpich/$mv/bin:$PATH"
                            "LD_LIBRARY_PATH=$AUTOMOD_PREFIX/software/mpich/$mv/lib") ;;
        openmpi-*) make_target=mpi
                 mv="${flavor#openmpi-}"
                 envs=(env "PATH=$AUTOMOD_PREFIX/software/openmpi/$mv/bin:$PATH"
                            "LD_LIBRARY_PATH=$AUTOMOD_PREFIX/software/openmpi/$mv/lib") ;;
    esac

    log "sparta [$flavor]: make clean + $make_target"
    sl "clean prior sparta objects [$flavor]" "$LOGDIR/sparta-$flavor-clean.log" "$SRCROOT/src" \
        make clean-all
    sl "compile sparta [$flavor] ($make_target)" "$LOGDIR/sparta-$flavor-build.log" "$SRCROOT/src" \
        "${envs[@]}" make -j"$(nproc_avail)" "$make_target"

    local built="$SRCROOT/src/spa_$make_target"
    [ -x "$built" ] || built="$(find "$SRCROOT/src" -maxdepth 1 -type f -executable \( -name 'spa_*' -o -name 'sparta_*' -o -name 'lmp_*' \) | head -1 || true)"
    if [ -z "$built" ] || [ ! -x "$built" ]; then
        echo "ERROR: sparta binary not found after make" >&2
        ls -la "$SRCROOT/src" >&2 | head -30
        exit 1
    fi
    mkdir -p "$OUT/bin"
    cp "$built" "$OUT/bin/sparta"
    info "sparta [$flavor]: installed $(basename "$built") -> $OUT/bin/sparta"
}

run_smoke() {
    local flavor="$1"
    local OUT="$AUTOMOD_PREFIX/software/sparta/$SPARTA_TAG/$flavor"
    log "sparta [$flavor]: smoke test"
    local pre=()
    case "$flavor" in
        gnu)     ;;
        mpich-*)   mv="${flavor#mpich-}"
                   pre=(env "PATH=$AUTOMOD_PREFIX/software/mpich/$mv/bin:$PATH"
                         "LD_LIBRARY_PATH=$AUTOMOD_PREFIX/software/mpich/$mv/lib") ;;
        openmpi-*) mv="${flavor#openmpi-}"
                   pre=(env "PATH=$AUTOMOD_PREFIX/software/openmpi/$mv/bin:$PATH"
                         "LD_LIBRARY_PATH=$AUTOMOD_PREFIX/software/openmpi/$mv/lib") ;;
    esac
    out="$(timeout 300 "${pre[@]}" "$OUT/bin/sparta" < /dev/null 2>&1 || true)"
    printf '%s\n' "$out" | tail -5 > "/tmp/sparta-$flavor.out"
    case "$out" in
        *SPARTA*) info "sparta [$flavor]: banner ok" ;;
        *) echo "WARNING: sparta [$flavor] banner not detected" >&2 ;;
    esac
}

serial_module() {
    local OUT="$AUTOMOD_PREFIX/software/sparta/$SPARTA_TAG/gnu"
    write_module "$AUTOMOD_MODULEFILES/apps/sparta/$SPARTA_TAG-gnu.lua" \
        TAG="$SPARTA_TAG" OUT="$OUT" <<'LUA'
help([[SPARTA %%TAG%% (serial DSMC Monte Carlo code) from the automod stack.]])
whatis("Name: SPARTA %%TAG%%")
whatis("Description: DSMC Monte Carlo simulation of low-density gases (serial gnu build)")

local root = "%%OUT%%"
prepend_path("PATH", root .. "/bin")
setenv("SPARTA_ROOT", root)
LUA
}

mpi_module() {
    local mimod="$1" miver="$2" flavor="$3"
    local OUT="$AUTOMOD_PREFIX/software/sparta/$SPARTA_TAG/$flavor"
    local target="$AUTOMOD_MODULEFILES/mpi/$mimod/$miver/sparta/$SPARTA_TAG.lua"
    write_module "$target" TAG="$SPARTA_TAG" MIMOD="$mimod" MIVER="$miver" OUT="$OUT" <<'LUA'
help([[SPARTA %%TAG%% (%%MIMOD%% %%MIVER%% build, DSMC Monte Carlo) from the automod stack.]])
whatis("Name: SPARTA %%TAG%%")
whatis("Description: DSMC Monte Carlo simulation of low-density gases")

if not isloaded("%%MIMOD%%/%%MIVER%%") then
    error("MPI module %%MIMOD%%/%%MIVER%% should be loaded first (SPARTA is built against it)")
end

local root = "%%OUT%%"
prepend_path("PATH", root .. "/bin")
setenv("SPARTA_ROOT", root)
LUA
}

build_flavor gnu
run_smoke gnu
serial_module

for mv in $MPICH_VERSIONS; do
    build_flavor "mpich-$mv"
    run_smoke "mpich-$mv"
    mpi_module mpich "$mv" "mpich-$mv"
done

for mv in $OPENMPI_VERSIONS; do
    build_flavor "openmpi-$mv"
    run_smoke "openmpi-$mv"
    mpi_module openmpi "$mv" "openmpi-$mv"
done

stamp "sparta stack OK (serial + every mpich/openmpi version)"
