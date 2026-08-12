"""Command-line monitor for detecting stalled checkpoint files."""

from __future__ import annotations


import argparse
import os
import subprocess
import time
from pathlib import Path
from time import localtime, strftime
from typing import Optional

from . import __version__

try:
    import ezpz
    logger = ezpz.get_logger(__name__)
except Exception:
    import logging
    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s][%(levelname)s][%(name)s] - %(message)s',
    )
    logger = logging.getLogger(__name__)
    logger.setLevel("INFO")


def get_date(etime: float) -> str:
    return strftime("%Y-%m-%d %H:%M:%S", localtime(etime))


def most_recent_mtime(paths: list[Path]) -> Optional[float]:
    """Return the most recent mtime among existing paths; None if none exist."""
    mtimes: list[float] = []
    for p in paths:
        try:
            if p.exists():
                mtimes.append(p.stat().st_mtime)
        except Exception:
            # Ignore transient stat errors
            pass
    return max(mtimes) if mtimes else None


def main():
    parser = argparse.ArgumentParser(
        description="Monitor output files for activity and kill a command if it hangs.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--timeout",
        default=300,
        type=int,
        help="Seconds of inactivity after which the job will be killed.",
    )
    parser.add_argument(
        "--check",
        default=5,
        type=int,
        help="Seconds between file-activity checks.",
    )
    parser.add_argument(
        "--kill-command",
        dest="kill_command",
        default="pkill -u $USER mpiexec",
        type=str,
        help="Shell command to terminate the job (e.g., 'pkill -u $USER mpiexec'). ",
    )
    parser.add_argument(
        "--outputs",
        dest="outputs",
        default="chkpt/latest",
        type=str,
        help="Colon- (or comma/space-) separated output files to watch (e.g., 'a.out:train.log').",
    )
    parser.add_argument(
        "--grace",
        default=10,
        type=int,
        help="Seconds to wait after sending the kill command before exiting.",
    )
    parser.add_argument(
        "--dry-run",
        dest="dry_run",
        action="store_true",
        help="If set, do not actually run the kill command—only log the action.",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    args = parser.parse_args()
    logger.info(f"Args:\n{args}")

    # Deduplicate while preserving order
    _seen = set()
    files = []
    # Accept colon/comma/space-separated lists (matches --outputs help).
    to_watch = args.outputs.replace(",", ":").replace(" ", ":").split(":")
    logger.info(f"Watching {to_watch}")
    for part in to_watch:
        part = part.strip()
        if not part:
            continue
        if part not in _seen:
            files.append(Path(part))
            _seen.add(part)

    start_wall = time.time()
    last_change = most_recent_mtime(files)
    if last_change is None:
        # If nothing exists yet, treat as no updates since start.
        last_change = time.time()
    last_report = 0.0

    logger.info("Job monitor started")
    logger.info(f"Watching: {', '.join(str(p) for p in files) if files else '(none)'}")
    logger.info(f"Timeout: {args.timeout}s | Check interval: {args.check}s")

    proc = None

    try:
        while True:
            time.sleep(args.check)

            if proc:
                # Poll the process to see if it has exited
                proc.poll()
                if proc.returncode is not None:
                    logger.info(
                        f"Monitored command exited with "
                        f"return code {proc.returncode}. Exiting monitor."
                    )
                    break

            # Update last_change if any file advanced
            current_latest = most_recent_mtime(files)
            if current_latest is not None and current_latest > last_change:
                last_change = current_latest

            now = time.time()
            idle = now - last_change
            runtime = now - start_wall

            # Periodic status line (not every loop)
            if now - last_report >= max(5, args.check):
                last_report = now
                if not any(p.exists() for p in files):
                    logger.info("None of the watched files exist yet; monitoring...")
                else:
                    job_metrics = {
                        "now": get_date(now),
                        "last_change": get_date(last_change),
                        "runtime_s": f"{runtime:.1f}",
                        "idle_s": f"{idle:.1f}",
                    }
                    metrics_str = " ".join(f"{k}={v}" for k, v in job_metrics.items())
                    logger.info(metrics_str)

            if idle >= args.timeout:
                logger.info(
                    f"[{get_date(now)}] Output has not been updated for {idle:.1f} seconds. "
                    f"Issuing kill command..."
                )
                if not args.dry_run:
                    try:
                        if proc:
                            logger.info(f"Killing monitored process (PID: {proc.pid})")
                            proc.kill()
                        else:
                            logger.info(f"Executing kill command: {args.kill_command}")
                            # Use shell so "$USER" env var works in defaults
                            subprocess.run(args.kill_command, shell=True, check=True)

                        if args.grace > 0:
                            logger.info(f"Waiting {args.grace}s grace period before exit...")
                            time.sleep(args.grace)
                    except Exception as e:
                        logger.error(f"Failed to execute kill command: {e}")
                else:
                    logger.info("(dry-run) Skipping kill execution")

                logger.info(f"Monitor exiting after inactivity timeout.")
                break
    except KeyboardInterrupt:
        logger.info("Monitor interrupted by user. Exiting.")
        if proc and proc.returncode is None:
            logger.info("Attempting to terminate the monitored command...")
            proc.terminate()
            try:
                proc.wait(timeout=args.grace)
                logger.info("Command terminated.")
            except subprocess.TimeoutExpired:
                logger.info("Command did not terminate gracefully. Forcing kill.")
                proc.kill()
    finally:
        if proc and proc.returncode is None:
            logger.info("Ensuring monitored process is terminated before exit.")
            proc.kill()


if __name__ == "__main__":
    main()
