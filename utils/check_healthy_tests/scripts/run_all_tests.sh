#!/bin/bash
# run_all_tests.sh -- build and run every health-check microkernel, report the
# wall time each one took, and exit non-zero if any of them failed.
#
# Submit as a PBS job:
#
#     qsub -A <project> -q debug -l select=2:ncpus=208 \
#          -l walltime=00:30:00 -l filesystems=flare \
#          utils/check_healthy_tests/scripts/run_all_tests.sh
#
# Or run inside an existing allocation:
#
#     ./utils/check_healthy_tests/scripts/run_all_tests.sh
#
# Environment:
#   REPO_DIR      repo checkout (default: derived from this script's location)
#   RESULTS_DIR   output root   (default: $REPO_DIR/test_results)
#   PPN           ranks per node (default 12, one per GPU tile)
#   SKIP_SLOW     set to 1 to skip pci, gemm and fftc2c (~76 s of the runtime)
#   BUILD         set to 0 to skip the build step
#
# Each run writes to RESULTS_DIR/run_<jobid>/ so a re-run cannot overwrite
# earlier evidence, and a COMPLETE sentinel is written as the final action:
# its absence means the suite died partway, which "job left the queue" alone
# cannot tell you.
#
# IMPORTANT: do not `module load frameworks` before the SYCL kernels. It
# overrides the default oneAPI runtime and they abort with "No device of
# requested type available" (SIGABRT, rc=134). It is loaded here only in a
# subshell for the Python runner, which needs PyYAML.

set -u

