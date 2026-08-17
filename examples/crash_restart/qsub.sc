#!/bin/bash
#PBS -l walltime=1:00:00
#PBS -q capacity
#PBS -N crash_restart_4of6
#PBS -l select=6
#PBS -l filesystems=flare
#PBS -A datascience

# Artifacts (including PBS stdout/stderr) are collected under tests/, not here.

# ---------------------------------------------------------------------------
# Node-crash restart test.
#
#   JOBSIZE=4 with a 50% reserve -> overalloc.sh 4 50 -> select=6
#
# Trial 1 runs on 4 of the 6 nodes and one of them is crashed on purpose.
# That node is retired and trial 2 restarts on a node pulled from the free
# pool, resuming from the checkpoint, and runs to completion.
#
# All artifacts of a run (nodefiles, checkpoint, logs, scratch) are written
# inside a single self-contained directory: runs/<jobid>/
# Nothing is written to $HOME or /tmp.
# ---------------------------------------------------------------------------

MAX_TRIALS=5
export JOBSIZE=4
export RESERVE_PERCENT=50

# REPO_DIR is the checkpoint_restart checkout, derived from this script's own
# location (examples/crash_restart/qsub.sc) so the script works no matter which
# directory it is submitted from.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/../.." && pwd)
CRASH_DIR=$SCRIPT_DIR
cd "${PBS_O_WORKDIR:-$SCRIPT_DIR}"

# Same environment the other submission scripts use; without it `python` is
# not on PATH on the compute nodes and every rank dies with exit 127.
source /flare/Aurora_deployment/AuroraGPT/soft/checkpoint_restart/conda.sh
export PATH=$REPO_DIR/utils:$REPO_DIR/job_monitoring:$REPO_DIR:$PATH

IFS='.' read -ra ADDR <<< "$PBS_JOBID"
export JOBID=$ADDR

# Test artifacts stay out of the repo under test. Override with TEST_ROOT.
TEST_ROOT=${TEST_ROOT:-$(dirname "$REPO_DIR")/tests}
RUNDIR=$TEST_ROOT/03-multi-node/results/batch-${JOBID:-manual}
rm -rf "$RUNDIR"
mkdir -p "$RUNDIR"
cd "$RUNDIR"

cat $PBS_NODEFILE | uniq > nodefile_all
NALLOC=$(cat nodefile_all | wc -l)
NEED=$(overalloc.sh $JOBSIZE $RESERVE_PERCENT)

{
echo "=========================================================="
echo "Run dir   : $RUNDIR"
echo "Allocated : $NALLOC nodes"
echo "JOBSIZE   : $JOBSIZE  (+${RESERVE_PERCENT}% reserve -> needs $NEED)"
echo "Nodes     : $(tr '\n' ' ' < nodefile_all)"
echo "=========================================================="
} | tee -a run.log

if [ "$NALLOC" -lt "$NEED" ]; then
    echo "FAIL: allocation of $NALLOC is smaller than the required $NEED" | tee -a run.log
    exit 1
fi

touch crashed_nodes
NO_PROGRESS=0
PREV_CKPT=""

# The candidate pool is the full allocation; nodes are retired as they crash.
cp nodefile_all nodefile_pool

# Crash the SECOND node of the allocation, during trial 1 only.
export CRASH_NODE=$(sed -n 2p nodefile_all)
export CRASH_ON_TRIAL=1
# Must exceed the time to the first checkpoint (~1s per iteration) so there is
# real progress to resume from, but leave iterations remaining.
export CRASH_AFTER=12
export CRASHED_NODES_FILE=$RUNDIR/crashed_nodes
echo "Will inject a crash on $CRASH_NODE during trial $CRASH_ON_TRIAL" | tee -a run.log

echo "Started running job at `date`" | tee -a run.log

