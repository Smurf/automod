#!/usr/bin/env bash
# Build Open MPI as an Lmod MPI module. Idempotent: skips if prefix exists.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

PREFIX="$AUTOMOD_PREFIX/software/openmpi/$OPENMPI_VERSION"
if build_done "$PREFIX/bin/mpicc"; then
    log "openmpi $OPENMPI_VERSION already built, skipping"
    exit 0
fi

tarball="$(fetch "$OPENMPI_URL")"

log "unpacking openmpi"
mkdir -p /tmp/build/openmpi
tar -C /tmp/build/openmpi -xzf "$tarball" --strip-components=1
cd /tmp/build/openmpi

log "configuring openmpi (vendored hwloc/libevent/pmix/prrte, gcc toolchain)"
CC=gcc CXX=g++ FC=gfortran F77=gfortran F90=gfortran \
./configure --prefix="$PREFIX" \
    --with-libevent=internal \
    --with-hwloc=internal \
    --with-pmix=internal \
    --with-prrte=internal \
    --enable-shared \
    --without-x \
    > /tmp/openmpi-configure.log 2>&1

log "compiling openmpi ($(nproc_avail) jobs)"
make -j"$(nproc_avail)" > /tmp/openmpi-build.log 2>&1
make install > /tmp/openmpi-install.log 2>&1

log "writing modulefile"
write_module "$AUTOMOD_MODULEFILES/mpi/openmpi/$OPENMPI_VERSION.lua" \
    STACK="automod" PKG="openmpi" VER="$OPENMPI_VERSION" PREFIX="$PREFIX" <<'LUA'
help([[Open MPI %%VER%% (gcc backend, internal PMIx/PRRTE/hwloc/libevent) built by the automod stack.]])
whatis("Name: Open MPI %%VER%%")
whatis("Description: Message Passing Interface implementation")
whatis("Built with: GCC (gcc/g++/gfortran)")

family("MPI")

local root = "%%PREFIX%%"
prepend_path("PATH",            pathJoin(root, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(root, "lib"))
prepend_path("CPATH",           pathJoin(root, "include"))
prepend_path("LIBRARY_PATH",    pathJoin(root, "lib"))
prepend_path("MANPATH",         pathJoin(root, "share", "man"))
prepend_path("PKG_CONFIG_PATH", pathJoin(root, "lib", "pkgconfig"))
prepend_path("MODULEPATH",      pathJoin(root, "modulefiles"))
setenv("OMPI_ROOT", root)
LUA

log "smoke test: compile and run MPI hello with 2 ranks"
export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
"$PREFIX/bin/mpicc" "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o /tmp/ompi-hello
timeout 300 "$PREFIX/bin/mpirun" --oversubscribe -n 2 /tmp/ompi-hello | sort | tee /tmp/ompi-hello.out
grep -q "rank 1" /tmp/ompi-hello.out
stamp "openmpi $OPENMPI_VERSION OK"
