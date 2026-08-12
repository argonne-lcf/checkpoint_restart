"""CLI entry point that enumerates the bundled examples."""
from __future__ import annotations

from . import available_examples


def main() -> int:
    examples = available_examples()
    if not examples:
        print("No packaged examples are available.")
        return 0

    print("Available Check Mate examples:\n")
    for example in examples:
        print(f"  python -m check_mate.examples.{example}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
