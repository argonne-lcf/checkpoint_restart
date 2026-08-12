# Shell script logic reference

This document summarizes the orchestration logic used by the shell utilities that ship with the
checkpoint/restart examples.  Each section provides a narrative description and a Mermaid sequence
diagram so that the interactions between commands, files, and cluster services can be understood at a
glance.

## `get_healthy_nodes.sh`

`get_healthy_nodes.sh NODEFILE SELECT_COUNT OUTPUT_FILE` (in `utils/`) inspects the allocation that PBS provides and
builds a node file containing only the first `SELECT_COUNT` responsive hosts.  The script launches
parallel `ping` checks, records healthy nodes, and concatenates the requested number of results.

### Flow of control

```mermaid
sequenceDiagram
    participant User as Caller
    participant Script as get_healthy_nodes.sh
    participant PBS as PBS_TMPDIR
    participant Node as Candidate node
    participant Output as OUTPUT_FILE

    Caller->>Script: Provide node list, select count, output path
    Script->>PBS: Create per-node temp files
    loop For each unique host in NODEFILE
        Script->>Node: ping -c2 (background)
        alt ping succeeds
            Node-->>Script: 0 exit status
            Script->>PBS: write host to node<n>.dat
        else ping fails
            Node-->>Script: non-zero exit
            Script->>PBS: create empty node<n>.dat
        end
    end
    Script->>Script: wait for background pings
    Script->>Output: Concatenate first SELECT_COUNT node<n>.dat files
    Script->>Caller: Report selected host count
    Script->>PBS: Remove temporary directory
```

## `flush.sh`

`flush.sh` (in `utils/`) cleans residual user processes across the nodes of a job.  The first node in
`$PBS_NODEFILE` is considered the head node and is skipped; all other unique nodes receive a `pkill`
call that targets the current user ID.

### Flow of control

```mermaid
sequenceDiagram
    participant Caller
    participant Script as flush.sh
    participant PBS
    participant clush
    participant Nodes as Compute nodes

    Caller->>Script: Invoke with PBS_NODEFILE in environment
    Script->>Script: Resolve UID
    Script->>PBS: Collect unique hosts, drop head node
    Script->>clush: Run pkill -U UID across hostfile
    clush->>Nodes: Issue pkill for user
```

## `launcher.sh`

`launcher.sh` (in `utils/`) is a thin MPI rank shim. It reads the per-rank environment that PALS/PMIx
exports on Aurora — falling back to PMIx values first, then overriding with PALS values — and exports
`RANK`, `LOCAL_RANK`, and `WORLD_SIZE` for the application. `WORLD_SIZE` is computed as
`PALS_LOCAL_SIZE * PBS_JOBSIZE` (unique nodes in `$PBS_NODEFILE`). If any of these variables are unset,
it falls back to `RANK=0`, `LOCAL_RANK=0`, `WORLD_SIZE=1`. It then execs the command passed on its
command line (`$@`). It does **not** set `MASTER_ADDR`/`MASTER_PORT`.

### Flow of control

```mermaid
sequenceDiagram
    participant Launcher as mpiexec
    participant Script as launcher.sh
    participant Env as Environment
    participant App as Target command

    Launcher->>Script: Provide PMIx/PALS environment and the command to run
    Script->>Env: Read PMIX_* then PALS_* rank variables
    Script->>Env: Export RANK, LOCAL_RANK, WORLD_SIZE (PALS_LOCAL_SIZE * PBS_JOBSIZE)
    Script->>Env: Fall back to RANK=0, LOCAL_RANK=0, WORLD_SIZE=1 when unset
    Script->>App: exec "$@" (the provided command)
```

## `qsub_multi_mpiexec.sc`

`qsub_multi_mpiexec.sc` is a PBS submission script that reruns a failing MPI workload inside the same
allocation until it succeeds or the trial limit is reached.

### Flow of control

```mermaid
sequenceDiagram
    participant PBS as PBS scheduler
    participant Script as qsub_multi_mpiexec.sc
    participant Nodes as Allocated nodes
    participant Monitor as check_hang.py
    participant MPI as mpiexec job

    PBS->>Script: Launch job with allocation
    Script->>Script: Initialize modules, environment, MAX_TRIALS
    loop For each trial up to MAX_TRIALS
        Script->>Nodes: get_healthy_nodes.sh -> subset nodefile
        Script->>Monitor: Start check_hang.py in background
        Script->>MPI: Launch mpiexec with launcher.sh shim
        MPI-->>Script: Return exit code
        alt Success
            Script->>PBS: Log success and break loop
        else Failure
            Script->>PBS: Log failure and intention to retry
            Script->>Monitor: pkill check_hang.py
            Script->>Nodes: flush.sh to clean compute hosts
            Script->>Script: sleep 5 before retry
        end
    end
    Script->>PBS: Emit final completion message
```
