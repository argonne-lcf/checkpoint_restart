# ✅ Check Mate

> Checkpoint/Restart helpers for exascale computing

Check Mate packages the monitoring utilities that the ALCF uses to keep
large-scale simulations alive: lightweight log inspectors, hang detectors,
and wrappers around the original shell tooling for rebuilding a healthy node
allocation. Install the Python package and you immediately gain access to
both the Python APIs and the bundled command line entry points that are
documented under [`docs/`](docs/index.md).

## Features

- 🔍 **Runtime monitors** – `check-mate-hang` watches checkpoint files for stalled
  updates while `check-mate-nan` searches log files for `NaN`/`Inf` tokens.
- 🧠 **Checkpoint modelling** – the `check_mate.optimal_checkpointing`
  module computes optimal checkpoint cadences and expected efficiency.
- 🧰 **Bundled shell helpers** – `check-mate` proxies the original
  node-health, launcher, and cache-flush scripts via `importlib.resources`.
- 📚 **Full documentation** – the MkDocs site includes step-by-step guides and
  working examples for each utility.

## Installation

```bash
pip install check-mate
```

Optional extras:

```bash
# Documentation build dependencies (MkDocs + theme)
pip install check-mate[docs]

# Development linting hooks (ruff + pre-commit)
pip install check-mate[dev]
```

## Quick start

Verify your installation and inspect the shipped version:

```bash
$ check-mate --version
check-mate 0.1.0
```
The wheel installs the `check-mate`, `check-mate-hang`, and `check-mate-nan` console entry points. The `check-mate` dispatcher additionally exposes the `get-healthy-nodes`, `launcher`, and `flush` subcommands (invoked as `check-mate <subcommand>`). All are covered in the [CLI reference](docs/cli.md).

## Running the test suite

The project ships with a comprehensive pytest suite that exercises both the numerical checkpoint
optimizer and the command-line monitors. To run the tests locally:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e .[dev]
pytest
```

The optional `dev` extras include `pytest`, so no additional installation steps are required. If you
prefer not to use those extras, ensure that `pytest` is installed in your active environment before
invoking the test command. The suite also includes filesystem-based
checks, so running it from a writable working directory is recommended. The
[Testing and verification](docs/index.md#testing-and-verification) notes in the documentation repeat
these steps and include troubleshooting tips.

## Building distributable artifacts

The project uses the [`uv`](https://docs.astral.sh/uv/) build backend. After installing `uv`
(`pip install uv uv-build`), you can produce source and wheel distributions locally with:

```bash
uv build --wheel --sdist
```

Artifacts are written to the `dist/` directory. To test the wheel in a clean environment you can
install it via `uv pip install dist/check_mate-<version>-py3-none-any.whl`. Publishing to an index
is handled by `uv publish`, which reuses the same build backend and upload credentials.

Import the package from Python and evaluate a checkpoint cadence for a
1,024-node workload that writes 250 GB per node to the DAOS-128 storage tier:

```python
>>> import check_mate as cm
>>> from check_mate import optimal_checkpointing as oc
>>> cadence = oc.optimal_checkpoint_cadence(
...     node_count=1024,
...     node_memory=2.5e11,
...     chkpt_bandwidth="DAOS-128",
... )
>>> efficiency = oc.compute_efficiency(
...     node_count=1024,
...     node_memory=2.5e11,
...     chkpt_bandwidth="DAOS-128",
... )
>>> cm.__version__
'0.1.0'
>>> f"{cadence:.3f} h"
'6.951 h'
>>> f"{efficiency:.3%}"
'36.531%'
```

## Command line tools

The top-level dispatcher summarises every bundled helper:

```bash
$ check-mate --help
usage: check-mate [-h] [--version] {get-healthy-nodes,launcher,flush} ...

Utility command dispatcher for check-mate tools.

positional arguments:
  {get-healthy-nodes,launcher,flush}
                        Which bundled tool to execute.
  args

options:
  -h, --help            show this help message and exit
  --version             show program's version number and exit

Available commands:
  get-healthy-nodes  Select responsive nodes from a nodefile.
    Selects a subset of responsive nodes from a nodefile by delegating to the bundled shell implementation.
  launcher           Launch the check-mate job runner.
  flush              Flush all check-mate caches.
