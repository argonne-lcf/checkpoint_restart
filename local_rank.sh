#!/bin/bash                                                                                                                                                
export LOCAL_RANK=$PMIX_LOCAL_RANK
export RANK=$PMIX_RANK
export PBS_JOBSIZE=$(cat $PBS_NODEFILE | uniq | wc -l)
export SIZE=$((PALS_LOCAL_SIZE*PBS_JOBSIZE))
export LOCAL_RANK=$PALS_LOCAL_RANKID
export RANK=$PALS_RANKID
export WORLD_SIZE=$SIZE
if [ -z "${RANK}" ]; then
    RANK=0
fi
if [ -z "${WORLD_SIZE}" ] || [ $WORLD_SIZE -eq 0 ] ; then
    WORLD_SIZE=1
fi
if [ -z "${LOCAL_RANK}" ]; then
    LOCAL_RANK=0
fi

IFS='.' read -ra ADDR <<< "`cat $PBS_NODEFILE | head -1`"
export MASTER_ADDR=$ADDR".hsn.cm.aurora.alcf.anl.gov"
export MASTER_PORT=1234
echo "I am $RANK of $WORLD_SIZE: $LOCAL_RANK on `hostname`"
$@
