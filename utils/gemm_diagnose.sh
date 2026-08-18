#!/bin/bash
# gemm_diagnose.sh -- run the GPU perf kernels against a specific node set and
# decide whether a node should be retired permanently or returned to the pool.
#
# Usage: gemm_diagnose.sh NODEFILE OUTPUT_PREFIX [THRESHOLD_PCT]
#
# This is deliberately NOT part of node selection. gemm at 8192^3 x 6
# precisions is far too expensive to run on every restart, and until a node
# has actually misbehaved there is nothing to diagnose. It answers a narrower
# question: this node has now crashed twice, is the hardware degraded or was
# it unlucky?
#
# Exit codes:
#   0  no tile below threshold; the node set looks healthy (return to pool)
#   3  at least one tile below threshold (candidate for permanent retirement)
#   2  usage or environment error
#
# The candidate list is written to OUTPUT_PREFIX.candidates, one hostname per
# line, deduplicated, ready to append to a crashed_nodes exclude file.

NODEFILE=$1
PREFIX=$2
THRESHOLD=${3:-${GEMM_OUTLIER_PCT:-10}}

if [[ -z "$NODEFILE" || -z "$PREFIX" ]]; then
    echo "Usage: $0 NODEFILE OUTPUT_PREFIX [THRESHOLD_PCT]"
    exit 2
fi

if [[ ! -f "$NODEFILE" ]]; then
    echo "gemm_diagnose: nodefile $NODEFILE not found"
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEMM_BIN=${GEMM_BIN:-}
if [[ -z "$GEMM_BIN" ]]; then
    for cand in \
        "$SCRIPT_DIR/../build/health_checks/gemm" \
        "$SCRIPT_DIR/../../build/health_checks/gemm" \
        "$(command -v gemm 2>/dev/null)"; do
        if [[ -n "$cand" && -x "$cand" ]]; then
            GEMM_BIN="$cand"
            break
        fi
    done
fi

if [[ -z "$GEMM_BIN" || ! -x "$GEMM_BIN" ]]; then
    echo "gemm_diagnose: gemm binary not found; build it or set GEMM_BIN"
    exit 2
fi

NNODES=$(sort -u "$NODEFILE" | wc -l)
NRANKS=$((NNODES * 12))

echo "gemm_diagnose: $NNODES node(s), $NRANKS ranks, threshold ${THRESHOLD}%"
echo "gemm_diagnose: binary $GEMM_BIN"

TILE_WRAPPER="$SCRIPT_DIR/check_healthy_tests/scripts/gpu_tile_compact.sh"
[[ -x "$TILE_WRAPPER" ]] || TILE_WRAPPER=""

# Without the tile wrapper every rank can land on tile 0, which makes the
# per-tile comparison meaningless rather than merely coarse.
if [[ -z "$TILE_WRAPPER" ]]; then
    echo "gemm_diagnose: WARNING tile wrapper not found; ranks may share a tile"
fi

PBS_NODEFILE="$NODEFILE" mpiexec -np "$NRANKS" --ppn 12 --no-vni \
    $TILE_WRAPPER "$GEMM_BIN" --threshold "$THRESHOLD" \
    > "$PREFIX.log" 2>&1
MPI_RC=$?

if [[ $MPI_RC -ne 0 ]]; then
    # A launch failure is not evidence about the hardware.
    echo "gemm_diagnose: mpiexec exited $MPI_RC; no verdict (see $PREFIX.log)"
    exit 2
fi

grep "GEMM_CANDIDATE" "$PREFIX.log" | awk '{print $2}' | sort -u > "$PREFIX.candidates"
NCAND=$(wc -l < "$PREFIX.candidates")

echo "gemm_diagnose: full output $PREFIX.log"
if [[ "$NCAND" -gt 0 ]]; then
    echo "gemm_diagnose: $NCAND node(s) with tiles below threshold:"
    grep "GEMM_CANDIDATE" "$PREFIX.log"
    echo "gemm_diagnose: candidate hosts in $PREFIX.candidates"
    exit 3
fi

echo "gemm_diagnose: no tile below threshold"
exit 0
