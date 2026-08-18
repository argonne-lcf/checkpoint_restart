# Health-check microkernels

A set of small MPI/SYCL/OpenMP programs that measure whether a compute node is
fit to run work, plus the tooling that builds them, gates on their output, and
attributes a slowdown to a specific node.

Reachability is not health. A node that answers a ping can still have half its
memory consumed by a leaked allocation, or one GPU tile running 15% below its
peers. Either will slow a job or lose it hours later, and neither shows up in a
node's exit status. These kernels measure the machine and compare the numbers
against expectations.

```
ping            node answers            -> catches a node that has gone away
mem_and_gpu_row memory / GPU inventory  -> catches a degraded but reachable node
gemm            per-tile GPU throughput -> catches one slow tile among 12
```

## Layout

```
check_healthy_tests/
  CMakeLists.txt          top-level build, one option per dependency
  src/
    memory/               CPU and GPU memory inventory (no MPI)
    network/              MPI injection and bisection bandwidth
    gpu/                  per-node GPU microbenchmarks
    collective/           collective-communication tests
  scripts/                multi-kernel sweeps
  tools/                  post-processing helpers
```

## The tests

| Binary | Measures | Ranks | Wall time |
|---|---|---|---|
| `mem_and_gpu_row` | CPU/GPU memory inventory, CSV | serial | 0.05 s |
| `topology` | Level Zero fabric topology | serial | 0.04 s |
| `triad` | STREAM triad bandwidth | 1/tile | 3.3 s |
| `flops` | sustained FLOP rate | 1/tile | 2.7 s |
| `pci` | host-to-device PCIe bandwidth | 1/tile | 27.6 s |
| `peer2pear` | peer-to-peer tile bandwidth | 1/tile | 1.5 s |
| `gemm` | per-tile GEMM across 6 precisions | 1/tile | 31.4 s |
| `fftc2c` | complex-to-complex FFT throughput | 1/tile | 17.1 s |
| `simple_injection_bisection` | injection bandwidth | 1/tile | 0.9 s |
| `full_injection_bisection` | all-pairs bisection bandwidth | 1/tile | 0.9 s |

Wall times were measured on two Aurora nodes at 12 ranks per node. They set the
budget for what can run inside a retry loop: `mem_and_gpu_row` at 0.05 s is
free, `gemm` at 31 s is not.

## Requirements

| Dependency | Needed for | Absent |
|---|---|---|
| CMake ≥ 3.18 | everything | hard error |
| MPI compiler | network, GPU kernels | targets dropped, warning |
| OpenMP offload | `triad`, `flops` | targets dropped, warning |
| `icpx` + oneMKL | `pci`, `peer2pear`, `gemm`, `fftc2c` | targets dropped, warning |
| Level Zero | `topology` | target dropped, warning |
| Python 3.6+, PyYAML ≥ 6.0 | the runner | runner will not start |

A missing dependency drops the affected targets rather than failing the
configure, so the tree still builds on a login node without a GPU compiler.
This means **a successful build does not imply all ten binaries exist**. Check
the configure summary:

```
--   SYCL ......... ON
--   Level Zero ... ON
```

`SYCL ......... OFF` yields 5 of 10 binaries. That is graceful degradation, not
a build failure, and it is the usual explanation for a kernel that is
"missing" at run time.

## Build

On Aurora:

```bash
module load cmake
cd utils/check_healthy_tests
cmake -S . -B ../../build/health_checks \
      -DHEALTH_CHECKS_ENABLE_SYCL=ON \
      -DHEALTH_CHECKS_ENABLE_LEVEL_ZERO=ON
cmake --build ../../build/health_checks -j 16
```

Or through the runner, which reads the configure and build commands from
`health_checks.yaml`:

```bash
module load frameworks          # Python 3.12 + PyYAML
python3 system_monitoring/run_health_checks.py --build
```

Do not load `frameworks` before running the SYCL kernels themselves. It
overrides the default oneAPI runtime and the kernels abort with `No device of
requested type available` (SIGABRT, exit 134). Load it only for the Python
runner, or in a subshell.

