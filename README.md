# Checkmate: Resilient Job Continuation with Checkpoint/Restart and Node-Health Tooling at Exascale

For questions, please contact: Kaushik Velusamy <kaushik.v@anl.gov> and Huihuo Zheng <huihuo.zheng@anl.gov>

Exascale computing systems often experience instabilities that can cause job terminations before completion.

To enhance the resilience of large-scale simulations on exascale systems, checkpoint/restart mechanisms and node-health monitoring are essential for detecting failures, minimizing lost computation, and enabling efficient recovery.

This repository provides three things, usable independently.

**Detect.** Microkernels in `utils/check_healthy_tests` measure what a node can
actually do: memory bandwidth, floating-point throughput per GPU tile, PCIe and
tile-to-tile transfer rates, network injection and bisection bandwidth, and
available host and device memory. Each reports a number rather than a verdict.
The useful question is not "did it run" but "how does this node compare with
its peers".

**Decide.** `system_monitoring/run_health_checks.py` applies thresholds to
those numbers. A check that exits successfully while reporting a third of the
expected bandwidth is a failure, and treating exit status as health misses it
entirely. Bounds are optional per rule: a rule without them records and trends
a value without gating on it, which is how a threshold gets calibrated before
it is enforced.

**Recover.** `utils/get_healthy_nodes.sh` selects nodes for the next attempt
and can probe each one for free memory before admitting it. The retry loop in
`examples/crash_restart` restarts from the last checkpoint on the surviving
nodes. The key idea is to over-allocate, so a job can restart on a healthy
subset. A node is retired only after a measured slowdown, not after a single
crash, because most crashes are not the node's fault.

Also included are programs that simulate the common failure modes — hanging,
mid-run failure, and successful completion — for testing a restart loop without
waiting for real hardware to misbehave.

![alt text](.docs/figures/schematic.png)

## Where to start

| Goal | Path |
|---|---|
| See the state of every node in an allocation | `utils/node_memory_report.sh` |
| Run every microkernel and report values and timings | `utils/check_healthy_tests/scripts/run_all_tests.sh` |
| Define or adjust a health threshold | `system_monitoring/health_checks.yaml` |
| Restart a job across node failures | `examples/crash_restart/` |
| Diagnose a node suspected of being slow | `utils/gemm_diagnose.sh` |

## Install the package

```bash
git clone https://github.com/argonne-lcf/checkmate
cd checkmate
pip install -e .
```
This will install the `check_hang.py`, `check_nan.py`, `get_healthy_nodes.sh` and `gemm_diagnose.sh` scripts into your environment.

### Requirements

- Python 3.6 or later; `PyYAML>=6.0` for the health-check runner
  (`pip install -r requirements.txt`).
- CMake 3.18 or later and an MPI compiler to build the microkernels.
- Optional: `icpx` for the SYCL/oneMKL kernels and Level Zero for the
  fabric topology tool. A missing dependency drops the affected
  targets with a warning rather than failing the configure.

On Aurora, `module load frameworks` provides Python 3.12 with PyYAML,
and `module load cmake` puts CMake on PATH. Load `frameworks` only for
the Python runner: it overrides the default oneAPI runtime, and SYCL
kernels launched under it abort with "No device of requested type
available".

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
  checkmate can request additional nodes. The reserve must be included
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

Start with `examples/crash_restart/`.

- [examples/crash_restart/](./examples/crash_restart/)
  4-node job with a 50% reserve (6 nodes) that crashes one node on purpose and
  restarts on a spare. Its README explains how to make an ordinary job script
  fault tolerant, with sample output from a real run.
- [qsub_multi_mpiexec.sc](./qsub_multi_mpiexec.sc)
  the same restart loop without the crash injector. Use this one as a
  production template.

Both keep a pool of candidate nodes and retire only the nodes that actually
failed, so one failure does not use up the whole reserve. The example adds a
deliberate fault and writes its output outside the repository, which is why it
is a test rather than a template.

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
- value-based pass/fail via `expect:` rules (see below)
- which microkernels are enabled (`enabled: true|false`)
- grouping (`group`) for selective execution
- concrete launch command (`command`) and optional timeout/env
- build commands (`build.configure_command` and `build.build_command`)

By default, the YAML keeps MPI/PBS-sensitive checks disabled for local development.
Enable them on cluster allocations with:
```bash
run_health_checks.py --build --include-disabled --checks simple_injection_bisection,full_injection_bisection,triad,flops,topology
```

### Value-based health gating

A check can pass its exit code and still be unhealthy. An `expect:`
block gates on measured values parsed from the check's stdout:

```yaml
- id: mem_and_gpu_row
  command: ["{build_dir}/mem_and_gpu_row", "--csv"]
  env:
    ZES_ENABLE_SYSMAN: "1"
  expect:
    - name: mem_available_mib
      column: mem_available_mib
      min: 65536
    - name: gpu_devices
      column: gpu_core_devices
      min: 1
```

The value is located by column name, taken from the header the kernel prints.
Adding a column upstream cannot silently change which number is gated, which a
positional regex cannot promise. To see the available names:

```bash
./build/health_checks/mem_and_gpu_row --csv | head -1 | tr ',' '\n'
```

Three levels are available:

