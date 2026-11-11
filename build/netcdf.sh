#!/usr/bin/env bash
# Build the netCDF stack (HDF5, netCDF-C, netCDF-Fortran) for every netCDF
# version pair in $NETCDF_C_VERSIONS/$NETCDF_FORTRAN_VERSIONS (paired by
# index) and every flavor: serial gnu, plus one build per MPI version for
# the Lmod hierarchy:
#   libs/netcdf/<ncver>.lua                        (serial)
#   mpi/mpich/<mpiver>/netcdf/<ncver>.lua
#   mpi/openmpi/<mpiver>/netcdf/<ncver>.lua
# Software flavor directories encode the MPI version: mpich-4.3.2 etc.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

read -ra NCVERS <<< "$NETCDF_C_VERSIONS"
read -ra NFVERS <<< "$NETCDF_FORTRAN_VERSIONS"
if [ "${#NCVERS[@]}" -ne "${#NFVERS[@]}" ]; then
    echo "ERROR: NETCDF_C_VERSIONS (${NCVERS[*]}) must pair 1:1 with NETCDF_FORTRAN_VERSIONS (${NFVERS[*]})" >&2
    exit 1
fi

# Emit "<flavor> <cc> <fc> <mpilib>" lines: gnu serial, then one per MPI version.
mpi_flavors() {
    printf 'gnu gcc gfortran\n'
    local mv p
    for mv in $MPICH_VERSIONS; do
        p="$AUTOMOD_PREFIX/software/mpich/$mv"
        printf 'mpich-%s %s %s %s\n' "$mv" "$p/bin/mpicc" "$p/bin/mpif90" "$p/lib"
    done
    for mv in $OPENMPI_VERSIONS; do
        p="$AUTOMOD_PREFIX/software/openmpi/$mv"
        printf 'openmpi-%s %s %s %s\n' "$mv" "$p/bin/mpicc" "$p/bin/mpif90" "$p/lib"
    done
}

