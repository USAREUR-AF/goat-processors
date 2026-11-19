"""goat-correlator Python engine, written from spec/correlate.md."""

from .engine import Engine, Pack, PackError, load_pack

__all__ = ["Engine", "Pack", "PackError", "load_pack"]
