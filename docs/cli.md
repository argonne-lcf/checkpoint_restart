# Command line reference

Check Mate ships both standalone executables (`check-mate-hang`, `check-mate-nan`) and a
multi-tool dispatcher (`check-mate`). This page documents each entry point and
provides real output captures so you know what to expect.

## Dispatcher: `check-mate`

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

Invoke the dispatcher with `check-mate <command> ...` to reach the individual
scripts documented below.

## `check-mate get-healthy-nodes`

- **Purpose:** Ping each host in a nodefile and emit a cleaned list of
  responsive nodes.
- **Usage:** `check-mate get-healthy-nodes SOURCE TOTAL DEST`
- **Exit codes:**
  - `0` – success
  - `100` – fewer responsive nodes than requested

Example with loopback hosts:

```bash
$ printf '127.0.0.1\n127.0.0.1\n' > nodes.txt
$ check-mate get-healthy-nodes nodes.txt 1 selected.txt
Build a selected.txt nodes nodefile from nodes.txt, which contains 1 nodes
Total number of nodes checked: 1
Number of nodes that are selected: 1
$ cat selected.txt
127.0.0.1
```

## `check-mate launcher`

- **Purpose:** Export PMI/PALS environment variables and run a command.
- **Usage:** `check-mate launcher -- <command ...>`
- **Requirements:** `PBS_NODEFILE`, `PALS_LOCAL_SIZE`, and optional rank IDs
  must be present in the environment.

Example with synthetic metadata:

```bash
$ export PBS_NODEFILE=$(pwd)/nodes.txt
$ export PALS_LOCAL_SIZE=2
$ export PALS_LOCAL_RANKID=1
$ export PALS_RANKID=5
$ check-mate launcher -- echo "Hello from launcher"
I am 5 of 4: 1 on 22a1e6e6a625
Hello from launcher
```

## `check-mate flush`

- **Purpose:** Delegate to the original `flush.sh` helper for cleaning up jobs.
- **Usage:** `check-mate flush [extra args]`
- **Tip:** Ensure `PBS_NODEFILE` is defined so the script can determine which
  nodes to operate on.

## Standalone monitors

### `check-mate-hang`

- **Purpose:** Watch checkpoint files for stalled updates.
- **Usage:** `check-mate-hang --outputs FILE[:FILE...] [options]`
- **Key options:**
  - `--timeout` – seconds of inactivity before declaring a hang (default 300)
  - `--check` – polling interval in seconds (default 5)
  - `--kill-command` – shell command to terminate the job (default `pkill -u $USER mpiexec`)
  - `--outputs` – colon-separated list of files to monitor (default `chkpt/latest`)
  - `--grace` – seconds to wait after sending the kill command before exiting (default 10)
  - `--dry-run` – report the issue without killing anything

Dry-run against a missing file:

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

### `check-mate-nan`

- **Purpose:** Stream log files and terminate if `NaN`/`Inf` tokens appear.
- **Usage:** `check-mate-nan --outputs PATTERN [options]`
- **Key options:**
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

Run the detector against a synthetic log:

```bash
$ cat <<'LOG' > demo.log
step=1 loss=1.23
step=2 loss=nan
LOG
$ check-mate-nan --outputs demo.log --check 1 --timeout 0 --dry-run
[2025-10-09 15:45:18] Monitoring for NaN in: demo.log
[2025-10-09 15:45:18] Detected NaN in demo.log.
[DRY-RUN] Would terminate job (skipping actual kill).
$ rm demo.log
```