## Running the tests

### 1. Everything enabled, on an allocation

```bash
python3 system_monitoring/run_health_checks.py --build \
    --dashboard-json system_monitoring/data/health_${PBS_JOBID%%.*}.json \
    --pbs-jobid "$PBS_JOBID" \
    --nodefile "$PBS_NODEFILE"
```

### 1b. Everything, with one command

`scripts/run_all_tests.sh` builds the tree, runs every kernel at serial, single
node and full allocation scale, and prints how long each one took.

```bash
# as a batch job
qsub -A <project> -q debug -l select=2:ncpus=208 \
     -l walltime=00:30:00 -l filesystems=flare \
     utils/check_healthy_tests/scripts/run_all_tests.sh

# or inside an existing allocation
./utils/check_healthy_tests/scripts/run_all_tests.sh
```

| Variable | Default | Effect |
|---|---|---|
| `REPO_DIR` | auto-detected | repo checkout |
| `RESULTS_DIR` | `$REPO_DIR/test_results` | output root |
| `PPN` | 12 | ranks per node |
| `SKIP_SLOW` | 0 | set to 1 to skip `pci`, `fftc2c`, `gemm` (~76 s) |
| `BUILD` | 1 | set to 0 to use the existing build |

Output goes to `RESULTS_DIR/run_<jobid>/`: a `summary.log`, one
`out.<test>.log` per kernel, and a `COMPLETE` sentinel written as the final
action. **Check for the sentinel, not just for the job leaving the queue.** A
job that dies partway also disappears from `qstat`, and only the sentinel
distinguishes the two.

The script exits non-zero if any kernel failed, so it can gate a pipeline.

Each kernel is checked two ways: its exit status, and the presence of exactly
one `KERNEL_TIME` line. MPI kernels print that line from rank 0 only, so any
other count means the kernel never reached its exit path -- a kill or an early
abort that a zero exit status can hide.

### 2. A subset

```bash
run_health_checks.py --list                                  # what is enabled
run_health_checks.py --checks mem_and_gpu_row                # one check
run_health_checks.py --groups memory,injection_bisection     # by group
run_health_checks.py --include-disabled --checks triad,flops # override YAML
run_health_checks.py --dry-run                               # print, do not run
```

### 3. Directly, without the runner

```bash
# memory inventory, serial
./build/health_checks/mem_and_gpu_row --csv

# GPU bandwidth, one rank per tile
mpiexec --no-vni -n 12 --ppn 12 ./build/health_checks/triad

# fabric, across two nodes
mpiexec --no-vni -n 24 --ppn 12 ./build/health_checks/full_injection_bisection
```

`--no-vni` is required on Aurora. Without it, multi-node launches fail with
`NA_HOSTUNREACH`.

## Kernel wall time

Every kernel prints one line immediately before it exits:

```
KERNEL_TIME gemm 31.425 s
```

MPI kernels print from **rank 0 only**, so a 12-rank run emits exactly one
line. That makes the line count a cheap assertion that the kernel reached its
exit path rather than being killed partway:

```bash
n=$(mpiexec --no-vni -n 12 --ppn 12 ./build/health_checks/triad | grep -c KERNEL_TIME)
[ "$n" -eq 1 ] || echo "kernel did not reach its exit path"
```

A kernel that runs several distinct phases also reports each one:

```
PHASE_TIME gemm DGEMM 7.812 s
PHASE_TIME gemm SGEMM 5.331 s
PHASE_TIME gemm HGEMM 0.534 s
PHASE_TIME gemm BF16GEMM 0.543 s
PHASE_TIME gemm TF32GEMM 1.083 s
PHASE_TIME gemm I8GEMM 0.269 s
KERNEL_TIME gemm 31.425 s
```

`gemm` reports one phase per precision. The breakdown is what makes the total
actionable: a tile that is slow in one precision points somewhere different
from a tile that is slow in all six.