build_flavor() {
    local ncver="$1" nfver="$2" flavor="$3" cc="$4" fc="$5" mpilib="$6"

    local HROOT="$AUTOMOD_PREFIX/software/hdf5/$HDF5_VERSION/$flavor"
    local CROOT="$AUTOMOD_PREFIX/software/netcdf/$ncver/$flavor"
    local FROOT="$AUTOMOD_PREFIX/software/netcdf-fortran/$nfver/$flavor"
    local hparallel="" cparallel=""
    if [ -n "$mpilib" ]; then hparallel="--enable-parallel"; cparallel="--enable-parallel4"; fi

    # ---- HDF5 ----
    if build_done "$HROOT/lib/libhdf5.so"; then
        log "hdf5 [$ncver/$flavor]: cached"
    else
        tarball="$(fetch "$HDF5_URL" "$HDF5_URL_ALT")"
        rm -rf /tmp/build/hdf5 && mkdir -p /tmp/build/hdf5 && tar -C /tmp/build/hdf5 -xzf "$tarball"
        # GitHub release assets may nest the tree (hdf5-1.14.6/hdf5-1.14.6);
        # hoist whichever directory actually holds configure.
        if [ ! -f /tmp/build/hdf5/configure ]; then
            # The true root configure sits at depth 1 (single-nested tarball) or
            # 2 (double-nested GitHub release asset, e.g. hdf5-1.14.6/hdf5-1.14.6).
            # Deeper matches are examples/sub-configures and must be skipped.
            inner_dir="$(dirname "$(find /tmp/build/hdf5 -maxdepth 2 -type f -name configure | head -1)")"
            [ -d "$inner_dir" ] || { echo "ERROR: hdf5 configure not found in $tarball" >&2; exit 1; }
            mkdir -p /tmp/build/hdf5-hoist
            mv "$inner_dir"/* ""/tmp/build/hdf5-hoist/"" || tar -C "$inner_dir" -cf - . | tar -C /tmp/build/hdf5-hoist -xf -
            rm -rf /tmp/build/hdf5 && mv /tmp/build/hdf5-hoist /tmp/build/hdf5
        fi
        sl "configure hdf5 [$ncver/$flavor]" "$LOGDIR/hdf5-$flavor-$ncver-configure.log" /tmp/build/hdf5 \
            env CC="$cc" FC="$fc" ./configure --prefix="$HROOT" \
                --enable-shared --disable-static --disable-fortran $hparallel
        sl "compile hdf5 [$ncver/$flavor]" "$LOGDIR/hdf5-$flavor-$ncver-build.log" /tmp/build/hdf5 make -j"$(nproc_avail)"
        sl "install hdf5 [$ncver/$flavor]" "$LOGDIR/hdf5-$flavor-$ncver-install.log" /tmp/build/hdf5 make install
    fi

    # ---- netCDF-C ----
    if build_done "$CROOT/bin/nc-config"; then
        log "netcdf-c [$ncver/$flavor]: cached"
    else
        tarball="$(fetch "$(netcdf_c_url "$ncver")" "$(netcdf_c_url_alt "$ncver")")"
        rm -rf /tmp/build/netcdf-c && mkdir -p /tmp/build/netcdf-c && tar -C /tmp/build/netcdf-c -xzf "$tarball" --strip-components=1
        sl "configure netcdf-c [$ncver/$flavor]" "$LOGDIR/netcdf-c-$flavor-$ncver-configure.log" /tmp/build/netcdf-c \
            env CC="$cc" ./configure --prefix="$CROOT" \
                --enable-shared --disable-static --disable-byterange --disable-libxml2 $cparallel \
                CPPFLAGS="-I$HROOT/include" \
                LDFLAGS="-L$HROOT/lib -Wl,-rpath,$HROOT/lib"
        sl "compile netcdf-c [$ncver/$flavor]" "$LOGDIR/netcdf-c-$flavor-$ncver-build.log" /tmp/build/netcdf-c make -j"$(nproc_avail)"
        sl "install netcdf-c [$ncver/$flavor]" "$LOGDIR/netcdf-c-$flavor-$ncver-install.log" /tmp/build/netcdf-c make install
    fi

    # ---- netCDF-Fortran ----
    if build_done "$FROOT/bin/nf-config"; then
        log "netcdf-fortran [$nfver/$flavor]: cached"
    else
        tarball="$(fetch "$(netcdf_f_url "$nfver")" "$(netcdf_f_url_alt "$nfver")")"
        rm -rf /tmp/build/netcdf-fortran && mkdir -p /tmp/build/netcdf-fortran && tar -C /tmp/build/netcdf-fortran -xzf "$tarball" --strip-components=1
        sl "configure netcdf-fortran [$nfver/$flavor]" "$LOGDIR/netcdf-fortran-$flavor-$nfver-configure.log" /tmp/build/netcdf-fortran \
            env PATH="$CROOT/bin:$PATH" CC="$cc" FC="$fc" ./configure --prefix="$FROOT" \
                --enable-shared --disable-static \
                CPPFLAGS="-I$HROOT/include -I$CROOT/include" \
                LDFLAGS="-L$HROOT/lib -Wl,-rpath,$HROOT/lib -L$CROOT/lib -Wl,-rpath,$CROOT/lib"
        sl "compile netcdf-fortran [$nfver/$flavor]" "$LOGDIR/netcdf-fortran-$flavor-$nfver-build.log" /tmp/build/netcdf-fortran make -j"$(nproc_avail)"
        sl "install netcdf-fortran [$nfver/$flavor]" "$LOGDIR/netcdf-fortran-$flavor-$nfver-install.log" /tmp/build/netcdf-fortran make install
    fi

    # ---- smoke test ----
    log "netcdf [$ncver/$flavor]: smoke test"
    gcc "$AUTOMOD_ROOT/tests/assets/nc-rt-test.c" \
        -I"$CROOT/include" -L"$CROOT/lib" -Wl,-rpath,"$CROOT/lib" \
        -L"$HROOT/lib" -Wl,-rpath,"$HROOT/lib" -lnetcdf \
        -o "/tmp/nc-rt-$ncver-$flavor"
    "/tmp/nc-rt-$ncver-$flavor" > "/tmp/nc-rt-$ncver-$flavor.out"
    grep -q "netcdf smoke test ok" "/tmp/nc-rt-$ncver-$flavor.out"
    info "netcdf [$ncver/$flavor]: $(head -1 "/tmp/nc-rt-$ncver-$flavor.out")"
}

serial_module() {
    local ncver="$1" nfver="$2"
    local CROOT="$AUTOMOD_PREFIX/software/netcdf/$ncver/gnu"
    local FROOT="$AUTOMOD_PREFIX/software/netcdf-fortran/$nfver/gnu"
    local HROOT="$AUTOMOD_PREFIX/software/hdf5/$HDF5_VERSION/gnu"
    write_module "$AUTOMOD_MODULEFILES/libs/netcdf/$ncver.lua" \
        NCC="$ncver" NCF="$nfver" \
        CROOT="$CROOT" FROOT="$FROOT" HROOT="$HROOT" <<'LUA'
help([[netCDF-C %%NCC%% + netCDF-Fortran %%NCF%% (serial gcc build) from the automod stack.]])
whatis("Name: netCDF %%NCC%%/%%NCF%%")
whatis("Description: NetCDF C/Fortran APIs, serial, built with GCC")
whatis("Includes: bundled HDF5")

local nc  = "%%CROOT%%"
local nf  = "%%FROOT%%"
local hdf = "%%HROOT%%"
prepend_path("PATH",            pathJoin(nc, "bin"))
prepend_path("CPATH",           pathJoin(nc, "include"))
prepend_path("CPATH",           pathJoin(nf, "include"))
prepend_path("LD_LIBRARY_PATH", pathJoin(nc, "lib"))
prepend_path("LD_LIBRARY_PATH", pathJoin(nf, "lib"))
prepend_path("LD_LIBRARY_PATH", pathJoin(hdf, "lib"))
prepend_path("LIBRARY_PATH",    pathJoin(nc, "lib"))
prepend_path("LIBRARY_PATH",    pathJoin(nf, "lib"))
prepend_path("LIBRARY_PATH",    pathJoin(hdf, "lib"))
prepend_path("PKG_CONFIG_PATH", pathJoin(nc, "lib", "pkgconfig"))
setenv("NETCDF_ROOT", nc)
setenv("NETCDF_FORTRAN_ROOT", nf)
LUA
}

mpi_module() {
    # $1 = flavor dir name (mpich-4.3.2), $2 = module scope name (mpich),
    # $3 = MPI version, $4 = netCDF-C version, $5 = netCDF-Fortran version
    local flavor="$1" mime="$2" miver="$3" ncver="$4" nfver="$5"
    local CROOT="$AUTOMOD_PREFIX/software/netcdf/$ncver/$flavor"
    local FROOT="$AUTOMOD_PREFIX/software/netcdf-fortran/$nfver/$flavor"
    local HROOT="$AUTOMOD_PREFIX/software/hdf5/$HDF5_VERSION/$flavor"
    local target="$AUTOMOD_MODULEFILES/mpi/$mime/$miver/netcdf/$ncver.lua"
    write_module "$target" \
        NCC="$ncver" NCF="$nfver" \
        MIMOD="$mime" MIVER="$miver" \
        CROOT="$CROOT" FROOT="$FROOT" HROOT="$HROOT" <<'LUA'
help([[netCDF-C %%NCC%% + netCDF-Fortran %%NCF%% (%%MIMOD%% %%MIVER%% parallel build) from the automod stack.]])
whatis("Name: netCDF %%NCC%%/%%NCF%%")
whatis("Description: NetCDF C/Fortran with parallel I/O, built against loaded MPI")
whatis("Includes: parallel HDF5")

if not isloaded("%%MIMOD%%/%%MIVER%%") then
    error("MPI module %%MIMOD%%/%%MIVER%% should be loaded first (netCDF %%NCC%% is built against it)")
end

local nc  = "%%CROOT%%"
local nf  = "%%FROOT%%"
local hdf = "%%HROOT%%"
prepend_path("PATH",            pathJoin(nc, "bin"))
prepend_path("CPATH",           pathJoin(nc, "include"))
prepend_path("CPATH",           pathJoin(nf, "include"))
prepend_path("LD_LIBRARY_PATH", pathJoin(nc, "lib"))
prepend_path("LD_LIBRARY_PATH", pathJoin(nf, "lib"))
prepend_path("LD_LIBRARY_PATH", pathJoin(hdf, "lib"))
prepend_path("LIBRARY_PATH",    pathJoin(nc, "lib"))
prepend_path("LIBRARY_PATH",    pathJoin(nf, "lib"))
prepend_path("LIBRARY_PATH",    pathJoin(hdf, "lib"))
setenv("NETCDF_ROOT", nc)
setenv("NETCDF_FORTRAN_ROOT", nf)
LUA
}

for i in "${!NCVERS[@]}"; do
    ncver="${NCVERS[$i]}"; nfver="${NFVERS[$i]}"
    while read -r flavor cc fc mpilib; do
        build_flavor "$ncver" "$nfver" "$flavor" "$cc" "$fc" "$mpilib"
    done < <(mpi_flavors)
done

for i in "${!NCVERS[@]}"; do
    ncver="${NCVERS[$i]}"; nfver="${NFVERS[$i]}"
    serial_module "$ncver" "$nfver"
    for mv in $MPICH_VERSIONS; do
        mpi_module "mpich-$mv" mpich "$mv" "$ncver" "$nfver"
    done
    for mv in $OPENMPI_VERSIONS; do
        mpi_module "openmpi-$mv" openmpi "$mv" "$ncver" "$nfver"
    done
done

stamp "netcdf stack OK (gnu + every mpich/openmpi version, ${NCVERS[*]})"
