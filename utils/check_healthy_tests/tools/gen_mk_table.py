#!/usr/bin/env python3
# gen_mk_table.py -- turn microkernel log output into a markdown table.
#
# Reads a log containing both single-tile and full-node runs of the same
# metric and emits a markdown table with a scaling column, so a node that is
# not scaling across its tiles is visible at a glance.
#
# For each metric name it collects every matching line in file order and takes
# the FIRST occurrence as the one-tile result and the LAST as the full-node
# result -- which requires that run.sh emit them in that order. A metric that
# appears fewer than two times is skipped silently.
#
# Values of 1000 or more are rescaled one unit upward (G -> T) for readability.
#
# USAGE   gen_mk_table.py <logfile> <micro|GEMM|FFT>
#           micro  flops, triad, PCIe, tile/GPU peer bandwidth
#           GEMM   the six GEMM precisions
#           FFT    1D and 2D C2C transforms
# OUTPUT  A markdown table on stdout: metric, one tile, full node, scaling.

import sys
import re

with open(sys.argv[1]) as f:
    data=f.readlines()

def str_unit(value, unit):
    if value >= 1000:
        return f"{value/1000:.0f} {unit.replace('G','T')}"
    else:
        return f"{value:.0f} {unit}"

def finds(target):
    for line in data:
        if line.startswith(target):
            *_, value, unit = line.split()
            yield (float(value), unit)

def yield_row(target):
    for target in target:
        try:
            tile, *_, node = list(finds(target))
        except ValueError:
            continue
        scaling = node[0] / tile[0]
        tile, node = [str_unit(v,u) for v,u in [tile,node]]
        yield(f"| {target} | {tile} | {node} | {scaling:.1f} |")


if sys.argv[2] == "micro":
    targets = ["Single Precision Peak Flops", "Double Precision Peak Flops",
               "Memory Bandwidth (triad)",
               "PCIe Unidirectional Bandwidth (H2D)", "PCIe Unidirectional Bandwidth (D2H)", 
               "PCIe Bidirectional Bandwidth",
               "Tile2Tile Unidirectional Bandwidth", "Tile2Tile Bidirectional Bandwidth",
               "GPU2GPU Unidirectional Bandwidth", "GPU2GPU Bidirectional Bandwidth"]

elif sys.argv[2] == "GEMM":
    targets = ["DGEMM","SGEMM","HGEMM","BF16GEMM","TF32GEMM","I8GEMM"]
elif sys.argv[2] == "FFT":
    targets = ["Single-precision FFT C2C 1D", "Single-precision FFT C2C 2D"]

print ("| | One Tile | Full Node | Scaling |")
print ("|---|-----------:|-----------:|----:|")
for row in yield_row(targets):
    print (row)


