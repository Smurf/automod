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
mkdir -p /tmp/build/mpich
tar -C /tmp/build/mpich -xzf "$tarball" --strip-components=1
cd /tmp/build/mpich

log "configuring mpich (ch4:ofi device, gcc toolchain)"
CC=gcc CXX=g++ FC=gfortran F77=gfortran F90=gfortran \
./configure --prefix="$PREFIX" \
    --with-device=ch4:ofi \
    --enable-shared \
    --without-x \
    > /tmp/mpich-configure.log 2>&1

log "compiling mpich ($(nproc_avail) jobs)"
make -j"$(nproc_avail)" > /tmp/mpich-build.log 2>&1
make install > /tmp/mpich-install.log 2>&1

log "writing modulefile"
write_module "$AUTOMOD_MODULEFILES/mpi/mpich/$MPICH_VERSION.lua" \
    STACK="automod" PKG="mpich" VER="$MPICH_VERSION" PREFIX="$PREFIX" <<'LUA'
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
prepend_path("MODULEPATH",      pathJoin(root, "modulefiles"))
setenv("MPICH_ROOT", root)
LUA

log "smoke test: compile and run MPI hello with 2 ranks"
cp "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" /tmp/mpi-hello.c
export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
"$PREFIX/bin/mpicc" /tmp/mpi-hello.c -o /tmp/mpi-hello
timeout 300 "$PREFIX/bin/mpirun" -n 2 /tmp/mpi-hello | sort | tee /tmp/mpi-hello.out
grep -q "rank 1" /tmp/mpi-hello.out
stamp "mpich $MPICH_VERSION OK"
