#!/bin/bash
# node_memory_report.sh -- show the memory and GPU state of every node in an
# allocation. Read-only: nothing is selected, retired or written to a nodefile.
#
# Use before launching an application to see what you are actually running on,
# or afterwards to see what a job left behind.
#
#     ./utils/node_memory_report.sh                 # every node in $PBS_NODEFILE
#     ./utils/node_memory_report.sh mynodes.txt     # a specific list
#     FORMAT=csv ./utils/node_memory_report.sh      # machine-readable
#
# Environment:
#   HEALTH_PROBE_BIN   path to mem_and_gpu_row (default: repo build tree)
#   PROBE_TIMEOUT      per-node timeout in seconds (default 30)
#   FORMAT             table (default) or csv
#   WARN_MEM_MIB       highlight nodes below this available RAM (default 65536)
#   WARN_GPU_MIB       highlight nodes above this GPU memory in use (default 4096)
#
# Exit status is 0 whenever the report was produced, even if some nodes look
# bad: this is an observation tool and the caller decides what to do. A node
# that could not be probed is shown as UNREACHABLE rather than being silently
# dropped.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PROBE="${HEALTH_PROBE_BIN:-$REPO_DIR/build/health_checks/mem_and_gpu_row}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-30}"
FORMAT="${FORMAT:-table}"
WARN_MEM_MIB="${WARN_MEM_MIB:-65536}"
WARN_GPU_MIB="${WARN_GPU_MIB:-4096}"

NODEFILE="${1:-${PBS_NODEFILE:-}}"

if [ -z "$NODEFILE" ] || [ ! -f "$NODEFILE" ]; then
    echo "usage: $(basename "$0") [NODEFILE]" >&2
    echo "  no nodefile given and \$PBS_NODEFILE is unset or missing" >&2
    exit 2
fi

if [ ! -x "$PROBE" ]; then
    echo "error: probe binary not found or not executable:" >&2
    echo "  $PROBE" >&2
    echo "build it with:" >&2
    echo "  module load cmake" >&2
    echo "  cmake -S $REPO_DIR/utils/check_healthy_tests -B $REPO_DIR/build/health_checks" >&2
    echo "  cmake --build $REPO_DIR/build/health_checks -j 16" >&2
    echo "or set HEALTH_PROBE_BIN to an existing copy." >&2
    exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sort -u "$NODEFILE" > "$TMP/nodes"
NCOUNT=$(wc -l < "$TMP/nodes")

# Probe every node in parallel. Each writes one line to its own file so the
# results cannot interleave.
i=0
while read -r host; do
    (
        # Select the CSV data row by shape. The kernels print a trailing
        # KERNEL_TIME line, so `tail -1` would return the wrong line.
        row=$(timeout "$PROBE_TIMEOUT" ssh -n \
                -o BatchMode=yes -o StrictHostKeyChecking=no \
                -o ConnectTimeout=10 \
                "$host" "$PROBE --csv" 2>/dev/null \
              | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' | tail -1)

        if [ -z "$row" ]; then
            echo "$host UNREACHABLE" > "$TMP/r.$i"
            exit 0
        fi

        mem_total=$(echo "$row" | cut -d, -f3)
        mem_used=$(echo "$row"  | cut -d, -f4)
        mem_avail=$(echo "$row" | cut -d, -f5)
        gpu_dev=$(echo "$row"   | cut -d, -f16)
        gpu_total=$(echo "$row" | cut -d, -f17)
        gpu_used=$(echo "$row"  | cut -d, -f18)

        case "$mem_avail$gpu_used" in
            *[!0-9]*|"") echo "$host MALFORMED" > "$TMP/r.$i"; exit 0 ;;
        esac

        echo "$host OK $mem_total $mem_used $mem_avail $gpu_dev $gpu_total $gpu_used" \
            > "$TMP/r.$i"
    ) &
    i=$((i+1))
done < "$TMP/nodes"
wait

# ------------------------------------------------------------------ output
if [ "$FORMAT" = "csv" ]; then
    echo "host,status,mem_total_mib,mem_used_mib,mem_available_mib,gpu_devices,gpu_total_mib,gpu_used_mib"
    for f in "$TMP"/r.*; do
        [ -f "$f" ] || continue
        set -- $(cat "$f")
        if [ "$2" = "OK" ]; then
            echo "$1,OK,$3,$4,$5,$6,$7,$8"
        else
            echo "$1,$2,,,,,,"
        fi
    done
    exit 0
fi

echo "Node memory and GPU report"
echo "  nodefile : $NODEFILE ($NCOUNT nodes)"
echo "  probe    : $PROBE"
echo "  date     : $(date)"
echo
printf "%-28s %10s %10s %10s %6s %10s %10s\n" \
       "HOST" "RAM_TOT" "RAM_USED" "RAM_AVAIL" "GPUS" "VRAM_TOT" "VRAM_USED"
printf "%-28s %10s %10s %10s %6s %10s %10s\n" \
       "----------------------------" "----------" "----------" "----------" \
       "------" "----------" "----------"

nok=0; nbad=0; nlow=0
for f in "$TMP"/r.*; do
    [ -f "$f" ] || continue
    set -- $(cat "$f")
    host=$1; status=$2
    short=${host%%.*}
    if [ "$status" != "OK" ]; then
        printf "%-28s %10s\n" "$short" "$status"
        nbad=$((nbad+1))
        continue
    fi
    nok=$((nok+1))
    flag=""
    [ "$5" -lt "$WARN_MEM_MIB" ] && flag="  LOW_RAM"
    [ "$8" -gt "$WARN_GPU_MIB" ] && flag="$flag  VRAM_IN_USE"
    [ -n "$flag" ] && nlow=$((nlow+1))
    printf "%-28s %10s %10s %10s %6s %10s %10s%s\n" \
           "$short" "$3" "$4" "$5" "$6" "$7" "$8" "$flag"
done

echo
echo "All values in MiB. RAM_AVAIL is what a new allocation can actually use."
echo "  probed OK   : $nok"
echo "  not probed  : $nbad"
echo "  flagged     : $nlow  (RAM_AVAIL < $WARN_MEM_MIB or VRAM_USED > $WARN_GPU_MIB)"
echo
echo "This is a report only; no node was selected or excluded."
echo "To act on these numbers during node selection, use:"
echo "  HEALTH_LEVEL=mem get_healthy_nodes.sh <pool> <count> <out> [exclude]"
