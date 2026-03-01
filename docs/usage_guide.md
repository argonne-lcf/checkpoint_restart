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
  to hang or fail.
- **Health monitoring** – `check_hang.py` periodically inspects output
  files and terminates stuck runs.
- **Node management helpers** – shell utilities such as
  `get_healthy_nodes.sh`, `flush.sh`, and `local_rank.sh` select nodes,
  clean residual processes, and configure MPI rank metadata.
- **Batch workflow samples** – PBS scripts in
  `qsub_multi_mpiexec.sc` and `qsub_multi_qsub.sc` illustrate two
  strategies for recovering from failures on production systems.
- **Reference documentation** – `docs/shell_scripts.md` explains the
  shell orchestration logic and includes sequence diagrams.

The examples under `examples/` demonstrate how to vary parameters to
exercise success, hang, fail, and resubmission scenarios.

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
   git clone https://github.com/argonne-lcf/checkpoint_restart.git
   cd checkpoint_restart
   ```

2. Optional: create an isolated Python environment.

   ```bash
   python -m venv .venv
   source .venv/bin/activate
   ```

3. Ensure `test_pyjob.py` and `check_hang.py` are executable:

   ```bash
   chmod +x test_pyjob.py check_hang.py
   ```

4. Add the repository to your `PATH` if you plan to invoke helpers
   from other working directories:

   ```bash
   export PATH="$(pwd):$PATH"
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

`check_hang.py` watches one or more output files and terminates a job if
no updates occur within the timeout window.

```bash
check_hang.py --timeout 300 --check 10 --command python --output demo.log
```

- `--timeout` – Seconds since the last file modification before the
  job is deemed hung.
- `--check` – Polling interval in seconds.
- `--command` – Process name or prefix passed to `pkill` when
  cancellation is required.
- `--output` – Colon-separated list of files to monitor.

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
   PBS_NODEFILE=nodefile_all ./flush.sh
   ```

   The script removes processes associated with your user on all nodes
   except the allocation head node using `clush`.

3. **Configuring rank metadata**

   Wrap MPI launch commands with `local_rank.sh` to populate
   environment variables (`RANK`, `LOCAL_RANK`, `WORLD_SIZE`, and
   rendezvous coordinates) for downstream applications:

   ```bash
   mpiexec -np 8 --ppn 8 ./local_rank.sh python test_pyjob.py ...
   ```

## 7. Batch scheduling workflows

Two PBS scripts illustrate how to maintain progress when runs fail or
hang.  Adapt the directives (`#PBS` lines), module loads, and paths to
match your site.

### 7.1 Iterative mpiexec retries (`qsub_multi_mpiexec.sc`)

1. Copy the script and update the account, queue, and wall clock limit.
2. Adjust `JOBSIZE` (nodes per attempt), `MAX_TRIALS`, and workload
   parameters.
3. Submit the script with `qsub qsub_multi_mpiexec.sc`.
4. The workflow performs the following loop:
   - Select a subset of nodes with `get_healthy_nodes.sh`.
   - Start `check_hang.py` in the background.
   - Launch the MPI job with `mpiexec` and `local_rank.sh`.
   - If the job fails, clean the nodes with `flush.sh` and retry until
     success or `MAX_TRIALS` is reached.

### 7.2 Self-resubmitting job (`qsub_multi_qsub.sc`)

This alternative resubmits itself via `qsub` whenever the job exits
unsuccessfully.

1. Update resource directives as before.
2. Submit the script once with `qsub qsub_multi_qsub.sc`.
3. Upon failure, the script re-queues itself, ensuring the monitor and
   cleanup steps run before each attempt.

## 8. Example scenarios

The `examples/` directory contains ready-to-run configurations that
highlight different failure modes.  Use them as blueprints when crafting
new experiments.

- `examples/fail` – A job that exits after a configured runtime.
- `examples/hang` – Demonstrates detection and cleanup of hung jobs.
- `examples/resub` – Shows self-resubmission behavior.
- `examples/success` – A control scenario with a clean run.

## 9. Optimizing checkpoint intervals

`optimal_checkpointing.py` estimates how frequently to checkpoint based
on hardware characteristics.  Run it with:

```bash
python optimal_checkpointing.py --help
```

Provide the desired node count, memory footprint, checkpoint bandwidth,
and failure rate to compute recommended intervals.

## 10. Next steps

- Review `docs/shell_scripts.md` for deeper implementation details and
  flow diagrams.
- Tailor the helper scripts to reflect your scheduler, module system,
  or node management tooling.
- Integrate the monitoring and retry patterns into production
  workloads to improve resilience on unstable systems.