```

## Useful Scripts

This repository includes several scripts to help manage and monitor jobs. After installation, `check-mate-hang`, `check-mate-nan`, and `check-mate get-healthy-nodes` will be available in your PATH.

- `check-mate-hang`: Monitors files for updates and kills a job if it stops changing for longer than a specified timeout. This is useful for detecting hung processes.
  ```bash
  check-mate-hang --timeout 600 --check 10 --outputs chkpt/latest --kill-command "scancel $SLURM_JOB_ID"
  ```
  **Key options:**
  - `--timeout` – seconds of inactivity before declaring a hang (default 300)
  - `--check` – polling interval in seconds (default 5)
  - `--kill-command` – shell command to terminate the job (default `pkill -u $USER mpiexec`)
  - `--outputs` – colon-separated list of files to monitor (default `chkpt/latest`)
  - `--grace` – seconds to wait after sending the kill command before exiting (default 10)
  - `--dry-run` – report the issue without killing anything

- `check-mate-nan`: Monitors text output files for `NaN` or `Inf` values and terminates the job if they are found. This is useful for catching numerical stability issues.
  ```bash
  check-mate-nan --outputs "logs/*.out" --check 15 --kill-command "scancel $SLURM_JOB_ID"
  ```
  **Key options:**
  - `--outputs` – glob pattern for files to watch
  - `--recursive` – enable recursive globbing
  - `--check` – polling interval in seconds (default 15)
  - `--timeout` – exit cleanly if no match is found within the given seconds (0 disables timeout)
  - `--include-inf` – treat `inf` tokens as fatal
  - `--pid` – send a signal to a specific PID when a match is found
  - `--signal` – signal to send alongside `--pid` (default `TERM`)
  - `--grace` – seconds to wait before escalating to `SIGKILL` when using `--pid`
  - `--kill-command` – shell snippet to run on detection
  - `--dry-run` – suppress the kill action for testing
  - `--verbose` – print verbose progress messages

- `check-mate get-healthy-nodes`: Selects a subset of healthy nodes from a larger allocation, writing them to a new nodefile. This is key to the restart mechanism.
  ```bash
  check-mate get-healthy-nodes NODEFILE NUM_NODES_TO_SELECT NEW_NODEFILE
  ```

- `check-mate launcher`: Export launch-friendly environment variables derived from common PBS/PMI metadata before executing a command.
  ```bash
  check-mate launcher -- python -m check_mate.test --hang 30
  ```
- `check-mate flush`: Invoke the bundled flush helper to clean up processes on allocated nodes (requires `clush`).
  ```bash
  PBS_NODEFILE=NODEFILE check-mate flush
  ```

## Simulation of job execution: hang, fail, success
The `check_mate.test` module allows you to simulate various job behaviors:
```bash
$ printf '127.0.0.1\n127.0.0.1\n' > nodes.txt
$ check-mate get-healthy-nodes nodes.txt 1 selected.txt
Build a selected.txt nodes nodefile from nodes.txt, which contains 1 nodes
Total number of nodes checked: 1
Number of nodes that are selected: 1
$ cat selected.txt
127.0.0.1
```

#### Bootstrap launcher metadata

Mimic a PMI/PALS environment by providing the nodefile and rank metadata
before delegating to the original launcher script:

```bash
$ export PBS_NODEFILE=$(pwd)/nodes.txt
$ export PALS_LOCAL_SIZE=2
$ export PALS_LOCAL_RANKID=1
$ export PALS_RANKID=5
$ check-mate launcher -- echo "Hello from launcher"
I am 5 of 4: 1 on 22a1e6e6a625
Hello from launcher
```

#### Detect stalled checkpoints

Run the hang detector in dry-run mode against a non-existent checkpoint file
so the inactivity timer fires quickly:

```bash
$ check-mate-hang --timeout 3 --check 1 --outputs temp.chkpt --dry-run
[2025-10-09 15:46:04] Job monitor started
Watching: temp.chkpt
Timeout: 3s | Check interval: 1s

