#!/bin/bash
#PBS -l walltime=0:20:00
#PBS -q prod
#PBS -N test_checkpoint_restart
#PBS -l select=5

#PBS -A datascience

# Run JOBSIZE nodes and keep RESERVE_PERCENT extra nodes as a spare pool.
# Size the "select=" above with:  overalloc.sh $JOBSIZE $RESERVE_PERCENT
# e.g. JOBSIZE=4, RESERVE_PERCENT=20 -> overalloc.sh 4 20 -> select=5

MAX_TRIALS=10

# Resolve the repository from this script's own location, before any cd, so
# the utilities that ship with it are used rather than an older installed
# copy. conda.sh prepends the deployed installation to PATH, so the repository
# has to be prepended after it is sourced.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source /flare/Aurora_deployment/AuroraGPT/soft/checkpoint_restart/conda.sh
export PATH=$SCRIPT_DIR/utils:$SCRIPT_DIR/job_monitoring:$PATH

IFS='.' read -ra ADDR <<< "$PBS_JOBID"
export JOBID=$ADDR

cd ${PBS_O_WORKDIR}

cat $PBS_NODEFILE | uniq > nodefile_all

export JOBSIZE=4
export RESERVE_PERCENT=20

# The pool of candidate nodes. Nodes are retired from this pool as they fail,
# so each trial draws from what is still usable.
cp nodefile_all nodefile_pool

echo "Requested $(cat nodefile_all | wc -l) nodes for a $JOBSIZE node job (${RESERVE_PERCENT}% reserve)"

# select= above and JOBSIZE/RESERVE_PERCENT here are set independently, so a
# change to one can silently leave the job with a smaller reserve than intended.
# Fail immediately rather than discovering it when a node is lost.
NALLOC=$(cat nodefile_all | wc -l)
NEED=$(overalloc.sh $JOBSIZE $RESERVE_PERCENT)
if [ "$NALLOC" -lt "$NEED" ]; then
    echo "FAIL: allocation of $NALLOC nodes is smaller than the $NEED required"
    echo "      for JOBSIZE=$JOBSIZE with a ${RESERVE_PERCENT}% reserve."
    echo "      Set '#PBS -l select=$NEED' or lower JOBSIZE/RESERVE_PERCENT."
    exit 1
fi

rm -f check_hang.r$JOBID

# ---------------------------------------------------------------------------
# Optional once-per-job fitness baseline.
#
# This runs BEFORE the retry loop, deliberately. gemm is far too expensive to
# repeat on every restart, and its value here is a reference measurement taken
# while the allocation is known-good: a later diagnosis run has something to
# compare against. Off by default so the default path costs nothing.
#
#   GEMM_BASELINE=1   run the baseline before trial 1
# ---------------------------------------------------------------------------
if [ "${GEMM_BASELINE:-0}" = "1" ]; then
    echo "Recording gemm baseline before the first trial"
    gemm_diagnose.sh nodefile_all gemm_baseline.$JOBID "${GEMM_OUTLIER_PCT:-10}"
    BASELINE_RC=$?
    if [ $BASELINE_RC -eq 3 ]; then
        # Report only: a slow tile at job start is information, not grounds to
        # refuse to run. Retirement decisions are made after a real crash.
        echo "Baseline flagged slow tiles; see gemm_baseline.$JOBID.candidates"
    elif [ $BASELINE_RC -ne 0 ]; then
        echo "Baseline did not produce a verdict (rc=$BASELINE_RC); continuing"
    fi
fi

# Tracks how many trials each node has been part of that ended in failure.
# A node is only diagnosed once it has been implicated twice, because a single
# crash is far more often the job than the hardware.
: > node_failures.$JOBID

echo "Started running job at `date`"

for RUN in `seq 1 $MAX_TRIALS`
do
    # select a subset of nodes to run the job, drawing from the pool
    get_healthy_nodes.sh nodefile_pool $JOBSIZE pbs_nodefile$RUN
    if [ $? -ne 0 ]; then
        echo "Spare pool exhausted: fewer than $JOBSIZE healthy nodes remain. Giving up after $((RUN-1)) trials."
        break
    fi

    # NOTE: only the run itself sees the subset; the pool is left intact
    # so the next trial can still reach the spare nodes.
    export PBS_NODEFILE=pbs_nodefile$RUN

    # constantly check the job and kill the job if it hangs for 300 seconds
    check_hang.py --timeout 300 --outputs $PBS_JOBNAME.o$JOBID:$PBS_JOBNAME.e$JOBID:output.log --kill-command "pkill -u $USER mpiexec" >> check_hang.r$JOBID &

    # run the actual job, in this case, the job will run for 200 seconds and fail (finished about 9 iterations each time)
    mpiexec -np $((JOBSIZE*12)) --ppn 12 launcher.sh python ./test_pyjob.py --compute 10 --niters 100 --output output.log

    EXIT_CODE=$?
    # Check the job status
    if [ $EXIT_CODE -ne 0 ]; then
	echo "Job exited with $EXIT_CODE error code, will rerun"
    else
        echo "Job run successfully"
        break
    fi

    # Retire only the nodes that failed the health check. Nodes that were
    # merely in use return to the pool: retiring an entire trial would drain a
    # 5 node pool after a single 4 node attempt, leaving nothing for a restart.
    cat pbs_nodefile$RUN.unhealthy 2>/dev/null | sort -u > retired_nodes$RUN

    # -----------------------------------------------------------------------
    # Two-strike diagnosis.
    #
    # Every node in a failed trial gets a strike. A node reaching two strikes
    # has now been present for two failures, which is weak evidence of bad
    # hardware but enough to justify the cost of a perf probe. Only those
    # nodes are diagnosed, and only a measured slowdown retires one.
    #
    #   GEMM_DIAGNOSE=1   enable (off by default)
    # -----------------------------------------------------------------------
    if [ "${GEMM_DIAGNOSE:-0}" = "1" ]; then
        sort -u pbs_nodefile$RUN >> node_failures.$JOBID
        sort node_failures.$JOBID | uniq -c \
            | awk '$1 >= 2 {print $2}' > repeat_offenders$RUN

        NREPEAT=$(wc -l < repeat_offenders$RUN)
        if [ "$NREPEAT" -gt 0 ]; then
            echo "Diagnosing $NREPEAT node(s) implicated in two or more failures"
            gemm_diagnose.sh repeat_offenders$RUN gemm_diag.$JOBID.r$RUN \
                "${GEMM_OUTLIER_PCT:-10}"
            if [ $? -eq 3 ]; then
                # Measured slow: retire permanently, on top of the ping result.
                cat gemm_diag.$JOBID.r$RUN.candidates >> retired_nodes$RUN
                sort -u retired_nodes$RUN -o retired_nodes$RUN
                echo "Retiring measured-slow node(s):"
                cat gemm_diag.$JOBID.r$RUN.candidates
            else
                # No measured defect: the node goes back to the pool rather
                # than being drained on suspicion alone.
                echo "No measured slowdown; repeat offenders stay in the pool"
            fi
        fi
    fi

    grep -vxF -f retired_nodes$RUN nodefile_pool > nodefile_pool.next
    mv nodefile_pool.next nodefile_pool
    echo "Spare pool after trial $RUN: $(cat nodefile_pool | wc -l) nodes remain"

    echo "Rerun the job at `date`; time of trials: $RUN"
    # clear up the nodes for rerun the job
    pkill check_hang.py
    PBS_NODEFILE=nodefile_all flush.sh
    sleep 5
done

echo "Finished running jobs with $RUN trials at `date`"
