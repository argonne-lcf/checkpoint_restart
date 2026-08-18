#!/usr/bin/env python3

# all_reduce_torch_xccl.py -- PyTorch distributed allreduce latency on Intel GPUs.
#
# Measures how long a collective takes across every GPU in the allocation using
# the same software path a training job uses: torch.distributed over Intel's
# XCCL/oneCCL backend on XPU devices. The three numbers reported per rank are
#
#   import_ms          time to import torch and IPEX (catches a slow or broken
#                      module load / filesystem before it looks like a hang)
#   init_ms            time to build the process group (catches rendezvous and
#                      fabric problems)
#   allreduce_p50_us   median allreduce latency (the actual health signal)
#
# An outlier rank in any of these columns identifies the node to drain. Rows
# are printed ordered by (hostname, rank) so runs are diffable across jobs.
#
# BACKEND SELECTION
#   torch >= 2.8 has XCCL built in and is used directly. Older torch falls back
#   to the "ccl" backend, which additionally requires oneccl_bindings_for_pytorch.
#   Rendezvous is env:// with rank 0's hostname as MASTER_ADDR, broadcast over
#   MPI, so no external store is needed.
#
# REQUIREMENTS
#   module load frameworks    (provides torch, IPEX and mpi4py matched to the
#                              driver; a pip-installed torch will not see XPU)
#   XPU must be available -- the script raises rather than silently falling
#   back to CPU, because a CPU-path number is not a GPU health measurement.
#
# USAGE
#   mpiexec -np ${NRANKS} -ppn 12 --cpu-bind ${CPU_BINDING} \
#     python3 all_reduce_torch_xccl.py [size] [--iters N]
#
#   size    buffer per rank, accepts k/kb/m/mb/g/gb   (default 1mb)
#   --iters iterations to time                        (default 2)
#
# ENVIRONMENT expected by the oneCCL path (set these in the job script):
#   export CCL_PROCESS_LAUNCHER=pmix
#   export CCL_ATL_TRANSPORT=mpi
#   export CCL_KVS_MODE=mpi
#   export CCL_CONFIGURATION_PATH=""
#   export CCL_CONFIGURATION=cpu_gpu_dpcpp
#   export CCL_KVS_CONNECTION_TIMEOUT=600
#   export CCL_KVS_USE_MPI_RANKS=1
#   export MPI_PROVIDER=$FI_PROVIDER
#   CPU_BINDING=list:4:9:14:19:20:25:56:61:66:71:74:79
#
# OUTPUT  a torch_version line, a CSV header, then one CSV row per rank:
#   timestamp,hostname,backend,buf_bytes,iters,import_ms,init_ms,allreduce_p50_us


import os, sys, socket, datetime
from time import perf_counter_ns
from statistics import median
from mpi4py import MPI

# ----------------- tiny helpers -----------------
def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")

def parse_size(s: str) -> int:
    s = s.strip().lower()
    # accept "mb"/"kb"/"gb" and "m"/"k"/"g"
    suffix = None
    for suf in ("kb","mb","gb","k","m","g"):
        if s.endswith(suf):
            suffix = suf
            s = s[: -len(suf)]
            break
    mult = 1
    if suffix in ("k","kb"): mult = 1 << 10
    elif suffix in ("m","mb"): mult = 1 << 20
    elif suffix in ("g","gb"): mult = 1 << 30
    return int(float(s) * mult)

def ordered_print_rows(comm, my_row: str):
    """Print rows sorted by hostname then rank, one at a time."""
    rank = comm.Get_rank()
    size = comm.Get_size()
    host = socket.gethostname()
    hosts = comm.allgather(host)
    order = list(range(size))
    # stable insertion sort by (hostname, rank)
    for i in range(1, size):
        key = order[i]
        j = i - 1
        while j >= 0 and (hosts[order[j]] > hosts[key] or
                          (hosts[order[j]] == hosts[key] and order[j] > key)):
            order[j+1] = order[j]
            j -= 1
        order[j+1] = key
    for pos in order:
        if pos == rank:
            print(my_row, flush=True)
        comm.Barrier()

# ----------------- MPI + args -----------------
comm  = MPI.COMM_WORLD
rank  = comm.Get_rank()
world = comm.Get_size()

