#!/usr/bin/env bash
#
# run_interconnect_suite.sh -- run the GPU microkernel suite at 1, 2 and 12
# ranks and print the results as markdown tables.
#
# Scaling from 1 tile to a full node is the point of the exercise: a node whose
# 12-tile result is not close to 12x its 1-tile result has a problem that a
# single-tile run will not reveal.
#
# This script only launches binaries; it does not compile. Build the tree
# first (see README.md):
#
#   cmake -S <source> -B <build> -DHEALTH_CHECKS_ENABLE_SYCL=ON \
#         -DHEALTH_CHECKS_ENABLE_LEVEL_ZERO=ON -DCMAKE_CXX_COMPILER=mpicxx
#   cmake --build <build> -j
#
# ENVIRONMENT
#   BUILD_DIR   directory holding the built binaries   (default: ./ then ../../build/health_checks)
#   SCRIPT_DIR  directory holding the tile wrappers    (default: this script's directory)
#   RANKS       rank counts to sweep                   (default "1 2 12")
#   LOG         raw log path                           (default interconnect_log.txt)
#
# USAGE  (inside a single-node PBS job)
#   ./run_interconnect_suite.sh
#   RANKS="1 12" ./run_interconnect_suite.sh
#
# Missing binaries are skipped with a notice rather than failing the run, so a
# tree built without SYCL still produces the OpenMP-offload tables.

set -uo pipefail

SCRIPT_DIR=${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
REPO_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)

# Resolve the build directory: an explicit BUILD_DIR wins, then the current
# directory (the common case when running from the build tree), then the
# location health_checks.yaml configures.
if [[ -n "${BUILD_DIR:-}" ]]; then
  :
elif [[ -x ./flops || -x ./triad ]]; then
  BUILD_DIR=$(pwd)
else
  BUILD_DIR=$(cd "${REPO_DIR}/../.." 2>/dev/null && pwd)/build/health_checks
fi

RANKS=${RANKS:-"1 2 12"}
LOG=${LOG:-interconnect_log.txt}
TILE_COMPACT=${SCRIPT_DIR}/gpu_tile_compact.sh
TILE_PLAN=${SCRIPT_DIR}/gpu_tile_plan_compact.sh

echo "Build dir:  ${BUILD_DIR}"
echo "Rank sweep: ${RANKS}"
echo "Log:        ${LOG}"
echo

# run_kernel <binary name> <wrapper> [extra args...]
run_kernel() {
  local name=$1; shift
  local wrapper=$1; shift
  local bin="${BUILD_DIR}/${name}"

  if [[ ! -x "${bin}" ]]; then
    echo "-- skipping ${name}: not built at ${bin}"
    return 0
  fi

  local extra_mpi=()
  # PCIe transfers are sensitive to which NUMA domain the rank sits on.
  if [[ "${name}" == "pci" ]]; then
    extra_mpi=(--cpu-bind list:1,2,3,4,5,6,52,53,54,55,56,57)
  fi

  for n in ${RANKS}; do
    # peer-to-peer needs rank pairs; a single rank has no partner.
    if [[ "${name}" == "peer2pear" && "${n}" -lt 2 ]]; then
      continue
    fi
    echo "-- ${name} @ ${n} rank(s) ${*:+(args: $*)}"
    mpiexec -n "${n}" "${extra_mpi[@]}" -- "${wrapper}" "${bin}" "$@" || \
      echo "-- ${name} @ ${n} rank(s) failed (rc=$?)"
  done
}

{
  # Peak FLOPs and memory bandwidth: OpenMP offload.
  run_kernel flops "${TILE_COMPACT}"
  run_kernel triad "${TILE_COMPACT}"

  # Host/device transfer over PCIe.
  run_kernel pci "${TILE_COMPACT}"

  # Peer bandwidth. copy_high_bandwidth selects the copy engine intended for
  # bulk transfers rather than the default low-latency one.
  export MPIR_CVAR_CH4_IPC_GPU_ENGINE_TYPE=copy_high_bandwidth
  run_kernel peer2pear "${TILE_COMPACT}" "Tile2Tile"

  if [[ -x "${BUILD_DIR}/topology" ]]; then
    # gpu_tile_plan_compact.sh shells out to ./topology, so run from the build
    # directory where that binary lives.
    ( cd "${BUILD_DIR}" && run_kernel peer2pear "${TILE_PLAN}" "GPU2GPU" )
  else
    echo "-- skipping GPU2GPU: topology not built (needs -DHEALTH_CHECKS_ENABLE_LEVEL_ZERO=ON)"
  fi

  # oneMKL kernels.
  run_kernel gemm "${TILE_COMPACT}"
  run_kernel fftc2c "${TILE_COMPACT}"
} 2>&1 | tee "${LOG}"

echo
echo "=== Summary tables ==="
for section in micro GEMM FFT; do
  echo
  echo "## ${section}"
  "${REPO_DIR}/tools/gen_mk_table.py" "${LOG}" "${section}" \
    | column -t -s "|" -o "|" -R 0
done
