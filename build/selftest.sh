#!/usr/bin/env bash
# Final validation of a built automod tree: load every module with Lmod and
# exercise the binaries. Run inside the container after all build scripts.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

fail=0
check() {
    local what="$1"
    shift
    if "$@" > /tmp/selftest.out 2>&1; then
        info "PASS: $what"
    else
        echo "FAIL: $what" >&2
        cat /tmp/selftest.out >&2
        fail=1
    fi
}

log "lmod: module avail"
source /usr/share/lmod/lmod/init/bash
export MODULEPATH="/opt/automod/modulefiles:/etc/modulefiles:/usr/share/lmod/lmod/modulefiles"
module --version || { echo "lmod missing"; exit 1; }
module avail 2>&1 | tee /tmp/module-avail.out

# serial gcc netcdf
check "module load netcdf" module load netcdf
check "netcdf serial binary" /tmp/nc-rt-gnu
module purge

# Each MPI loads, then compiles+runs hello (mpicc/mpicxx).
for pair in "mpich $MPICH_VERSION" "openmpi $OPENMPI_VERSION"; do
    read -r name ver <<< "$pair"
    if module load "$name/$ver"; then
        check "$name mpicc hello" "$AUTOMOD_PREFIX/software/$name/$ver/bin/mpicc" \
            "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o "/tmp/hello-$name"
        export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
        OMPI_MCA_plm_rsh_agent=""
        check "$name mpirun 2 ranks" mpirun -n 2 "/tmp/hello-$name"
        export LD_LIBRARY_PATH="$AUTOMOD_PREFIX/software/$name/$ver/lib:${LD_LIBRARY_PATH:-}"
        export PATH="$AUTOMOD_PREFIX/software/$name/$ver/bin:$PATH"
        check "sparta $name banner" timeout 300 sparta < /dev/null
        check "netcdf $name serial-api file" /tmp/nc-rt-$name
        module purge
    else
        echo "FAIL: load $name/$ver"
        fail=1
    fi
done

# oneapi + intelmpi
if [ -d /opt/intel/oneapi/compiler ] && [ -d /opt/intel/oneapi/mpi ]; then
    CVER="$(ls -1d /opt/intel/oneapi/compiler/* | xargs -n1 basename | sort -V | tail -1)"
    MVER="$(ls -1d /opt/intel/oneapi/mpi/* | xargs -n1 basename | sort -V | tail -1)"
    if module load compilers/oneapi/$CVER; then
        check "icx hello" /opt/intel/oneapi/compiler/$CVER/bin/icx \
            "$AUTOMOD_ROOT/tests/assets/hello.c" -o /tmp/hello-icx-selftest
        module purge
    else
        echo "FAIL: load compilers/oneapi/$CVER"; fail=1
    fi
    if module load mpi/intelmpi/$MVER; then
        check "intelmpi compile" /opt/intel/oneapi/mpi/$MVER/bin/mpiicc \
            "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o /tmp/hello-intelmpi
        export FI_PROVIDER=shm
        check "intelmpi mpirun 2 ranks" mpirun -n 2 /tmp/hello-intelmpi
        module purge
    else
        echo "FAIL: load mpi/intelmpi/$MVER"; fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "SELFTEST FAILED" >&2
    exit 1
fi
stamp "selftest OK"
