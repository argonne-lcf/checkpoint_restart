# Utilities

This folder contains helper scripts and microkernel assets used by checkpoint/restart workflows.

## Top-level scripts

- `get_healthy_nodes.sh`: Select reachable nodes from an allocation and write a filtered nodefile.
- `launcher.sh`: Launch helper script for multi-step runs.
- `flush.sh`: Cleanup helper for allocated nodes.
- `optimal_checkpointing.py`: Utility to estimate checkpoint interval tradeoffs.

## `check_healthy_tests/`

Microkernel source and support files used for node and communication health
checks. See `check_healthy_tests/README.md` for the full test list, build
options and run instructions.

- Build definitions: `check_healthy_tests/CMakeLists.txt`
- Kernel and test sources:
  - `check_healthy_tests/src/memory/` -- CPU and GPU memory inventory
  - `check_healthy_tests/src/network/` -- MPI injection and bisection bandwidth
  - `check_healthy_tests/src/gpu/` -- GPU compute, PCIe, peer bandwidth, topology
  - `check_healthy_tests/src/collective/` -- torch.distributed allreduce latency
- Launch wrappers and suite drivers: `check_healthy_tests/scripts/`
- Log post-processing: `check_healthy_tests/tools/`

The YAML-driven health-check orchestrator now lives in `system_monitoring/`:

- `system_monitoring/run_health_checks.py`
- `system_monitoring/health_checks.yaml`

Those files call into binaries built from `utils/check_healthy_tests/CMakeLists.txt`.
Individual tests are triggered by ID, for example:

```bash
python3 system_monitoring/run_health_checks.py --checks mem_and_gpu_row
python3 system_monitoring/run_health_checks.py --groups gpu_compute
```

### Node selection levels

`get_healthy_nodes.sh` screens nodes at one of two levels, chosen with the
`HEALTH_LEVEL` environment variable.

| Level | Checks | Cost | Default |
|---|---|---|---|
| `ping` | reachability only | ~2s | yes |
| `mem` | ping, then a memory/GPU probe per node | ~2s + ~0.05s/node | no |

The `mem` level exists because ping cannot see the failure that actually
breaks a restart: a node that answers but has leaked host RAM. Such a node is
selected, the job lands on it, and it runs out of memory.

The probe also carries a GPU memory threshold, which is effective only where
Sysman reports real values. On Aurora it does not, so leaked VRAM is not
detected; see the note below the tunables.

Tunables, all optional. The two memory defaults are starting points chosen by
hand, not values derived from a measured failure threshold: 65536 MiB is
roughly what a 12-rank job needs, and an idle Aurora node measured 1144006 MiB
available (job 8763237). Calibrate them against a real allocation before
relying on them to exclude a node.

| Variable | Default | Meaning |
|---|---|---|
| `HEALTH_MIN_MEM_AVAIL_MIB` | 65536 | minimum `mem_available_mib` |
| `HEALTH_MAX_GPU_USED_MIB` | 4096 | maximum `gpu_sysman_used_mib` |
| `HEALTH_MIN_GPU_DEVICES` | 0 | minimum `gpu_sysman_devices` |
| `HEALTH_PROBE_BIN` | auto-detected | path to `mem_and_gpu_row` |
| `HEALTH_PROBE_TIMEOUT` | 30 | per-node probe timeout, seconds |

`HEALTH_MIN_GPU_DEVICES` defaults to 0 so the probe never fails a node merely
for reporting no GPUs.

Do not raise it on Aurora. It gates `gpu_sysman_devices`, and Sysman is
unavailable there: a healthy node with six working GPUs reports 0 for every
Sysman column, with or without `ZES_ENABLE_SYSMAN=1` (measured, job 8763307).
Setting it to 6 would fail every node in the allocation. The same measurement
means `HEALTH_MAX_GPU_USED_MIB` cannot detect pinned VRAM on Aurora, because
`gpu_sysman_used_mib` is always 0. Both remain useful on platforms where
Sysman works.

The kernel does enumerate GPUs through the core Level Zero API, reported as
`gpu_core_devices` (6 on a healthy Aurora node). The per-node probe in
`get_healthy_nodes.sh` does not currently read that column; the YAML check
`mem_and_gpu_row` gates on it instead.

Per-node probe results are written to `NEW_NODEFILE.probe` with a reason for
each failure. The probe is fail-open on infrastructure errors: a missing
binary degrades to ping with a warning rather than draining the allocation.
It is fail-closed on an actual threshold breach.

### Retry-loop integration

`qsub_multi_mpiexec.sc` supports two optional behaviours, both off by default.

| Variable | Effect |
|---|---|
| `GEMM_BASELINE=1` | run `gemm_diagnose.sh` once before the first trial and record a reference measurement |
| `GEMM_DIAGNOSE=1` | after a failed trial, diagnose nodes implicated in two or more failures |

The baseline runs outside the retry loop because repeating it on every restart
would be prohibitively expensive. It reports only; a slow tile at job start is
information, not grounds to refuse to run.

The diagnosis path uses a two-strike rule: every node in a failed trial gets a
strike, and only a node reaching two strikes is probed. A single crash is far
more often the job than the hardware. A node is retired permanently only when
`gemm` measures an actual slowdown; otherwise it returns to the spare pool
rather than being drained on suspicion.