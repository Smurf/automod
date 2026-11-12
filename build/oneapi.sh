#!/usr/bin/env bash
# Install Intel oneAPI (icx/ifx compiler, Intel MPI, and MKL) from Intel's
# apt repo — every version in ONEAPI_COMPILER_VERSIONS / INTEL_MPI_VERSIONS /
# MKL_VERSIONS installed side by side — then write Lmod modules:
#   compilers/oneapi/<ver>.lua
#   mpi/intelmpi/<ver>.lua
#   libs/mkl/<ver>.lua
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

ONEAPI_BASE=/opt/intel/oneapi

# Versioned apt packages install into per-version directories
# (/opt/intel/oneapi/<component>/<ver>), so several versions coexist.
# Only versions whose directory is missing are (re)installed, which keeps
# the step idempotent across the persistent /opt/intel volume.
ensure_oneapi_versions() {
    local pkgs=() need=0 kind ver
    for kind in compiler mpi mkl; do
        while read -r ver; do
            [ -n "$ver" ] || continue
            if [ -d "$ONEAPI_BASE/$kind/$ver" ]; then
                info "oneapi $kind $ver: already installed"
                continue
            fi
            need=1
            case "$kind" in
                compiler) pkgs+=("intel-oneapi-compiler-dpcpp-cpp-$ver"
                                 "intel-oneapi-compiler-fortran-$ver") ;;
                mpi)      pkgs+=("intel-oneapi-mpi-$ver"
                                 "intel-oneapi-mpi-devel-$ver") ;;
                mkl)      pkgs+=("intel-oneapi-mkl-$ver"
                                 "intel-oneapi-mkl-devel-$ver") ;;
            esac
        done < <(list_versions "$kind")
    done
    [ "$need" = 1 ] || return 0

    setup_intel_repo_and_install "${pkgs[@]}"
}

# Both the apt repo (Ubuntu) and the yum repo (Rocky/EL) publish the same
# versioned packages, which install into per-version directories
# (/opt/intel/oneapi/<component>/<ver>) so several versions coexist.
setup_intel_repo_and_install() {
    if command -v apt-get >/dev/null 2>&1; then
        log "oneapi: adding intel apt repo"
        install -d -m 0755 /usr/share/keyrings
        curl --fail --retry 3 --show-error --silent --location \
            https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
            | gpg --dearmor --yes -o /usr/share/keyrings/intel-oneapi.gpg
        printf 'deb [ signed-by=/usr/share/keyrings/intel-oneapi.gpg ] https://apt.repos.intel.com/oneapi all main\n' \
            > /etc/apt/sources.list.d/intel-oneapi.list
        sl "apt-get update (incl. intel repo)" "$LOGDIR/oneapi-apt-update.log" - \
            bash -c 'apt-get update -o Dir::Etc::SourceParts=/etc/apt/sources.list.d -o APT::Get::List-Cleanup=0 || apt-get update'

        log "oneapi: installing ${#pkgs[@]} versioned packages (this is a large download)"
        sl "apt-get install oneapi packages" "$LOGDIR/oneapi-apt-install.log" - \
            env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
    elif command -v dnf >/dev/null 2>&1; then
        log "oneapi: adding intel yum repo"
        sl "rpm import intel gpg key" "$LOGDIR/oneapi-rpm-key.log" - \
            rpm --import https://yum.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
        # repo_gpgcheck=0: Intel's repomd signature does not verify against
        # the published key; package signatures are still checked (gpgcheck=1).
        printf '[intel-oneapi]\nname=Intel oneAPI\nbaseurl=https://yum.repos.intel.com/oneapi\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=0\n' \
            > /etc/yum.repos.d/intel-oneapi.repo

        log "oneapi: dnf installing ${#pkgs[@]} versioned packages (this is a large download)"
        sl "dnf install oneapi packages" "$LOGDIR/oneapi-dnf-install.log" - \
            dnf -y install --setopt=install_weak_deps=False "$@"
    else
        echo "ERROR: no supported package manager (apt-get / dnf) found" >&2
        exit 1
    fi
}

