#!/usr/bin/env bash
#
# hello_world_scale.sh -- MPI launch smoke test.
#
# Launches one rank per available slot across the allocation and has each print
# its hostname. This is the cheapest possible check that the launcher, the node
# list, and the CPU bindings all work; if it fails, no other microkernel result
# is trustworthy.
#
# The script reads its scale from the allocation rather than hardcoding it, so
# it works unchanged whether the job holds 1 node or 1024. Run it directly
# inside an existing job, or submit it with qsub.
#
# ENVIRONMENT
#   RANKS_PER_NODE  ranks per node                       (default 12, one per GPU tile)
#   CPU_BINDING     mpiexec --cpu-bind argument          (default: Aurora 12-rank list)
#   OUTFILE         where to write raw per-rank output   (default: mktemp)
#
# USAGE
#   Inside a job:  ./hello_world_scale.sh
#   As a job:      qsub -l select=2 -l walltime=00:10:00 -A <project> \
#                       -l filesystems=flare -q debug ./hello_world_scale.sh
#
# EXIT STATUS
#   0  every expected rank reported in
#   1  PBS_NODEFILE missing, or the reported rank count did not match
#
#PBS -A datascience
#PBS -k doe
#PBS -l select=1:ncpus=208
#PBS -q debug
#PBS -l walltime=00:10:00
#PBS -l filesystems=flare
#PBS -j oe

set -uo pipefail

if [[ -n "${PBS_O_WORKDIR:-}" ]]; then
  cd "${PBS_O_WORKDIR}"
fi

if [[ -z "${PBS_NODEFILE:-}" || ! -f "${PBS_NODEFILE}" ]]; then
  echo "hello_world_scale.sh: PBS_NODEFILE is not set or does not exist." >&2
  echo "  Run this inside a PBS job, or submit it with qsub." >&2
  exit 1
fi

NNODES=$(wc -l < "${PBS_NODEFILE}")
RANKS_PER_NODE=${RANKS_PER_NODE:-12}
NRANKS=$(( NNODES * RANKS_PER_NODE ))

# One rank per GPU tile, each pinned to a core on the correct NUMA domain.
CPU_BINDING=${CPU_BINDING:-list:4:9:14:19:20:25:56:61:66:71:74:79}

OUTFILE=${OUTFILE:-$(mktemp "${TMPDIR:-/tmp}/hello_world_scale.XXXXXX")}

echo "Job ID:         ${PBS_JOBID:-<none>}"
echo "Nodes:          ${NNODES}"
echo "Ranks per node: ${RANKS_PER_NODE}"
echo "Total ranks:    ${NRANKS}"
echo "Started:        $(date -Is)"

# --no-vni is required on Aurora; without it the launcher tries to allocate
# network resources this trivial job does not need and can fail on a busy node.
mpiexec -np "${NRANKS}" -ppn "${RANKS_PER_NODE}" \
        --cpu-bind "${CPU_BINDING}" --no-vni -genvall \
        hostname > "${OUTFILE}"
rc=$?

if (( rc != 0 )); then
  echo "mpiexec failed with rc=${rc}" >&2
  exit "${rc}"
fi

reported=$(wc -l < "${OUTFILE}")
distinct=$(sort -u "${OUTFILE}" | wc -l)

echo "Distinct hosts reporting: ${distinct} of ${NNODES}"
sort "${OUTFILE}" | uniq -c

if (( reported != NRANKS )); then
  echo "FAIL: expected ${NRANKS} ranks, ${reported} reported." >&2
  echo "Raw output kept at ${OUTFILE}" >&2
  exit 1
fi

if (( distinct != NNODES )); then
  echo "FAIL: expected ${NNODES} distinct hosts, ${distinct} reported." >&2
  echo "Raw output kept at ${OUTFILE}" >&2
  exit 1
fi

echo "Finished:       $(date -Is)"
echo "PASS: all ${NRANKS} ranks on ${NNODES} nodes reported in."
rm -f "${OUTFILE}"
