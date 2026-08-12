# Logic and Orchestration of Shell Scripts

This document summarizes the orchestration logic used by the shell utilities that ship with the
checkpoint/restart examples.  Each section provides a narrative description and a Mermaid sequence
diagram so that the interactions between commands, files, and cluster services can be understood at a
glance.

## `get_healthy_nodes.sh`

`get_healthy_nodes.sh NODEFILE SELECT_COUNT OUTPUT_FILE` inspects the allocation that PBS provides and
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

`flush.sh` cleans residual user processes across the nodes of a job.  The first node in
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

## `local_rank.sh`

`local_rank.sh` normalizes environment variables required by distributed PyTorch or MPI launchers. It
prioritizes PALS/PMIx variables when available, computes a global `WORLD_SIZE`, selects a master
address, and finally delegates to the command that was supplied on the script's command line.

### Flow of control

```mermaid
sequenceDiagram
    participant Launcher as MPI/PBS launcher
    participant Script as local_rank.sh
    participant Env as Environment
    participant App as Target command

    Launcher->>Script: Provide PMIx/PALS environment and arguments
    Script->>Env: Read PMIX_* and PALS_* rank variables
    Script->>Env: Calculate WORLD_SIZE and fall back to defaults when missing
    Script->>Env: Derive MASTER_ADDR/PORT from PBS nodefile head
    Script->>App: Execute provided command with normalized environment
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
        Script->>Monitor: Start background hang detection
        Script->>MPI: Launch mpiexec with local_rank shim
        MPI-->>Script: Return exit code
        alt Success
            Script->>PBS: Log success and break loop
        else Failure
            Script->>PBS: Log failure and intention to retry
            Script->>Nodes: pkill python
            Script->>Nodes: flush.sh to clean compute hosts
            Script->>Script: sleep 5 before retry
        end
    end
    Script->>PBS: Emit final completion message
```

## `qsub_multi_qsub.sc`

`qsub_multi_qsub.sc` is an alternative PBS submission script that resubmits itself upon failure. It
performs one trial per submission and uses the same helper utilities for health checks and cleanup.

### Flow of control

```mermaid
sequenceDiagram
    participant PBS as PBS scheduler
    participant Script as qsub_multi_qsub.sc
    participant Nodes as Allocated nodes
    participant Monitor as check_hang.py
    participant MPI as mpiexec job

    PBS->>Script: Launch job with allocation
    Script->>Script: Initialize modules and environment
    Script->>Nodes: get_healthy_nodes.sh -> subset nodefile
    Script->>Monitor: Start background hang detection
    Script->>MPI: Launch mpiexec with local_rank shim
    MPI-->>Script: Return exit code
    alt Success
        Script->>PBS: Log success and exit
    else Failure
        Script->>PBS: Log failure and call qsub on itself
        Script->>Nodes: pkill python
        Script->>Nodes: flush.sh cleanup and sleep 5
    end
```
