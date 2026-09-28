#!/bin/bash
# Set up gnina from the official prebuilt release on a machine with no NVIDIA
# GPU, no CUDA toolkit, and no sudo. Idempotent: safe to re-run.
#
# The upstream README only documents a source build, which hard-requires the
# CUDA toolkit (CMakeLists declares CUDA as a project language). That is
# unnecessary here: the release binary already contains the compiled CUDA code
# and only needs the CUDA *runtime* shared libraries at load time, which we
# install as pip wheels into a local venv instead of system-wide.
set -euo pipefail

GNINA_VERSION=v1.3.3
GNINA_ASSET=gnina.cuda12.8.static
GNINA_SHA256=3340c1f49cd3c7c84d8699182a1c6af13c7fa2a22448d1204640446106f72172

# The 7 libs `ldd` reports missing on a machine with no CUDA install. Note
# libcuda.so.1 (the driver) is deliberately absent from this list: the binary
# dlopens it lazily, which is why it runs CPU-only without a GPU present.
CUDA_WHEELS=(
    nvidia-cudnn-cu12        # libcudnn.so.9
    nvidia-cuda-runtime-cu12 # libcudart.so.12
    nvidia-cublas-cu12       # libcublas.so.12, libcublasLt.so.12
    nvidia-cusparse-cu12     # libcusparse.so.12
    nvidia-cufft-cu12        # libcufft.so.11
    nvidia-cusolver-cu12     # libcusolver.so.11
)
TEST_WHEELS=(openbabel-wheel numpy pytest)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/bin/gnina.bin"
VENV="$ROOT/.venv"

step() { printf '\n==> %s\n' "$1"; }

step "Creating venv at $VENV"
if [[ ! -x "$VENV/bin/python" ]]; then
    python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip

step "Installing CUDA runtime libs (~3.6GB) and test deps"
"$VENV/bin/pip" install --quiet "${CUDA_WHEELS[@]}" "${TEST_WHEELS[@]}"
"$VENV/bin/pip" cache purge >/dev/null 2>&1 || true

step "Fetching gnina $GNINA_ASSET ($GNINA_VERSION, ~2GB)"
mkdir -p "$ROOT/bin"
if [[ -f "$BIN" ]] && echo "$GNINA_SHA256  $BIN" | sha256sum -c --status; then
    echo "already present and checksum matches, skipping download"
else
    url="https://github.com/gnina/gnina/releases/download/$GNINA_VERSION/$GNINA_ASSET"
    curl -L --progress-bar -o "$BIN" "$url"
    echo "$GNINA_SHA256  $BIN" | sha256sum -c
fi
chmod +x "$BIN" "$ROOT/bin/gnina"

step "Fetching upstream test suite ($GNINA_VERSION, sparse — test/ and scripts/)"
# Sparse partial clone: ~8MB instead of the ~400MB full clone. Not vendored
# into this repo on purpose, so it stays pullable from upstream and its
# Apache/GPL licensing stays with upstream.
if [[ -d "$ROOT/upstream/.git" ]]; then
    git -C "$ROOT/upstream" fetch --depth 1 origin "$GNINA_VERSION" --quiet
    git -C "$ROOT/upstream" checkout --quiet FETCH_HEAD
else
    rm -rf "$ROOT/upstream"
    git clone --depth 1 --filter=blob:none --sparse --quiet \
        --branch "$GNINA_VERSION" https://github.com/gnina/gnina.git "$ROOT/upstream"
    git -C "$ROOT/upstream" sparse-checkout set test scripts
fi

step "Smoke test"
cd "$ROOT/upstream/test/gnina"
out=$("$ROOT/bin/gnina" -r data/noelem_rec.pdb -l data/noelem.sdf --score_only 2>&1)
aff=$(grep -oP 'Affinity: \K\S+' <<<"$out")
cnn=$(grep -oP 'CNNaffinity: \K\S+' <<<"$out")
echo "Affinity=$aff  CNNaffinity=$cnn"
# Same thresholds upstream's own test_gnina.py asserts for this complex.
awk -v a="$aff" -v c="$cnn" 'BEGIN{ if (a<-8 && c>5) print "PASS"; else { print "FAIL"; exit 1 } }'

printf '\nDone. Run gnina via %s/bin/gnina\n' "$ROOT"
