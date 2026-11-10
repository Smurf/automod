#!/usr/bin/env bash
# Build MPICH as an Lmod MPI module. Idempotent: skips work if prefix exists.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

PREFIX="$AUTOMOD_PREFIX/software/mpich/$MPICH_VERSION"
if build_done "$PREFIX/bin/mpicc"; then
    log "mpich $MPICH_VERSION already built, skipping"
    exit 0
fi

tarball="$(fetch "$MPICH_URL")"
log "unpacking mpich"
rm -rf /tmp/build/mpich && mkdir -p /tmp/build/mpich && cd /tmp/build/mpich && tar -xzf "$tarball" --strip-components=1

# Ubuntu ships all providers inside libfabric.so, but the distro libfabric.pc
# still lists every provider's static deps on Libs.private (psm, verbs, efa...).
# MPICH probes `pkg-config --static` and would append those to every future
# mpicc link line, which breaks the build and later app builds. Install a
# cleaned-up .pc shim and point --with-libfabric at it.
mkdir -p /tmp/libfabric-shim/lib/pkgconfig
pcfile="$(find /usr/lib -name libfabric.pc | head -1)"
sed '/^Libs.private:/d' "$pcfile" > /tmp/libfabric-shim/lib/pkgconfig/libfabric.pc

sl "configure mpich (ch4:ofi over system libfabric, gcc)" "$LOGDIR/mpich-configure.log" /tmp/build/mpich \
    env CC=gcc CXX=g++ FC=gfortran F77=gfortran F90=gfortran \
    ./configure --prefix="$PREFIX" --with-device=ch4:ofi --with-libfabric=/tmp/libfabric-shim \
    --enable-shared --without-x

sl "compile mpich" "$LOGDIR/mpich-build.log" /tmp/build/mpich make -j"$(nproc_avail)"
sl "install mpich" "$LOGDIR/mpich-install.log" /tmp/build/mpich make install

log "writing modulefile"
write_module "$AUTOMOD_MODULEFILES/mpi/mpich/$MPICH_VERSION.lua" \
    PKG="mpich" VER="$MPICH_VERSION" PREFIX="$PREFIX" \
    MFPATH="$AUTOMOD_MODULEFILES/mpi/mpich/$MPICH_VERSION" <<'LUA'
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

log "smoke test: compile and run MPI hello with 2 ranks"
export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
"$PREFIX/bin/mpicc" "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o /tmp/mpi-hello
timeout 300 "$PREFIX/bin/mpirun" -n 2 /tmp/mpi-hello | sort | tee /tmp/mpi-hello.out
grep -q "rank 1" /tmp/mpi-hello.out
stamp "mpich $MPICH_VERSION OK"