buf_bytes = 1 << 20   # 1 MiB default
iters     = 2
argv = sys.argv[1:]
i = 0
if i < len(argv) and not argv[i].startswith("-"):
    buf_bytes = parse_size(argv[i]); i += 1
while i < len(argv):
    if argv[i] == "--iters" and i+1 < len(argv):
        iters = int(argv[i+1]); i += 2
    else:
        print(f"Unknown arg: {argv[i]}", file=sys.stderr); i += 1

# ----------------- import torch (+print version) -----------------
t1 = perf_counter_ns()
import torch
try:
    import intel_extension_for_pytorch as ipex  # enables torch.xpu on many images
except Exception:
    pass
import torch.distributed as dist
t2 = perf_counter_ns()
import_ms = (t2 - t1) / 1e6

if rank == 0:
    print(f"torch_version,{torch.__version__}", flush=True)

# ----------------- XPU required  -----------------
if not (hasattr(torch, "xpu") and torch.xpu.is_available()):
    raise RuntimeError("XPU is required and torch.xpu.is_available() returned False. "
                       "Please load IPEX/driver stack for XPU.")

# Map device by per-node local rank
nodecomm   = comm.Split_type(MPI.COMM_TYPE_SHARED, 0, MPI.INFO_NULL)
local_rank = nodecomm.Get_rank()
ndev = torch.xpu.device_count()
if ndev <= 0:
    raise RuntimeError("No XPU devices reported by torch.xpu.device_count().")
dev_index = local_rank % ndev
torch.xpu.set_device(dev_index)
device = torch.device(f"xpu:{dev_index}")

# ----------------- env:// rendezvous -----------------
os.environ['RANK']       = str(os.environ.get('PMI_RANK', rank))
os.environ['WORLD_SIZE'] = str(os.environ.get('PMI_SIZE', world))
if rank == 0:
    master_addr = socket.gethostname()
    master_port = int(os.environ.get("MASTER_PORT", "23456"))
else:
    master_addr = None
    master_port = None
master_addr = comm.bcast(master_addr, root=0)
master_port = comm.bcast(master_port, root=0)
os.environ["MASTER_ADDR"] = master_addr
os.environ["MASTER_PORT"] = str(master_port)

# ----------------- choose backend: xccl (>=2.8) else ccl -----------------
def version_is_ge_2_8(ver: str) -> bool:
    # parse "2.8.0", "2.8.0a0", "2.8.1+cpu", etc.
    base = ver.split("+", 1)[0]
    base = base.split("a", 1)[0].split("b", 1)[0]
    parts = base.split(".")
    try:
        major = int(parts[0])
        minor = int(parts[1]) if len(parts) > 1 else 0
    except Exception:
        return False
    return (major > 2) or (major == 2 and minor >= 8)

backend = "xccl" if version_is_ge_2_8(torch.__version__) else "ccl"
if backend == "ccl":
    # Required for legacy torch-ccl backend
    import oneccl_bindings_for_pytorch  # noqa: F401

t3 = perf_counter_ns()
dist.init_process_group(
    backend=backend,
    init_method='env://',
    world_size=world,
    rank=rank,
    timeout=datetime.timedelta(seconds=3600),
)
t4 = perf_counter_ns()
init_ms = (t4 - t3) / 1e6

comm.Barrier()

# ----------------- allreduce timing -----------------
numel = max(1, buf_bytes // 4)  # float32
lat_us = []
for _ in range(iters):
    x = torch.ones(numel, dtype=torch.float32, device=device)
    t5 = perf_counter_ns()
    dist.all_reduce(x, op=dist.ReduceOp.SUM)
    torch.xpu.synchronize()
    t6 = perf_counter_ns()
    lat_us.append((t6 - t5) / 1e3)

p50_us = median(lat_us)

# ----------------- print summary (header once, then one row per rank) -----------------
header = "timestamp,hostname,backend,buf_bytes,iters,import_ms,init_ms,allreduce_p50_us"
if rank == 0:
    print(header, flush=True)

row = (f"{now_iso()},{socket.gethostname()},{backend},"
       f"{buf_bytes},{iters},{import_ms:.2f},{init_ms:.2f},{p50_us:.1f}")

ordered_print_rows(comm, row)

# ----------------- teardown -----------------
dist.barrier()
dist.destroy_process_group()
nodecomm.Free()