#!/bin/bash
# Print a node-usage summary for a checkpoint/restart run.
#
# Usage: node_usage_summary.sh [RUNDIR] [simple|full]
#        node_usage_summary.sh --full [RUNDIR]
#
#   simple (default)  Fixed-size report. Output does not grow with node count,
#                     so it stays readable for a 1000 node job. Per-node
#                     detail is aggregated; only crashed nodes are named, and
#                     that list is capped.
#   full              Every node and every trial listed individually.
#
# Reads node_usage.tsv, the ledger the submission script appends to:
#   trial <TAB> node <TAB> START|COMPLETED|STOPPED|CRASHED <TAB> timestamp <TAB> epoch

MODE=simple
ARGS=()
for a in "$@"; do
    case "$a" in
        --full|full)     MODE=full ;;
        --simple|simple) MODE=simple ;;
        *)               ARGS+=("$a") ;;
    esac
done
RUNDIR=${ARGS[0]:-$PWD}

# How many crashed nodes to name in simple mode before truncating.
MAX_LIST=${NODE_SUMMARY_MAX_LIST:-10}

cd "$RUNDIR" 2>/dev/null || { echo "no such directory: $RUNDIR" >&2; exit 1; }

if [ ! -s node_usage.tsv ]; then
    echo "no node_usage.tsv in $RUNDIR -- nothing to summarise" >&2
    exit 1
fi

fmt_dur() {   # seconds -> Hh MMm SSs, omitting empty leading units
    local s=${1:-0}
    if   [ "$s" -ge 3600 ]; then printf '%dh %02dm %02ds' $((s/3600)) $((s%3600/60)) $((s%60))
    elif [ "$s" -ge 60 ];   then printf '%dm %02ds' $((s/60)) $((s%60))
    else printf '%ds' "$s"; fi
}

# Print at most MAX_LIST names, then a count of the remainder.
print_capped() {
    local n=0 total
    total=$(grep -c . <<< "$1")
    [ -z "$1" ] && return
    while read -r name; do
        [ -z "$name" ] && continue
        n=$((n+1))
        if [ "$n" -gt "$MAX_LIST" ]; then
            echo "    ... and $((total - MAX_LIST)) more (use 'full' to list all)"
            return
        fi
        echo "    $name"
    done <<< "$1"
}

TOTAL_ALLOC=$(wc -l < nodefile_all 2>/dev/null || echo 0)
TRIAL_IDS=$(awk -F'\t' '$3=="START"{print $1}' node_usage.tsv | sort -un)
TRIALS=$(grep -c . <<< "$TRIAL_IDS")

RUN_START=$(head -1 node_usage.tsv | cut -f4)
RUN_START_E=$(head -1 node_usage.tsv | cut -f5)
RUN_END=$(tail -1 node_usage.tsv | cut -f4)
RUN_END_E=$(tail -1 node_usage.tsv | cut -f5)

USED=$(awk -F'\t' '$3=="START"{print $2}' node_usage.tsv | sort -u)
NUSED=$(grep -c . <<< "$USED")
CRASHED=$(awk -F'\t' '$3=="CRASHED"{print $2}' node_usage.tsv | sort -u)
NCRASH=$(grep -c . <<< "$CRASHED")
[ -z "$CRASHED" ] && NCRASH=0

FIRST_TRIAL=$(head -1 <<< "$TRIAL_IDS")
N_FIRST=$(awk -F'\t' -v t="$FIRST_TRIAL" '$1==t && $3=="START"' node_usage.tsv | wc -l)
SPARES_SPENT=$((NUSED - N_FIRST))