for RUN in `seq 1 $MAX_TRIALS`
do
    export RUN
    {
    echo "---------- TRIAL $RUN ----------"
    echo "pool: $(tr '\n' ' ' < nodefile_pool)"
    } | tee -a run.log

    # Draw JOBSIZE healthy nodes, never reusing a node that already crashed
    get_healthy_nodes.sh nodefile_pool $JOBSIZE pbs_nodefile$RUN crashed_nodes 2>&1 | tee -a run.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "Spare pool exhausted: fewer than $JOBSIZE usable nodes remain." | tee -a run.log
        echo "RESULT: FAILED (out of spare nodes) after $((RUN-1)) trials" | tee -a run.log
        break
    fi

    export PBS_NODEFILE=$RUNDIR/pbs_nodefile$RUN

    # Record when each node entered service this trial. node_usage.tsv is the
    # ledger the end-of-run summary reads.
    TRIAL_START_EPOCH=$(date +%s)
    TRIAL_START=$(date '+%Y-%m-%d %H:%M:%S')
    while read -r NODE; do
        printf '%s\t%s\t%s\t%s\t%s\n' "$RUN" "$NODE" "START" "$TRIAL_START" "$TRIAL_START_EPOCH" \
            >> node_usage.tsv
    done < pbs_nodefile$RUN

    {
    echo "trial $RUN started at $TRIAL_START"
    echo "running on:"
    while read -r NODE; do echo "    [$TRIAL_START] $NODE"; done < pbs_nodefile$RUN
    echo "free pool : $(tr '\n' ' ' < pbs_nodefile$RUN.free)"
    } | tee -a run.log

    touch output.log
    check_hang.py --timeout 300 --outputs output.log \
        --kill-command "pkill -u $USER mpiexec" >> check_hang.log 2>&1 &
    HANG_PID=$!

    # crash_node.sh sits between the launcher and the payload so it can fail
    # one specific host; every other rank runs test_pyjob.py normally.
    mpiexec --no-vni -np $((JOBSIZE*12)) --ppn 12 \
        launcher.sh $CRASH_DIR/crash_node.sh \
        python $REPO_DIR/test_pyjob.py \
            --compute 1 --niters 30 --checkpoint latest --save-interval 1 \
            --output output.log 2>&1 | tee -a run.log

    EXIT_CODE=${PIPESTATUS[0]}
    kill $HANG_PID 2>/dev/null

    # Close out this trial's node usage. Mark the nodes that crashed so the
    # summary can distinguish "released cleanly" from "died".
    TRIAL_END_EPOCH=$(date +%s)
    TRIAL_END=$(date '+%Y-%m-%d %H:%M:%S')
    while read -r NODE; do
        if grep -qxF "$NODE" crashed_nodes 2>/dev/null; then STATE=CRASHED
        elif [ $EXIT_CODE -eq 0 ]; then STATE=COMPLETED
        else STATE=STOPPED; fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$RUN" "$NODE" "$STATE" "$TRIAL_END" "$TRIAL_END_EPOCH" \
            >> node_usage.tsv
    done < pbs_nodefile$RUN
    echo "trial $RUN ended at $TRIAL_END (exit $EXIT_CODE)" | tee -a run.log

    if [ $EXIT_CODE -eq 0 ]; then
        echo "Job run successfully on trial $RUN" | tee -a run.log
        echo "RESULT: SUCCESS after $RUN trial(s)" | tee -a run.log
        break
    fi

    echo "Job exited with $EXIT_CODE, will rerun" | tee -a run.log

    # A restart only helps if the failure was a node failure. If no node was
    # recorded as crashed and no rank was even able to start (127 = command
    # not found, i.e. a broken environment), retrying just burns the
    # remaining trials on the same error.
    if [ ! -s crashed_nodes ] && [ ! -s pbs_nodefile$RUN.unhealthy ]; then
        NEW_CKPT=$(cat latest 2>/dev/null || echo "")
        if [ "$NEW_CKPT" == "$PREV_CKPT" ]; then
            NO_PROGRESS=$((NO_PROGRESS+1))
        else
            NO_PROGRESS=0
        fi
        if [ $NO_PROGRESS -ge 2 ]; then
            echo "Two consecutive trials failed with no node failure and no" | tee -a run.log
            echo "checkpoint progress: this is not a recoverable node fault." | tee -a run.log
            echo "RESULT: ABORTED (non-recoverable) after $RUN trials" | tee -a run.log
            break
        fi
    else
        NO_PROGRESS=0
    fi
    PREV_CKPT=$(cat latest 2>/dev/null || echo "")

    # Retire ONLY the nodes that actually died, plus any that failed the health
    # check. Nodes that were merely in use stay in the pool -- retiring all of
    # them would drain a 6 node pool after a single 4 node trial.
    cat crashed_nodes pbs_nodefile$RUN.unhealthy 2>/dev/null | sort -u > retired_nodes$RUN
    {
    echo "retired so far: $(tr '\n' ' ' < retired_nodes$RUN)"
    echo "checkpoint at : $(cat latest 2>/dev/null || echo none)"
    } | tee -a run.log

    PBS_NODEFILE=$RUNDIR/nodefile_all flush.sh >> run.log 2>&1
    sleep 5
    echo | tee -a run.log
done

{
echo "Finished at `date`"
echo "=========================================================="
echo "Trials used     : $RUN"
echo "Crashed nodes   : $(tr '\n' ' ' < crashed_nodes)"
echo "Final checkpoint: $(cat latest 2>/dev/null || echo none)"
echo "Output lines    : $([ -f output.log ] && wc -l < output.log || echo 0)"
echo "Artifacts in    : $RUNDIR"
echo "=========================================================="
} | tee -a run.log

# High level node usage. The console gets the fixed-size 'simple' report so a
# large job cannot flood the screen; the full per-node breakdown is written to
# node_usage_full.log alongside the other artifacts.
node_usage_summary.sh "$RUNDIR" simple 2>&1 | tee -a run.log
node_usage_summary.sh "$RUNDIR" full > node_usage_full.log 2>&1
echo "Full per-node breakdown: $RUNDIR/node_usage_full.log" | tee -a run.log
