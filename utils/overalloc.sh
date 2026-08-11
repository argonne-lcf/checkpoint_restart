#!/bin/bash
# Usage: overalloc.sh JOBSIZE RESERVE_PERCENT
#
# Prints the number of nodes to request from PBS so that JOBSIZE nodes can run
# while keeping RESERVE_PERCENT extra nodes as a spare pool for restarts.
#
#   total = JOBSIZE + ceil(JOBSIZE * RESERVE_PERCENT / 100)
#
# A non-zero RESERVE_PERCENT always yields at least one spare node.
#
# Example:
#   overalloc.sh 10 20   -> 12
#   #PBS -l select=$(overalloc.sh 10 20)

JOBSIZE=$1
PERCENT=$2

if [[ -z "$JOBSIZE" || -z "$PERCENT" ]]; then
    echo "Usage: $0 JOBSIZE RESERVE_PERCENT" >&2
    exit 2
fi

if ! [[ "$JOBSIZE" =~ ^[0-9]+$ ]] || [ "$JOBSIZE" -lt 1 ]; then
    echo "JOBSIZE must be a positive integer, got '$JOBSIZE'" >&2
    exit 2
fi

if ! [[ "$PERCENT" =~ ^[0-9]+$ ]]; then
    echo "RESERVE_PERCENT must be a non-negative integer, got '$PERCENT'" >&2
    exit 2
fi

# Integer ceiling division
SPARE=$(( (JOBSIZE * PERCENT + 99) / 100 ))

# Any non-zero reserve should give at least one spare node
if [ "$PERCENT" -gt 0 ] && [ "$SPARE" -lt 1 ]; then
    SPARE=1
fi

echo $((JOBSIZE + SPARE))
