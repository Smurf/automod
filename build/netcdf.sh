#!/usr/bin/env bash
# Build the netCDF stack (HDF5, netCDF-C, netCDF-Fortran) three times:
# serial gnu flavor, plus one per MPI for the Lmod hierarchy:
#   libs/netcdf/<ver>.lua                    (serial)
#   mpi/mpich/<mpi>/netcdf/<ver>.lua
#   mpi/openmpi/<mpi>/netcdf/<ver>.lua
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

setup_flavor_env() {
    case "$1" in
        gnu)     printf 'gcc\ngfortran\n\n' ;;
        mpich)   printf '%s\n%s\n%s\n' \
                     "$AUTOMOD_PREFIX/software/mpich/$MPICH_VERSION/bin/mpicc" \
                     "$AUTOMOD_PREFIX/software/mpich/$MPICH_VERSION/bin/mpif90" \
                     "$AUTOMOD_PREFIX/software/mpich/$MPICH_VERSION/lib" ;;
        openmpi) printf '%s\n%s\n%s\n' \
                     "$AUTOMOD_PREFIX/software/openmpi/$OPENMPI_VERSION/bin/mpicc" \
                     "$AUTOMOD_PREFIX/software/openmpi/$OPENMPI_VERSION/bin/mpif90" \
                     "$AUTOMOD_PREFIX/software/openmpi/$OPENMPI_VERSION/lib" ;;
        *) echo "unknown flavor '$1'" >&2; exit 1 ;;
    esac
}

build_flavor() {
    local flavor="$1"
    local cc fc mpilib
    { read -r cc; read -r fc; read -r mpilib; } < <(setup_flavor_env "$flavor")

    local HROOT="$AUTOMOD_PREFIX/software/hdf5/$HDF5_VERSION/$flavor"
    local CROOT="$AUTOMOD_PREFIX/software/netcdf/$NETCDF_C_VERSION/$flavor"
    local FROOT="$AUTOMOD_PREFIX/software/netcdf-fortran/$NETCDF_FORTRAN_VERSION/$flavor"
    local hparallel="" cparallel=""
    if [ -n "$mpilib" ]; then hparallel="--enable-parallel"; cparallel="--enable-parallel4"; fi

    # ---- HDF5 ----
    if build_done "$HROOT/lib/libhdf5.so"; then
        log "hdf5 [$flavor]: cached"
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
        sl "configure hdf5 [$flavor]" "$LOGDIR/hdf5-$flavor-configure.log" /tmp/build/hdf5 \
            env CC="$cc" FC="$fc" ./configure --prefix="$HROOT" \
                --enable-shared --disable-static --disable-fortran $hparallel
        sl "compile hdf5 [$flavor]" "$LOGDIR/hdf5-$flavor-build.log" /tmp/build/hdf5 make -j"$(nproc_avail)"
        sl "install hdf5 [$flavor]" "$LOGDIR/hdf5-$flavor-install.log" /tmp/build/hdf5 make install
    fi

    # ---- netCDF-C ----
    if build_done "$CROOT/bin/nc-config"; then
        log "netcdf-c [$flavor]: cached"
    else
        tarball="$(fetch "$NETCDF_C_URL" "$NETCDF_C_URL_ALT")"
        rm -rf /tmp/build/netcdf-c && mkdir -p /tmp/build/netcdf-c && tar -C /tmp/build/netcdf-c -xzf "$tarball" --strip-components=1
        sl "configure netcdf-c [$flavor]" "$LOGDIR/netcdf-c-$flavor-configure.log" /tmp/build/netcdf-c \
            env CC="$cc" ./configure --prefix="$CROOT" \
                --enable-shared --disable-static --disable-byterange --disable-libxml2 $cparallel \
                CPPFLAGS="-I$HROOT/include" \
                LDFLAGS="-L$HROOT/lib -Wl,-rpath,$HROOT/lib"
        sl "compile netcdf-c [$flavor]" "$LOGDIR/netcdf-c-$flavor-build.log" /tmp/build/netcdf-c make -j"$(nproc_avail)"
        sl "install netcdf-c [$flavor]" "$LOGDIR/netcdf-c-$flavor-install.log" /tmp/build/netcdf-c make install
    fi

    # ---- netCDF-Fortran ----
    if build_done "$FROOT/bin/nf-config"; then
        log "netcdf-fortran [$flavor]: cached"
    else
        tarball="$(fetch "$NETCDF_FORTRAN_URL" "$NETCDF_FORTRAN_URL_ALT")"
        rm -rf /tmp/build/netcdf-fortran && mkdir -p /tmp/build/netcdf-fortran && tar -C /tmp/build/netcdf-fortran -xzf "$tarball" --strip-components=1
        sl "configure netcdf-fortran [$flavor]" "$LOGDIR/netcdf-fortran-$flavor-configure.log" /tmp/build/netcdf-fortran \
            env PATH="$CROOT/bin:$PATH" CC="$cc" FC="$fc" ./configure --prefix="$FROOT" \
                --enable-shared --disable-static \
                CPPFLAGS="-I$HROOT/include -I$CROOT/include" \
                LDFLAGS="-L$HROOT/lib -Wl,-rpath,$HROOT/lib -L$CROOT/lib -Wl,-rpath,$CROOT/lib"
        sl "compile netcdf-fortran [$flavor]" "$LOGDIR/netcdf-fortran-$flavor-build.log" /tmp/build/netcdf-fortran make -j"$(nproc_avail)"
        sl "install netcdf-fortran [$flavor]" "$LOGDIR/netcdf-fortran-$flavor-install.log" /tmp/build/netcdf-fortran make install
    fi

    # ---- smoke test ----
    log "netcdf [$flavor]: smoke test"
    gcc "$AUTOMOD_ROOT/tests/assets/nc-rt-test.c" \
        -I"$CROOT/include" -L"$CROOT/lib" -Wl,-rpath,"$CROOT/lib" \
        -L"$HROOT/lib" -Wl,-rpath,"$HROOT/lib" -lnetcdf \
        -o "/tmp/nc-rt-$flavor"
    "/tmp/nc-rt-$flavor" > "/tmp/nc-rt-$flavor.out"
    grep -q "netcdf smoke test ok" "/tmp/nc-rt-$flavor.out"
    info "netcdf [$flavor]: $(head -1 "/tmp/nc-rt-$flavor.out")"
}

