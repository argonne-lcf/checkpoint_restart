# Developing a monitoring dashboard

For the system monitoring, I would like to have a dashboard to be able to visualize the health condition of the nodes.

- [x] Load health data from JSON files.
- [x] Provide an HTTP dashboard service to visualize node health.
  - Added: `system_monitoring/dashboard.py`
  - Added: `system_monitoring/README.md`
  - Added sample data pattern: `system_monitoring/data/health_<job_id>.json`

Current dashboard endpoints:
- `/` web UI
- `/api/health` JSON summary + per-node rows
- `/api/ping` liveness

Next enhancements:
- HTTPS/reverse-proxy deployment mode
- Authentication
- History/trend charts across time windows
