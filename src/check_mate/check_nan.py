"""Command-line utility for detecting NaN/Inf tokens in log files."""

from __future__ import annotations

import argparse
import glob
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime
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


# --- Regex helpers -----------------------------------------------------------
NAN_RE = re.compile(r"(?<![A-Za-z0-9_])nan(?![A-Za-z0-9_])", re.IGNORECASE)
INF_RE = re.compile(r"(?<![A-Za-z0-9_])inf(?![A-Za-z0-9_])", re.IGNORECASE)

# --- Helpers ----------------------------------------------------------------


def now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def vprint(verbose: bool, *msg):
    if verbose:
        logger.info(*msg)
        # logger.info(f"[{now()}]", *msg, flush=True)


def split_outputs(outputs: str) -> list[str]:
    """Split --outputs string by ':' and ',' into a list of specs, stripping blanks."""
    if not outputs:
        return []
    specs: list[str] = []
    # to_watch = args.outputs.split(" ")
    to_watch = outputs.replace(",", ":").replace(" ", ":").split(":")
    logger.info(f"Watching {to_watch}")
    for part in to_watch:
        part = part.strip()
        if part:
            specs.append(part)
    return specs


def is_glob(spec: str) -> bool:
    return any(ch in spec for ch in ["*", "?", "["])


def list_files(specs: list[str], recursive: bool) -> dict[str, int]:
    """Resolve a list of file specs (globs or literal paths) to existing files -> size."""
    files: dict[str, int] = {}
    for spec in specs:
        matched: list[str]
        if is_glob(spec):
            matched = glob.glob(spec, recursive=recursive)
        else:
            matched = [spec]
        for f in matched:
            try:
                if os.path.isfile(f):
                    files[f] = os.path.getsize(f)
            except FileNotFoundError:
                # File may appear later; ignore for now
                pass
            except OSError:
                # Permissions or transient FS error; skip this round
                pass
    return files


def scan_new_bytes(path: str, start: int) -> tuple[int, str]:
    """Read text from a file starting at offset `start` and return (new_end, text)."""
    try:
        size = os.path.getsize(path)
        if start >= size:
            return size, ""
        with open(path, "r", errors="replace") as fh:
            fh.seek(start)
            data = fh.read()
        return size, data
    except (FileNotFoundError, PermissionError, OSError):
        return start, ""


def contains_bad_tokens(text: str, include_inf: bool) -> bool:
    if not text:
        return False
    if NAN_RE.search(text):
        return True
    if include_inf and INF_RE.search(text):
        return True
    return False


# --- Kill / Termination actions ---------------------------------------------


def try_kill(args: argparse.Namespace) -> None:
    """Attempt to terminate the job/process according to flags."""
    if args.dry_run:
        logger.info("[DRY-RUN] Would terminate job (skipping actual kill).")
        return

    did_something = False

    # 1) PID signaling
    if args.pid:
        sig = getattr(signal, f"SIG{args.signal}")
        logger.info(f"Sending SIG{args.signal} to PID {args.pid}")
        try:
            os.kill(args.pid, sig)
            did_something = True
        except ProcessLookupError:
            logger.warning(f"[WARN] PID {args.pid} does not exist.")
        except PermissionError as e:
            logger.error(f"[ERROR] No permission to signal PID {args.pid}: {e}")
        except Exception as e:
            logger.error(f"[ERROR] Failed to signal PID {args.pid}: {e}")

        # Optional escalation to SIGKILL
        if args.grace > 0 and sig != signal.SIGKILL:
            time.sleep(args.grace)
            try:
                os.kill(args.pid, 0)
            except ProcessLookupError:
                pass  # process is gone
            else:
                logger.info(f"Escalating to SIGKILL for PID {args.pid}")
                try:
                    os.kill(args.pid, signal.SIGKILL)
                except Exception as e:
                    logger.error(f"[ERROR] SIGKILL failed for PID {args.pid}: {e}")

    # 2) Arbitrary kill command (works for PBS, etc.)
    if args.kill_command:
        logger.info(f"Running kill command: {args.kill_command}")
        try:
            subprocess.run(args.kill_command, shell=True, check=False)
            did_something = True
        except Exception as e:
            logger.error(f"[ERROR] Kill command failed: {e}")

    if not did_something:
        logger.warning("[WARN] No kill action executed (provide --pid or --kill-command).")


# --- CLI / Main --------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Monitor files for NaN/Inf and terminate a job if detected.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument(
        "--outputs",
        required=True,
        help=(
            "File specs to watch. Accepts colon/comma-separated literal paths or glob patterns. "
            "Quote the argument to avoid shell expansion."
        ),
    )
    p.add_argument(
        "--recursive",
        action="store_true",
        help="Enable recursive globbing for patterns containing **.",
    )
    p.add_argument(
        "--check",
        type=int,
        default=15,
        help="Polling interval in seconds.",
    )
    p.add_argument(
        "--timeout",
        type=int,
        default=0,
        help=(
            "Optional: exit with code 0 if no NaN/Inf found after this many seconds. "
            "0 disables the timeout."
        ),
    )
    p.add_argument(
        "--include-inf",
        action="store_true",
        help="Also treat 'inf' tokens as fatal (in addition to 'nan').",
    )
    p.add_argument(
        "--pid",
        type=int,
        default=0,
        help="If set, send a signal to this PID on detection (TERM by default).",
    )
    p.add_argument(
        "--signal",
        choices=["TERM", "KILL", "INT", "HUP"],
        default="TERM",
        help="Signal to send when using --pid.",
    )
    p.add_argument(
        "--grace",
        type=int,
        default=15,
        help="Seconds to wait before escalating to SIGKILL if --pid is used.",
    )
    p.add_argument(
        "--kill-command",
        default="",
        help="Arbitrary shell command to run on detection (e.g., 'qdel $PBS_JOBID').",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Detect and report but do not kill or run commands.",
    )
    p.add_argument(
        "--verbose",
        action="store_true",
        help="Print verbose progress messages.",
    )
    return p.parse_args()


def main() -> int:
    args = parse_args()
    specs = split_outputs(args.outputs)

    if not specs:
        logger.error("[ERROR] No valid --outputs provided.")
        return 3

    logger.info(f"Monitoring for NaN{'/Inf' if args.include_inf else ''} in: {', '.join(specs)}")

    offsets: dict[str, int] = {}
    first_seen = time.time()

    while True:
        # Timeout condition (optional)
        if args.timeout and (time.time() - first_seen) >= args.timeout:
            logger.info(f"Timeout reached ({args.timeout}s). No issues detected. Exiting.")
            return 0

        # Discover files and initialize offsets for new files
        current = list_files(specs, args.recursive)
        for path, size in current.items():
            if path not in offsets:
                offsets[path] = 0  # start reading from beginning for new files

        # Remove offsets for files that disappeared
        for tracked in list(offsets.keys()):
            if tracked not in current:
                del offsets[tracked]

        # Scan new bytes for each file
        for path in sorted(current.keys()):
            start = offsets.get(path, 0)
            end, chunk = scan_new_bytes(path, start)
            offsets[path] = end
            if not chunk:
                continue

            if contains_bad_tokens(chunk, include_inf=args.include_inf):
                logger.info(f"Detected NaN{'/Inf' if args.include_inf else ''} in {path}.")
                try_kill(args)
                return 2

        vprint(args.verbose, f"Scanned {len(current)} files. Sleeping {args.check}s…")
        time.sleep(args.check)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        logger.info("Interrupted by user.")
        sys.exit(130)
