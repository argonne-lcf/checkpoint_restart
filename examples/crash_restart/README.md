# crash_restart

Reference example for node-failure tolerance: over-allocate a node reserve, and
on node failure substitute a spare and resume from the last checkpoint.

Without fault tolerance, the loss of a single node terminates the entire job and
all uncheckpointed work is discarded. This example demonstrates the alternative:

```
trial 1 : nodeA  nodeB  nodeC  nodeD          nodeB fails at iteration 10
trial 2 : nodeA         nodeC  nodeD  nodeE   nodeE substituted from reserve
          execution resumes at iteration 10 and runs to completion
```

## Comparison

The same four-node job, run on a system where one node fails partway through.

### Without checkpoint_restart

```bash
#PBS -l select=4

mpiexec -np 48 --ppn 12 python my_app.py
```

```
00:00  job starts on nodeA nodeB nodeC nodeD
02:00  nodeB fails
02:00  PBS terminates the job
       - all four nodes released
       - two hours of computation discarded
       - the job must be resubmitted and requeued
```

### With checkpoint_restart

```bash
#PBS -l select=6                       # 4 + 50% reserve

for RUN in $(seq 1 $MAX_TRIALS); do
    get_healthy_nodes.sh nodefile_pool $JOBSIZE pbs_nodefile$RUN crashed_nodes || break
    export PBS_NODEFILE=$PWD/pbs_nodefile$RUN
    mpiexec --no-vni -np 48 --ppn 12 python my_app.py --checkpoint ckpt/
    [ $? -eq 0 ] && break
    flush.sh
done
```

```
00:00  trial 1 starts on nodeA nodeB nodeC nodeD; nodeE nodeF held in reserve
        ...  checkpoints written throughout
02:00  nodeB fails
02:00  nodeB recorded in crashed_nodes and excluded from further selection
02:01  trial 2 starts on nodeA nodeC nodeD nodeE
       - resumes from the last checkpoint
       - the job never leaves the queue
       - nodeF remains in reserve for a subsequent failure
```

### Summary

| | Without | With |
|---|---|---|
| Nodes requested | 4 | 6 (4 + 50% reserve) |
| Application changes | none | must checkpoint and resume |
| Job script changes | none | retry loop, node selection |
| Outcome of one node failure | job terminates | continues on a spare |
| Work lost | everything since job start | everything since last checkpoint |
| Recovery | manual resubmission, requeued | automatic, within the same allocation |
| Node-hours consumed | 4 nodes x 2 h, discarded | 6 nodes held; 2 h retained |
| Failures tolerated | 0 | 2 (one per spare node) |

The reserve is not free: 6 nodes are charged for the duration of the job whether
or not the spares are used. The trade is that cost against the expected cost of
losing the job, which grows with both run time and node count. At small scale
and short walltime, resubmission may well be cheaper. At large node counts, or
for runs long enough that a failure becomes probable, the reserve is the lower
expected cost.

## Application requirements

The application must satisfy two conditions:

1. It writes a checkpoint at a regular interval.
2. On startup it detects an existing checkpoint and resumes from it.

These are the only requirements. An application that cannot resume from a
checkpoint will restart from the beginning on every trial, and node
substitution provides no benefit.

## Adapting an existing job script

A conventional four-node submission:

```bash
#!/bin/bash
#PBS -l select=4
#PBS -l walltime=1:00:00
#PBS -q capacity
#PBS -A datascience
#PBS -l filesystems=flare

cd $PBS_O_WORKDIR
mpiexec -np 48 --ppn 12 python my_app.py --checkpoint ckpt/
```

Five modifications are required.

### 1. Request the node reserve

**The reserve must be requested by the user. checkpoint_restart cannot obtain
additional nodes.**

PBS reads the `#PBS -l select=` directive before the first line of the script is
executed, so no code in the job can enlarge its own allocation. The package
operates entirely within the nodes PBS has already granted: it selects `JOBSIZE`
of them for the application, holds the remainder in reserve, and substitutes
from that reserve when a node fails. If the allocation contains no surplus
nodes, there is nothing to substitute and a node failure ends the job.

