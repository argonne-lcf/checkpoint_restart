#!/bin/bash
export UID=$(id -u $USER)
mkdir -p /tmp/$USER/pbs/
export PBS_JOBSIZE=$(cat $PBS_NODEFILE | uniq | wc -l)
cat $PBS_NODEFILE | uniq | tail -$((PBS_JOBSIZE-1)) > /tmp/$USER/pbs/pbs_nodefile_no_head
clush -f 512 --hostfile /tmp/$USER/pbs/pbs_nodefile_no_head pkill -U $UID
