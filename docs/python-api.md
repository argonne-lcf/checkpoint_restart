# Python API

The `check_mate` package exposes a small, type-annotated surface area designed
to slot directly into scientific Python notebooks and orchestration scripts.
This page focuses on the `optimal_checkpointing` module, which models the
interplay between checkpoint cost and system reliability.

```python
>>> import check_mate as cm
>>> from check_mate import optimal_checkpointing as oc
>>> cm.__version__
'0.1.0'
```

## `optimal_checkpoint_cadence`

```python
optimal_checkpoint_cadence(
    node_count: int,
    node_memory: float,
    MTBAI: float = 0.67,
    chkpt_bandwidth: float | int | str = "DAOS-128",
    R_0: float | None = None,
) -> float
```

Return the optimal time in **hours** between checkpoints for a job that uses
`node_count` nodes with `node_memory` bytes per node. Bandwidth can be provided
as a numeric value (bytes/second) or via the built-in labels:

- `"DAOS-128"` → 5,000 bytes/s per node
- `"LUSTRE"` → 650 bytes/s per node

A minimal example:

```python
>>> cadence = oc.optimal_checkpoint_cadence(
...     node_count=1024,
...     node_memory=2.5e11,
...     chkpt_bandwidth="DAOS-128",
... )
>>> f"{cadence:.3f} h"
'6.951 h'
```

Pass an explicit `R_0` if you already computed the reliability coefficient for
your machine. Otherwise, the default converts the mean time between application
interruptions (MTBAI) using the built-in factor of 10,624.

## `compute_efficiency`

```python
compute_efficiency(
    node_count: int,
    node_memory: float,
    MTBAI: float = 0.67,
    chkpt_bandwidth: float | int | str = "DAOS-128",
    R_0: float | None = None,
    T_c: float = 4.0,
    T_w: float = 3.0,
) -> float
```

Return the expected efficiency (a 0–1 ratio) for the provided checkpointing
parameters. The function validates all positive inputs and emits a warning when
the computed cadence is unrealistically small.

Example using the cadence from above:

```python
>>> efficiency = oc.compute_efficiency(
...     node_count=1024,
...     node_memory=2.5e11,
...     chkpt_bandwidth="DAOS-128",
... )
>>> f"{efficiency:.3%}"
'36.531%'
```

## Integrating into your workflow

- Pair the cadence with your scheduler by converting the number of hours into
  wall-clock minutes between checkpoints.
- Feed the efficiency ratio into throughput calculators when sizing
  allocations.
- Combine the model with the [workflow recipes](workflows.md) to trigger
  recovery scripts at the predicted cadence.
