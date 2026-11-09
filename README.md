# automod

A reproducible HPC environment-module stack for Ubuntu clusters, built as
**lmod** modulefiles. Everything is compiled inside custom container images
(Ubuntu 24.04 and 26.04) by GitHub Actions using **podman**, so what is tested
locally is byte-for-byte the pipeline that runs in CI.

## Modules produced

| Module file                                   | Software                              |
|-----------------------------------------------|---------------------------------------|
| `mpi/mpich/4.3.2`                             | MPICH (ch4/ofi device, gcc backend)   |
| `mpi/openmpi/4.1.8`                           | Open MPI 4.1.8                         |
| `mpi/mpich/4.3.2/netcdf/4.9.3`                | netCDF-C + Fortran, parallel I/O      |
| `mpi/openmpi/4.1.8/netcdf/4.9.3`              | netCDF-C + Fortran, parallel I/O      |
| `mpi/mpich/4.3.2/sparta/27Aug2026`            | SPARTA DSMC, MPICH build              |
| `mpi/openmpi/4.1.8/sparta/27Aug2026`          | SPARTA DSMC, Open MPI build           |
| `mpi/intelmpi/<ver>`                          | Intel MPI Library                      |
| `compilers/oneapi/<ver>`                      | Intel oneAPI compilers (icx/ifx)      |
| `apps/sparta/27Aug2026-gnu`                   | SPARTA DSMC, serial build             |
| `libs/netcdf/4.9.3`                           | netCDF-C + Fortran, serial (gcc)      |

The MPI and netCDF/SPARTA modules follow the usual Lmod hierarchy: load an MPI
first (`module load mpich/4.3.2`), and its MPI-specific `netcdf` / `sparta`
modules become visible in `module avail`.

## Layout

```
containers/ubuntu-XX.04/Containerfile   custom builder image (gcc, gfortran, lmod, libfabric)
build/versions.env                      pinned upstream versions + tarball URLs
build/*.sh                              one build script per module
build/selftest.sh                       lmod load + runtime validation of the whole tree
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
podman build --quiet -t automod:ubuntu-24.04 -f containers/ubuntu-24.04/Containerfile containers/ubuntu-24.04
mkdir -p modtree-24.04
podman run --rm --workdir /src -v "$PWD:/src" -v "$PWD/modtree-24.04:/opt/automod" \
    automod:ubuntu-24.04 bash /src/build/mpich.sh
# then openmpi.sh, netcdf.sh, sparta.sh, oneapi.sh and finally
podman run --rm --workdir /src -v "$PWD:/src" -v "$PWD/modtree-24.04:/opt/automod" \
    automod:ubuntu-24.04 bash /src/build/selftest.sh
```

Builds are idempotent, so re-running a script after a failure only repeats the
remaining work.

## Using the result on the cluster

1. Download the `automod-modtree-ubuntu-<rel>` artifact from a successful
   GitHub Actions run.
2. Extract it at the filesystem root on the cluster: `tar -xf automod-modtree-ubuntu-24.04.tar.gz -C /`
   (trees are built to live under `/opt/automod`).
3. Make lmod aware of it: `module use /opt/automod/modulefiles` (or drop that
   line into `/etc/profile.d`).
4. Intel oneAPI/Intel MPI is a binary apt install under `/opt/intel/oneapi`,
   performed by the same container images; the artifact therefore ships its
   modulefiles, while the cluster needs the matching Intel runtime packages
   (Intel MPI runtime + libfabric) installed separately.

## Supported versions

See `build/versions.env` for the exact pinned tarballs (mpich 4.3.2, Open MPI
4.1.8, HDF5 1.14.6, netCDF-C 4.9.3, netCDF-Fortran 4.6.2, SPARTA tag
27Aug2026). Intel oneAPI tracks the current release of Intel's apt repo.

## Supported Ubuntu releases

24.04 (noble) and 26.04 — both built on every push, PR, weekly schedule, and
`workflow_dispatch`.
