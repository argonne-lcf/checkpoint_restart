# Workflow recipes

This guide demonstrates how to stitch the CLI tools together inside batch
scripts and ad-hoc recovery loops.

## PBS/PMI style launcher with monitors

The following shell fragment shows how you might wire `check-mate-hang` and
`check-mate-nan` around an MPI job while letting the `check-mate` dispatcher seed
rank metadata. The monitors run in the background and exit automatically once a
problem is detected.

```bash
#!/bin/bash
set -euo pipefail

# Pretend we are inside an allocation that exported PMI metadata
export PBS_NODEFILE=$PWD/nodes.txt
export PALS_LOCAL_SIZE=${PALS_LOCAL_SIZE:-2}
export PALS_LOCAL_RANKID=${PALS_LOCAL_RANKID:-0}
export PALS_RANKID=${PALS_RANKID:-0}

# Launch monitors in dry-run mode for local testing
check-mate-hang --outputs demo.chkpt --timeout 10 --check 2 --dry-run &
HANG_PID=$!
check-mate-nan --outputs output.log --timeout 15 --dry-run &
NAN_PID=$!

# Your application (replace with mpiexec, srun, etc.)
check-mate launcher -- python test_pyjob.py \
  --niters 5 \
  --compute 1 \
  --checkpoint demo.chkpt \
  --save-interval 1 \
  --nan-after 0 \
  --output output.log || true

# Allow monitors to wrap up gracefully
wait $HANG_PID $NAN_PID
```

You can try this recipe locally by first creating a mock nodefile:

```bash
printf '127.0.0.1\n127.0.0.1\n' > nodes.txt
```

During a dry run you will see the same monitor output as in the
[getting started guide](getting-started.md) when the detector scripts notice a
stalled checkpoint or a `nan` token.

## Regenerating a healthy nodefile mid-run

When a job is resubmitted after a failure, reuse the saved allocation to prune
bad nodes before relaunching the application:

```bash
check-mate get-healthy-nodes $PBS_NODEFILE 4 healthy_nodes.txt
mpiexec -n 4 -machinefile healthy_nodes.txt ./restart_app.sh
```

The command prints the number of responsive hosts it found and writes the list
into `healthy_nodes.txt`, matching the behaviour shown in the
[CLI reference](cli.md).

## Planning checkpoint cadence

Combine the modelled cadence with the monitor configuration so the scheduler
makes sense of the overall runtime:

```python
>>> from check_mate import optimal_checkpointing as oc
>>> cadence = oc.optimal_checkpoint_cadence(
...     node_count=2048,
...     node_memory=3.2e11,
...     chkpt_bandwidth="LUSTRE",
... )
>>> f"Checkpoint every {cadence * 60:.1f} minutes"
'Checkpoint every 208.5 minutes'
```

Feed the calculated cadence into your job script to pick the timeout value for
`check-mate-hang` and the polling interval for `check-mate-nan` so the monitors align with
realistic checkpoint intervals.
