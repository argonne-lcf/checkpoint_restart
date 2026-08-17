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

mkdir -p /tmp/$USER/pbs/
export PBS_TMPDIR=$(mktemp -d /tmp/$USER/pbs/XXXXXX)

echo "Build a $SELECT nodes nodefile from $ALL_NODEFILE"

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