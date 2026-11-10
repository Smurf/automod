# automod

A reproducible HPC environment-module stack for Ubuntu clusters, built as
**lmod** modulefiles. Everything is compiled inside custom container images
(Ubuntu 24.04 and 26.04) by GitHub Actions using **podman**, so what is tested
locally is byte-for-byte the pipeline that runs in CI.

## Modules produced

MODULEPATH roots are the four scope directories
(`modulefiles/{mpi,libs,apps,compilers}`), each registered as its own root, so
users load plain names (`mpich/4.3.2`, `netcdf/4.9.3`); Lmod displays MPI-flavored
hierarchy modules with the MPI name prefixed (`mpich/4.3.2/netcdf/4.9.3`).

| `module load` name                            | Software                              |
|-----------------------------------------------|---------------------------------------|
| `mpich/4.3.2`                                 | MPICH (ch4/ofi device, gcc backend)   |
| `openmpi/4.1.8`                               | Open MPI 4.1.8                        |
| `intelmpi/2021.19`                            | Intel MPI Library                     |
| `oneapi/2026.2`                               | Intel oneAPI compilers (icx/ifx)      |
| `netcdf/4.9.3` (load `mpich/4.3.2` first)     | netCDF-C + Fortran, MPICH parallel    |
| `netcdf/4.9.3` (load `openmpi/4.1.8` first)   | netCDF-C + Fortran, Open MPI parallel |
| `netcdf/4.9.3` (serial)                       | netCDF-C + Fortran, serial (gcc)      |
| `sparta/27Aug2026` (load `mpich/4.3.2` first) | SPARTA DSMC, MPICH build              |
| `sparta/27Aug2026` (load `openmpi/4.1.8` first)| SPARTA DSMC, Open MPI build          |
| `sparta/27Aug2026-gnu` (serial)               | SPARTA DSMC, serial build             |

The MPI and netCDF/SPARTA modules follow the usual Lmod hierarchy: load an MPI
first (`module load mpich/4.3.2`), then load the MPI-specific `netcdf` /
`sparta` modules that become visible in `module avail`.

## Layout

```
containers/ubuntu-XX.04/Containerfile   custom builder image (gcc, gfortran, lmod, libfabric)
build/versions.env                      pinned upstream versions + tarball URLs
build/*.sh                              one build script per module
build/selftest.sh                       lmod load + runtime validation of the whole tree
test/local.sh                           local podman driver for the full pipeline
tests/assets/                           tiny C/Fortran smoke-test programs
.github/workflows/build.yml             GitHub Actions matrix: 24.04 & 26.04
```

## What a finished build looks like

Each CI job (and each local run) produces `/opt/automod`:

```
/opt/automod
├── modulefiles/...          the lmod tree listed above
└── software/
    ├── hdf5/1.14.6/<flavor>       hdf5 linked against that flavor
    ├── netcdf/4.9.3/<flavor>      netcdf-c
    ├── netcdf-fortran/4.6.2/<flavor>
    ├── mpich/4.3.2/               full install tree
    ├── openmpi/4.1.8/
    ├── sparta/27Aug2026/<flavor>
    └── intel oneapi lives in /opt/intel/oneapi (binary install)
```

`<flavor>` is `gnu` (serial) or `mpich` / `openmpi`.

## Local testing with podman

```bash
./test/local.sh 24.04            # full pipeline: mpich, openmpi, netcdf,
                                 # sparta, oneapi, selftest
./test/local.sh 24.04 sparta.sh  # re-run a single script (builds are
                                 # idempotent, so only missing work repeats)
./test/local.sh 26.04            # same pipeline for the next Ubuntu release
```

Each run writes into `./modtree-<os>/` (the module tree) and `./.intel-<os>/`
(the oneAPI install, mounted as `/opt/intel`). Step-by-step build logs land in
`./.tmplogs/` for inspection after a failure.

## Using the result on the cluster

1. Download the `automod-modtree-ubuntu-<rel>` artifact from a successful
   GitHub Actions run.
2. Extract it at the filesystem root on the cluster: `tar -xf automod-modtree-ubuntu-24.04.tar.gz -C /`
   (trees are built to live under `/opt/automod`).
3. Make lmod aware of it — each scope directory is its own MODULEPATH root:

   ```bash
   module use /opt/automod/modulefiles/mpi \
              /opt/automod/modulefiles/libs \
              /opt/automod/modulefiles/apps \
              /opt/automod/modulefiles/compilers
   ```

4. Intel oneAPI/Intel MPI is a binary apt install under `/opt/intel/oneapi`,
   performed by the same container images; the artifact therefore ships its
   modulefiles, while the cluster needs the matching Intel runtime packages
   (Intel MPI runtime + libfabric) installed at `/opt/intel` separately.
   Intel MPI's 2026-series wrappers default to the removed legacy `icc`
   backend — with the `oneapi` module loaded, point them at the current
   compilers: `export I_MPI_CC=icx I_MPI_CXX=icpx I_MPI_FC=ifx`. The
   gcc-backed wrappers (`mpigcc`, `mpigxx`) work without `oneapi` loaded.

## Supported versions

See `build/versions.env` for the exact pinned tarballs (mpich 4.3.2, Open MPI
4.1.8, HDF5 1.14.6, netCDF-C 4.9.3, netCDF-Fortran 4.6.2, SPARTA tag
27Aug2026). Intel oneAPI tracks the current release of Intel's apt repo.

## Supported Ubuntu releases

24.04 (noble) and 26.04 — both built on every push, PR, weekly schedule, and
`workflow_dispatch`.
