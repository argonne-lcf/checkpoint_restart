#!/bin/bash -x
#PBS -A datascience
#PBS -k doe
#PBS -l select=1024:ncpus=208
#PBS -q prod
#PBS -l walltime=00:15:00
#PBS -l filesystems=flare
#PBS -j oe
#PBS -o /dev/null



cd $PBS_O_WORKDIR
echo Jobid: $PBS_JOBID
echo Running on nodes `cat $PBS_NODEFILE`
NNODES=`wc -l < $PBS_NODEFILE`
RANKS_PER_NODE=12          # Number of MPI ranks per node
NRANKS=$(( NNODES * RANKS_PER_NODE ))
echo "NUM_OF_NODES=${NNODES}  TOTAL_NUM_RANKS=${NRANKS}  RANKS_PER_NODE=${RANKS_PER_NODE}"
CPU_BINDING1=list:4:9:14:19:20:25:56:61:66:71:74:79

date
mpiexec -np ${NRANKS} -ppn ${RANKS_PER_NODE} --cpu-bind ${CPU_BINDING1}  --no-vni -genvall bash -c 'echo "hello world" & hostname' > outfile.$PBS_JOBID
sort outfile.$PBS_JOBID | uniq

date
