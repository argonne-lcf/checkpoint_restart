# Getting started

This quick start shows how to install Check Mate, validate the command line
entry points, and exercise the most popular monitoring utilities on a laptop or
login node.

## Install the package

```bash
pip install check-mate
```

Optional extras:

```bash
pip install check-mate[docs]  # MkDocs + Material theme
pip install check-mate[dev]   # Ruff + pre-commit hooks
```

## Verify the installation

The dispatcher exposes a version flag so you can confirm the wheel installed
correctly:

```bash
$ check-mate --version
check-mate 0.1.0
```

The bundled help text enumerates the available subcommands:

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

## Run your first monitors

### Detect a stalled checkpoint

Invoke `check-mate-hang` in dry-run mode against a non-existent checkpoint file so
the inactivity timer expires almost immediately:

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

### Flag NaNs in a log file

Create a throwaway log file that contains a `nan` token and run the detector
with `--dry-run` so no kill command fires:

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

### Rebuild a healthy nodefile

The `check-mate get-healthy-nodes` helper pings each node listed in the input
file and writes the first *N* responsive hosts to the destination file. The
example below uses two loopback entries so the script succeeds instantly:

```bash
$ printf '127.0.0.1\n127.0.0.1\n' > nodes.txt
$ check-mate get-healthy-nodes nodes.txt 1 selected.txt
Build a selected.txt nodes nodefile from nodes.txt, which contains 1 nodes
Total number of nodes checked: 1
Number of nodes that are selected: 1
$ cat selected.txt
127.0.0.1
$ rm nodes.txt selected.txt
```

## Next steps

- Learn the full option sets in the [CLI reference](cli.md).
- Use the [Python API](python-api.md) to plan checkpoint cadences.
- Combine the monitors inside a batch script via the [workflow recipes](workflows.md).
