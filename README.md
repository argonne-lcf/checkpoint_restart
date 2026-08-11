# Checkpoint / Restart tests on Exascale computing systems

For questions, please contact: Huihuo Zheng <huihuo.zheng@anl.gov>

Exascale computing systems often experience instabilities that can cause job terminations before completion.

To ensure large-scale simulations can continue efficiently, checkpoint/restart mechanisms are essential.

This repository provides:
	•	Simple programs to simulate common job execution issues:
(1) hanging, (2) mid-run failures, and (3) successful completion.
	•	Example submission scripts that automatically detect failures and restart jobs using healthy nodes.

The **key idea** is to over-allocate nodes, allowing jobs to be restarted on a healthy subset of nodes if a failure occurs.

![alt text](.docs/figures/schematic.png)

## Install the package

```bash
git clone https://github.com/argonne-lcf/checkpoint_restart
cd checkpoint_restart
pip install -e .
```
This will install the `check_hang.py`, `check_nan.py`, and `get_healthy_nodes.sh` scripts into your environment.

## Useful Scripts

This repository includes several scripts to help manage and monitor jobs. After installation, `check_hang.py`, `check_nan.py`, and `get_healthy_nodes.sh` will be available in your PATH.

- `check_hang.py`: Monitors files for updates and kills a job if it stops changing for longer than a specified timeout. This is useful for detecting hung processes.
  ```bash
  check_hang.py --timeout 600 --check 10 --command "mpiexec python train.py"
  ```
  **Arguments:**
  - `--timeout`: Seconds of inactivity after which the job will be killed (default: 300).
  - `--check`: Seconds between file-activity checks (default: 5).
  - `--kill-command`: Shell command to terminate the job (default: `pkill -u $USER mpiexec`).
  - `--outputs`: Colon-separated list of output files to watch (default: `chkpt/latest`).
  - `--grace`: Seconds to wait after sending the kill command before exiting (default: 10).
  - `--dry-run`: If set, do not actually run the kill command—only log the action.

- `check_nan.py`: Monitors text output files for `NaN` or `Inf` values and terminates the job if they are found. This is useful for catching numerical stability issues.
  ```bash
  check_nan.py --outputs "logs/*.out" --check 15 --kill-command "scancel $SLURM_JOB_ID"
  ```
  **Arguments:**
  - `--outputs`: Glob pattern for files to watch.
  - `--recursive`: Enable recursive globbing.
  - `--check`: Polling interval in seconds (default: 15).
  - `--timeout`: Exit with code 0 if no NaN/Inf found after this many seconds (0 disables timeout).
  - `--include-inf`: Also treat 'inf' tokens as fatal.
  - `--pid`: If set, send a signal to this PID on detection.
  - `--signal`: Signal to send when using `--pid` (default: `TERM`).
  - `--grace`: Seconds to wait before escalating to `SIGKILL` if `--pid` is used (default: 15).
  - `--kill-command`: Arbitrary shell command to run on detection.
  - `--dry-run`: Detect and report but do not kill or run commands.
  - `--verbose`: Print verbose progress messages.

- `get_healthy_nodes.sh`: Selects a subset of healthy nodes from a larger allocation, writing them to a new nodefile. This is key to the restart mechanism.
  ```bash
  get_healthy_nodes.sh NODEFILE NUM_NODES_TO_SELECT NEW_NODEFILE [EXCLUDE_FILE]
  ```
  Alongside `NEW_NODEFILE`, three node lists are written:
  - `NEW_NODEFILE.healthy`: all nodes that passed the health check
  - `NEW_NODEFILE.unhealthy`: all nodes that failed the check, or were excluded
  - `NEW_NODEFILE.free`: healthy nodes not selected for this run (spares)

  The invariant is `healthy = selected + free`, so the remaining spare capacity
  of an over-allocated job can be inspected at any point during the run.

  The optional `EXCLUDE_FILE` lists nodes that must never be selected, which is
  how a node that crashed an earlier trial is kept out of later ones.

