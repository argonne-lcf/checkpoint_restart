"""Tools for monitoring and restarting large-scale simulations."""

from importlib.metadata import PackageNotFoundError, version

try:  # pragma: no cover - version metadata only at runtime
    __version__ = version("check-mate")
except PackageNotFoundError:  # pragma: no cover - fallback during dev installs
    __version__ = "0.0.0"

__all__ = ["__version__"]