`utils/overalloc.sh` is a calculator, run before submission, that determines the
value to place in the directive:

```bash
$ overalloc.sh 4 50     # 4 nodes, 50% reserve
6
$ overalloc.sh 512 20   # 512 nodes, 20% reserve
615
```

The resulting figure is written into the job script by hand, together with the
two variables that must agree with it:

```bash
#PBS -l select=6              # total nodes requested from PBS
...
export JOBSIZE=4              # nodes the application runs on
export RESERVE_PERCENT=50     # must satisfy overalloc.sh 4 50 = 6
```

These three values are declared in two separate places and are not derived from
one another. Raising `JOBSIZE` without also raising `select=` produces a job
with a smaller reserve than intended, or none at all. The example script guards
against this by recomputing the requirement at runtime and aborting when the
allocation is insufficient:

```bash
NEED=$(overalloc.sh $JOBSIZE $RESERVE_PERCENT)
if [ "$NALLOC" -lt "$NEED" ]; then
    echo "FAIL: allocation of $NALLOC is smaller than the required $NEED"
    exit 1
fi
```

Reproducing this check in an adapted script is recommended; the failure it
prevents is otherwise silent until a node is lost.

Select the reserve percentage according to the observed failure rate of the
target system. 20% is a reasonable starting point at large node counts. Jobs at
small node counts require at least one full spare node to tolerate any
failure.

### 2. Configure the environment

```bash
source /flare/Aurora_deployment/AuroraGPT/soft/checkpoint_restart/conda.sh
export PATH=$REPO_DIR/utils:$REPO_DIR/job_monitoring:$PATH
```

The `conda.sh` invocation is mandatory. Without it, `python` is not present on
the compute nodes and every rank terminates with exit status 127. `module load
frameworks` may be substituted if a newer Python is required.

### 3. Enclose the run in a retry loop

```bash
cat $PBS_NODEFILE | uniq > nodefile_all
cp nodefile_all nodefile_pool
touch crashed_nodes

JOBSIZE=4
for RUN in $(seq 1 10); do
    # Select JOBSIZE healthy nodes, excluding any that have already failed
    get_healthy_nodes.sh nodefile_pool $JOBSIZE pbs_nodefile$RUN crashed_nodes || {
        echo "insufficient healthy nodes remaining"; break
    }
    export PBS_NODEFILE=$PWD/pbs_nodefile$RUN

    mpiexec --no-vni -np $((JOBSIZE*12)) --ppn 12 \
        python my_app.py --checkpoint ckpt/
    [ $? -eq 0 ] && break        # completed successfully

    flush.sh                     # terminate residual processes before retrying
done
```

`get_healthy_nodes.sh` writes three list files adjacent to the nodefile:

| File | Contents |
|------|----------|
| `pbs_nodefile$RUN` | nodes selected for this trial |
| `.healthy` | all nodes that passed the health check |
| `.unhealthy` | nodes that failed the check or were listed in the exclude file |
| `.free` | healthy nodes not selected for this trial (the remaining reserve) |

### 4. Identify failed nodes

The fourth argument to `get_healthy_nodes.sh` is an exclude file. Nodes listed
in it are treated as unusable and are never selected, irrespective of whether
they remain reachable.

The mechanism for populating this file depends on the failure detection
available to the application. Where the application can identify the failed
node, append it under a lock, as multiple ranks may write concurrently:

```bash
flock -x crashed_nodes.lock -c "echo $BAD_NODE >> crashed_nodes"
```

Entries must use the same form as `$PBS_NODEFILE`, the fully qualified
`.hsn.cm.aurora.alcf.anl.gov` name. The output of `hostname` is the short name
and will not match; `hostname -f` returns a different domain (`.hostmgmt.`) and
will also fail to match.

Where the failed node cannot be identified, `get_healthy_nodes.sh` pings every
node at the start of each trial and excludes those that are unreachable.

### 5. Report node usage

