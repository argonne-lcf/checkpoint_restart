#!/usr/bin/env bash
#
# gpu_tile_plan_compact.sh -- pin an MPI rank to a GPU tile chosen by fabric
# plane, then exec the payload.
#
# Same purpose as gpu_tile_compact.sh, but instead of mapping rank N to tile
# N in compact order it asks the topology binary which tile sits at position N
# in the fabric plane listing. Ranks paired as (0,1), (2,3), ... therefore land
# on GPUs that share a direct Xe Link, which is what the GPU2GPU peer bandwidth
# measurement requires.
#
# REQUIREMENT  The topology binary must be present in the current directory.
#              Build it with -DHEALTH_CHECKS_ENABLE_LEVEL_ZERO=ON and run from
#              the build directory, or copy it alongside this script.
#
# USAGE  mpiexec -n <ranks> -- ./gpu_tile_plan_compact.sh ./peer2pear "GPU2GPU"

set -euo pipefail

if [[ -z "${PALS_LOCAL_RANKID:-}" ]]; then
  echo "gpu_tile_plan_compact.sh: PALS_LOCAL_RANKID is not set." >&2
  echo "  This script must run under mpiexec on Aurora (PALS launcher)." >&2
  exit 2
fi

if [[ ! -x ./topology ]]; then
  echo "gpu_tile_plan_compact.sh: ./topology not found or not executable." >&2
  echo "  Configure with -DHEALTH_CHECKS_ENABLE_LEVEL_ZERO=ON and run from the" >&2
  echo "  build directory." >&2
  exit 2
fi

_MPI_RANKID=${PALS_LOCAL_RANKID}

export ZE_ENABLE_PCI_ID_DEVICE_ORDER=1
export ZES_ENABLE_SYSMAN=1
export ZE_AFFINITY_MASK=$(./topology "${_MPI_RANKID}")

exec "$@"
