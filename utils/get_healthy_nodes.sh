#!/bin/bash
# Usage: get_healthy_nodes.sh NODEFILE NUM_NODES_TO_SELECT NEW_NODEFILE [EXCLUDE_FILE]
#
# Selects NUM_NODES_TO_SELECT healthy nodes from NODEFILE into NEW_NODEFILE.
# Nodes listed in the optional EXCLUDE_FILE are treated as unusable and are
# never selected (used to retire nodes that crashed a previous run).
#
# In addition to NEW_NODEFILE, three list files are written alongside it:
#   NEW_NODEFILE.healthy    - every node that passed the health check
#   NEW_NODEFILE.unhealthy  - every node that failed the check or was excluded
#   NEW_NODEFILE.free       - healthy nodes not selected for this run (spares)
#
# Invariant: healthy = selected + free
#
# HEALTH_LEVEL controls how much screening is done:
#
#   ping   (default)  reachability only; the historical behaviour, unchanged
#   mem               ping, then a memory/GPU probe on each reachable node
#
# The `mem` level exists because ping cannot see the failure that actually
# breaks a restart: a node that answers but has leaked host RAM or still has
# VRAM pinned by a previous job's zombie ranks. Such a node is selected, the
# job lands on it, and it OOMs. The probe is mem_and_gpu_row, which is serial,
# needs no GPU compiler, prints one CSV row per host, and takes ~0.05s.
#
# Tunables for HEALTH_LEVEL=mem (all optional):
#   HEALTH_MIN_MEM_AVAIL_MIB   minimum mem_available_mib      (default 65536)
#   HEALTH_MAX_GPU_USED_MIB    maximum gpu_sysman_used_mib    (default 4096)
#   HEALTH_MIN_GPU_DEVICES     minimum gpu_sysman_devices     (default 0)
#   HEALTH_PROBE_BIN           path to mem_and_gpu_row
#   HEALTH_PROBE_TIMEOUT       per-node probe timeout seconds (default 30)
#
# HEALTH_MIN_GPU_DEVICES defaults to 0 so the probe never fails a node merely
# for reporting no GPUs; set it to 6 on Aurora compute nodes to catch a node
# whose Level Zero stack has fallen over. A node that fails the probe is
# recorded as unhealthy with a reason in NEW_NODEFILE.probe.
#
# The probe is fail-open on infrastructure errors: if the binary is missing or
# unreadable the script warns and degrades to ping rather than draining the
# whole allocation. It is fail-closed on an actual threshold breach.

ALL_NODEFILE=$1
SELECT=$2
NEW_NODEFILE=$3
EXCLUDE_FILE=$4

if [[ -z "$ALL_NODEFILE" || -z "$SELECT" || -z "$NEW_NODEFILE" ]]; then
    echo "Usage: $0 NODEFILE NUM_NODES_TO_SELECT NEW_NODEFILE [EXCLUDE_FILE]"
    exit 2
fi

HEALTHY_NODEFILE=$NEW_NODEFILE.healthy
UNHEALTHY_NODEFILE=$NEW_NODEFILE.unhealthy
FREE_NODEFILE=$NEW_NODEFILE.free
PROBE_LOG=$NEW_NODEFILE.probe

HEALTH_LEVEL=${HEALTH_LEVEL:-ping}
HEALTH_MIN_MEM_AVAIL_MIB=${HEALTH_MIN_MEM_AVAIL_MIB:-65536}
HEALTH_MAX_GPU_USED_MIB=${HEALTH_MAX_GPU_USED_MIB:-4096}
HEALTH_MIN_GPU_DEVICES=${HEALTH_MIN_GPU_DEVICES:-0}
HEALTH_PROBE_TIMEOUT=${HEALTH_PROBE_TIMEOUT:-30}

mkdir -p /tmp/$USER/pbs/
export PBS_TMPDIR=$(mktemp -d /tmp/$USER/pbs/XXXXXX)

