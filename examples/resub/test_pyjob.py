#!/usr/bin/env python
import time
import argparse
import datetime
import sys
parser = argparse.ArgumentParser()
parser.add_argument("--compute", default=10, type=int)
parser.add_argument("--exit", default=0, type=int)
parser.add_argument("--niters", default=100, type=int)
parser.add_argument("--checkpoint", default="latest", type=str)
parser.add_argument("--hang", default=None, type=int)
parser.add_argument("--fail", default=None, type=int)
parser.add_argument("--save-interval", default=1, type=int)
parser.add_argument("--output", default="output.log", type=str)
args = parser.parse_args()
import os
rank = int(os.getenv("RANK", "0"))
import threading

def f(tt):
    if rank==0:
        print(f"WARNING: Job will run {tt} seconds and fail")
    time.sleep(tt)
    os._exit(1)

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
        with open(args.checkpoint, "w") as fc:
            fc.write(f"{i}\n")
    if rank==0:
        print(f"{i} iteration ...")
        fout.write(f"{i} iteration ...\n")
fout.close()    
if rank==0:
    print(f"Job finished at {datetime.datetime.now()}")
exit(0)
if args.fail is not None:
    t1.join()
    