# Pinned versions of a component (from versions.env), newest first.
list_versions() {
    case "$1" in
        compiler) printf '%s\n' $ONEAPI_COMPILER_VERSIONS ;;
        mpi)      printf '%s\n' $INTEL_MPI_VERSIONS ;;
        mkl)      printf '%s\n' $MKL_VERSIONS ;;
    esac
}

# First existing library directory for an MKL install (layout moved from
# lib/intel64 to lib across releases).
mkl_libdir() {
    if [ -d "$1/lib" ] && ls "$1"/lib/libmkl_rt.so >/dev/null 2>&1; then
        printf '%s/lib\n' "$1"
    else
        printf '%s/lib/intel64\n' "$1"
    fi
}

ensure_oneapi_versions

# --- modules: one per pinned version -----------------
for CVER in $ONEAPI_COMPILER_VERSIONS; do
    CMPL="$ONEAPI_BASE/compiler/$CVER"
    [ -d "$CMPL" ] || { echo "ERROR: oneAPI compiler $CVER missing after install ($CMPL)" >&2; exit 1; }
    log "oneapi: detected compiler=$CVER"
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
prepend_path("MANPATH",         pathJoin(root, "share", "man"))
prepend_path("PKG_CONFIG_PATH", pathJoin(root, "lib", "pkgconfig"))
setenv("CMPLR_ROOT", root)
LUA
done

for MVER in $INTEL_MPI_VERSIONS; do
    MPIR="$ONEAPI_BASE/mpi/$MVER"
    [ -d "$MPIR" ] || { echo "ERROR: Intel MPI $MVER missing after install ($MPIR)" >&2; exit 1; }
    log "oneapi: detected mpi=$MVER"
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
done

for KVER in $MKL_VERSIONS; do
    MKLR="$ONEAPI_BASE/mkl/$KVER"
    [ -d "$MKLR" ] || { echo "ERROR: MKL $KVER missing after install ($MKLR)" >&2; exit 1; }
    MKLLIB="$(mkl_libdir "$MKLR")"
    log "oneapi: detected mkl=$KVER (libs in $MKLLIB)"
    write_module "$AUTOMOD_MODULEFILES/libs/mkl/$KVER.lua" \
        VER="$KVER" MKLR="$MKLR" MKLLIB="$MKLLIB" <<'LUA'
help([[Intel oneAPI Math Kernel Library %%VER%% (BLAS/LAPACK/SOLVER, gnu or intel toolchain) from the automod stack.]])
whatis("Name: Intel MKL %%VER%%")
whatis("Description: Intel Math Kernel Library, single dynamic interface (libmkl_rt)")

family("Math")
conflict("mkl")

local root  = "%%MKLR%%"
local mlib  = "%%MKLLIB%%"
prepend_path("PATH",            pathJoin(root, "bin"))
prepend_path("CPATH",           pathJoin(root, "include"))
prepend_path("LD_LIBRARY_PATH", mlib)
prepend_path("LIBRARY_PATH",    mlib)
prepend_path("PKG_CONFIG_PATH", pathJoin(mlib, "pkgconfig"))
prepend_path("CPATH",           pathJoin(root, "include", "intel64", "lp64"))
setenv("MKL_ROOT", root)
setenv("MKLROOT", root)
setenv("MKL_INTERFACE_LAYER", "LP64")
LUA
done

# ---- smoke tests: one per installed version -------------
# Each version is tested against a clean base environment so no earlier
# version's lib dirs leak into its run.
BASEPATH="$PATH"
BASELDP="${LD_LIBRARY_PATH:-}"
BASECPATH="${CPATH:-}"
for CVER in $ONEAPI_COMPILER_VERSIONS; do
    CMPL="$ONEAPI_BASE/compiler/$CVER"
    export PATH="$CMPL/bin:$BASEPATH"
    export LD_LIBRARY_PATH="$CMPL/lib:$BASELDP"
    log "oneapi: smoke test icx/ifx ($CVER)"
    "$CMPL/bin/icx" "$AUTOMOD_ROOT/tests/assets/hello.c" -o "/tmp/hello-icx-$CVER"
    "/tmp/hello-icx-$CVER" | grep -q "hello from icx"
    "$CMPL/bin/ifx" "$AUTOMOD_ROOT/tests/assets/hello.f90" -o "/tmp/hello-ifx-$CVER"
    "/tmp/hello-ifx-$CVER" | grep -q "hello from ifx"
    info "icx/ifx compile + run ok ($CVER)"