echo "Build a $SELECT nodes nodefile from $ALL_NODEFILE"
echo "Health level: $HEALTH_LEVEL"

n=0
for ip in `cat $ALL_NODEFILE | uniq`;
do
   (
      # A node retired by a previous trial is unusable regardless of ping
      if [[ -n "$EXCLUDE_FILE" && -f "$EXCLUDE_FILE" ]] && grep -qxF "$ip" "$EXCLUDE_FILE"; then
	  echo $ip > $PBS_TMPDIR/down.$n
	  exit 0
      fi

      ping $ip -c2 &> /dev/null ;

      if [ $? -eq 0 ];
      then
	  echo $ip > $PBS_TMPDIR/up.$n
      else
	  echo $ip > $PBS_TMPDIR/down.$n
      fi
   )&
   n=$((n+1))
done
wait

rm -f $NEW_NODEFILE $HEALTHY_NODEFILE $UNHEALTHY_NODEFILE $FREE_NODEFILE
touch $HEALTHY_NODEFILE $UNHEALTHY_NODEFILE $FREE_NODEFILE

# Collect in original nodefile order (numeric index, not glob order)
for i in `seq 0 $((n-1))`
do
    [ -f $PBS_TMPDIR/up.$i ]   && cat $PBS_TMPDIR/up.$i   >> $HEALTHY_NODEFILE
    [ -f $PBS_TMPDIR/down.$i ] && cat $PBS_TMPDIR/down.$i >> $UNHEALTHY_NODEFILE
done

NUM_PINGED=$(cat $HEALTHY_NODEFILE | wc -l)

