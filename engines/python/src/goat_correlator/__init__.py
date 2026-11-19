"""goat-correlator Python engine, written from spec/correlator-spec.md."""

from .engine import Engine, Pack, PackError, load_pack

__all__ = ["Engine", "Pack", "PackError", "load_pack"]
