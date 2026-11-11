#!/usr/bin/env bash
# Final validation of the built automod tree: load every module with Lmod and
# exercise the binaries. Run inside the container after all build scripts.
# MODULEPATH scope roots (see Containerfile profile.d): mpi/, libs/, apps/, compilers/
# Covers every version in the versions.env matrix: each netcdf version
# (serial), and under every mpich/openmpi version the hierarchical netcdf +
# sparta modules, plus every oneAPI compiler / Intel MPI / MKL version.
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

read -ra NCVERS <<< "$NETCDF_C_VERSIONS"

# serial gcc netcdf: one module load per netCDF version
for ncver in "${NCVERS[@]}"; do
    if module load "netcdf/$ncver"; then
        check "netcdf $ncver serial compile" gcc "$AUTOMOD_ROOT/tests/assets/nc-rt-test.c" \
            -I"$AUTOMOD_PREFIX/software/netcdf/$ncver/gnu/include" \
            -L"$AUTOMOD_PREFIX/software/netcdf/$ncver/gnu/lib" \
            -L"$AUTOMOD_PREFIX/software/hdf5/$HDF5_VERSION/gnu/lib" \
            -lnetcdf -o "/tmp/nc-rt-gnu-$ncver"
        check "netcdf $ncver serial binary" "/tmp/nc-rt-gnu-$ncver"
        module purge
    else
        echo "FAIL: load netcdf/$ncver (serial)"; fail=1
    fi
done

# Each MPI: load each version, hierarchically-visible netcdf + sparta must
# load & run. Under the mpi/ root the Lmod names of the hidden hierarchy are
# prefixed with the MPI package (e.g. openmpi/4.1.6/netcdf/4.9.3); a bare
# "netcdf/<ver>" would match the serial libs/ flavor instead.
check_mpi() {
    local name="$1" ver="$2"
    if ! module load "$name/$ver"; then
        echo "FAIL: load $name/$ver"; fail=1; return 0
    fi
    check "$name/$ver mpicc hello" "$AUTOMOD_PREFIX/software/$name/$ver/bin/mpicc" \
        "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o "/tmp/hello-$name-$ver"
    export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
    export OMPI_MCA_plm_rsh_agent=""
    check "$name/$ver mpirun 2 ranks" mpirun -n 2 "/tmp/hello-$name-$ver"

    for ncver in "${NCVERS[@]}"; do
        check "netcdf $ncver visible under $name/$ver" \
            bash -c "module avail 2>&1 | grep -q 'netcdf/$ncver'"
        if module load "$name/$ver/netcdf/$ncver"; then
            # compile the runtime test against the MPI-flavored netcdf, run 2 ranks
            check "netcdf $ncver [$name/$ver] compile test" gcc "$AUTOMOD_ROOT/tests/assets/nc-rt-test.c" \
                -I"$AUTOMOD_PREFIX/software/netcdf/$ncver/$name-$ver/include" \
                -L"$AUTOMOD_PREFIX/software/netcdf/$ncver/$name-$ver/lib" \
                -L"$AUTOMOD_PREFIX/software/hdf5/$HDF5_VERSION/$name-$ver/lib" \
                -lnetcdf -o "/tmp/nc-rt-$name-$ver-$ncver"
            check "netcdf $ncver [$name/$ver] run" "/tmp/nc-rt-$name-$ver-$ncver"
            module unload "$name/$ver/netcdf/$ncver"
        else
            echo "FAIL: load $name/$ver/netcdf/$ncver"; fail=1
        fi
    done

    if module load "$name/$ver/sparta/$SPARTA_TAG"; then
        check "sparta [$name/$ver] banner" timeout 300 sparta < /dev/null
        module unload "$name/$ver/sparta/$SPARTA_TAG"
    else
        echo "FAIL: load $name/$ver/sparta/$SPARTA_TAG"; fail=1
    fi
    module purge
}

for mv in $MPICH_VERSIONS; do   check_mpi mpich "$mv";   done
for mv in $OPENMPI_VERSIONS; do check_mpi openmpi "$mv"; done

# oneapi + intelmpi + mkl: every pinned version
if [ -d /opt/intel/oneapi/compiler ] && [ -d /opt/intel/oneapi/mpi ]; then
    export FI_PROVIDER=shm
    export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
    for cver in $ONEAPI_COMPILER_VERSIONS; do
        check "icx hello ($cver)" /opt/intel/oneapi/compiler/$cver/bin/icx \
            "$AUTOMOD_ROOT/tests/assets/hello.c" -o "/tmp/hello-icx-selftest-$cver"
        check "ifx hello ($cver)" /opt/intel/oneapi/compiler/$cver/bin/ifx \
            "$AUTOMOD_ROOT/tests/assets/hello.f90" -o "/tmp/hello-ifx-selftest-$cver"
    done
    for mver in $INTEL_MPI_VERSIONS; do
        if module load "intelmpi/$mver"; then
            check "intelmpi $mver gcc wrapper" /opt/intel/oneapi/mpi/$mver/bin/mpigcc \
                "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o "/tmp/hello-intelmpi-gcc-$mver"
            check "intelmpi $mver mpirun 2 ranks" mpirun -n 2 "/tmp/hello-intelmpi-gcc-$mver"
            module purge
        else
            echo "FAIL: load intelmpi/$mver"; fail=1
        fi
    done
    # newest compiler + newest mpi: icx-backed wrappers
    cnew="$(echo $ONEAPI_COMPILER_VERSIONS | awk '{print $1}')"
    mnew="$(echo $INTEL_MPI_VERSIONS | awk '{print $1}')"
    if module load "intelmpi/$mnew" && module load "oneapi/$cnew"; then
        check "intelmpi $mnew icx wrapper" env I_MPI_CC=icx I_MPI_CXX=icpx I_MPI_FC=ifx \
            /opt/intel/oneapi/mpi/$mnew/bin/mpiicc \
            "$AUTOMOD_ROOT/tests/assets/mpi-hello.c" -o /tmp/hello-intelmpi-icx
        check "intelmpi $mnew icx mpirun" mpirun -n 2 /tmp/hello-intelmpi-icx
        module purge
    else
        echo "FAIL: load intelmpi/$mnew + oneapi/$cnew"; fail=1
    fi
fi

if [ -d /opt/intel/oneapi/mkl ]; then
    for kver in $MKL_VERSIONS; do
        if module load "mkl/$kver"; then
            check "mkl $kver sgemm compile" gcc "$AUTOMOD_ROOT/tests/assets/mkl-hello.c" \
                -lmkl_rt -lm -o "/tmp/mkl-hello-selftest-$kver"
            check "mkl $kver sgemm run" env MKL_THREADING_LAYER=GNU "/tmp/mkl-hello-selftest-$kver"
            module purge
        else
            echo "FAIL: load mkl/$kver"; fail=1
        fi
    done
fi

if [ "$fail" -ne 0 ]; then
    echo "SELFTEST FAILED" >&2
    exit 1
fi
stamp "selftest OK"