serial_module() {
    local CROOT="$AUTOMOD_PREFIX/software/netcdf/$NETCDF_C_VERSION/gnu"
    local FROOT="$AUTOMOD_PREFIX/software/netcdf-fortran/$NETCDF_FORTRAN_VERSION/gnu"
    local HROOT="$AUTOMOD_PREFIX/software/hdf5/$HDF5_VERSION/gnu"
    write_module "$AUTOMOD_MODULEFILES/libs/netcdf/$NETCDF_C_VERSION.lua" \
        NCC="$NETCDF_C_VERSION" NCF="$NETCDF_FORTRAN_VERSION" \
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
    # $1 = flavor dir name (mpich), $2 = module scope name (mpich), $3 = MPI version
    local flavor="$1" mime="$2" miver="$3"
    local CROOT="$AUTOMOD_PREFIX/software/netcdf/$NETCDF_C_VERSION/$flavor"
    local FROOT="$AUTOMOD_PREFIX/software/netcdf-fortran/$NETCDF_FORTRAN_VERSION/$flavor"
    local HROOT="$AUTOMOD_PREFIX/software/hdf5/$HDF5_VERSION/$flavor"
    local target="$AUTOMOD_MODULEFILES/mpi/$mime/$miver/netcdf/$NETCDF_C_VERSION.lua"
    write_module "$target" \
        NCC="$NETCDF_C_VERSION" NCF="$NETCDF_FORTRAN_VERSION" \
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

build_flavor gnu
build_flavor mpich
build_flavor openmpi

serial_module
mpi_module mpich mpich "$MPICH_VERSION"
mpi_module openmpi openmpi "$OPENMPI_VERSION"

stamp "netcdf stack OK (gcc + mpich + openmpi flavors)"
