# Utilities

This folder contains the microkernel assets used by checkpoint/restart
workflows for node/communication health checks.

The former top-level helper scripts now ship inside the `check_mate` package:

- `get_healthy_nodes.sh`, `launcher.sh`, `flush.sh` live in
  `src/check_mate/resources/` (exposed via the `check-mate` CLI).
- `optimal_checkpointing.py` is now the `check_mate.optimal_checkpointing`
  module.

## `check_healthy_tests/`

Microkernel source and support files used for node/communication health checks.

- Build definitions: `check_healthy_tests/CMakeLists.txt`
- Kernel/test sources:
  - `check_healthy_tests/injection_bisection_tests/`
  - `check_healthy_tests/memory_cpu_gpu_check/`
  - `check_healthy_tests/compute_node_interconnects/`

The YAML-driven health-check orchestrator now lives in `system_monitoring/`:

- `system_monitoring/run_health_checks.py`
- `system_monitoring/health_checks.yaml`

Those files call into binaries built from `utils/check_healthy_tests/CMakeLists.txt`.