# ---------------------------------------------------------------------------
# HEALTH_LEVEL=mem: probe the nodes that answered ping.
# ---------------------------------------------------------------------------
if [[ "$HEALTH_LEVEL" == "mem" ]]; then
    if [[ -z "$HEALTH_PROBE_BIN" ]]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        for cand in \
            "$SCRIPT_DIR/../build/health_checks/mem_and_gpu_row" \
            "$SCRIPT_DIR/../../build/health_checks/mem_and_gpu_row" \
            "$(command -v mem_and_gpu_row 2>/dev/null)"; do
            if [[ -n "$cand" && -x "$cand" ]]; then
                HEALTH_PROBE_BIN="$cand"
                break
            fi
        done
    fi

    if [[ -z "$HEALTH_PROBE_BIN" || ! -x "$HEALTH_PROBE_BIN" ]]; then
        # Fail open: a missing probe must not drain the allocation.
        echo "WARNING: HEALTH_LEVEL=mem but mem_and_gpu_row was not found; using ping only."
        echo "         Set HEALTH_PROBE_BIN to the built binary to enable the probe."
    else
        echo "Probing $NUM_PINGED reachable nodes with $HEALTH_PROBE_BIN"
        echo "Thresholds: mem_available >= ${HEALTH_MIN_MEM_AVAIL_MIB} MiB, gpu_used <= ${HEALTH_MAX_GPU_USED_MIB} MiB, gpu_devices >= ${HEALTH_MIN_GPU_DEVICES}"
        : > $PROBE_LOG

        p=0
        while read -r ip; do
            (
                row=$(timeout "$HEALTH_PROBE_TIMEOUT" ssh -n \
                        -o BatchMode=yes -o StrictHostKeyChecking=no \
                        -o ConnectTimeout=10 \
                        "$ip" "$HEALTH_PROBE_BIN --csv" 2>/dev/null \
                        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' | tail -1)

                if [[ -z "$row" ]]; then
                    # Unreachable for exec, or the probe produced nothing. The
                    # node pinged but cannot run work, so treat it as unusable.
                    echo "$ip PROBE_FAIL no_output" > $PBS_TMPDIR/probe.$p
                    exit 0
                fi

                mem_avail=$(echo "$row" | cut -d, -f5)
                gpu_dev=$(echo "$row"  | cut -d, -f16)
                gpu_used=$(echo "$row" | cut -d, -f18)

                # Guard against a malformed row yielding empty comparisons.
                case "$mem_avail$gpu_dev$gpu_used" in
                    *[!0-9]*|"")
                        echo "$ip PROBE_FAIL malformed_row" > $PBS_TMPDIR/probe.$p
                        exit 0
                        ;;
                esac

                reason=""
                [[ "$mem_avail" -lt "$HEALTH_MIN_MEM_AVAIL_MIB" ]] && \
                    reason="mem_available=${mem_avail}<${HEALTH_MIN_MEM_AVAIL_MIB}"
                [[ "$gpu_used" -gt "$HEALTH_MAX_GPU_USED_MIB" ]] && \
                    reason="${reason:+$reason,}gpu_used=${gpu_used}>${HEALTH_MAX_GPU_USED_MIB}"
                [[ "$gpu_dev" -lt "$HEALTH_MIN_GPU_DEVICES" ]] && \
                    reason="${reason:+$reason,}gpu_devices=${gpu_dev}<${HEALTH_MIN_GPU_DEVICES}"

                if [[ -n "$reason" ]]; then
                    echo "$ip PROBE_FAIL $reason" > $PBS_TMPDIR/probe.$p
                else
                    echo "$ip PROBE_OK mem_available=${mem_avail} gpu_used=${gpu_used} gpu_devices=${gpu_dev}" \
                        > $PBS_TMPDIR/probe.$p
                fi
            )&
            p=$((p+1))
        done < $HEALTHY_NODEFILE
        wait

        # Rebuild the healthy list, preserving nodefile order.
        mv $HEALTHY_NODEFILE $PBS_TMPDIR/pinged
        touch $HEALTHY_NODEFILE
        for i in `seq 0 $((p-1))`
        do
            [ -f $PBS_TMPDIR/probe.$i ] || continue
            cat $PBS_TMPDIR/probe.$i >> $PROBE_LOG
            node=$(awk '{print $1}' $PBS_TMPDIR/probe.$i)
            if grep -q "PROBE_OK" $PBS_TMPDIR/probe.$i; then
                echo "$node" >> $HEALTHY_NODEFILE
            else
                echo "$node" >> $UNHEALTHY_NODEFILE
            fi
        done

        NUM_PROBE_FAIL=$(grep -c "PROBE_FAIL" $PROBE_LOG 2>/dev/null); NUM_PROBE_FAIL=${NUM_PROBE_FAIL:-0}
        echo "Nodes failing the memory/GPU probe: $NUM_PROBE_FAIL"
        [ "$NUM_PROBE_FAIL" -gt 0 ] && grep "PROBE_FAIL" $PROBE_LOG
        echo "Probe detail: $PROBE_LOG"
    fi
fi

NUM_HEALTHY=$(cat $HEALTHY_NODEFILE | wc -l)
NUM_UNHEALTHY=$(cat $UNHEALTHY_NODEFILE | wc -l)

echo "Total number of nodes checked: $n"
echo "Number of nodes that are healthy: $NUM_HEALTHY"
echo "Number of nodes that are unhealthy: $NUM_UNHEALTHY"

if [[ $NUM_HEALTHY -lt $SELECT ]]; then
    echo "The number of healthy nodes ($NUM_HEALTHY) is smaller than requested ($SELECT); existing..."
    rm -rf $PBS_TMPDIR
    exit 100
fi

# Select the first SELECT healthy nodes; the rest stay free as spares
head -n $SELECT           $HEALTHY_NODEFILE >  $NEW_NODEFILE
tail -n +$((SELECT+1))    $HEALTHY_NODEFILE >  $FREE_NODEFILE

echo "Number of nodes that are selected: $(cat $NEW_NODEFILE | uniq | wc -l)"
echo "Number of healthy nodes still free: $(cat $FREE_NODEFILE | uniq | wc -l)"
echo "Node lists: $HEALTHY_NODEFILE $UNHEALTHY_NODEFILE $FREE_NODEFILE"

rm -rf $PBS_TMPDIR
