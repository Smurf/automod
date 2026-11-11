#!/usr/bin/env bash
# Local testing helper: build the container image and run the full module
# pipeline for one Ubuntu release. Usage: ./test/local.sh 24.04 [script.sh...]
# Mirrors the CI flow: /opt/intel persists across containers via a local dir
# so the oneapi step's apt install is visible to the selftest step.
set -euo pipefail
os="${1:-24.04}"
shift || true
cd "$(cd "$(dirname "$0")/.." && pwd)"

tag="automod:ubuntu-$os"
tree="modtree-$os"
intel=".intel-$os"

if [ ! "$(podman image ls -q "$tag")" ]; then
    podman build --quiet -t "$tag" -f "containers/ubuntu-$os/Containerfile" "containers/ubuntu-$os"
fi
mkdir -p "$tree" "$intel"

run() { podman run --rm --workdir /src \
    -e "LOGDIR=/src/.tmplogs" \
    -v "$PWD:/src" -v "$PWD/$tree:/opt/automod" -v "$PWD/$intel:/opt/intel" \
    "$tag" bash "/src/build/$1"; }

tasks=("$@")
if [ "${#tasks[@]}" -eq 0 ]; then
    tasks=(mpich.sh openmpi.sh netcdf.sh sparta.sh oneapi.sh selftest.sh)
fi
mkdir -p .tmplogs
for t in "${tasks[@]}"; do
    echo "== $t =="
    run "$t"
done
echo "done; module tree written to ./$tree"
