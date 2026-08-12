"""Entry point helpers for the packaged example."""
from __future__ import annotations

from typing import Sequence

from .. import run_example_cli

EXAMPLE = __name__.rsplit('.', 1)[-1]

__all__ = ["EXAMPLE", "main"]


def main(argv: Sequence[str] | None = None) -> int:
    """Dispatch to the shared example CLI helper."""
    return run_example_cli(EXAMPLE, argv)
