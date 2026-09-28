#!/bin/bash
# Time gnina's scoring/docking modes on CPU, to show where the cost sits when
# there is no GPU. Pass a receptor and ligand, or run with no arguments to use
# the 184l complex from the upstream test data.
#
#   ./bench.sh [receptor.pdb ligand.sdf]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GNINA="$ROOT/bin/gnina"
OUT="$ROOT/bench_out"

if [[ $# -eq 2 ]]; then
    PDB="$(realpath "$1")"
    SRC="$(realpath "$2")"
else
    PDB="$ROOT/upstream/test/gnina/data/184l_rec.pdb"
    SRC="$ROOT/upstream/test/gnina/data/184l_lig.sdf"
fi

mkdir -p "$OUT"
LIG="$OUT/lig1.sdf"
# First molecule only, so we time one ligand even if given a multi-mol SDF.
awk '{print} /^\$\$\$\$/{exit}' "$SRC" > "$LIG"

echo "receptor: $(basename "$PDB")   ligand: $(basename "$SRC")"
echo "ligand atoms: $(sed -n '4p' "$LIG" | awk '{print $1}')"
echo "cores: $(nproc)   load: $(cut -d' ' -f1-3 /proc/loadavg)"
echo

run() {
    local label="$1"; shift
    printf '%-46s' "$label"
    local t0 t1
    t0=$(date +%s.%N)
    if timeout 2400 "$GNINA" -r "$PDB" -l "$LIG" --autobox_ligand "$LIG" \
         --seed 0 "$@" >"$OUT/out.log" 2>&1; then
        t1=$(date +%s.%N)
        printf '%8.1f s\n' "$(echo "$t1 - $t0" | bc)"
    else
        printf '  FAILED/TIMEOUT (see %s)\n' "$OUT/out.log"
        tail -3 "$OUT/out.log"
    fi
}

run "score_only, CNN default (ensemble)"   --score_only
run "score_only, --cnn fast (1 model)"     --score_only --cnn fast
run "score_only, --cnn_scoring=none"       --score_only --cnn_scoring=none
run "minimize, --cnn_scoring=none"         --minimize --cnn_scoring=none
run "minimize, CNN default"                --minimize
run "dock exh=8, --cnn_scoring=none"       -o "$OUT/d1.sdf.gz" --exhaustiveness 8 --cnn_scoring=none
run "dock exh=8, --cnn fast"               -o "$OUT/d2.sdf.gz" --exhaustiveness 8 --cnn fast
run "dock exh=8, CNN default (ensemble)"   -o "$OUT/d3.sdf.gz" --exhaustiveness 8