- `utils/overalloc.sh`: Computes how many nodes to request so that a job of
  `JOBSIZE` nodes keeps a percentage of extra nodes as a spare pool for restarts.
  ```bash
  overalloc.sh JOBSIZE RESERVE_PERCENT
  ```
  `total = JOBSIZE + ceil(JOBSIZE * RESERVE_PERCENT / 100)`, and any non-zero
  percentage reserves at least one spare node.

  **This is a calculator, not an allocator.** PBS fixes the node count from the
  `#PBS -l select=` directive before the job script runs, so no part of
  checkpoint_restart can request additional nodes. The reserve must be included
  in the submission by the user; the package then manages spares within the
  allocation it is given. Run `overalloc.sh` before submitting and write the
  result into the directive:
  ```bash
  #PBS -l select=6         # overalloc.sh 4 50 -> 6
  export JOBSIZE=4
  export RESERVE_PERCENT=50
  ```
  These three values are not derived from one another. Changing `JOBSIZE`
  without changing `select=` yields a smaller reserve than intended. Both
  submission scripts recompute the requirement at runtime and abort if the
  allocation is short.
  | JOBSIZE | reserve | request | spares |
  |---------|---------|---------|--------|
  | 4       | 50%     | 6       | 2      |
  | 10      | 20%     | 12      | 2      |
  | 16      | 25%     | 20      | 4      |
  | 512     | 20%     | 615     | 103    |
  | 10      | 0%      | 10      | 0      |

- `utils/flush.sh`: A utility to clean up processes on allocated nodes, excluding the head node. This script is not installed via pip.
  ```bash
  PBS_NODEFILE=NODEFILE ./utils/flush.sh
  ```

## Simulation of job execution: hang, fail, success
The test_pyjob.py script allows you to simulate various job behaviors:
```bash
--hang N              # Hang for N seconds
--fail N              # Fail after N seconds
--compute T           # Compute time per iteration
--niters NITERS       # Total number of iterations
--checkpoint PATH     # Checkpoint file path
--checkpoint_time T   # Time to write a single checkpoint
```

```
python test_pyjob.py --fail 120 --checkpoint ./chkpt --niters 1000
```


- `node_usage_summary.sh`: Prints a high level node-usage report for a run:
  which nodes ran work, when each entered and left service, how long each was
  held, which crashed, and how much of the spare reserve was spent.
  ```bash
  node_usage_summary.sh [RUNDIR] [simple|full]    # RUNDIR defaults to $PWD
  ```
  Two levels, because a 1000 node job would otherwise bury the screen:
  - `simple` (default): output size depends on the number of trials, not the
    number of nodes. One line per trial, an outcome histogram, and a capped
    list of crashed nodes. Measured at 31 lines for a 1000 node, 3 trial run
    where `full` produced 3434.
  - `full`: every trial and every node listed individually.

  Counts are always exact; only the node *name* lists are capped. Raise the cap
  with `NODE_SUMMARY_MAX_LIST=<n>`. The submission script prints `simple` to the
  console and writes `full` to `node_usage_full.log` in the run directory, so
  the detail is always kept.
  Reads `node_usage.tsv`, a tab-separated ledger the submission script appends
  to as nodes enter and leave service:
  ```
  trial <TAB> node <TAB> START|COMPLETED|STOPPED|CRASHED <TAB> timestamp <TAB> epoch
  ```

## Example submission scripts
- [qsub_multi_mpiexec.sc](./qsub_multi_mpiexec.sc)
  submission script doing continual trials of mpiexec until success or timeout
- [examples/crash_restart/](./examples/crash_restart/)
  4-node job with a 50% reserve (6 nodes) that crashes one node on purpose and
  restarts on a spare. Its README walks through converting an ordinary job
  script into a fault-tolerant one.

### Spare-node pool across restarts

The submission script keeps a `nodefile_pool` of candidate nodes, separate from
the per-trial nodefile handed to `mpiexec`. `PBS_NODEFILE` must **not** be
pointed at the per-trial subset when selecting nodes: doing so shrinks the
candidate pool to the nodes already in use and makes the spares unreachable on
later trials.

