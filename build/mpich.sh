#!/usr/bin/env bash
# Build every MPICH version from $MPICH_VERSIONS as Lmod MPI modules.
# Idempotent: skips work if a version's prefix exists.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# Ubuntu ships all providers inside libfabric.so, but the distro libfabric.pc
# still lists every provider's static deps on Libs.private (psm, verbs, efa...).
# MPICH probes `pkg-config --static` and would append those to every future
# mpicc link line, which breaks the build and later app builds. Install a
# cleaned-up .pc shim and point --with-libfabric at it.
ensure_libfabric_shim() {
    if [ -f /tmp/libfabric-shim/lib/pkgconfig/libfabric.pc ]; then
        return 0
    fi
    mkdir -p /tmp/libfabric-shim/lib/pkgconfig
    pcfile="$(find /usr/lib /usr/lib64 -name libfabric.pc 2>/dev/null | head -1)"
    if [ -z "$pcfile" ]; then
        echo "ERROR: libfabric.pc not found under /usr/lib(64) — install libfabric-devel" >&2
        exit 1
    fi
    sed '/^Libs.private:/d' "$pcfile" > /tmp/libfabric-shim/lib/pkgconfig/libfabric.pc
}

for MPVER in $MPICH_VERSIONS; do
    need_var MPVER
    PREFIX="$AUTOMOD_PREFIX/software/mpich/$MPVER"

    if ! build_done "$PREFIX/bin/mpicc"; then
        ensure_libfabric_shim
        tarball="$(fetch "$(mpich_url "$MPVER")")"
        log "unpacking mpich $MPVER"
        rm -rf "/tmp/build/mpich-$MPVER" && mkdir -p "/tmp/build/mpich-$MPVER" \
            && cd "/tmp/build/mpich-$MPVER" && tar -xzf "$tarball" --strip-components=1

        sl "configure mpich $MPVER (ch4:ofi over system libfabric, gcc)" \
            "$LOGDIR/mpich-$MPVER-configure.log" "/tmp/build/mpich-$MPVER" \
            env CC=gcc CXX=g++ FC=gfortran F77=gfortran F90=gfortran \
            ./configure --prefix="$PREFIX" --with-device=ch4:ofi --with-libfabric=/tmp/libfabric-shim \
            --enable-shared --without-x

        sl "compile mpich $MPVER" "$LOGDIR/mpich-$MPVER-build.log" "/tmp/build/mpich-$MPVER" \
            make -j"$(nproc_avail)"
        sl "install mpich $MPVER" "$LOGDIR/mpich-$MPVER-install.log" "/tmp/build/mpich-$MPVER" make install
    else
        log "mpich $MPVER build cached"
    fi

    log "writing modulefile for mpich $MPVER"
    write_module "$AUTOMOD_MODULEFILES/mpi/mpich/$MPVER.lua" \
        PKG="mpich" VER="$MPVER" PREFIX="$PREFIX" \
        MFPATH="$AUTOMOD_MODULEFILES/mpi/mpich/$MPVER" <<'LUA'
help([[MPICH %%VER%% (ch4/ofi device, gcc backend) built by the automod stack.]])
whatis("Name: MPICH %%VER%%")
whatis("Description: Message Passing Interface implementation, ch4 over libfabric")
whatis("Built with: GCC (gcc/g++/gfortran)")

family("MPI")

local root = "%%PREFIX%%"
prepend_path("PATH",            pathJoin(root, "bin"))
prepend_path("PATH",            pathJoin(root, "sbin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(root, "lib"))
prepend_path("CPATH",           pathJoin(root, "include"))
prepend_path("LIBRARY_PATH",    pathJoin(root, "lib"))
prepend_path("MANPATH",         pathJoin(root, "share", "man"))
prepend_path("PKG_CONFIG_PATH", pathJoin(root, "lib", "pkgconfig"))
prepend_path("MODULEPATH",      "%%MFPATH%%")
setenv("MPICH_ROOT", root)
LUA

    log "smoke test: compile and run MPI hello with 2 ranks (mpich $MPVER)"
    export PATH="$PREFIX/bin:$PATH"
    export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
    "$PREFIX/bin/mpicc" "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o "/tmp/mpi-hello-$MPVER"
    timeout 300 "$PREFIX/bin/mpirun" -n 2 "/tmp/mpi-hello-$MPVER" | sort | tee "/tmp/mpi-hello-$MPVER.out"
    grep -q "rank 1" "/tmp/mpi-hello-$MPVER.out"
    stamp "mpich $MPVER OK"
done
