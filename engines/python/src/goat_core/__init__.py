"""goat-processors, the Python engine: correlate, filter, fuse and quality.

Every function has the same entry point (`Function`): load the pack,
create the engine, then `ingest(report)` and `tick(now_ms)`, each returning
(events, trace records), and `snapshot()`. FUNCTIONS is the one table of
functions; the runner (io.main) and the tests reach every engine through it.
Standard library only."""

from . import correlate, filter, fuse, quality
from .packdef import PackError


class Function:
    """One function's entry point: parse_pack(text), load_pack(directory),
    make_engine(pack), and open(directory) = make_engine(load_pack(directory))."""

    def __init__(self, name, parse_pack, load_pack, make_engine):
        self.name = name
        self.parse_pack = parse_pack
        self.load_pack = load_pack
        self.make_engine = make_engine

    def open(self, directory):
        return self.make_engine(self.load_pack(directory))


FUNCTIONS = {
    "correlate": Function("correlate", correlate.parse_pack, correlate.load_pack, correlate.make_engine),
    "filter": Function("filter", filter.parse_pack, filter.load_pack, filter.make_engine),
    "fuse": Function("fuse", fuse.parse_pack, fuse.load_pack, fuse.make_engine),
    "quality": Function("quality", quality.parse_pack, quality.load_pack, quality.make_engine),
}

__all__ = ["FUNCTIONS", "Function", "PackError"]
