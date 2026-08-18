#!/usr/bin/env bash
#
# gpu_tile_compact.sh -- pin an MPI rank to one GPU tile, then exec the payload.
#
# Aurora nodes carry 6 GPUs of 2 tiles each, 12 tiles total, which is why the
# standard rank count per node is 12. This wrapper maps the node-local rank to
# a tile in compact order (rank 0 -> 0.0, rank 1 -> 0.1, rank 2 -> 1.0, ...)
# and exports ZE_AFFINITY_MASK so the payload sees exactly that one tile.
#
# Without this wrapper every rank on the node opens tile 0.0 and the measured
# bandwidth is the contention between them, not the device.
#
# ZE_ENABLE_PCI_ID_DEVICE_ORDER makes Level Zero enumerate devices in PCI bus
# order, so the mapping is stable across nodes and reboots.
#
# USAGE  mpiexec -n <ranks> -- ./gpu_tile_compact.sh ./<binary> [args]
#
# For pairing ranks onto same-plane GPUs instead of adjacent tiles, use
# gpu_tile_plan_compact.sh.

set -euo pipefail

num_gpu=6
num_tile=2

if [[ -z "${PALS_LOCAL_RANKID:-}" ]]; then
  echo "gpu_tile_compact.sh: PALS_LOCAL_RANKID is not set." >&2
  echo "  This script must run under mpiexec on Aurora (PALS launcher)." >&2
  exit 2
fi

_MPI_RANKID=${PALS_LOCAL_RANKID}
gpu_id=$((_MPI_RANKID / num_tile))
tile_id=$((_MPI_RANKID % num_tile))

if (( gpu_id >= num_gpu )); then
  echo "gpu_tile_compact.sh: local rank ${_MPI_RANKID} maps to GPU ${gpu_id}," \
       "but this node has only ${num_gpu}. Use at most $((num_gpu * num_tile))" \
       "ranks per node." >&2
  exit 2
fi

export ZE_ENABLE_PCI_ID_DEVICE_ORDER=1
export ZE_AFFINITY_MASK=${gpu_id}.${tile_id}

exec "$@"