# Total node-seconds across all trials, and the per-node aggregate table.
NODE_TOTALS=$(awk -F'\t' '
    $3=="START" { start[$1 SUBSEP $2]=$5; trials[$2]++; next }
                { k=$1 SUBSEP $2
                  if (k in start) { total[$2] += $5 - start[k]; delete start[k] }
                  if ($3=="CRASHED") outcome[$2]="CRASHED"
                  else if (outcome[$2]!="CRASHED") outcome[$2]=$3 }
    END { for (n in trials) printf "%s\t%d\t%d\t%s\n", n, trials[n], total[n], outcome[n] }
' node_usage.tsv | sort)

NODE_SECONDS=$(awk -F'\t' '{s+=$3} END {print s+0}' <<< "$NODE_TOTALS")

echo "=========================================================="
echo " NODE USAGE SUMMARY ($MODE)"
echo "=========================================================="
echo "Run directory : $RUNDIR"
echo "Window        : $RUN_START -> $RUN_END  ($(fmt_dur $((RUN_END_E - RUN_START_E))))"
echo "Allocated     : $TOTAL_ALLOC nodes"
echo "Trials run    : $TRIALS"
echo "Nodes used    : $NUSED of $TOTAL_ALLOC"
echo "Node-time     : $(fmt_dur $NODE_SECONDS) total across all nodes and trials"
echo

if [ "$MODE" == "full" ]; then
    echo "--- Per trial ---"
    for T in $TRIAL_IDS; do
        T_START=$(awk -F'\t' -v t="$T" '$1==t && $3=="START"{print $4; exit}' node_usage.tsv)
        T_START_E=$(awk -F'\t' -v t="$T" '$1==t && $3=="START"{print $5; exit}' node_usage.tsv)
        T_END=$(awk -F'\t' -v t="$T" '$1==t && $3!="START"{print $4; exit}' node_usage.tsv)
        T_END_E=$(awk -F'\t' -v t="$T" '$1==t && $3!="START"{print $5; exit}' node_usage.tsv)
        NNODES=$(awk -F'\t' -v t="$T" '$1==t && $3=="START"' node_usage.tsv | wc -l)
        if [ -n "$T_END_E" ]; then DUR=$(fmt_dur $((T_END_E - T_START_E)))
        else DUR="(did not finish)"; T_END="-"; fi
        echo "Trial $T: $NNODES nodes   $T_START -> ${T_END}   held $DUR"
        awk -F'\t' -v t="$T" '$1==t && $3=="START"{printf "    %s  %s\n", $4, $2}' node_usage.tsv
        awk -F'\t' -v t="$T" '$1==t && $3=="CRASHED"{printf "    %s  %s  <-- CRASHED\n", $4, $2}' node_usage.tsv
        echo
    done

    echo "--- Per node (total time in service) ---"
    printf "%-46s %7s %9s  %s\n" "NODE" "TRIALS" "HELD" "OUTCOME"
    while IFS=$'\t' read -r NODE NT SECS OUT; do
        [ -z "$NODE" ] && continue
        printf "%-46s %7s %9s  %s\n" "$NODE" "$NT" "$(fmt_dur ${SECS:-0})" "${OUT:-UNKNOWN}"
    done <<< "$NODE_TOTALS"
    echo
else
    # Simple mode: one line per trial, and counts instead of node lists.
    echo "--- Per trial ---"
    printf "%-7s %7s  %-19s %-19s %s\n" "TRIAL" "NODES" "START" "END" "HELD"
    for T in $TRIAL_IDS; do
        T_START=$(awk -F'\t' -v t="$T" '$1==t && $3=="START"{print $4; exit}' node_usage.tsv)
        T_START_E=$(awk -F'\t' -v t="$T" '$1==t && $3=="START"{print $5; exit}' node_usage.tsv)
        T_END=$(awk -F'\t' -v t="$T" '$1==t && $3!="START"{print $4; exit}' node_usage.tsv)
        T_END_E=$(awk -F'\t' -v t="$T" '$1==t && $3!="START"{print $5; exit}' node_usage.tsv)
        NNODES=$(awk -F'\t' -v t="$T" '$1==t && $3=="START"' node_usage.tsv | wc -l)
        NCR=$(awk -F'\t' -v t="$T" '$1==t && $3=="CRASHED"' node_usage.tsv | wc -l)
        if [ -n "$T_END_E" ]; then DUR=$(fmt_dur $((T_END_E - T_START_E)))
        else DUR="(running)"; T_END="-"; fi
        NOTE=""
        [ "$NCR" -gt 0 ] && NOTE="  ($NCR crashed)"
        printf "%-7s %7s  %-19s %-19s %s%s\n" "$T" "$NNODES" "$T_START" "$T_END" "$DUR" "$NOTE"
    done
    echo

    # Outcome histogram rather than one row per node.
    echo "--- Node outcomes ---"
    awk -F'\t' '{c[$4]++} END {for (o in c) printf "    %-12s %d\n", o, c[o]}' <<< "$NODE_TOTALS" | sort -k2 -rn
    echo
fi

echo "--- Spare capacity ---"
echo "Nodes that ran work : $NUSED of $TOTAL_ALLOC allocated"
NEVER=""
if [ -s nodefile_all ]; then
    NEVER=$(grep -vxF -f <(echo "$USED") nodefile_all 2>/dev/null)
fi
NNEVER=$(grep -c . <<< "$NEVER")
[ -z "$NEVER" ] && NNEVER=0
echo "Nodes lost to crash : $NCRASH"
[ "$SPARES_SPENT" -gt 0 ] && \
    echo "Spares drawn in     : $SPARES_SPENT (beyond the $N_FIRST that started trial $FIRST_TRIAL)"
echo "Unspent reserve     : $NNEVER"

if [ "$NCRASH" -gt 0 ]; then
    echo "Crashed nodes:"
    if [ "$MODE" == "full" ]; then echo "$CRASHED" | sed 's/^/    /'
    else print_capped "$CRASHED"; fi
fi
if [ "$NNEVER" -gt 0 ] && [ "$MODE" == "full" ]; then
    echo "Never used (unspent reserve):"
    echo "$NEVER" | sed 's/^/    /'
fi
echo "=========================================================="
[ "$MODE" == "simple" ] && echo "(node_usage_summary.sh $RUNDIR full  for the per-node breakdown)"