# ---------------------------------------------------------------- locations
# Resolving the repo is not as simple as looking at $0. When this script is
# submitted with `qsub run_all_tests.sh`, PBS copies it into a private spool
# directory and executes the copy, so BASH_SOURCE points at /var/spool/... and
# the derived repo path is wrong. Try the candidates in order of reliability
# and take the first that actually looks like the checkout.
resolve_repo() {
    local c
    for c in "${REPO_DIR:-}" \
             "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)" \
             "${PBS_O_WORKDIR:-}" \
             "${PBS_O_WORKDIR:-}/checkmate" \
             "$(git -C "${PBS_O_WORKDIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
             "$PWD"; do
        [ -n "$c" ] || continue
        if [ -f "$c/utils/check_healthy_tests/CMakeLists.txt" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(resolve_repo)" || {
    echo "error: cannot locate the checkmate checkout." >&2
    echo "  Set REPO_DIR explicitly, for example:" >&2
    echo "    qsub -v REPO_DIR=/path/to/checkmate ... run_all_tests.sh" >&2
    exit 2
}
BUILD_DIR="$REPO_DIR/build/health_checks"
RESULTS_DIR="${RESULTS_DIR:-$REPO_DIR/test_results}"

JOBID="${PBS_JOBID:-}"
JOBID="${JOBID%%.*}"
[ -z "$JOBID" ] && JOBID="local_$(date +%Y%m%d_%H%M%S)"
RUN="$RESULTS_DIR/run_${JOBID}"
mkdir -p "$RUN" || {
    echo "error: cannot create results directory:" >&2
    echo "  $RUN" >&2
    echo "Set RESULTS_DIR to a writable path on a shared filesystem." >&2
    exit 1
}

SUMMARY="$RUN/summary.log"
say() { echo "$@" | tee -a "$SUMMARY"; }

PPN="${PPN:-12}"
SKIP_SLOW="${SKIP_SLOW:-0}"
BUILD="${BUILD:-1}"

# Aurora launch configuration. Both matter for the numbers to mean anything.
#
# CPU_BINDING pins one core per GPU tile across both sockets. GPU_WRAP is
# gpu_tile_compact.sh, which sets ZE_AFFINITY_MASK so each rank drives its own
# tile instead of all ranks piling onto tile 0.
#
# Launching without these is not merely slower, it is a different experiment:
# gemm measured 297 s unbound against 31.4 s bound on the same node count.
CPU_BINDING="${CPU_BINDING:-list:4:9:14:19:20:25:56:61:66:71:74:79}"
GPU_WRAP="${GPU_WRAP:-$REPO_DIR/utils/check_healthy_tests/scripts/gpu_tile_compact.sh}"

if [ ! -x "$GPU_WRAP" ]; then
    echo "warning: GPU tile wrapper not found or not executable:" >&2
    echo "  $GPU_WRAP" >&2
    echo "GPU kernels will run without tile affinity and their timings" >&2
    echo "will not be comparable with bound runs." >&2
    GPU_WRAP=""
fi

# ---------------------------------------------------------------- node list
if [ -n "${PBS_NODEFILE:-}" ] && [ -f "$PBS_NODEFILE" ]; then
    sort -u "$PBS_NODEFILE" > "$RUN/nodefile"
else
    hostname > "$RUN/nodefile"
fi
NNODES=$(wc -l < "$RUN/nodefile")

say "############################################################"
say "# health-check microkernel suite"
say "# jobid=$JOBID  nodes=$NNODES  ppn=$PPN"
say "# cpu-bind=$CPU_BINDING"
say "# gpu-wrap=${GPU_WRAP:-<none>}"
say "# repo=$REPO_DIR"
say "# date=$(date)"
say "############################################################"
while read -r n; do say "#   $n"; done < "$RUN/nodefile"
say ""

PASS=0
FAIL=0
declare -a TIMED

# ---------------------------------------------------------------- build
if [ "$BUILD" = "1" ]; then
    say "===== build ====="
    module load cmake >/dev/null 2>&1
    if cmake -S "$REPO_DIR/utils/check_healthy_tests" -B "$BUILD_DIR" \
             -DHEALTH_CHECKS_ENABLE_SYCL=ON \
             -DHEALTH_CHECKS_ENABLE_LEVEL_ZERO=ON > "$RUN/configure.log" 2>&1 \
       && cmake --build "$BUILD_DIR" -j 16 > "$RUN/build.log" 2>&1; then
        say "  build OK"
    else
        say "  BUILD FAILED - see $RUN/configure.log and $RUN/build.log"
        say "  (continuing; kernels that did build are still exercised)"
    fi
    # A partial build is normal on a host missing icpx or Level Zero.
    for feat in SYCL "Level Zero" OpenMP MPI; do
        line=$(grep -- "--   ${feat}" "$RUN/configure.log" 2>/dev/null | head -1)
        [ -n "$line" ] && say "  $(echo "$line" | sed 's/^-- *//')"
    done
    say ""
fi

# ---------------------------------------------------------------- helper
# run_kernel <label> <ranks> <binary> [args...]
#
# Asserts the kernel emitted exactly one KERNEL_TIME line. MPI kernels print
# from rank 0 only, so any other count means the kernel did not reach its exit
# path -- a kill or an early abort that a zero exit status can hide.
run_kernel() {
    local label="$1"; shift
    local ranks="$1"; shift
    local bin="$1"; shift
    local log="$RUN/out.${label}.log"

    if [ ! -x "$bin" ]; then
        say "===== $label ====="
        say "  SKIP: $(basename "$bin") not built"
        say ""
        return 0
    fi

    say "===== $label ====="
    local t0 t1 rc
    t0=$(date +%s.%N)
    if [ "$ranks" = "serial" ]; then
        "$bin" "$@" > "$log" 2>&1
        rc=$?
    else
        if [ -n "$GPU_WRAP" ]; then
            mpiexec -n "$ranks" --ppn "$PPN" --cpu-bind "$CPU_BINDING" \
                    --no-vni -- "$GPU_WRAP" "$bin" "$@" > "$log" 2>&1
        else
            mpiexec -n "$ranks" --ppn "$PPN" --cpu-bind "$CPU_BINDING" \
                    --no-vni -- "$bin" "$@" > "$log" 2>&1
        fi
        rc=$?
    fi
    t1=$(date +%s.%N)

    local wall
    wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')

    local ktlines internal
    ktlines=$(grep -c '^KERNEL_TIME ' "$log" 2>/dev/null)
    ktlines=${ktlines:-0}
    internal=$(grep '^KERNEL_TIME ' "$log" 2>/dev/null | head -1 | awk '{print $3}')

    say "  rc=$rc  wall=${wall}s  internal=${internal:-none}s  KERNEL_TIME_lines=$ktlines (want 1)"

    # Per-phase breakdown, when the kernel reports one.
    grep '^PHASE_TIME ' "$log" 2>/dev/null | while read -r _ _ ph secs _; do
        echo "    phase $ph ${secs}s" | tee -a "$SUMMARY"
    done

    if [ "$rc" -eq 0 ] && [ "$ktlines" -eq 1 ]; then
        say "  VERDICT: PASS"
        PASS=$((PASS+1))
        TIMED+=("$label ${internal:-$wall} $wall")
    else
        say "  VERDICT: FAIL"
        [ "$rc" -ne 0 ] && say "    exit status $rc"
        [ "$ktlines" -ne 1 ] && say "    expected 1 KERNEL_TIME line, saw $ktlines"
        say "    last lines:"
        tail -5 "$log" | sed 's/^/      /' | tee -a "$SUMMARY" >/dev/null
        tail -5 "$log" | sed 's/^/      /'
        FAIL=$((FAIL+1))
    fi
    say ""
}

R1=$PPN
R2=$((NNODES * PPN))

# ---------------------------------------------------------------- serial
say "##################### serial kernels #####################"
run_kernel mem_and_gpu_row serial "$BUILD_DIR/mem_and_gpu_row" --csv
run_kernel topology        serial "$BUILD_DIR/topology"

# ---------------------------------------------------------------- 1 node
say "################ single node, $R1 ranks ##################"
run_kernel triad_1n                      "$R1" "$BUILD_DIR/triad"
run_kernel flops_1n                      "$R1" "$BUILD_DIR/flops"
run_kernel peer2pear_1n                  "$R1" "$BUILD_DIR/peer2pear"
run_kernel simple_injection_bisection_1n "$R1" "$BUILD_DIR/simple_injection_bisection"
run_kernel full_injection_bisection_1n   "$R1" "$BUILD_DIR/full_injection_bisection"

if [ "$SKIP_SLOW" != "1" ]; then
    run_kernel pci_1n    "$R1" "$BUILD_DIR/pci"
    run_kernel fftc2c_1n "$R1" "$BUILD_DIR/fftc2c"
    run_kernel gemm_1n   "$R1" "$BUILD_DIR/gemm"
else
    say "(skipping pci, fftc2c, gemm: SKIP_SLOW=1)"
    say ""
fi

# ---------------------------------------------------------------- 2+ nodes
if [ "$NNODES" -gt 1 ]; then
    say "############### $NNODES nodes, $R2 ranks #################"
    run_kernel triad_${NNODES}n                      "$R2" "$BUILD_DIR/triad"
    run_kernel flops_${NNODES}n                      "$R2" "$BUILD_DIR/flops"
    run_kernel simple_injection_bisection_${NNODES}n "$R2" "$BUILD_DIR/simple_injection_bisection"
    run_kernel full_injection_bisection_${NNODES}n   "$R2" "$BUILD_DIR/full_injection_bisection"
    [ "$SKIP_SLOW" != "1" ] && \
        run_kernel gemm_${NNODES}n "$R2" "$BUILD_DIR/gemm"
else
    say "(single node allocation: multi-node tests skipped)"
    say ""
fi

# ---------------------------------------------------------------- timing table
say "############################################################"
say "# wall time per test"
say "############################################################"
printf "%-38s %12s %10s\n" "test" "internal(s)" "wall(s)" | tee -a "$SUMMARY"
for row in "${TIMED[@]}"; do
    set -- $row
    printf "%-38s %12s %10s\n" "$1" "$2" "$3" | tee -a "$SUMMARY"
done
say ""
say "############################################################"
say "# PASS=$PASS FAIL=$FAIL"
say "# results: $RUN"
say "############################################################"

date > "$RUN/COMPLETE"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
