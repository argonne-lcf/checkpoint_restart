# Repository Usage Guide

This guide walks you through using the checkpoint/restart experimentation
framework that accompanies the Aurora stability investigations.  It
covers local simulations, job monitoring, node management helpers, and
batch scheduling workflows that repeatedly launch workloads until they
succeed.

## 1. Repository overview

The repository provides the following building blocks:

- **Synthetic workload** – `test_pyjob.py` simulates a distributed
  application that iterates, writes checkpoints, and can be instructed
  to hang, fail, or emit NaN/Inf.
- **Health monitoring** – `job_monitoring/check_hang.py` terminates a job
  whose output files stop advancing, and `job_monitoring/check_nan.py`
  terminates a job when NaN/Inf appears in its output.
- **Node management helpers** – shell utilities in `utils/`
  (`get_healthy_nodes.sh`, `flush.sh`, and `launcher.sh`) select nodes,
  clean residual processes, and configure MPI rank metadata.
- **Batch workflow sample** – the PBS script `qsub_multi_mpiexec.sc`
  illustrates recovering from failures by retrying on a healthy subset of
  nodes within a single allocation.
- **Reference documentation** – `docs/shell_scripts.md` explains the
  shell orchestration logic and includes sequence diagrams.

The examples under `examples/` demonstrate how to vary parameters to
exercise success, hang, fail, and NaN scenarios.

## 2. Prerequisites

1. **Python** – Python 3.7 or newer is recommended.  Only the standard
   library is required.
2. **MPI stack** – The scripts assume `mpiexec` (or a compatible launch
   command) is available for distributed execution.
3. **Process management tools** – Production scenarios rely on
   `clush`, PBS environment variables, and Aurora-specific modules.
   Adapt those commands when running on other systems.
4. **Job scheduler** – The batch samples target PBS Pro.  Translate the
   launch directives if your scheduler differs.

## 3. Getting started

1. Clone the repository on your login node or workstation:

   ```bash
   git clone https://github.com/argonne-lcf/checkmate.git
   cd checkmate
   ```

2. Optional: create an isolated Python environment.

   ```bash
   python -m venv .venv
   source .venv/bin/activate
   ```

3. Install the package. This places `check_hang.py`, `check_nan.py`,
   `get_healthy_nodes.sh`, `launcher.sh`, and `flush.sh` on your `PATH`,
   which is how the submission scripts invoke them:

   ```bash
   pip install -e .
   ```

## 4. Running the synthetic workload locally

Run a quick single-process simulation to verify the setup:

```bash
python test_pyjob.py --compute 1 --niters 5 --output demo.log
```

Key options include:

| Flag | Description |
| --- | --- |
| `--compute` | Seconds spent per iteration to emulate work. |
| `--niters` | Total iteration count. |
| `--checkpoint` | File used to persist the latest iteration index. |
| `--save-interval` | Iteration frequency for writing checkpoints. |
| `--checkpoint_time` | Additional seconds spent writing a checkpoint. |
| `--fail` | Causes the program to exit with a failure after *N* seconds. |
| `--hang` | Suspends the job for *N* seconds before entering the loop. |

To exercise restart behavior, run once with failure enabled and then
rerun without altering the checkpoint file:

```bash
python test_pyjob.py --compute 1 --niters 10 --checkpoint state.chk --fail 5
# After failure, rerun from the saved checkpoint
python test_pyjob.py --compute 1 --niters 10 --checkpoint state.chk
```

## 5. Monitoring runs for hangs

`check_hang.py` watches one or more output files and, if none of them are
modified within the timeout window, runs a kill command to terminate the
workload. It does not launch the workload itself — start it in the
background alongside the job.

```bash
check_hang.py --timeout 300 --check 10 \
    --outputs output.log --kill-command "pkill -u $USER python ./test_pyjob.py"
```

- `--timeout` – Seconds since the last file modification before the job is
  deemed hung (default: 300).
- `--check` – Seconds between file-activity checks (default: 5).
- `--outputs` – Colon-separated list of output files to watch
  (default: `chkpt/latest`).
- `--kill-command` – Shell command run to terminate the job
  (default: `pkill -u $USER mpiexec`).
- `--grace` – Seconds to wait after issuing the kill command before
  exiting (default: 10).
