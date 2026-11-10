#!/usr/bin/env bash
# Final validation of the built automod tree: load every module with Lmod and
# exercise the binaries. Run inside the container after all build scripts.
# MODULEPATH scope roots (see Containerfile profile.d): mpi/, libs/, apps/, compilers/
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

export MODULEPATH="/opt/automod/modulefiles/mpi:/opt/automod/modulefiles/libs:/opt/automod/modulefiles/apps:/opt/automod/modulefiles/compilers:/etc/modulefiles:/usr/share/lmod/lmod/modulefiles"
log "lmod: module init + avail"
source /usr/share/lmod/lmod/init/bash
module --version || { echo "lmod missing"; exit 1; }
module avail 2>&1 | tee /tmp/module-avail.out

# serial gcc netcdf
if module load netcdf/4.9.3; then
    check "netcdf serial compile" gcc "$AUTOMOD_ROOT/tests/assets/nc-rt-test.c" \
        -I"$AUTOMOD_PREFIX/software/netcdf/$NETCDF_C_VERSION/gnu/include" \
        -L"$AUTOMOD_PREFIX/software/netcdf/$NETCDF_C_VERSION/gnu/lib" \
        -L"$AUTOMOD_PREFIX/software/hdf5/$HDF5_VERSION/gnu/lib" \
        -lnetcdf -o /tmp/nc-rt-gnu
    check "netcdf serial binary" /tmp/nc-rt-gnu
    module purge
else
    echo "FAIL: load netcdf/4.9.3 (serial)"; fail=1
fi

# Each MPI: load it, hierarchically-visible netcdf + sparta must load & run
# Under the mpi/ root the Lmod names of the hidden hierarchy are prefixed
# with the MPI package (e.g. openmpi/4.1.8/netcdf/4.9.3); a bare
# "netcdf/4.9.3" would match the serial libs/ flavor instead.
for pair in "mpich $MPICH_VERSION" "openmpi $OPENMPI_VERSION"; do
    read -r name ver <<< "$pair"
    if module load "$name/$ver"; then
        check "netcdf $name visible after load" bash -c "module avail 2>&1 | grep -q 'netcdf/4.9.3'"
        check "$name mpicc hello" "$AUTOMOD_PREFIX/software/$name/$ver/bin/mpicc" \
            "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o "/tmp/hello-$name"
        export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
        export OMPI_MCA_plm_rsh_agent=""
        check "$name mpirun 2 ranks" mpirun -n 2 "/tmp/hello-$name"

        if module load "$name/$ver/netcdf/$NETCDF_C_VERSION"; then
            # compile the runtime test against the MPI-flavored netcdf, run 2 ranks
            check "netcdf $name compile test" gcc "$AUTOMOD_ROOT/tests/assets/nc-rt-test.c" \
                -I"$AUTOMOD_PREFIX/software/netcdf/$NETCDF_C_VERSION/$name/include" \
                -L"$AUTOMOD_PREFIX/software/netcdf/$NETCDF_C_VERSION/$name/lib" \
                -L"$AUTOMOD_PREFIX/software/hdf5/$HDF5_VERSION/$name/lib" \
                -lnetcdf -o "/tmp/nc-rt-$name"
            check "netcdf $name run" "/tmp/nc-rt-$name"
            module unload "$name/$ver/netcdf/$NETCDF_C_VERSION"
        else
            echo "FAIL: load $name/$ver/netcdf/$NETCDF_C_VERSION"; fail=1
        fi

        if module load "$name/$ver/sparta/$SPARTA_TAG"; then
            check "sparta $name banner" timeout 300 sparta < /dev/null
            module unload "$name/$ver/sparta/$SPARTA_TAG"
        else
            echo "FAIL: load $name/$ver/sparta/$SPARTA_TAG under $name"; fail=1
        fi
        module purge
    else
        echo "FAIL: load $name/$ver"
        fail=1
    fi
done

# oneapi + intelmpi
if [ -d /opt/intel/oneapi/compiler ] && [ -d /opt/intel/oneapi/mpi ]; then
    CVER="$(ls -1d /opt/intel/oneapi/compiler/* | xargs -n1 basename 2>/dev/null | grep -v ^latest$ | sort -V | tail -1)"
    MVER="$(ls -1d /opt/intel/oneapi/mpi/* | xargs -n1 basename 2>/dev/null | grep -v ^latest$ | sort -V | tail -1)"
    export FI_PROVIDER=shm
    check "icx hello" /opt/intel/oneapi/compiler/$CVER/bin/icx \
        "$AUTOMOD_ROOT/tests/assets/hello.c" -o /tmp/hello-icx-selftest
    if module load intelmpi/$MVER; then
        check "intelmpi gcc wrapper" /opt/intel/oneapi/mpi/$MVER/bin/mpigcc \
            "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o /tmp/hello-intelmpi-gcc
        export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
        check "intelmpi mpirun 2 ranks" mpirun -n 2 /tmp/hello-intelmpi-gcc
        if module load oneapi/$CVER; then
            check "intelmpi icx wrapper" env I_MPI_CC=icx I_MPI_CXX=icpx I_MPI_FC=ifx \
                /opt/intel/oneapi/mpi/$MVER/bin/mpiicc \
                "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o /tmp/hello-intelmpi-icx
            module unload oneapi/$CVER
        else
            echo "FAIL: load oneapi/$CVER"; fail=1
        fi
        module purge
    else
        echo "FAIL: load intelmpi/$MVER"; fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "SELFTEST FAILED" >&2
    exit 1
fi
stamp "selftest OK"
