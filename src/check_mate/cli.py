"""Thin wrappers that expose bundled shell utilities as console scripts."""

from __future__ import annotations

import argparse
import subprocess
import sys
import textwrap
from importlib import resources
from typing import Iterable

from . import __version__

_RESOURCE_PACKAGE = "check_mate.resources"

_TOOLS: tuple[tuple[str, str, str, str | None], ...] = (
    (
        "get-healthy-nodes",
        "get_healthy_nodes.sh",
        "Select responsive nodes from a nodefile.",
        (
            "Selects a subset of responsive nodes from a nodefile by delegating to "
            "the bundled shell implementation."
        ),
    ),
    (
        "launcher",
        "launcher.sh",
        "Launch the check-mate job runner.",
        None,
    ),
    (
        "flush",
        "flush.sh",
        "Flush all check-mate caches.",
        None,
    ),
)
_TOOL_SCRIPTS = {name: script for name, script, *_ in _TOOLS}
_COMMAND_LINES: list[str] = []
for name, _, help_text, description in _TOOLS:
    _COMMAND_LINES.append(f"  {name:<18} {help_text}")
    if description:
        _COMMAND_LINES.append(f"    {description}")
_COMMAND_SUMMARY = "\n".join(_COMMAND_LINES)


def _run_shell(script: str, argv: Iterable[str]) -> int:
    """Execute a packaged shell script with ``bash``.

    Output is streamed to the parent's stdout/stderr rather than captured, so
    long-running wrappers (e.g. ``launcher`` under ``mpiexec``) stream live and
    diagnostics written to stderr are never hidden.
    """
    try:
        resource = resources.files(_RESOURCE_PACKAGE) / script
    except (FileNotFoundError, ModuleNotFoundError):  # pragma: no cover - importlib edge cases
        raise RuntimeError(f"Unable to locate bundled script: {script}") from None

    with resources.as_file(resource) as path:
        try:
            result = subprocess.run(["bash", str(path), *list(argv)])
        except KeyboardInterrupt:  # pragma: no cover - user interrupt
            print("Execution interrupted by user.", file=sys.stderr)
            return 130
        except OSError as exc:
            raise RuntimeError(
                f"Failed to execute script '{script}': {exc.strerror or exc}"
            ) from exc

    if result.returncode != 0:
        print(
            f"Error running script '{script}' (exit code {result.returncode}).",
            file=sys.stderr,
        )
    return result.returncode


def get_healthy_nodes(argv: list[str] | None = None) -> int:
    return _run_shell(
        _TOOL_SCRIPTS["get-healthy-nodes"],
        argv if argv is not None else sys.argv[1:],
    )


def launcher(argv: list[str] | None = None) -> int:
    return _run_shell(
        _TOOL_SCRIPTS["launcher"],
        argv if argv is not None else sys.argv[1:],
    )


def flush(argv: list[str] | None = None) -> int:
    return _run_shell(
        _TOOL_SCRIPTS["flush"],
        argv if argv is not None else sys.argv[1:],
    )


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - convenience dispatcher
    parser = argparse.ArgumentParser(
        prog="check-mate",
        description="Utility command dispatcher for check-mate tools.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(
            "Available commands:\n" + _COMMAND_SUMMARY
        ).strip(),
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {__version__}",
    )
    parser.add_argument(
        "command",
        choices=tuple(_TOOL_SCRIPTS.keys()),
        help="Which bundled tool to execute.",
    )
    parser.add_argument("args", nargs=argparse.REMAINDER)

    ns = parser.parse_args(argv)
    forwarded = ns.args
    # argparse.REMAINDER keeps a literal "--" sentinel (documented as
    # `check-mate launcher -- <cmd>`); drop it so it isn't passed to the script.
    if forwarded and forwarded[0] == "--":
        forwarded = forwarded[1:]
    return _run_shell(_TOOL_SCRIPTS[ns.command], forwarded)


if __name__ == "__main__":  # pragma: no cover - script entry point
    sys.exit(main())