After a failed trial, only the nodes that actually died are retired:

```bash
cat crashed_nodes pbs_nodefile$RUN.unhealthy | sort -u > retired_nodes$RUN
get_healthy_nodes.sh nodefile_pool $JOBSIZE pbs_nodefile$NEXT crashed_nodes
```

Retiring every node the failed trial *used* would drain the pool too fast: a
4-node trial out of 6 would leave only 2 usable nodes and the next trial could
not start. Retiring just the failed node keeps the healthy ones in rotation.

When fewer than `JOBSIZE` usable nodes remain, `get_healthy_nodes.sh` exits 100
and the loop stops early rather than spending the remaining trials on an
allocation that can no longer host the job.

### Run directory layout

A run writes its own artifacts into one self-contained directory:

```
<rundir>/
  run.log                    combined log for the whole job
  nodefile_all               the full PBS allocation
  nodefile_pool              candidate nodes, shrinks as nodes are retired
  crashed_nodes              nodes that died, excluded from later trials
  pbs_nodefile<N>            nodes used by trial N
  pbs_nodefile<N>.healthy    health lists for trial N
  pbs_nodefile<N>.unhealthy
  pbs_nodefile<N>.free
  retired_nodes<N>           cumulative retired set after trial N
  node_usage.tsv             per-node ledger, one row per node per event
  node_usage_full.log        full per-node usage summary
  latest                     checkpoint (iteration number)
  output.log                 job output
  check_hang.log             hang-detector log
```

The location of `<rundir>` depends on the submission script:

| Script | Run directory |
|--------|---------------|
| `qsub_multi_mpiexec.sc` | `$PBS_O_WORKDIR`, the directory the job was submitted from |
| `examples/crash_restart/qsub.sc` | `tests/03-multi-node/results/batch-<jobid>/`, overridable with `TEST_ROOT` |

The example writes outside the repository so that a test run leaves no artifacts
in the tree under test.

`get_healthy_nodes.sh` and `flush.sh` use `/tmp/$USER/pbs/` for node-local
scratch; only the run's own artifacts are written to `<rundir>`.

## System Monitoring
- [system_monitoring/README.md](./system_monitoring/README.md)
  Monitoring scripts and dashboard service for JSON-based node health visualization.

## YAML-driven microkernel health checks
- Config file: [system_monitoring/health_checks.yaml](./system_monitoring/health_checks.yaml)
- Runner: [system_monitoring/run_health_checks.py](./system_monitoring/run_health_checks.py)
- Build system (C/C++ microkernels): [utils/check_healthy_tests/CMakeLists.txt](./utils/check_healthy_tests/CMakeLists.txt)

Typical usage:
```bash
# list active checks from YAML
run_health_checks.py --list

# configure/build microkernels, then run enabled checks
run_health_checks.py --build

# run a subset by group
run_health_checks.py --build --groups injection_bisection,memory

# include checks marked disabled in YAML
run_health_checks.py --build --include-disabled --checks triad,flops
```

The YAML controls:
- which microkernels are enabled (`enabled: true|false`)
- grouping (`group`) for selective execution
- concrete launch command (`command`) and optional timeout/env
- build commands (`build.configure_command` and `build.build_command`)

By default, the YAML keeps MPI/PBS-sensitive checks disabled for local development.
Enable them on cluster allocations with:
```bash
run_health_checks.py --build --include-disabled --checks simple_injection_bisection,full_injection_bisection,triad,flops,topology
```

## Various simulation examples
- [fail/](./examples/fail): job failed after 100 seconds, restart
- [hang/](./examples/hang): job hang, kill and restart
- [success/](./examples/success): job run seccessfully
- [nan/](./examples/nan): NaN after a few iterations, restart

## Checkpoint interval optimization utility
- [optimal_checkpointing.py](./optimal_checkpointing.py)
  Determine the optimal time interval of computation between checkpoints
  for a job of determined node size and checkpointed memory per node
