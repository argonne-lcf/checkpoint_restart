#!/bin/bash
#PBS -l walltime=0:20:00
#PBS -q lustre_scaling
#PBS -N test_multi_mpiexec
#PBS -l select=4
#PBS -A Aurora_deployment

MAX_TRIALS=10

IFS='.' read -ra ADDR <<< "$PBS_JOBID"
export JOBID=$ADDR

module load frameworks
cd ${PBS_O_WORKDIR}

cat $PBS_NODEFILE | uniq > nodefile_all

export PATH=/flare/Aurora_deployment/AuroraGPT/soft/checkpoint_restart/:$PATH

export JOBSIZE=2
export local_rank=/flare/Aurora_deployment/AuroraGPT/soft/checkpoint_restart/local_rank.sh

rm -f check_hang.r$JOBID

echo "Started running job at `date`"

# select a subset of nodes to run the job
get_healthy_nodes.sh $PBS_NODEFILE $JOBSIZE pbs_nodefile$RUN
export PBS_NODEFILE=pbs_nodefile$RUN

# constantly check the job and kill the job if it hangs for 300 seconds
check_hang.py --timeout 300 --output $PBS_JOBNAME.o$JOBID:$PBS_JOBNAME.e$JOBID:output.log >> check_hang.r$JOBID &

# run the job
mpiexec -np $((JOBSIZE*12)) --ppn 12 ${local_rank} python ./test_pyjob.py --compute 10 --niters 100 --output output.log 

EXIT_CODE=$?
# Check the job status, if fail, resubmit
if [ $EXIT_CODE -ne 0 ]; then
    echo "Job exited with $EXIT_CODE error code, will rerun"
    qsub $0
else
    echo "Job run successfully"
    break
fi

# clear up the nodes for rerun the job
pkill check_hang.py
PBS_NODEFILE=nodefile_all flush.sh
sleep 5
qsub $0