done

for MVER in $INTEL_MPI_VERSIONS; do
    MPIR="$ONEAPI_BASE/mpi/$MVER"
    log "oneapi: smoke test intelmpi ($MVER)"
    export PATH="$MPIR/bin:$BASEPATH"
    export LD_LIBRARY_PATH="$MPIR/lib:$MPIR/libfabric/lib:$BASELDP"
    export FI_PROVIDER=shm FI_PROVIDER_PATH="$MPIR/libfabric/lib/prov"
    export I_MPI_ROOT="$MPIR"
    export CPATH="$MPIR/include${BASECPATH:+:$BASECPATH}"
    # gcc-backed wrappers need no oneAPI compiler loaded
    "$MPIR/bin/mpigcc" "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o "/tmp/impi-hello-$MVER"
    timeout 300 "$MPIR/bin/mpirun" -n 2 "/tmp/impi-hello-$MVER" | sort | tee "/tmp/impi-hello-$MVER.out"
    grep -q "rank 1" "/tmp/impi-hello-$MVER.out"
    info "intelmpi compile + 2-rank run ok ($MVER)"
done

# newest compiler + newest MPI together: icx-backed wrappers
CMPL="$ONEAPI_BASE/compiler/$(list_versions compiler | head -1)"
MPIR="$ONEAPI_BASE/mpi/$(list_versions mpi | head -1)"
export PATH="$CMPL/bin:$MPIR/bin:$BASEPATH"
export LD_LIBRARY_PATH="$CMPL/lib:$MPIR/lib:$MPIR/libfabric/lib:$BASELDP"
export FI_PROVIDER=shm
# Intel MPI 2026-series wrappers default to the removed legacy 'icc' backend;
# point them explicitly at the oneAPI compilers (mpigcc still works for gcc users).
export I_MPI_CC=icx I_MPI_CXX=icpx I_MPI_FC=ifx
export I_MPI_ROOT="$MPIR" CMPLR_ROOT="$CMPL"
export FI_PROVIDER_PATH="$MPIR/libfabric/lib/prov"
export CPATH="$MPIR/include${BASECPATH:+:$BASECPATH}"
"$MPIR/bin/mpiicc" "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o /tmp/impi-hello-icx
timeout 300 "$MPIR/bin/mpirun" -n 2 /tmp/impi-hello-icx | sort | tee /tmp/impi-hello-icx.out
grep -q "rank 1" /tmp/impi-hello-icx.out
info "intelmpi icx wrappers compile + 2-rank run ok"

for KVER in $MKL_VERSIONS; do
    MKLR="$ONEAPI_BASE/mkl/$KVER"
    MKLLIB="$(mkl_libdir "$MKLR")"
    log "oneapi: smoke test mkl ($KVER)"
    # GNU toolchain + single dynamic interface; the GNU threading layer needs
    # no Intel OpenMP runtime.
    gcc "$AUTOMOD_ROOT/tests/assets/mkl-hello.c" \
        -I"$MKLR/include" -L"$MKLLIB" -Wl,-rpath,"$MKLLIB" -lmkl_rt -lm \
        -o "/tmp/mkl-hello-$KVER"
    env LD_LIBRARY_PATH="$MKLLIB" MKL_THREADING_LAYER=GNU MKL_INTERFACE_LAYER=LP64 \
        "/tmp/mkl-hello-$KVER" | grep -q "mkl smoke test ok"
    info "mkl sgemm via libmkl_rt ok ($KVER)"
done

stamp "oneapi ($(list_versions compiler | tr '\n' ' ')) + intelmpi ($(list_versions mpi | tr '\n' ' ')) + mkl ($(list_versions mkl | tr '\n' ' ')) OK"
