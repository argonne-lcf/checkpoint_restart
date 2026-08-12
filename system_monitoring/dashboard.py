#!/usr/bin/env python3
"""Simple dashboard server for visualizing node health JSON data."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import parse_qs, urlsplit


def iso_now() -> str:
    return dt.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def parse_timestamp(value: Optional[str]) -> Optional[dt.datetime]:
    if not value or not isinstance(value, str):
        return None
    raw = value.strip()
    if not raw:
        return None
    try:
        if raw.endswith("Z"):
            raw = raw[:-1] + "+00:00"
        return dt.datetime.fromisoformat(raw)
    except Exception:
        return None


def normalize_status(record: Dict) -> str:
    status = str(record.get("status", "")).strip().lower()
    if status in {"healthy", "unhealthy", "warning", "unknown"}:
        return status

    if "healthy" in record:
        return "healthy" if bool(record["healthy"]) else "unhealthy"

    score = record.get("score")
    if isinstance(score, (int, float)):
        if score >= 0.8:
            return "healthy"
        if score >= 0.5:
            return "warning"
        return "unhealthy"

    return "unknown"


def normalize_node(record: Dict) -> str:
    for key in ("node", "hostname", "host", "name"):
        if key in record and str(record[key]).strip():
            return str(record[key]).strip()
    return "unknown"


def normalize_job_id(record: Dict) -> str:
    for key in ("PBS_JOBID", "pbs_jobid", "job_id", "jobid", "job"):
        if key in record and str(record[key]).strip():
            return str(record[key]).strip()
    return "unknown"


@dataclass
class NodeState:
    node: str
    job_id: str
    status: str
    timestamp: Optional[str]
    source_file: str
    details: Dict


class HealthDataStore:
    def __init__(self, data_dir: Path):
        self.data_dir = data_dir
        self._lock = threading.Lock()
        self._rows: List[NodeState] = []
        self._source_files: List[str] = []
        self._job_ids: List[str] = []
        self._last_refresh_utc = iso_now()

    def refresh(self) -> None:
        files = sorted(self.data_dir.glob("*.json"))
        latest_by_job_node: Dict[tuple, NodeState] = {}
        source_names: List[str] = []
        job_ids = set()

        for path in files:
            source_names.append(path.name)
            try:
                payload = json.loads(path.read_text(encoding="utf-8"))
            except Exception:
                continue

            rows = []
            if isinstance(payload, list):
                rows = [r for r in payload if isinstance(r, dict)]
            elif isinstance(payload, dict):
                if isinstance(payload.get("nodes"), list):
                    rows = [r for r in payload["nodes"] if isinstance(r, dict)]
                else:
                    rows = [payload]

            for row in rows:
                node = normalize_node(row)
                job_id = normalize_job_id(row)
                status = normalize_status(row)
                ts_raw = row.get("timestamp") or row.get("time")
                ts = str(ts_raw).strip() if ts_raw is not None else None

                candidate = NodeState(
                    node=node,
                    job_id=job_id,
                    status=status,
                    timestamp=ts,
                    source_file=path.name,
                    details=row,
                )
                job_ids.add(job_id)

                key = (job_id, node)
                prev = latest_by_job_node.get(key)
                if prev is None:
                    latest_by_job_node[key] = candidate
                    continue

                prev_dt = parse_timestamp(prev.timestamp)
                curr_dt = parse_timestamp(candidate.timestamp)
                if prev_dt is None and curr_dt is not None:
                    latest_by_job_node[key] = candidate
                elif prev_dt is not None and curr_dt is not None and curr_dt >= prev_dt:
                    latest_by_job_node[key] = candidate

        with self._lock:
            self._rows = list(latest_by_job_node.values())
            self._source_files = source_names
            self._job_ids = sorted(job_ids)
            self._last_refresh_utc = iso_now()

    def snapshot(self, selected_job_id: str = "all") -> Dict:
        with self._lock:
            rows = list(self._rows)
            files = list(self._source_files)
            job_ids = list(self._job_ids)
            last_refresh = self._last_refresh_utc

        if selected_job_id not in ("", "all"):
            rows = [row for row in rows if row.job_id == selected_job_id]

        status_counts = {"healthy": 0, "warning": 0, "unhealthy": 0, "unknown": 0}
        for n in rows:
            status_counts[n.status] = status_counts.get(n.status, 0) + 1

        return {
            "last_refresh_utc": last_refresh,
            "data_dir": str(self.data_dir),
            "source_files": files,
            "job_ids": job_ids,
            "selected_job_id": selected_job_id if selected_job_id else "all",
            "summary": {
                "total_nodes": len(rows),
                "healthy": status_counts.get("healthy", 0),
                "warning": status_counts.get("warning", 0),
                "unhealthy": status_counts.get("unhealthy", 0),
                "unknown": status_counts.get("unknown", 0),
            },
            "nodes": [
                {
                    "node": n.node,
                    "job_id": n.job_id,
                    "status": n.status,
                    "timestamp": n.timestamp,
                    "source_file": n.source_file,
                    "details": n.details,
                }
                for n in sorted(rows, key=lambda x: (x.node, x.job_id))
            ],
        }


def build_index_html(refresh_seconds: int) -> str:
    return f"""<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>Node Health Dashboard</title>
  <style>
    :root {{
      --bg: #f5f7fb;
      --panel: #ffffff;
      --ink: #1f2937;
      --muted: #64748b;
      --healthy: #0f766e;
      --warning: #b45309;
      --unhealthy: #b91c1c;
      --unknown: #475569;
      --accent: #0ea5e9;
    }}
    body {{ margin: 0; font-family: "IBM Plex Sans", "Segoe UI", sans-serif; background: radial-gradient(circle at 15% 10%, #dbeafe, transparent 35%), var(--bg); color: var(--ink); }}
    .wrap {{ max-width: 1100px; margin: 0 auto; padding: 24px; }}
    .head {{ display: flex; justify-content: space-between; align-items: baseline; gap: 12px; flex-wrap: wrap; }}
    .title {{ font-size: 28px; font-weight: 700; letter-spacing: 0.01em; }}
    .meta {{ color: var(--muted); font-size: 14px; }}
    .cards {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin-top: 16px; }}
    .card {{ background: var(--panel); border-radius: 12px; padding: 14px; box-shadow: 0 4px 14px rgba(15, 23, 42, 0.08); }}
    .card .k {{ color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.06em; }}
    .card .v {{ font-size: 28px; font-weight: 700; line-height: 1.1; margin-top: 6px; }}
    .healthy .v {{ color: var(--healthy); }}
    .warning .v {{ color: var(--warning); }}
    .unhealthy .v {{ color: var(--unhealthy); }}
    .unknown .v {{ color: var(--unknown); }}
    .toolbar {{ margin-top: 18px; display: flex; gap: 10px; flex-wrap: wrap; }}
    input, select {{ border: 1px solid #cbd5e1; border-radius: 8px; padding: 8px 10px; font-size: 14px; background: white; }}
    table {{ width: 100%; border-collapse: collapse; margin-top: 14px; background: var(--panel); border-radius: 12px; overflow: hidden; box-shadow: 0 4px 14px rgba(15, 23, 42, 0.08); }}
    th, td {{ padding: 10px 12px; border-bottom: 1px solid #e2e8f0; text-align: left; font-size: 14px; }}
    th {{ background: #f8fafc; font-weight: 600; color: #334155; }}
    tr:last-child td {{ border-bottom: none; }}
    .pill {{ display: inline-block; font-size: 12px; font-weight: 700; border-radius: 999px; padding: 3px 8px; color: white; text-transform: uppercase; }}
    .pill.healthy {{ background: var(--healthy); }}
    .pill.warning {{ background: var(--warning); }}
    .pill.unhealthy {{ background: var(--unhealthy); }}
    .pill.unknown {{ background: var(--unknown); }}
    .small {{ color: var(--muted); font-size: 12px; }}
    .check-btn {{ border: 1px solid #cbd5e1; background: #f8fafc; border-radius: 8px; padding: 4px 8px; cursor: pointer; font-size: 12px; }}
    .check-btn:hover {{ background: #e2e8f0; }}
  </style>
</head>
<body>
  <div class=\"wrap\">
    <div class=\"head\">
      <div class=\"title\">Node Health Dashboard</div>
      <div class=\"meta\" id=\"meta\">Loading...</div>
    </div>

    <div class=\"cards\">
      <div class=\"card\"><div class=\"k\">Total Nodes</div><div class=\"v\" id=\"total\">0</div></div>
      <div class=\"card healthy\"><div class=\"k\">Healthy</div><div class=\"v\" id=\"healthy\">0</div></div>
      <div class=\"card warning\"><div class=\"k\">Warning</div><div class=\"v\" id=\"warning\">0</div></div>
      <div class=\"card unhealthy\"><div class=\"k\">Unhealthy</div><div class=\"v\" id=\"unhealthy\">0</div></div>
      <div class=\"card unknown\"><div class=\"k\">Unknown</div><div class=\"v\" id=\"unknown\">0</div></div>
    </div>

    <div class=\"toolbar\">
      <select id=\"jobId\">
        <option value=\"all\">All PBS_JOBID</option>
      </select>
      <input id=\"search\" placeholder=\"Filter nodes...\" />
      <select id=\"status\">
        <option value=\"all\">All status</option>
        <option value=\"healthy\">Healthy</option>
        <option value=\"warning\">Warning</option>
        <option value=\"unhealthy\">Unhealthy</option>
        <option value=\"unknown\">Unknown</option>
      </select>
    </div>

    <table>
      <thead>
        <tr>
          <th>Node</th>
          <th>PBS_JOBID</th>
          <th>Status</th>
          <th>Checks (Pass/Fail)</th>
          <th>Timestamp</th>
          <th>Source</th>
        </tr>
      </thead>
      <tbody id=\"rows\"></tbody>
    </table>
  </div>

<script>
const refreshMs = {max(1000, refresh_seconds * 1000)};
let cache = [];
let activeJobId = 'all';
let renderedRows = [];

function esc(s) {{
  return String(s ?? '').replace(/[&<>\"]/g, c => ({{'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}}[c]));
}}

function pill(status) {{
  return `<span class=\"pill ${{esc(status)}}\">${{esc(status)}}</span>`;
}}

function checkStats(n) {{
  const summary = n?.details?.summary || {{}};
  const checks = Array.isArray(n?.details?.checks) ? n.details.checks : [];
  const total = Number.isFinite(summary.total_checks) ? summary.total_checks : checks.length;
  const failed = Number.isFinite(summary.failed_checks)
    ? summary.failed_checks
    : checks.filter(c => (c?.status || '').toLowerCase() !== 'healthy').length;
  const passed = Number.isFinite(summary.passed_checks)
    ? summary.passed_checks
    : Math.max(0, total - failed);
  return `${{passed}}/${{failed}}`;
}}

function passedCheckNames(n) {{
  const summary = n?.details?.summary || {{}};
  if (Array.isArray(summary.passed_check_names) && summary.passed_check_names.length > 0) {{
    return summary.passed_check_names.join(', ');
  }}
  const checks = Array.isArray(n?.details?.checks) ? n.details.checks : [];
  return checks.filter(c => (c?.status || '').toLowerCase() === 'healthy').map(c => c?.id || '').filter(Boolean).join(', ');
}}

function failedCheckNames(n) {{
  const summary = n?.details?.summary || {{}};
  if (Array.isArray(summary.failed_check_names) && summary.failed_check_names.length > 0) {{
    return summary.failed_check_names.join(', ');
  }}
  const checks = Array.isArray(n?.details?.checks) ? n.details.checks : [];
  return checks.filter(c => (c?.status || '').toLowerCase() !== 'healthy').map(c => c?.id || '').filter(Boolean).join(', ');
}}

function renderRows() {{
  const q = document.getElementById('search').value.trim().toLowerCase();
  const status = document.getElementById('status').value;
  const rows = document.getElementById('rows');

  const filtered = cache.filter(n => {{
    const matchesQ = !q || (n.node || '').toLowerCase().includes(q);
    const matchesS = status === 'all' || n.status === status;
    return matchesQ && matchesS;
  }});
  renderedRows = filtered;

  rows.innerHTML = filtered.map((n, i) => `
    <tr>
      <td>${{esc(n.node)}}</td>
      <td><span class=\"small\">${{esc(n.job_id || 'unknown')}}</span></td>
      <td>${{pill(n.status)}}</td>
      <td><button class=\"check-btn\" data-row-index=\"${{i}}\">${{esc(checkStats(n))}}</button></td>
      <td><span class=\"small\">${{esc(n.timestamp || '')}}</span></td>
      <td><span class=\"small\">${{esc(n.source_file || '')}}</span></td>
    </tr>
  `).join('');
}}

function updateJobIdOptions(jobIds, selected) {{
  const sel = document.getElementById('jobId');
  const prev = sel.value || 'all';
  const wanted = selected || prev || 'all';
  const values = ['all', ...(jobIds || [])];
  sel.innerHTML = values.map(v => {{
    const label = v === 'all' ? 'All PBS_JOBID' : v;
    return `<option value=\"${{esc(v)}}\">${{esc(label)}}</option>`;
  }}).join('');
  if (values.includes(wanted)) {{
    sel.value = wanted;
  }} else {{
    sel.value = 'all';
  }}
  activeJobId = sel.value;
}}

async function refresh() {{
  try {{
    const q = activeJobId && activeJobId !== 'all' ? `?job_id=${{encodeURIComponent(activeJobId)}}` : '';
    const res = await fetch(`/api/health${{q}}`);
    const data = await res.json();

    cache = data.nodes || [];
    updateJobIdOptions(data.job_ids || [], data.selected_job_id || 'all');

    document.getElementById('total').textContent = data.summary?.total_nodes ?? 0;
    document.getElementById('healthy').textContent = data.summary?.healthy ?? 0;
    document.getElementById('warning').textContent = data.summary?.warning ?? 0;
    document.getElementById('unhealthy').textContent = data.summary?.unhealthy ?? 0;
    document.getElementById('unknown').textContent = data.summary?.unknown ?? 0;

    const fileCount = (data.source_files || []).length;
    document.getElementById('meta').textContent = `Last refresh: ${{data.last_refresh_utc || ''}} | Sources: ${{fileCount}} | PBS_JOBID: ${{data.selected_job_id || 'all'}}`;

    renderRows();
  }} catch (err) {{
    document.getElementById('meta').textContent = `Failed to refresh: ${{err}}`;
  }}
}}

document.getElementById('rows').addEventListener('click', (ev) => {{
  const target = ev.target;
  if (!(target instanceof HTMLElement)) return;
  if (!target.classList.contains('check-btn')) return;

  const idxRaw = target.getAttribute('data-row-index');
  const idx = Number(idxRaw);
  if (!Number.isInteger(idx) || idx < 0 || idx >= renderedRows.length) return;

  const node = renderedRows[idx];
  const passed = passedCheckNames(node) || '-';
  const failed = failedCheckNames(node) || '-';

  alert(
    `Node: ${{node.node || 'unknown'}}\\n` +
    `PBS_JOBID: ${{node.job_id || 'unknown'}}\\n\\n` +
    `Passed checks:\\n${{passed}}\\n\\n` +
    `Failed checks:\\n${{failed}}`
  );
}});

document.getElementById('search').addEventListener('input', renderRows);
document.getElementById('status').addEventListener('change', renderRows);
document.getElementById('jobId').addEventListener('change', () => {{
  activeJobId = document.getElementById('jobId').value || 'all';
  refresh();
}});
refresh();
setInterval(refresh, refreshMs);
</script>
</body>
</html>
"""


class DashboardHandler(BaseHTTPRequestHandler):
    store: HealthDataStore = None  # type: ignore
    refresh_seconds: int = 10

    def _send_json(self, data: Dict, status: int = 200) -> None:
        payload = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _send_html(self, html: str, status: int = 200) -> None:
        payload = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlsplit(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path in {"/", "/index.html"}:
            self._send_html(build_index_html(self.refresh_seconds))
            return

        if path == "/api/health":
            self.store.refresh()
            selected_job_id = query.get("job_id", ["all"])[0]
            self._send_json(self.store.snapshot(selected_job_id=selected_job_id))
            return

        if path == "/api/ping":
            self._send_json({"ok": True, "time": iso_now()})
            return

        self._send_json({"error": "not found"}, status=404)


def run_server(data_dir: Path, host: str, port: int, refresh_seconds: int) -> None:
    data_dir.mkdir(parents=True, exist_ok=True)

    store = HealthDataStore(data_dir)
    store.refresh()

    DashboardHandler.store = store
    DashboardHandler.refresh_seconds = refresh_seconds

    server = ThreadingHTTPServer((host, port), DashboardHandler)
    print(f"Dashboard started on http://{host}:{port}")
    print(f"Reading JSON data from: {data_dir}")
    print("Endpoints: /, /api/health, /api/ping")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Serve a node-health dashboard from JSON files.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--data-dir",
        default="system_monitoring/data",
        help="Directory containing node health JSON files.",
    )
    parser.add_argument("--host", default="127.0.0.1", help="Host bind address.")
    parser.add_argument("--port", type=int, default=8080, help="HTTP port.")
    parser.add_argument(
        "--refresh-seconds",
        type=int,
        default=10,
        help="UI/API refresh interval in seconds.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_server(
        data_dir=Path(args.data_dir).resolve(),
        host=args.host,
        port=args.port,
        refresh_seconds=max(1, args.refresh_seconds),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
