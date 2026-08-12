"""Helper utilities for distributing checkpoint restart job examples."""
from __future__ import annotations

import argparse
from importlib import resources
from pathlib import Path
from typing import Sequence

__all__ = [
    "available_examples",
    "read_script",
    "run_example_cli",
]

_SCRIPT_NAME = "qsub.sc"


def available_examples() -> list[str]:
    """Return the sorted collection of packaged example names."""
    package_contents = resources.files(__name__)
    examples: list[str] = []
    for entry in package_contents.iterdir():
        if entry.is_dir() and (entry / _SCRIPT_NAME).is_file():
            examples.append(entry.name)
    return sorted(examples)


def _script_resource(example: str) -> resources.abc.Traversable:
    script = resources.files(__name__).joinpath(example, _SCRIPT_NAME)
    if not script.is_file():
        raise FileNotFoundError(
            f"No '{_SCRIPT_NAME}' script bundled for the '{example}' example."
        )
    return script


def read_script(example: str) -> str:
    """Return the contents of the packaged submission script for *example*."""
    return _script_resource(example).read_text()


def _write_script(example: str, destination: Path, overwrite: bool) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and not overwrite:
        raise FileExistsError(
            f"Destination '{destination}' already exists. Use --overwrite to replace it."
        )
    destination.write_text(read_script(example))
    return destination


def run_example_cli(example: str, argv: Sequence[str] | None = None) -> int:
    """Entry-point helper that prints or writes a packaged submission script."""
    parser = argparse.ArgumentParser(
        prog=f"check_mate.examples.{example}",
        description=(
            "Display the packaged batch submission script or write it to a file for easy reuse."
        ),
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Optional destination to write the script instead of printing it.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite --output if it already exists.",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    if args.output is None:
        print(read_script(example))
        return 0

    written_to = _write_script(example, args.output, args.overwrite)
    print(f"Wrote {example} example submission script to {written_to}")
    return 0
