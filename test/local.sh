#!/usr/bin/env bash
# Local testing helper: build the container image and run the full module
# pipeline for one OS. Usage:
#   ./test/local.sh 24.04            Ubuntu 24.04
#   ./test/local.sh rocky-9          Rocky Linux 9 (or any containers/<name>)
#   ./test/local.sh 24.04 sparta.sh  re-run a single script (builds are
#                                    idempotent, so only missing work repeats)
# Mirrors the CI flow: /opt/intel persists across containers via a local dir
# so the oneapi step's apt/dnf install is visible to the selftest step.
set -euo pipefail
os="${1:-24.04}"
shift || true
cd "$(cd "$(dirname "$0")/.." && pwd)"

# "24.04"-style arguments select an Ubuntu release; anything else is used
# verbatim as the containers/<name> directory (e.g. rocky-9).
case "$os" in
    [0-9]*) image="ubuntu-$os" ;;
    *)      image="$os" ;;
esac

tag="automod:$image"
tree="modtree-$image"
intel=".intel-$image"

if [ ! "$(podman image ls -q "$tag")" ]; then
    podman build --quiet -t "$tag" -f "containers/$image/Containerfile" "containers/$image"
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