| YAML | behaviour |
|---|---|
| no `expect:` | exit code only |
| `expect:` without `min`/`max` | record-only: measured and trended, never fails |
| `expect:` with `min`/`max` | gates the check |

Record-only is the mechanism for acquiring a threshold that is not yet
known: run it across a real allocation, read the recorded values from
the dashboard JSON, then set a bound.

See [system_monitoring/README.md](./system_monitoring/README.md) for
the full rule syntax.

### What a healthy Aurora node measures

Reference values from a two-node debug allocation, 12 ranks per node, CPU-bound
with one rank per GPU tile (job 8763237). These are measurements from one run
on one pair of nodes, not vendor specifications. Use them to recognise a node
that is obviously wrong, and collect a local baseline before setting
thresholds.

| Measurement | 12 ranks (1 node) | 24 ranks (2 nodes) |
|---|---|---|
| Memory bandwidth (triad) | 12311.8 GB/s | 20843.8 GB/s |
| Peak FP32 | 255605 GFlop/s | 479661 GFlop/s |
| Peak FP64 | 190517 GFlop/s | 363820 GFlop/s |
| DGEMM | 171351 GFlop/s | 339606 GFlop/s |
| SGEMM | 247324 GFlop/s | 492117 GFlop/s |
| HGEMM | 2467740 GFlop/s | 4693590 GFlop/s |
| BF16 GEMM | 2462280 GFlop/s | 4752330 GFlop/s |
| TF32 GEMM | 1288180 GFlop/s | 2459870 GFlop/s |
| I8 GEMM | 5088330 GFlop/s | 9287100 GFlop/s |
| FFT C2C 1D | 36596.2 GFlop/s | not run |
| FFT C2C 2D | 34933.6 GFlop/s | not run |
| PCIe H2D | 328 GB/s | not run |
| PCIe D2H | 264 GB/s | not run |
| PCIe bidirectional | 357 GB/s | not run |
| Tile-to-tile unidirectional | 211 GB/s | not run |
| Tile-to-tile bidirectional | 391 GB/s | not run |
| Network injection, aggregate | 153.98 GB/s | 396.90 GB/s |
| Network bisection, aggregate | 490.05 GB/s | 694.05 GB/s |
| Host memory available | 1144006 MiB | not run |
| GPU devices enumerated | 6 | not run |

Compute figures scale close to twice the single-node values, as expected for
per-rank kernels that do not communicate. Network bisection does not double,
because the second node introduces off-node traffic.

The spread across tiles is often a better signal than the absolute value. In
the run above the slowest tile was within 6.6% of the median on every
precision, and `gemm` reported no exclusion candidates. A tile 10% or more
below its peers across several precisions is worth investigating.

## Inspecting node state before a run

`utils/node_memory_report.sh` reports the memory and GPU state of every node in
an allocation. It is read-only: no node is selected, excluded or retired.

```bash
./utils/node_memory_report.sh              # every node in $PBS_NODEFILE
./utils/node_memory_report.sh mynodes.txt  # a specific list
FORMAT=csv ./utils/node_memory_report.sh   # machine-readable
```

```
HOST                            RAM_TOT   RAM_USED  RAM_AVAIL   GPUS   VRAM_TOT  VRAM_USED
x4302c2s0b0n0                   1030432      45231    1143660      6     786432          0
x4302c2s1b0n0                   1030432     892104      98311      6     786432      12288  LOW_RAM  VRAM_IN_USE
```

All values are MiB. `RAM_AVAIL` is what a new allocation can actually use.
Nodes that cannot be probed appear as `UNREACHABLE` rather than being dropped
from the report.

| Variable | Default | Effect |
|---|---|---|
| `HEALTH_PROBE_BIN` | build tree path | probe binary |
| `PROBE_TIMEOUT` | 30 | per-node timeout, seconds |
| `FORMAT` | `table` | `table` or `csv` |
| `WARN_MEM_MIB` | 65536 | flag nodes below this available RAM |
| `WARN_GPU_MIB` | 4096 | flag nodes above this GPU memory in use |

Use this to see the state of a pool. To act on it during node selection, use
`HEALTH_LEVEL=mem` with `get_healthy_nodes.sh`, which applies the same probe as
a gate.

## Running the full microkernel suite

```bash
qsub -A <project> -q debug -l select=2:ncpus=208 \
     -l walltime=00:30:00 -l filesystems=flare \
     utils/check_healthy_tests/scripts/run_all_tests.sh
```

Builds the microkernels, runs each one at serial, single-node and full
allocation scale, and prints a per-test wall-time table. Results land in
`test_results/run_<jobid>/`. See
[utils/check_healthy_tests/README.md](./utils/check_healthy_tests/README.md).

## Various simulation examples
- [crash_restart/](./examples/crash_restart): node failure, substitute a spare and resume
- [fail/](./examples/fail): job failed after 100 seconds, restart
- [hang/](./examples/hang): job hang, kill and restart
- [success/](./examples/success): job run seccessfully
- [nan/](./examples/nan): NaN after a few iterations, restart

## Checkpoint interval optimization utility
- [optimal_checkpointing.py](./utils/optimal_checkpointing.py)
  Determine the optimal time interval of computation between checkpoints
  for a job of determined node size and checkpointed memory per node
