// // cd $PBS_O_WORKDIR
// echo Jobid: $PBS_JOBID
// echo Running on nodes `cat $PBS_NODEFILE`
// NNODES=`wc -l < $PBS_NODEFILE`
// RANKS_PER_NODE=12          # Number of MPI ranks per node
// NRANKS=$(( NNODES * RANKS_PER_NODE ))
// echo "NUM_OF_NODES=${NNODES}  TOTAL_NUM_RANKS=${NRANKS}  RANKS_PER_NODE=${RANKS_PER_NODE}"
// CPU_BINDING1=list:4:9:14:19:20:25:56:61:66:71:74:79
// mpiexec -np ${NRANKS} -ppn ${RANKS_PER_NODE} --cpu-bind ${CPU_BINDING1}  --no-vni -genvall ./in-bi-bw injection --size 1m --iters 50
// mpiexec -np ${NRANKS} -ppn ${RANKS_PER_NODE} --cpu-bind ${CPU_BINDING1}  --no-vni -genvall ./in-bi-bw bisection --size 512k --iters 200
// mpiexec -np ${NRANKS} -ppn ${RANKS_PER_NODE} --cpu-bind ${CPU_BINDING1}  --no-vni -genvall ./in-bi-bw injection --size 2g --iters 10
// mpiexec -np ${NRANKS} -ppn ${RANKS_PER_NODE} --cpu-bind ${CPU_BINDING1}  --no-vni -genvall ./in-bi-bw-2 injection --size 10g --iters 200 