```bash
node_usage_summary.sh "$RUNDIR" simple
```

Reports the nodes that executed work, the time each entered and left service,
total time held per node, nodes lost to failure, and the proportion of the
reserve consumed. The `full` argument produces the complete per-node table.
At 1000 nodes `full` exceeds 3400 lines; `simple` is fixed size at
approximately 30 lines and is recommended for console output.

## Running this example

```bash
qsub examples/crash_restart/qsub.sc
```

The job allocates six nodes, runs a four-node workload, induces a failure on one
node during trial 1, and verifies that execution completes on a substituted
spare. Artifacts are written to `tests/03-multi-node/results/batch-<jobid>/`,
which may be redirected with `TEST_ROOT`.

Parameters are defined at the top of the script:

| Variable | Default | Description |
|----------|---------|-------------|
| `JOBSIZE` | 4 | nodes used by the application |
| `RESERVE_PERCENT` | 50 | additional nodes requested as reserve |
| `MAX_TRIALS` | 10 | maximum number of restarts before abandoning the job |
| `CRASH_ON_TRIAL` | 1 | trial in which the fault is injected |
| `CRASH_AFTER` | 40 | seconds into the run before the fault is injected |

## Sample output

Abridged from job 8747861 on Aurora. Per-rank progress lines and the repeated
per-rank crash messages are elided; everything else is verbatim.

```
==========================================================
Run dir   : .../tests/03-multi-node/results/batch-8747861
Allocated : 6 nodes
JOBSIZE   : 4  (+50% reserve -> needs 6)
==========================================================
Will inject a crash on x4210c2s3b0n0 during trial 1

---------- TRIAL 1 ----------
Build a 4 nodes nodefile from nodefile_pool
Total number of nodes checked: 6
Number of nodes that are healthy: 6
Number of nodes that are unhealthy: 0
Number of nodes that are selected: 4
Number of healthy nodes still free: 2
Node lists: pbs_nodefile1.healthy pbs_nodefile1.unhealthy pbs_nodefile1.free
trial 1 started at 2026-08-11 04:37:07
running on:
    [2026-08-11 04:37:07] x4216c7s0b0n0.hsn.cm.aurora.alcf.anl.gov
    [2026-08-11 04:37:07] x4210c2s3b0n0.hsn.cm.aurora.alcf.anl.gov
    [2026-08-11 04:37:07] x4300c2s4b0n0.hsn.cm.aurora.alcf.anl.gov
    [2026-08-11 04:37:07] x4310c1s0b0n0.hsn.cm.aurora.alcf.anl.gov
free pool : x4618c1s3b0n0.hsn... x4417c4s7b0n0.hsn...
CRASH-INJECT: simulating node failure on x4210c2s3b0n0 (trial 1)
x4210c2s3b0n0.hsn...: rank 21 exited with code 42
x4210c2s3b0n0.hsn...: rank 12 died from signal 15
trial 1 ended at 2026-08-11 04:37:19 (exit 143)
Job exited with 143, will rerun
retired so far: x4210c2s3b0n0.hsn.cm.aurora.alcf.anl.gov
checkpoint at : 11

---------- TRIAL 2 ----------
Build a 4 nodes nodefile from nodefile_pool
Total number of nodes checked: 6
Number of nodes that are healthy: 5
Number of nodes that are unhealthy: 1
Number of nodes that are selected: 4
Number of healthy nodes still free: 1
trial 2 started at 2026-08-11 04:37:27
running on:
    [2026-08-11 04:37:27] x4216c7s0b0n0.hsn.cm.aurora.alcf.anl.gov
    [2026-08-11 04:37:27] x4300c2s4b0n0.hsn.cm.aurora.alcf.anl.gov
    [2026-08-11 04:37:27] x4310c1s0b0n0.hsn.cm.aurora.alcf.anl.gov
    [2026-08-11 04:37:27] x4618c1s3b0n0.hsn.cm.aurora.alcf.anl.gov
free pool : x4417c4s7b0n0.hsn.cm.aurora.alcf.anl.gov
Reading checkpoint from 11
11 iteration ...
   ...
29 iteration ...
trial 2 ended at 2026-08-11 04:37:48 (exit 0)
Job run successfully on trial 2

RESULT: SUCCESS after 2 trial(s)
==========================================================
Trials used     : 2
Crashed nodes   : x4210c2s3b0n0.hsn.cm.aurora.alcf.anl.gov
Final checkpoint: 29
```

