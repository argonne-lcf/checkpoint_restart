#!/usr/bin/env python
"""
This script simulates a job with various behaviors for testing purposes.
It supports options to simulate hanging, failing, generating NaN/Inf values,
and checkpointing.

Arguments:
    --compute: Time period for each iteration (default: 10 seconds)
    --niters: Number of iterations (default: 100)
    --checkpoint: Checkpoint file to save progress (default: "latest")
    --hang: Time in seconds to hang the job (default: None)
    --fail: Time in seconds after which the job should fail (default: None)
    --exit-code: Exit code to use when failing (default: 1)
    --nan-after: Number of iterations after which to generate NaN/Inf (default: None)
    --save-interval: Interval for saving checkpoints (default: 1)
    --output: Output file to write results (default: "output.log")
    --checkpoint_time: Time period for checkpointing (default: 0 seconds)

Environment Variables:
    RANK: Rank of the process (default: 0)

Usage:
    python test_pyjob.py --compute 5 --niters 50 --fail 30 --exit-code 2
"""

import time
import argparse
import datetime
import sys
parser = argparse.ArgumentParser()
parser.add_argument("--compute", default=10, type=int, help="time period for each iteration")
parser.add_argument("--niters", default=100, type=int, help="number of iterations")
parser.add_argument("--checkpoint", default="latest", type=str, help="checkpoint file")
parser.add_argument("--hang", default=None, type=int, help="hang time in seconds")
parser.add_argument("--fail", default=None, type=int, help="after how many seconds to fail")
parser.add_argument("--exit-code", default=1, type=int, help="exit code when fail")
parser.add_argument("--nan-after", default=None, type=int, help="after how many iterations to generate nan/inf")
parser.add_argument("--save-interval", default=1, type=int, help="checkpoint saving interval")
parser.add_argument("--output", default="output.log", type=str, help="output file")
parser.add_argument("--checkpoint_time", default=0, type=int, help="time period for checkpointing")
args = parser.parse_args()
import os
rank = int(os.getenv("RANK", "0"))
import threading

def f(tt):
    if rank==0:
        print(f"WARNING: Job will run {tt} seconds and fail")
    time.sleep(tt)
    os._exit(args.exit_code)

t1 = None
if args.fail is not None:
    t1 = threading.Thread(target=f, args=(args.fail,))    
    t1.start()


if rank==0:
    print(f"Job started at {datetime.datetime.now()}")

if os.path.isfile(args.checkpoint):
    checkpoint = int(open(args.checkpoint).readline())
    if rank==0:
        print(f"Reading checkpoint from {checkpoint}")
else:
    checkpoint=0
    if rank==0:
        print("Starting job from scratch")

if (args.hang is not None) and args.hang > 0:
    if rank==0:
        print(f"WARNING: job will hang for {args.hang} seconds")
    time.sleep(args.hang)
fout = open(args.output, "w")    
for i in range(checkpoint, args.niters):
    time.sleep(args.compute)
    if (i-checkpoint+1)%args.save_interval==0:
        time.sleep(args.checkpoint_time)
        with open(args.checkpoint, "w") as fc:
            fc.write(f"{i}\n")
    if rank==0:
        print(f"{i} iteration ...")
        if args.nan_after is not None and (i - checkpoint) >= args.nan_after:
            fout.write(f"{i} iteration ..., result: NaN\n")
            fout.flush()
        else:
            fout.write(f"{i} iteration ..., result: ...\n")
            # Flush every iteration. check_hang.py decides whether the job is
            # alive from this file's mtime, and a buffered write leaves the
            # mtime unchanged, so an otherwise healthy job is killed as hung.
            fout.flush()
fout.close()    
if rank==0:
    print(f"Job finished at {datetime.datetime.now()}")
if args.fail is not None:
    t1.join()
    sys.exit(args.exit_code)
