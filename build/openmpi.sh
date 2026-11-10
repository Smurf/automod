#!/usr/bin/env bash
# Build Open MPI as an Lmod MPI module. Idempotent: skips if prefix exists.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

PREFIX="$AUTOMOD_PREFIX/software/openmpi/$OPENMPI_VERSION"
if ! build_done "$PREFIX/bin/mpicc"; then
    tarball="$(fetch "$OPENMPI_URL")"
    log "unpacking openmpi"
    rm -rf /tmp/build/openmpi && mkdir -p /tmp/build/openmpi && cd /tmp/build/openmpi && tar -xzf "$tarball" --strip-components=1

    sl "configure openmpi (internal pmix/prrte/hwloc/libevent, gcc)" "$LOGDIR/openmpi-configure.log" /tmp/build/openmpi \
        env CC=gcc CXX=g++ FC=gfortran F77=gfortran F90=gfortran \
        ./configure --prefix="$PREFIX" \
            --with-libevent=internal --with-hwloc=internal \
            --with-pmix=internal --with-prrte=internal \
            --enable-shared --without-x

    sl "compile openmpi" "$LOGDIR/openmpi-build.log" /tmp/build/openmpi make -j"$(nproc_avail)"
    sl "install openmpi" "$LOGDIR/openmpi-install.log" /tmp/build/openmpi make install
else
    log "openmpi $OPENMPI_VERSION build cached"
fi

log "writing modulefile"
write_module "$AUTOMOD_MODULEFILES/mpi/openmpi/$OPENMPI_VERSION.lua" \
    PKG="openmpi" VER="$OPENMPI_VERSION" PREFIX="$PREFIX" \
    MFPATH="$AUTOMOD_MODULEFILES/mpi/openmpi/$OPENMPI_VERSION" <<'LUA'
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
prepend_path("MODULEPATH",      "%%MFPATH%%")
setenv("OMPI_ROOT", root)
LUA

log "smoke test: compile and run MPI hello with 2 ranks"
export PATH="$PREFIX/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
# container builds run as root; Open MPI refuses by default (documented override)
export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
# local-only smoke launch: avoid the rsh agent inside containers
export OMPI_MCA_plm_rsh_agent=""
"$PREFIX/bin/mpicc" "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o /tmp/ompi-hello
timeout 300 "$PREFIX/bin/mpirun" --oversubscribe -n 2 /tmp/ompi-hello | sort | tee /tmp/ompi-hello.out
grep -q "rank 1" /tmp/ompi-hello.out
stamp "openmpi $OPENMPI_VERSION OK"
