# Check Mate

`check_mate` bundles the monitoring utilities that power the Check Mate
checkpoint/restart workflow. Use the package to:

- keep an eye on checkpoints with `check-mate-hang`
- kill jobs that emit `NaN`/`Inf` tokens with `check-mate-nan`
- rebuild clean allocations with `check-mate get-healthy-nodes`
- compute optimal checkpoint cadences via the Python API

The documentation is organised into the following guides:

| Guide | Summary |
| --- | --- |
| [Getting started](getting-started.md) | Install the package, verify the CLI, and run your first monitors. |
| [CLI reference](cli.md) | Complete documentation for every bundled command with worked examples. |
| [Python API](python-api.md) | Programmatic access to checkpoint cadence modelling helpers. |
| [Workflow recipes](workflows.md) | Combine the tools into resilient batch scripts. |

## Quick demo

Once the package is installed you can confirm the CLI entry point and Python
API in a few commands:

```bash
$ check-mate --version
check-mate 0.1.0
```

- `check-mate-hang` — watch checkpoint files for activity and terminate a job if they stall.
- `check-mate-nan` — inspect log files for `NaN`/`Inf` tokens and trigger recovery hooks.
- `check-mate get-healthy-nodes` — delegate to the bundled shell helper that prunes unresponsive nodes.
- `check-mate launcher` — export launcher-friendly environment variables and execute a command.
- `check-mate flush` — run the original flush helper used in PBS-style workflows.

Refer to the [project README](https://github.com/argonne-lcf/checkpoint_restart#readme) for detailed usage examples.

## Building and packaging

`check-mate` is published using the [`uv` build backend](https://docs.astral.sh/uv/). After installing
`uv` and `uv-build`, run `uv build --wheel --sdist` from the repository root to produce local
artifacts. The resulting `dist/` directory mirrors what `uv publish` will upload to package indexes.

## Packaged submission templates

Sample PBS scripts are distributed with the library and can be previewed or saved locally via

```bash
python -m check_mate.examples.fail            # print the failing job template
python -m check_mate.examples.hang --output hang.sc
```

## Testing and verification

The same workflow documented in the [project README](https://github.com/argonne-lcf/checkpoint_restart#running-the-test-suite) applies to the
docs site:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e .[dev]
pytest
```

The optional `dev` extras provide `pytest`, so no additional packages are required. When installing
without extras, ensure `pytest` is available in the active environment before running the suite.
Because several tests exercise filesystem interactions, execute the commands from a writable working
directory. Consult the README link above for troubleshooting tips and additional context.
