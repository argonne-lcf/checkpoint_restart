"""
check_mate/test.py

Synthetic workload used by the packaged submission templates.
"""
from __future__ import annotations
import argparse
import datetime as _dt
import os
from pathlib import Path
import threading
import time
from typing import Sequence


__all__ = ["main", "build_parser"]

try:
    import ezpz  # type:ignore
    logger = ezpz.get_logger(__name__)
except Exception:
    import logging
    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s][%(levelname)s][%(name)s] - %(message)s',
    )
    logger = logging.getLogger(__name__)
    logger.setLevel("INFO")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Simulate long-running jobs with hangs, NaNs, and failures.",
    )
    parser.add_argument("--compute", default=10, type=int, help="Seconds per iteration")
    parser.add_argument("--niters", default=100, type=int, help="Total number of iterations")
    parser.add_argument("--checkpoint", default="latest", help="Checkpoint file path")
    parser.add_argument("--hang", default=None, type=int, help="Optional hang duration in seconds")
    parser.add_argument("--fail", default=None, type=int, help="Seconds before forced failure")
    parser.add_argument("--exit-code", default=1, type=int, help="Exit code to use on failure")
    parser.add_argument(
        "--nan-after",
        default=None,
        type=int,
        help="Iteration offset after which NaN/Inf values are emitted",
    )
    parser.add_argument(
        "--save-interval",
        default=1,
        type=int,
        help="Iterations between checkpoint writes",
    )
    parser.add_argument(
        "--output", required=False, default="output.log", help="Destination log file"
    )
    parser.add_argument(
        "--checkpoint_time", default=0, type=int, help="Seconds spent writing each checkpoint"
    )
    return parser


def _spawn_fail_thread(delay: int, exit_code: int, rank: int) -> threading.Thread:
    def trigger_failure() -> None:
        if rank == 0:
            logger.warning(f"WARNING: Job will run {delay} seconds and fail")
        time.sleep(delay)
        os._exit(exit_code)

    thread = threading.Thread(target=trigger_failure, name="failure-timer", daemon=True)
    thread.start()
    return thread


def _read_checkpoint(path: Path, rank: int) -> int:
    if path.is_file():
        checkpoint = int(path.read_text().splitlines()[0])
        if rank == 0:
            logger.info(f"Reading checkpoint from {checkpoint}")
        return checkpoint

    if rank == 0:
        logger.info("Starting job from scratch")
    return 0


def _write_checkpoint(path: Path, iteration: int) -> None:
    with path.open("w", encoding="utf-8") as f:
        f.write(f"{iteration}\n")


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)

    rank = int(os.getenv("RANK", "0"))

    failure_thread: threading.Thread | None = None
    if args.fail and args.fail > 0:
        failure_thread = _spawn_fail_thread(args.fail, args.exit_code, rank)

    if rank == 0:
        logger.info(f"Job started at {_dt.datetime.now()}")

    checkpoint_path = Path(args.checkpoint)
    checkpoint = _read_checkpoint(checkpoint_path, rank)

    if args.hang and args.hang > 0:
        if rank == 0:
            logger.warning(f"WARNING: job will hang for {args.hang} seconds")
        time.sleep(args.hang)

    import random

    # with open(args.output, "w", encoding="utf-8") as fout:
    metrics = {}
    t0 = 0.0
    t1 = 0.0
    tc0 = 0.0
    tc1 = 0.0
    for iteration in range(checkpoint, args.niters):
        t0 = time.perf_counter()
        time.sleep(args.compute)
        if args.nan_after is not None and (iteration - checkpoint) >= args.nan_after:
            rando = float("nan")
        else:
            rando = random.random()
        t1 = time.perf_counter()
        metrics |= {
            "iter": iteration,
            "y": rando,
            "dtf": t1 - t0,
            "dtc": (
                (tc1 - tc0) if (iteration - checkpoint + 1) % args.save_interval == 0 else 0.0
            ),
        }
        mstr = " ".join(f"{k}={v}" for k, v in metrics.items())
        # mstr = " ".join(f"{k}={v}" for k, v in {
        #     "iter": iteration,
        #     "y": rando,
        #     "dtf": t1 - t0,
        #     "dtc": (
        #         (tc1 - tc0) if (iteration - checkpoint + 1) % args.save_interval == 0 else 0.0
        #     ),
        # })
        tc0 = time.perf_counter()
        if rank == 0:
            if (iteration - checkpoint + 1) % args.save_interval == 0:
                time.sleep(args.checkpoint_time)
                _write_checkpoint(checkpoint_path, iteration)
            logger.info(f"{mstr}")
            with Path(args.output).open("a", encoding="utf-8") as fout:
                fout.write(mstr)
                fout.flush()
        tc1 = time.perf_counter()

    if rank == 0:
        logger.info(f"Job finished at {_dt.datetime.now()}")

    if failure_thread is not None:
        failure_thread.join()
        return args.exit_code

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