- `--dry-run` – Log the kill action without executing it.

To also guard against numerical blow-ups, run `check_nan.py` in parallel;
it terminates the job when `NaN`/`Inf` appears in the watched files
(e.g. `check_nan.py --outputs output.log --check 1 --kill-command "qdel $PBS_JOBID"`).

On batch systems, launch the monitor in the background so it can run
concurrently with the workload.

## 6. Managing allocated nodes

The shell helpers assume a PBS allocation with `$PBS_NODEFILE`
containing the provisioned hosts.  Customize the commands to match your
cluster.

1. **Selecting healthy nodes**

   ```bash
   get_healthy_nodes.sh $PBS_NODEFILE 2 pbs_nodefile_subset
   ```

   This copies *NUM_NODES_TO_SELECT* unique entries into
   `pbs_nodefile_subset`, enabling you to run smaller pilot jobs within a
   larger allocation.

2. **Cleaning up residual processes**

   ```bash
   PBS_NODEFILE=nodefile_all flush.sh
   ```

   The script removes processes associated with your user on all nodes
   except the allocation head node using `clush`.

3. **Configuring rank metadata**

   Wrap MPI launch commands with `launcher.sh` to export the rank
   variables (`RANK`, `LOCAL_RANK`, and `WORLD_SIZE`) that downstream
   applications read. It derives these from the PALS/PMIx environment and
   execs the command that follows it:

   ```bash
   mpiexec -np 8 --ppn 8 launcher.sh python test_pyjob.py ...
   ```

## 7. Batch scheduling workflow

`qsub_multi_mpiexec.sc` illustrates how to maintain progress when runs
fail or hang, by retrying within a single allocation.  Adapt the
directives (`#PBS` lines), module loads, and paths to match your site.

1. Copy the script and update the account, queue, and wall clock limit.
2. Adjust `JOBSIZE` (nodes per attempt), `MAX_TRIALS`, and workload
   parameters.
3. Submit the script with `qsub qsub_multi_mpiexec.sc`.
4. The workflow performs the following loop up to `MAX_TRIALS` times:
   - Select a subset of healthy nodes with `get_healthy_nodes.sh`.
   - Start `check_hang.py` in the background.
   - Launch the MPI job with `mpiexec ... launcher.sh python ./test_pyjob.py`.
   - On success, break; on failure, stop the monitor (`pkill
     check_hang.py`), clean the nodes with `flush.sh`, and retry.

The `examples/nan/qsub.sc` variant follows the same pattern but also runs
`check_nan.py` in the background to catch numerical failures.

## 8. Example scenarios

The `examples/` directory contains ready-to-run configurations that
highlight different failure modes.  Use them as blueprints when crafting
new experiments.

- `examples/fail` – A job that exits after a configured runtime.
- `examples/hang` – Demonstrates detection and cleanup of hung jobs.
- `examples/nan` – Detects NaN/Inf in the output and restarts.
- `examples/success` – A control scenario with a clean run.

## 9. Optimizing checkpoint intervals

`utils/optimal_checkpointing.py` provides the function
`optimal_checkpoint_cadence(...)`, which solves an updated form of Eq. (21)
of Daly (2006) to return the recommended computation interval (in hours)
between checkpoints. It is imported and called rather than run as a CLI:

```python
from utils.optimal_checkpointing import optimal_checkpoint_cadence

# node_count nodes, node_memory GB checkpointed per node
interval_hours = optimal_checkpoint_cadence(
    node_count=1024,
    node_memory=100.0,
    chkpt_bandwidth="DAOS-128",  # or "LUSTRE", or a float in GB/s
)
```

Key parameters: `node_count`, `node_memory` (GB per node to checkpoint),
`chkpt_bandwidth` (`"DAOS-128"`, `"LUSTRE"`, or a GB/s float), and either
`MTBAI` (mean time between application interrupts, hours) or `R_0`
(failure rate in failures/node-hr, which overrides `MTBAI`).

## 10. Next steps

- Review `docs/shell_scripts.md` for deeper implementation details and
  flow diagrams.
- Tailor the helper scripts to reflect your scheduler, module system,
  or node management tooling.
- Integrate the monitoring and retry patterns into production
  workloads to improve resilience on unstable systems.
