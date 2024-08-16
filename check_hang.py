#!/usr/bin/env python3
import argparse
import time
parser = argparse.ArgumentParser()
import os
parser.add_argument("--timeout", default=300, type=int, help="Time limit after which the job will be killed")
parser.add_argument("--check", default=5, type=int, help="Checking intermitten time period")
parser.add_argument("--command", default="mpiexec", type=str, help="")
parser.add_argument("--output", default="a.out", type=str, help="The output files to check, separated by \":\"")
args = parser.parse_args()
from time import strftime, localtime
def get_date(etime):
    return strftime('%Y-%m-%d %H:%M:%S', localtime(etime))

try:
    ti_c = os.path.getctime(args.output)
except:
    ti_c = time.time()
import time
ct = time.time()
ti_c = time.time()
start_time = time.time()
print(f"[{get_date(time.time())}] Job started")
while (ct - ti_c < args.timeout):
    time.sleep(args.check)
    for f in args.output.split(":"):
        if os.path.isfile(f):
            ti_c_tmp = os.path.getmtime(f)
            if ti_c_tmp > ti_c:
                ti_c = ti_c_tmp
    print(f"\n[{get_date(time.time())}] Checking job running status")
    print(f"Most recent change to {args.output} is {get_date(ti_c)}")
    ct = time.time()
    print(f"Job has been running for {time.time() - start_time} seconds")
    print(f"{args.output} has not been updated for {ct-ti_c} seconds")
if (ct - ti_c >= args.timeout):
    print(f"[{get_date(time.time())}]Output has not been updated for {ct - ti_c} seconds. Killing the job now ...")
os.system(f"pkill -u $USER {args.command}")
print(f"[{get_date(time.time())}] Job killed after hanging for {args.timeout} seconds.")