To add phases to another kernel, call `kernel_timer_.phase("<label>")` at each
boundary. The phase clock resets on every call, so each line is that phase's
own duration rather than a running total.

**If you parse kernel stdout, select the line you want by shape, not by
position.** `KERNEL_TIME` is now the last line, so `tail -1` returns the timing
line rather than the data row. For a CSV row, anchor on the timestamp:

```bash
./build/health_checks/mem_and_gpu_row --csv | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' | tail -1
```

## Gating on measured values

An exit code of 0 means the kernel ran, not that the node is healthy. An
`expect:` block in `system_monitoring/health_checks.yaml` gates on the numbers:

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

| YAML | Behaviour |
|---|---|
| no `expect:` | exit code only |
| `expect:` without `min`/`max` | record-only: measured and trended, never fails |
| `expect:` with `min`/`max` | gates the check |

Record-only is how a threshold is acquired when its correct value is not yet
known: run it across a real allocation, read the values from the dashboard
JSON, then set a bound. Rule syntax is documented in
[system_monitoring/README.md](../../system_monitoring/README.md).

## Selecting healthy nodes

`utils/get_healthy_nodes.sh` chooses nodes for a run. By default it selects on
reachability. `HEALTH_LEVEL=mem` adds the measured probe:

```bash
export HEALTH_LEVEL=mem
export HEALTH_PROBE_BIN=$PWD/build/health_checks/mem_and_gpu_row
get_healthy_nodes.sh nodefile_pool 4 pbs_nodefile1 crashed_nodes
```

| Variable | Default | Meaning |
|---|---|---|
| `HEALTH_LEVEL` | `ping` | `ping` or `mem` |
| `HEALTH_PROBE_BIN` | build tree path | probe binary |
| `HEALTH_MIN_MEM_AVAIL_MIB` | 65536 | minimum available RAM |
| `HEALTH_MAX_GPU_USED_MIB` | 4096 | maximum GPU memory in use (Sysman only; reads 0 on Aurora) |
| `HEALTH_MIN_GPU_DEVICES` | 0 | minimum GPU count from sysman |

Per-node results are written to a `.probe` file beside the node lists:

```
x4418c2s1b0n0 PROBE_OK   mem_available=1143660 gpu_used=0 gpu_devices=0
x4418c2s3b0n0 PROBE_FAIL mem_available=1141181<99999999
```

The script **fails open on infrastructure** — a missing probe binary degrades
to `ping` with a warning rather than draining the pool — and **fails closed on
thresholds**. Exit status 100 means no node satisfied the request.

The default memory and GPU floors are conservative starting points, not
measured values. Calibrate them with a record-only rule before relying on them
to retire hardware.

## Diagnosing a slow node

`gemm` reports per-tile throughput across six precisions and flags tiles below
a threshold:

```
GEMM_TILE      x4302c2s0b0n0 5.1 11 215732.4 -10.22% OUTLIER (HGEMM)
GEMM_CANDIDATE x4302c2s0b0n0 tile 5.1 rank 11 slow_in 1/6 worst -10.87% mean -5.98%
GEMM_VERDICT   1 tile(s) below threshold
```

| Flag | Effect |
|---|---|
| `--threshold <pct>` | outlier threshold, default 10 |
| `--csv` | machine-readable rows |
| `--quiet-tiles` | suppress per-tile lines |
| `--fail-on-outlier` | exit 3 when a tile is slow |

`utils/gemm_diagnose.sh` wraps this to decide whether a node should be retired
or returned to the spare pool. It exits 0 when clean and 3 when it has
candidates, writing the hostnames to a `.candidates` file.

A caution supported by the runs so far: the same tile position (`tile 5.1 rank
11`) has appeared as the outlier on two different node pairs. A position that
is consistently slow across distinct hardware points at a systematic effect —
thermal or power — rather than a defective GPU. Establish a baseline across
several nodes before retiring anything on one observation.

