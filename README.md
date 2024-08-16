# Checkpoint / Restart tests on Exascale computing systems

For questions, please contact: Huihuo Zheng <huihuo.zheng@anl.gov>

We have seen that exascale computing systems suffer a lot of unstability which leads to termination of jobs before finishing. Therefore, checkpoint / restart become important to run large scale simulations on ``unstable" system. 

In this github repo, we provide simple program to simulate all kinds of job running issues such as (1) hang; (2) fail in the middle of the run; (3) success. We provide example submission script that can deal with various kind of situations. 

## Simulation of job execution: hang, fail, success
- test_pyjob.py 
  A simple simulation program, which can control
  ```bash
  --hang N: to hang for N seconds
  --fail N: to fail the job after N seconds
  --compute T: compute time per iteration
  --niters NITERS: total number of iterations
  --checkpoint CHECKPOINT: path for checkpoint
  --checkpoint_time T: time for writing one checkpoint
  ```
## Useful scripts to compose the submission scripts that are able to handle various job execution statuses. 

- [get_healthy_nodes.sh](./get_healthy_nodes.sh) ```NODEFILE NUM_NODES_TO_SELECT NEW_NODEFILE```
  
  This script is to select a subset of healthy nodes from the entire allocation

- [check_hang.py](./check_hang.py) ```--timeout TIMEOUT --check CHECKING_PERIOD --command COMMAND --output F1:F2:F3```

  This is to constantly checking whether the job hangs or not by checking whether output files are updated or not. If it is not updated for TIMEOUT seconds. It will kill the job

- PBS_NODEFILE=NODEFILE [flush.sh](./flush.sh)

  This is to clean up the nodes (except the headnode, the first one on the list)


## Example submission scripts
- [qsub_multi_mpiexec.sc](./qsub_multi_mpiexec.sc)
  submission script doing continual trials of mpiexec until success or timeout

- [qsub_multi_qsub.sc](./qsub_multi_qsub.sc)
  resubmit the job once it fails
  
## Various simulation examples
- [fail/](./fail): job failed after 100 seconds, restart
- [hang/](./hang): job hang, kill and restart
- [success/](./success): job run seccessfully
- [resub/](./resub): job fails after 100 seconds, and restart
