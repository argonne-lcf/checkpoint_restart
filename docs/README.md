# Documentation

Reference documentation for the checkpoint/restart testing tools. For the
project overview, motivation, and installation instructions, see the
[top-level README](../README.md).

- [Usage guide](./usage_guide.md) — step-by-step walkthrough: running the
  synthetic workload locally, monitoring for hangs and NaN/Inf, selecting
  healthy nodes, and the PBS retry workflow.
- [Shell script reference](./shell_scripts.md) — narrative descriptions and
  Mermaid sequence diagrams for the shell helpers
  (`get_healthy_nodes.sh`, `flush.sh`, `launcher.sh`) and the
  `qsub_multi_mpiexec.sc` submission script.

## Repository layout

- [`test_pyjob.py`](../test_pyjob.py) — synthetic MPI workload that
  iterates, writes a checkpoint, and can be told to hang, fail, or emit
  NaN/Inf.
- [`qsub_multi_mpiexec.sc`](../qsub_multi_mpiexec.sc) — PBS submission
  script that retries the workload on a healthy subset of nodes until it
  succeeds or `MAX_TRIALS` is reached.
- [`job_monitoring/`](../job_monitoring) — `check_hang.py` (kills a job
  whose output files stop advancing) and `check_nan.py` (kills a job when
  NaN/Inf appears in its output).
- [`utils/`](../utils) — `get_healthy_nodes.sh`, `flush.sh`, `launcher.sh`
  (MPI rank shim), and `optimal_checkpointing.py`.
- [`examples/`](../examples) — ready-to-run PBS cases: `fail/`, `hang/`,
  `nan/`, and `success/`.

Running `pip install -e .` from the repository root places `check_hang.py`,
`check_nan.py`, `get_healthy_nodes.sh`, `launcher.sh`, and `flush.sh` on
your `PATH`, which is how the submission scripts invoke them.

## Support

For questions, please contact Huihuo Zheng (<huihuo.zheng@anl.gov>).