Three lines establish that substitution occurred rather than a plain retry:
`Number of nodes that are unhealthy: 1` in trial 2 shows the failed node was
excluded; `x4618c1s3b0n0` appears in the trial 2 node list but not trial 1,
so a spare was drawn from the reserve; and `Reading checkpoint from 11`
confirms the work resumed instead of restarting.

The node-usage summary is printed automatically when the job ends:

```
==========================================================
 NODE USAGE SUMMARY (simple)
==========================================================
Window        : 2026-08-11 04:37:07 -> 2026-08-11 04:37:48  (41s)
Allocated     : 6 nodes
Trials run    : 2
Nodes used    : 5 of 6
Node-time     : 2m 12s total across all nodes and trials

--- Per trial ---
TRIAL     NODES  START               END                 HELD
1             4  2026-08-11 04:37:07 2026-08-11 04:37:19 12s  (1 crashed)
2             4  2026-08-11 04:37:27 2026-08-11 04:37:48 21s

--- Node outcomes ---
    COMPLETED    4
    CRASHED      1

--- Spare capacity ---
Nodes that ran work : 5 of 6 allocated
Nodes lost to crash : 1
Spares drawn in     : 1 (beyond the 4 that started trial 1)
Unspent reserve     : 1
Crashed nodes:
    x4210c2s3b0n0.hsn.cm.aurora.alcf.anl.gov
==========================================================
```

`simple` mode is fixed size irrespective of node count and is what appears on
the console. `full` mode adds per-trial node listings and a per-node table, and
is written to `node_usage_full.log`. At 1000 nodes the two are 31 and 3434 lines
respectively.

### Run directory contents

```
run.log              nodefile_all            node_usage.tsv
output.log           nodefile_pool           node_usage_full.log
check_hang.log       crashed_nodes           latest
pbs_nodefile1        pbs_nodefile1.healthy   pbs_nodefile1.unhealthy
pbs_nodefile1.free   retired_nodes1
pbs_nodefile2        pbs_nodefile2.healthy   pbs_nodefile2.unhealthy
pbs_nodefile2.free
```

## crash_node.sh

A fault injector intended for testing only. It wraps the target command and
exits with a non-zero status on one designated host, recording that host in
`$CRASHED_NODES_FILE`:

```bash
mpiexec ... launcher.sh crash_node.sh python my_app.py
```

On all other hosts it executes the command unmodified and is therefore
transparent.

It is located in `examples/` rather than `utils/` and is deliberately not
installed onto `$PATH`, as a utility whose function is to terminate running
applications should not be readily invocable in a production environment.

## Operational notes

**Checkpoint interval relative to failure time.** If the failure occurs before
the application has written its first checkpoint, the restart repeats all prior
work. When testing, ensure `CRASH_AFTER` exceeds the checkpoint interval.

**Exit status is not a reliable indicator of success.** A retry loop that
exhausts all trials still exits 0, and `qstat -x` reports terminated jobs with
`state=F`, identical to jobs that completed normally. Verify the run log.

**Retire only the nodes that failed.** Retiring every node used by a failed
trial exhausts the reserve prematurely: retiring all four nodes of a failed
trial reduces a six-node pool to two, and the subsequent trial cannot start.

**Select from the full pool on every trial.** Node selection must draw from
`nodefile_all` less the retired nodes. Selecting from the preceding trial's
subset causes the available pool to contract on each iteration.

## References

- `utils/README.md` — helper script documentation
- `../../README.md` — checkpoint_restart package documentation
- `../fail`, `../hang`, `../nan` — additional failure-mode examples