`gemm` is not part of the default retry loop. At 31 s it would re-run on every
restart trial, and for the common failure — a node that has gone away — a ping
answers the question in milliseconds.

## Adding a test

1. Add the source under the matching `src/<group>/` directory.
2. Register the target in that directory's `CMakeLists.txt`. Guard it with the
   feature option for its dependency so the tree still configures without it.
3. Include `kernel_timer.hpp` (or `kernel_timer.h` for C) and construct a
   `KernelTimer` as the first statement in `main` so the kernel reports its
   wall time like the others.
4. Add an entry to `system_monitoring/health_checks.yaml`, with an `expect:`
   block if the test produces a number worth gating on. Start record-only.
5. Verify on a real allocation. A login-node run does not exercise the GPUs,
   and a stub does not exercise the binary.

## Tools

| Path | Purpose |
|---|---|
| `tools/gen_mk_table.py` | tabulate kernel output; needs a mode argument (`GEMM`, `micro`) |
| `scripts/run_interconnect_suite.sh` | full interconnect sweep across a node pair |
| `../gemm_diagnose.sh` | retire-vs-return decision for a suspect node |
| `../get_healthy_nodes.sh` | node selection with optional measured probe |

## Verification

The suite was last exercised end to end on two Aurora compute nodes
(`x4302c2s0b0n0`, `x4302c2s1b0n0`): 10/10 binaries built, 14/14 checks passed,
and every kernel emitted exactly one `KERNEL_TIME` line. Node selection was
re-verified separately on `x4418c2s1b0n0` and `x4418c2s3b0n0`: 6/6 passed,
covering both health levels, an impossible threshold, and the fail-open path.

## Measured values

Wall-clock time indicates a kernel ran. It does not indicate whether the node
is healthy. The values below are what each kernel reported on a two-node debug
allocation, 12 ranks per node, CPU-bound with one rank per GPU tile
(job 8763237).

| Kernel | Measurement | 12 ranks | 24 ranks | Time (12 ranks) |
|---|---|---|---|---|
| `mem_and_gpu_row` | host memory available | 1144006 MiB | not run | 0.05 s |
| `mem_and_gpu_row` | GPU devices enumerated | 6 | not run | |
| `topology` | tile enumeration | 12 tiles | not run | 0.04 s |
| `triad` | memory bandwidth | 12311.8 GB/s | 20843.8 GB/s | 3.28 s |
| `flops` | peak FP32 | 255605 GFlop/s | 479661 GFlop/s | 2.69 s |
| `flops` | peak FP64 | 190517 GFlop/s | 363820 GFlop/s | |
| `pci` | H2D / D2H / bidirectional | 328 / 264 / 357 GB/s | not run | 27.83 s |
| `peer2pear` | tile-to-tile uni / bi | 211 / 391 GB/s | not run | 1.54 s |
| `gemm` | DGEMM | 171351 GFlop/s | 339606 GFlop/s | 31.47 s |
| `gemm` | SGEMM | 247324 GFlop/s | 492117 GFlop/s | |
| `gemm` | HGEMM | 2467740 GFlop/s | 4693590 GFlop/s | |
| `gemm` | BF16 | 2462280 GFlop/s | 4752330 GFlop/s | |
| `gemm` | TF32 | 1288180 GFlop/s | 2459870 GFlop/s | |
| `gemm` | I8 | 5088330 GFlop/s | 9287100 GFlop/s | |
| `fftc2c` | FFT C2C 1D / 2D | 36596.2 / 34933.6 GFlop/s | not run | 16.91 s |
| `simple_injection_bisection` | injection aggregate | 70.740 GB/s | 233.436 GB/s | 0.97 s |
| `simple_injection_bisection` | bisection aggregate | 98.47 GB/s | not recorded | |
| `full_injection_bisection` | injection aggregate | 153.98 GB/s | 396.90 GB/s | 0.93 s |
| `full_injection_bisection` | bisection aggregate | 490.05 GB/s | 694.05 GB/s | |

Per-precision timings inside `gemm`, from the same run:

