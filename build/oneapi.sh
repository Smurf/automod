#!/usr/bin/env bash
# Install Intel oneAPI (icx/ifx compiler) and Intel MPI from Intel's apt repo,
# then write Lmod modules:
#   compilers/oneapi/<ver>.lua
#   mpi/intelmpi/<ver>.lua
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

ONEAPI_BASE=/opt/intel/oneapi

install_oneapi() {
    if [ -d "$ONEAPI_BASE/compiler" ] && [ -d "$ONEAPI_BASE/mpi" ]; then
        log "oneapi: already installed, skipping apt phase"
        return 0
    fi
    log "oneapi: adding intel apt repo"
    install -d -m 0755 /usr/share/keyrings
    curl --fail --retry 3 --show-error --silent --location \
        https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
        | gpg --dearmor --yes -o /usr/share/keyrings/intel-oneapi.gpg
    printf 'deb [ signed-by=/usr/share/keyrings/intel-oneapi.gpg ] https://apt.repos.intel.com/oneapi all main\n' \
        > /etc/apt/sources.list.d/intel-oneapi.list
    apt-get update -o Dir::Etc::SourceParts=/etc/apt/sources.list.d -o APT::Get::List-Cleanup=0 \
        > /tmp/oneapi-apt-update.log 2>&1 || apt-get update > /tmp/oneapi-apt-update.log 2>&1

    log "oneapi: installing compiler + mpi packages (this is a large download)"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        intel-oneapi-common-vars \
        intel-oneapi-compiler-dpcpp-cpp \
        intel-oneapi-compiler-fortran \
        intel-oneapi-mpi \
        intel-oneapi-mpi-devel \
        > /tmp/oneapi-apt-install.log 2>&1
}

# Pick the newest installed version directory of a component.
pick_ver() {
    ls -1d "$ONEAPI_BASE/$1"/* 2>/dev/null | xargs -n1 basename | sort -V | tail -1
}

CVER="$(pick_ver compiler)"
MVER="$(pick_ver mpi)"
need_var CVER MVER

log "oneapi: detected compiler=$CVER mpi=$MVER"

# --- modules -----------------
CMPL="$ONEAPI_BASE/compiler/$CVER"
MPIR="$ONEAPI_BASE/mpi/$MVER"

write_module "$AUTOMOD_MODULEFILES/compilers/oneapi/$CVER.lua" \
    VER="$CVER" CMPL="$CMPL" <<'LUA'
help([[Intel oneAPI C/C++ (icx) + Fortran (ifx) %%VER%% runtime + toolchain, from the automod stack.]])
whatis("Name: Intel oneAPI %%VER%%")
whatis("Description: Intel oneAPI C/C++/Fortran compiler toolchain")

family("Compiler")
conflict("oneapi")

local root = "%%CMPL%%"
prepend_path("PATH",            pathJoin(root, "bin"))
prepend_path("PATH",            pathJoin(root, "opt", "compiler", "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(root, "lib"))
prepend_path("LD_LIBRARY_PATH", pathJoin(root, "opt", "compiler", "lib"))
prepend_path("CPATH",           pathJoin(root, "include"))
prepend_path("CPATH",           pathJoin(root, "opt", "compiler", "include"))
prepend_path("LIBRARY_PATH",    pathJoin(root, "lib"))
prepend_path("LIBRARY_PATH",    pathJoin(root, "opt", "compiler", "lib"))
prepend_path("MODULEPATH",      pathJoin(root, "lib", "modulefiles"))
prepend_path("MANPATH",         pathJoin(root, "share", "man"))
prepend_path("PKG_CONFIG_PATH", pathJoin(root, "lib", "pkgconfig"))
setenv("CMPLR_ROOT", root)
LUA

write_module "$AUTOMOD_MODULEFILES/mpi/intelmpi/$MVER.lua" \
    VER="$MVER" MPIR="$MPIR" <<'LUA'
help([[Intel MPI Library %%VER%% from the automod stack.]])
whatis("Name: Intel MPI %%VER%%")
whatis("Description: Intel MPI Library (mpirun, mpiicc wrappers, bundled libfabric)")

family("MPI")
conflict("mpich", "openmpi")

local root = "%%MPIR%%"
prepend_path("PATH",            pathJoin(root, "bin"))
prepend_path("PATH",            pathJoin(root, "bin", "mpiexec.hydra"))
prepend_path("PATH",            pathJoin(root, "opt", "mpi", "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(root, "lib"))
prepend_path("LD_LIBRARY_PATH", pathJoin(root, "lib", "release"))
prepend_path("LD_LIBRARY_PATH", pathJoin(root, "libfabric", "lib"))
prepend_path("CPATH",           pathJoin(root, "include"))
prepend_path("LIBRARY_PATH",    pathJoin(root, "lib"))
prepend_path("LIBRARY_PATH",    pathJoin(root, "libfabric", "lib"))
prepend_path("FI_PROVIDER_PATH", pathJoin(root, "libfabric", "lib", "prov"))
prepend_path("MANPATH",         pathJoin(root, "share", "man"))
setenv("I_MPI_ROOT", root)
setenv("FI_PROVIDER", "shm")
LUA

# ---- smoke tests -------------
export PATH="$CMPL/bin:$MPIR/bin:$PATH"
export LD_LIBRARY_PATH="$CMPL/lib:$MPIR/lib:$MPIR/libfabric/lib:${LD_LIBRARY_PATH:-}"

log "oneapi: smoke test icx/ifx"
"$CMPL/bin/icx" "$AUTOMOD_ROOT/tests/assets/hello.c" -o /tmp/hello-icx
/tmp/hello-icx | grep -q "hello from icx"
"$CMPL/bin/ifx" "$AUTOMOD_ROOT/tests/assets/hello.f90" -o /tmp/hello-ifx
/tmp/hello-ifx | grep -q "hello from ifx"
info "icx/ifx compile + run ok"

log "oneapi: smoke test intelmpi"
export FI_PROVIDER=shm
"$MPIR/bin/mpiicc" "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o /tmp/impi-hello
timeout 300 "$MPIR/bin/mpirun" -n 2 /tmp/impi-hello | sort | tee /tmp/impi-hello.out
grep -q "rank 1" /tmp/impi-hello.out
info "intelmpi compile + 2-rank run ok"

stamp "oneapi $CVER + intelmpi $MVER OK"
