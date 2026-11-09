#!/usr/bin/env bash
# Local testing helper: build the container image and run the full module
# pipeline for one Ubuntu release. Usage: ./test/local.sh 24.04 [tasks...]
set -euo pipefail
os="${1:-24.04}"
shift || true
cd "$(cd "$(dirname "$0")/.." && pwd)"

tag="automod:ubuntu-$os"
tree="modtree-$os"

if [ ! "$(podman image ls -q "$tag")" ]; then
    podman build --quiet -t "$tag" -f "containers/ubuntu-$os/Containerfile" "containers/ubuntu-$os"
fi
mkdir -p "$tree"

run() { podman run --rm --workdir /src -v "$PWD:/src" -v "$PWD/$tree:/opt/automod" "$tag" bash "/src/build/$1"; }

tasks=("$@")
if [ "${#tasks[@]}" -eq 0 ]; then
    tasks=(mpich.sh openmpi.sh netcdf.sh sparta.sh oneapi.sh selftest.sh)
fi
for t in "${tasks[@]}"; do
    echo "== $t =="
    run "$t"
done
echo "done; module tree written to ./$tree"