| Precision | Time |
|---|---|
| DGEMM | 12.457 s |
| SGEMM | 7.892 s |
| HGEMM | 2.746 s |
| BF16GEMM | 2.676 s |
| TF32GEMM | 3.384 s |
| I8GEMM | 2.317 s |

### Reading the numbers

Compute kernels scale close to linearly from 12 to 24 ranks because they are
per-rank and do not communicate. Network bisection does not, because the second
node introduces off-node traffic: `full_injection_bisection` rose from 490 to
694 GB/s rather than doubling.

Tile spread matters more than the absolute figure. In the run above the slowest
tile per precision was:

```
GEMM_SLOWEST DGEMM    tile 0.1 rank  1  14279.7 GFlop/s  -3.50% vs global median
GEMM_SLOWEST SGEMM    tile 2.1 rank  5  20615.3 GFlop/s  -0.02% vs global median
GEMM_SLOWEST HGEMM    tile 3.0 rank  6 223180.6 GFlop/s  -5.82% vs global median
GEMM_SLOWEST BF16GEMM tile 0.1 rank  1 220204.1 GFlop/s  -6.56% vs global median
GEMM_SLOWEST TF32GEMM tile 0.1 rank  1 112499.2 GFlop/s  -3.36% vs global median
GEMM_SLOWEST I8GEMM   tile 5.1 rank 11 463626.3 GFlop/s  -5.93% vs global median
GEMM_VERDICT none; every tile within 10.0% of its peers
```

Every tile was within 6.6% of the median, so nothing was flagged. A tile 10% or
more below its peers across several precisions is worth investigating; a tile
slow in one precision only is more likely thermal or scheduling noise.

### GPU memory reporting requires Sysman

`mem_and_gpu_row` reports GPU memory through two independent paths:

| Column | Source | Reports |
|---|---|---|
| `gpu_sysman_used_mib` | Level Zero Sysman | memory currently in use |
| `gpu_core_devices` | Level Zero core | device count and total memory |

The Sysman path requires `ZES_ENABLE_SYSMAN=1`, and on Aurora it returns
nothing even when that is set. Measured on a compute node with six GPUs
(job 8763307):

```
column                          off             on
gpu_sysman_devices                0              0
gpu_sysman_total_mib              0              0
gpu_sysman_used_mib               0              0
gpu_core_devices                  6              6
gpu_core_total_mib         78643200       78643200
```

Sysman is unavailable on this platform, not merely unset. The consequence is
that **`gpu_used_mib` cannot detect leaked VRAM on Aurora**. It is retained
with `missing_ok: true` for sites where Sysman does work, and
`health_checks.yaml` sets the variable so those sites get a real measurement,
but on Aurora the rule always sees zero and always reports OK.

Detecting a previous job's leaked VRAM therefore requires a different
mechanism. `xpu-smi`, where available, is the usual route.

The `gpu_core_devices` column does not depend on Sysman, which is why the
shipped configuration gates on it with `min: 1`. That rule does fire: on a node
with no GPU it reports `gpu_devices: 0 < min 1`. It proves GPUs were
enumerated, which is a weaker statement than "no VRAM is pinned" but is a real
measurement rather than an absent one.

### gpu_core_total_mib is wrong by 100x

The column reports 78643200 MiB across six devices, or 12.5 TiB each. Aurora
Max 1550 GPUs have 128 GiB each, so the value is exactly 100 times too large.

The cause is in `src/memory/mem_and_gpu_row.cpp`. `scan_total_size_from_props`
does not read a documented struct field; it scans a 256-byte opaque buffer at
four-byte strides for any 8-byte value between 1 GiB and 16 TiB, takes the
largest, and the caller then sums one such value per memory module. Whatever it
is finding is not the device VRAM size.

This is upstream code and is left unmodified. Nothing in the shipped
configuration gates on `gpu_core_total_mib`, and nothing should until it is
fixed. Use `gpu_core_devices`, which is a plain device count and is correct.
