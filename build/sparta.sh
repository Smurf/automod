#!/usr/bin/env bash
# Build SPARTA (SPARTA Monte Carlo / DSMC code, github.com/sparta/sparta)
# as Lmod modules: a serial flavor and hierarchical flavors under each MPI:
#   apps/sparta/<tag>-gnu.lua                (serial)
#   mpi/mpich/<mpi>/sparta/<tag>.lua
#   mpi/openmpi/<mpi>/sparta/<tag>.lua
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
    local exe="sparta_$flavor"
    local OUT="$AUTOMOD_PREFIX/software/sparta/$SPARTA_TAG/$flavor"
    if build_done "$OUT/bin/sparta"; then
        log "sparta [$flavor]: cached"
        return 0
    fi
    unpack_once

    log "sparta [$flavor]: make"
    ( cd "$SRCROOT/src" && \
        make clean-all > /dev/null 2>&1 || true && \
        case "$flavor" in
            gnu)     make -j"$(nproc_avail)" serial   > /tmp/sparta-gnu-build.log 2>&1 ;;
            mpich)   PATH="$AUTOMOD_PREFIX/software/mpich/$MPICH_VERSION/bin:$PATH" LD_LIBRARY_PATH="$AUTOMOD_PREFIX/software/mpich/$MPICH_VERSION/lib" make -j"$(nproc_avail)" mpi > /tmp/sparta-mpich-build.log 2>&1 ;;
            openmpi) PATH="$AUTOMOD_PREFIX/software/openmpi/$OPENMPI_VERSION/bin:$PATH" LD_LIBRARY_PATH="$AUTOMOD_PREFIX/software/openmpi/$OPENMPI_VERSION/lib" make -j"$(nproc_avail)" mpi > /tmp/sparta-openmpi-build.log 2>&1 ;;
        esac )

    local built
    built="$(ls -1 "$SRCROOT/src"/lmp* "$SRCROOT/src"/sparta* 2>/dev/null | head -1 || true)"
    if [ -z "$built" ] || [ ! -x "$built" ]; then
        echo "ERROR: sparta binary not found after make" >&2
        ls -la "$SRCROOT/src" >&2 | head -20
        exit 1
    fi
    mkdir -p "$OUT/bin" "$OUT/lib"
    cp "$built" "$OUT/bin/sparta"
    # lib/gzstream and friends get folded into the binary; nothing else to ship.
    info "sparta [$flavor]: installed $(basename "$built") -> $OUT/bin/sparta"
}

run_smoke() {
    local flavor="$1"
    local OUT="$AUTOMOD_PREFIX/software/sparta/$SPARTA_TAG/$flavor"
    log "sparta [$flavor]: smoke test"
    local out
    case "$flavor" in
        gnu)     MP=() ;;
        mpich)   MP=( "$AUTOMOD_PREFIX/software/mpich/$MPICH_VERSION/bin" "$AUTOMOD_PREFIX/software/mpich/$MPICH_VERSION/lib" ) ;;
        openmpi) MP=( "$AUTOMOD_PREFIX/software/openmpi/$OPENMPI_VERSION/bin" "$AUTOMOD_PREFIX/software/openmpi/$OPENMPI_VERSION/lib" ) ;;
    esac
    if [ "${#MP[@]}" -gt 0 ]; then
        out="$(PATH="${MP[0]}:$PATH" LD_LIBRARY_PATH="${MP[1]}:${LD_LIBRARY_PATH:-}" \
              timeout 300 "$OUT/bin/sparta" < /dev/null 2>&1 || true)"
    else
        out="$(timeout 300 "$OUT/bin/sparta" < /dev/null 2>&1 || true)"
    fi
    echo "$out" | tee "/tmp/sparta-$flavor.out"
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

build_flavor mpich
run_smoke mpich
mpi_module mpich "$MPICH_VERSION" mpich

build_flavor openmpi
run_smoke openmpi
mpi_module openmpi "$OPENMPI_VERSION" openmpi

stamp "sparta stack OK (serial + mpich + openmpi)"