[2025-10-09 15:46:05] Checking job status
None of the watched files exist yet; monitoring...
Job has been running for 1.0 seconds
No updates for 1.0 seconds
[2025-10-09 15:46:07] Output has not been updated for 3.0 seconds. Issuing kill command...
(dry-run) Skipping kill execution
[2025-10-09 15:46:07] Monitor exiting after inactivity timeout.
```

#### Catch NaNs in logs

Point `check-mate-nan` at an artificial log that contains a `nan` token. The
`--dry-run` flag avoids killing anything while still demonstrating the
recovery hook:

```bash
$ cat <<'LOG' > demo.log
step=1 loss=1.23
step=2 loss=nan
LOG
$ check-mate-nan --outputs demo.log --check 1 --timeout 0 --dry-run
[2025-10-09 15:45:18] Monitoring for NaN in: demo.log
[2025-10-09 15:45:18] Detected NaN in demo.log.
[DRY-RUN] Would terminate job (skipping actual kill).
```

### Additional scripts

- `check-mate flush` forwards directly to the original flush helper. Set the
  `PBS_NODEFILE` environment variable so the script knows which nodes to
  operate on.
- Dedicated executables (`check-mate-hang`, `check-mate-nan`) are packaged
  alongside the dispatcher for quick access; they share the same code paths as
  the subcommands highlighted in the [CLI reference](docs/cli.md).

## Simulation harness

The `check_mate.test` module can simulate failure, hanging, and successful runs.
Use it to validate your recovery strategy locally:

```bash
python -m check_mate.test --fail 120 --checkpoint ./chkpt --niters 1000
```

The `examples/` directory contains archived run logs for failed, hanging,
successful, and NaN-producing workloads.

## Packaged simulation examples
Reusable PBS submission templates ship with the library and can be accessed as
Python modules. Each example prints its `qsub.sc` template to `stdout` or writes
it to disk when paired with `--output`:

```bash
# Preview the failing job template
python -m check_mate.examples.fail

# Persist the NaN recovery template to a custom location
python -m check_mate.examples.nan --output ~/nan.sc
```

The available examples mirror the historical directories and cover failure,
hang detection, NaN recovery, and successful completion scenarios.

## System monitoring

- [system_monitoring/README.md](./system_monitoring/README.md):
  monitoring scripts and dashboard service for JSON-based node health
  visualization.

## YAML-driven microkernel health checks

- Config file: [system_monitoring/health_checks.yaml](./system_monitoring/health_checks.yaml)
- Runner: [system_monitoring/run_health_checks.py](./system_monitoring/run_health_checks.py)
- Build system (C/C++ microkernels): [utils/check_healthy_tests/CMakeLists.txt](./utils/check_healthy_tests/CMakeLists.txt)

Typical usage:

```bash
# list active checks from YAML
python system_monitoring/run_health_checks.py --list

# configure/build microkernels, then run enabled checks
python system_monitoring/run_health_checks.py --build

# run a subset by group
python system_monitoring/run_health_checks.py --build --groups injection_bisection,memory

# include checks marked disabled in YAML
python system_monitoring/run_health_checks.py --build --include-disabled --checks triad,flops
```

The YAML controls:

- which microkernels are enabled (`enabled: true|false`)
- grouping (`group`) for selective execution
- concrete launch command (`command`) and optional timeout/env
- build commands (`build.configure_command` and `build.build_command`)

By default, the YAML keeps MPI/PBS-sensitive checks disabled for local
development. Enable them on cluster allocations with:

```bash
python system_monitoring/run_health_checks.py --build --include-disabled --checks simple_injection_bisection,full_injection_bisection,triad,flops,topology
```

## Documentation

Comprehensive usage notes—including full CLI reference material, Python API
explanations, and job orchestration walkthroughs—live under `docs/` and can be
served locally with MkDocs:

```bash
pip install check-mate[docs]
mkdocs serve
```

Visit the hosted documentation for the latest guides and recipes.

## License

This project is distributed under the terms of the MIT License. See
[LICENSE](LICENSE) for details.

## Contact

For questions please contact Huihuo Zheng <huihuo.zheng@anl.gov>.

