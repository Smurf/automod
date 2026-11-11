#!/usr/bin/env bash
# Build every Open MPI version from $OPENMPI_VERSIONS as Lmod MPI modules.
# Idempotent: skips if a version's prefix exists.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

for MPVER in $OPENMPI_VERSIONS; do
    need_var MPVER
    PREFIX="$AUTOMOD_PREFIX/software/openmpi/$MPVER"
    if ! build_done "$PREFIX/bin/mpicc"; then
        tarball="$(fetch "$(openmpi_url "$MPVER")")"
        log "unpacking openmpi $MPVER"
        rm -rf "/tmp/build/openmpi-$MPVER" && mkdir -p "/tmp/build/openmpi-$MPVER" \
            && cd "/tmp/build/openmpi-$MPVER" && tar -xzf "$tarball" --strip-components=1

        # Open MPI < 4.1.7 relies on libfabric's rdma/fabric.h providing the
        # container_of macro; newer libfabric (Ubuntu 26.04) dropped it, and
        # the mtl/ofi MTL then fails with "implicit declaration of function
        # 'container_of'". 4.1.7+ include opal/util/misc.h, which carries the
        # same fallback definition — apply that include to older trees.
        if [ -f ompi/mca/mtl/ofi/mtl_ofi.h ] \
            && ! grep -q 'opal/util/misc.h' ompi/mca/mtl/ofi/mtl_ofi.h; then
            sed -i '/#include "opal\/util\/show_help.h"/a #include "opal\/util\/misc.h"' \
                ompi/mca/mtl/ofi/mtl_ofi.h
        fi

        sl "configure openmpi $MPVER (internal pmix/prrte/hwloc/libevent, gcc)" \
            "$LOGDIR/openmpi-$MPVER-configure.log" "/tmp/build/openmpi-$MPVER" \
            env CC=gcc CXX=g++ FC=gfortran F77=gfortran F90=gfortran \
            ./configure --prefix="$PREFIX" \
                --with-libevent=internal --with-hwloc=internal \
                --with-pmix=internal --with-prrte=internal \
                --enable-shared --without-x

        sl "compile openmpi $MPVER" "$LOGDIR/openmpi-$MPVER-build.log" "/tmp/build/openmpi-$MPVER" \
            make -j"$(nproc_avail)"
        sl "install openmpi $MPVER" "$LOGDIR/openmpi-$MPVER-install.log" "/tmp/build/openmpi-$MPVER" make install
    else
        log "openmpi $MPVER build cached"
    fi

    log "writing modulefile for openmpi $MPVER"
    write_module "$AUTOMOD_MODULEFILES/mpi/openmpi/$MPVER.lua" \
        PKG="openmpi" VER="$MPVER" PREFIX="$PREFIX" \
        MFPATH="$AUTOMOD_MODULEFILES/mpi/openmpi/$MPVER" <<'LUA'
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

    log "smoke test: compile and run MPI hello with 2 ranks (openmpi $MPVER)"
    export PATH="$PREFIX/bin:$PATH"
    export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
    # container builds run as root; Open MPI refuses by default (documented override)
    export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
    # local-only smoke launch: avoid the rsh agent inside containers
    export OMPI_MCA_plm_rsh_agent=""
    "$PREFIX/bin/mpicc" "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o "/tmp/ompi-hello-$MPVER"
    timeout 300 "$PREFIX/bin/mpirun" --oversubscribe -n 2 "/tmp/ompi-hello-$MPVER" | sort | tee "/tmp/ompi-hello-$MPVER.out"
    grep -q "rank 1" "/tmp/ompi-hello-$MPVER.out"
    stamp "openmpi $MPVER OK"
done
