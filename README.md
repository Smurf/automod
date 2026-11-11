# automod

A reproducible HPC environment-module stack for Ubuntu and Rocky Linux
clusters, built as **lmod** modulefiles. Everything is compiled inside custom
container images (Ubuntu 24.04, Ubuntu 26.04, Rocky Linux 9) by GitHub
Actions using **podman**, so what is tested locally is byte-for-byte the
pipeline that runs in CI.

## Modules produced

MODULEPATH roots are the four scope directories
(`modulefiles/{mpi,libs,apps,compilers}`), each registered as its own root, so
users load plain names (`mpich/4.3.2`, `netcdf/4.9.3`); Lmod displays MPI-flavored
hierarchy modules with the MPI name prefixed (`mpich/4.3.2/netcdf/4.9.3`).

| `module load` name                            | Software                              |
|-----------------------------------------------|---------------------------------------|
| `mpich/4.3.2`, `mpich/4.2.3`                   | MPICH (ch4/ofi device, gcc backend)   |
| `openmpi/4.1.8`, `openmpi/4.1.6`               | Open MPI 4.1.x                        |
| `intelmpi/2021.19`, `intelmpi/2021.18`         | Intel MPI Library                     |
| `oneapi/2026.2`, `oneapi/2025.3`               | Intel oneAPI compilers (icx/ifx)      |
| `mkl/2026.2`, `mkl/2025.3`                     | Intel Math Kernel Library (libmkl_rt) |
| `netcdf/4.9.3`, `netcdf/4.9.2` (serial)        | netCDF-C + Fortran, serial (gcc)      |
| `netcdf/<ver>` under `mpich/<v>`               | netCDF-C + Fortran, MPICH parallel    |
| `netcdf/<ver>` under `openmpi/<v>`             | netCDF-C + Fortran, Open MPI parallel |
| `sparta/27Aug2026` (serial or under an MPI)    | SPARTA DSMC                           |

Multiple versions of each package are built side by side (the matrix is
pinned in `build/versions.env`); load any of them by version. netCDF and
SPARTA are built against *every* MPI version, so the hierarchy is complete
(`mpi/mpich/4.2.3/netcdf/4.9.2` etc.).

The MPI and netCDF/SPARTA modules follow the usual Lmod hierarchy: load an MPI
first (`module load mpich/4.2.3`), then load the MPI-specific `netcdf` /
`sparta` modules that become visible in `module avail`. MKL links through the
single dynamic interface (`-lmkl_rt`); with a GNU toolchain set
`MKL_THREADING_LAYER=GNU` (the `mkl` module sets `MKL_INTERFACE_LAYER=LP64`).

## Layout

```
containers/ubuntu-XX.04/Containerfile   custom builder image (gcc, gfortran, lmod, libfabric)
containers/rocky-9/Containerfile         Rocky Linux 9 builder image (dnf, EPEL Lmod, CRB)
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
    ├── netcdf/<ncver>/<flavor>    netcdf-c (one per netCDF version)
    ├── netcdf-fortran/<nfver>/<flavor>
    ├── mpich/<mpiver>/            full install tree, one per version
    ├── openmpi/<mpiver>/
    ├── sparta/27Aug2026/<flavor>
    └── intel oneapi lives in /opt/intel/oneapi (binary install:
        compiler/<v>, mpi/<v> and mkl/<v> per version)
```

`<flavor>` is `gnu` (serial) or `<mpi>-<mpiver>` (e.g. `mpich-4.3.2`,
`openmpi-4.1.6`) — the MPI version is part of the flavor because the
parallel builds are linked against that exact MPI.

## Local testing with podman

```bash
./test/local.sh 24.04            # full pipeline: mpich, openmpi, netcdf,
                                 # sparta, oneapi, selftest
./test/local.sh 24.04 sparta.sh  # re-run a single script (builds are
                                 # idempotent, so only missing work repeats)
./test/local.sh 26.04            # same pipeline for the next Ubuntu release
./test/local.sh rocky-9          # Rocky Linux 9 (any containers/<name> dir)
```

Each run writes into `./modtree-<os>/` (the module tree) and `./.intel-<os>/`
(the oneAPI install, mounted as `/opt/intel`). Step-by-step build logs land in
`./.tmplogs/` for inspection after a failure. The harness is idempotent —
reruns rebuild only what is missing.

## Using the result on the cluster

1. Download the `automod-modtree-ubuntu-<rel>` artifact from a successful
   GitHub Actions run — or, easier, grab both tarballs (plus `SHA256SUMS`)
   from a published **GitHub release**: push a `v*` tag and the workflow
   builds both Ubuntu releases and attaches them, e.g.

   ```bash
   git tag v2026.11 && git push origin v2026.11
   ```
2. Extract it at the filesystem root on the cluster: `tar -xf automod-modtree-ubuntu-24.04.tar.gz -C /`
   (trees are built to live under `/opt/automod`).
3. Make lmod aware of it — each scope directory is its own MODULEPATH root:

   ```bash
   module use /opt/automod/modulefiles/mpi \
              /opt/automod/modulefiles/libs \
              /opt/automod/modulefiles/apps \
              /opt/automod/modulefiles/compilers
   ```

4. Intel oneAPI/Intel MPI/MKL are binary package installs under
   `/opt/intel/oneapi` (apt on Ubuntu, dnf from Intel's yum repo on Rocky),
   performed by the same container images; the artifact therefore ships its
   modulefiles, while the cluster needs the matching Intel runtime packages
   (Intel MPI runtime + libfabric) installed at `/opt/intel` separately.
   Intel MPI's 2026-series wrappers default to the removed legacy `icc`
   backend — with the `oneapi` module loaded, point them at the current
   compilers: `export I_MPI_CC=icx I_MPI_CXX=icpx I_MPI_FC=ifx`. The
   gcc-backed wrappers (`mpigcc`, `mpigxx`) work without `oneapi` loaded.

## Supported versions

See `build/versions.env` for the full version matrix: mpich 4.3.2/4.2.3,
Open MPI 4.1.8/4.1.6, HDF5 1.14.6, netCDF-C 4.9.3/4.9.2 with netCDF-Fortran
4.6.2/4.6.1 (paired by index), and Intel oneAPI compiler 2026.2/2025.3,
Intel MPI 2021.19/2021.18, MKL 2026.2/2025.3 installed side by side from
versioned packages (apt on Ubuntu, dnf from Intel's yum repo on Rocky).
SPARTA tag 27Aug2026 is built against each MPI
version. To add a version, extend the list in `versions.env` — the build
scripts, modulefiles and selftest pick it up automatically.

## Supported OS releases

Ubuntu 24.04 (noble), Ubuntu 26.04, and Rocky Linux 9 — all built on every
push, PR, weekly schedule, and `workflow_dispatch`.
