Monitoring TODO status

- [x] Master Python script + YAML configuration to select/run microkernels.
  - Added: `system_monitoring/run_health_checks.py`
  - Added: `system_monitoring/health_checks.yaml`
- [x] Build scripts for microkernels on Aurora/other systems.
  - Added: `utils/check_healthy_tests/CMakeLists.txt`

Quick start

```bash
run_health_checks.py --list
run_health_checks.py --build
```
