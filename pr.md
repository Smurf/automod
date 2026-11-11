# Multi-version module stack: netcdf, mpich, openmpi, oneAPI (+ Intel MKL)

## Summary

Until now every package in the automod stack was built from a single pinned
version, so loading `mpich/4.3.2` was the only choice a cluster user had.
This PR turns the pinned singletons into a version matrix: **multiple
versions of netCDF, MPICH, Open MPI and Intel oneAPI (compilers, Intel MPI,
and Intel MKL) are built side by side and exposed as ordinary Lmod
modules.**

The version matrix lives in `build/versions.env`:

| Package              | Versions built             |
|----------------------|----------------------------|
| MPICH                | 4.3.2, 4.2.3               |
| Open MPI             | 4.1.8, 4.1.6               |
| netCDF-C / Fortran   | 4.9.3/4.6.2, 4.9.2/4.6.1   |
| oneAPI compilers     | 2026.2, 2025.3             |
| Intel MPI            | 2021.19, 2021.18           |
| Intel MKL (new)      | 2026.2, 2025.3             |

Adding a version is now a one-line change: append it to the list and the
build scripts, modulefiles and selftest pick it up automatically. Tarball
URLs became per-version helpers (`mpich_url 4.2.3`, ...) since the file
name tracks the version.

## What is built

- **MPI roots**: `mpi/mpich/<v>.lua` and `mpi/openmpi/<v>.lua` for each
  version, each with its own prefix (`software/{mpich,openmpi}/<v>`) and a
  2-rank hello smoke test.
- **netCDF**: for every netCDF-C/Fortran pair, one serial `gnu` flavor plus
  one parallel flavor per MPI version (flavor dirs encode the MPI version:
  `mpich-4.3.2`, `openmpi-4.1.6`, ...). The Lmod hierarchy is therefore
  complete — `mpi/mpich/4.2.3/netcdf/4.9.2` etc. all exist.
- **SPARTA**: a build + hierarchy module under every MPI version
  (`mpi/mpich/4.2.3/sparta/<tag>` ...), plus the serial build.
- **Intel oneAPI**: versioned apt packages install side by side into
  `/opt/intel/oneapi/{compiler,mpi,mkl}/<ver>`; only versions whose
  directory is missing are installed, keeping the step idempotent on the
  persistent `/opt/intel` volume. One module per version:
  - `compilers/oneapi/<v>.lua` (icx/ifx)
  - `mpi/intelmpi/<v>.lua`
  - `libs/mkl/<v>.lua` — **new**: Intel MKL, exposing `MKLROOT` and linking
    through the single dynamic interface (`-lmkl_rt`,
    `MKL_INTERFACE_LAYER=LP64`; set `MKL_THREADING_LAYER=GNU` with a GNU
    toolchain). Validated with a `cblas_sgemm` smoke test
    (`tests/assets/mkl-hello.c`).

## Selftest

`build/selftest.sh` now walks the whole matrix: each netCDF serial version,
each MPI version (mpicc hello + mpirun, hierarchical netCDF compile+run,
SPARTA banner), each oneAPI compiler (icx + ifx), each Intel MPI version
(gcc wrapper + mpirun, plus the icx-backed `mpiicc` for the newest pair)
and each MKL version (sgemm through `libmkl_rt`).

## Local verification (test harness, podman, on this machine)

Full pipeline `./test/local.sh <os>` run end to end for both releases:

```
ubuntu-24.04: 54 PASS, 0 FAIL — selftest OK (exit 0)
ubuntu-26.04: 54 PASS, 0 FAIL — selftest OK (exit 0)
```

Resulting module tree (25 modulefiles per release): 2 mpich + 2 openmpi +
2 intelmpi roots, 2 oneapi compilers, 2 mkl libs, 2 serial netcdf, and
netcdf + sparta hierarchy modules under every one of the 4 MPI versions.

## Fixes along the way (found by the harness)

- **Open MPI < 4.1.7 on Ubuntu 26.04** failed to compile: libfabric 2.x
  dropped the `container_of` macro that `ompi/mca/mtl/ofi` relies on.
  Backported the 4.1.7 fix (the `opal/util/misc.h` fallback, inlined with
  `#ifndef container_of`) into older trees during the build.
- Intel MPI wrappers need `I_MPI_ROOT` exported per version; the smoke test
  also resets `PATH`/`LD_LIBRARY_PATH`/`CPATH` per version so no older
  install's libs leak into a newer one's run.
- `test/local.sh` passed the *host* path as `LOGDIR`, so per-step logs were
  written to a throwaway path inside the container and never reached
  `./.tmplogs/` — now `/src/.tmplogs` (matches CI).
- `build.yml` used one shared `.intel` mount for both matrix jobs — now
  per-job `.intel-<os>`, consistent with `test/local.sh`.

## CI: publish releases

The workflow now triggers on `v*` tags and a new `release` job (runs only
after both Ubuntu matrix jobs pass) attaches the finished module trees plus
a `SHA256SUMS` file to a GitHub release, created with the `gh` CLI and the
built-in token (no third-party actions, no secrets). Regular
push/PR/schedule runs are unchanged.

```bash
git tag v2026.11 && git push origin v2026.11
```

## Commits

| Commit | What |
|--------|------|
| `5be84e3` | versions.env version matrix + per-version URL helpers |
| `83c2403` | mpich/openmpi built per version |
| `6386913` | netCDF + SPARTA flavors per MPI version, multi-version netCDF |
| `66bc6ca` | multi-version oneAPI + Intel MPI + MKL modules, mkl smoke asset |
| `8c168c9` | selftest validates every version |
| `fcb6b9b` | README for the version matrix |
| `acf708e` | CI per-job `.intel-<os>` volume |
| `5964a43` | oneapi smoke test: per-version env, I_MPI_ROOT |
| `37e7623` | selftest loads intelmpi before icx-wrapper check |
| `cf68852` | local.sh keeps per-step logs |
| `7000885`, `1e39eb8` | Open MPI < 4.1.7 container_of backport |
| `3fe976c` | CI publishes module trees as GitHub releases on v* tags |
