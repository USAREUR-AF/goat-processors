"""goat-processors, the Python engine: correlate, filter, fuse and quality.

Every function has the same entry point (`Function`): load the pack,
create the engine, then `ingest(report)` and `tick(now_ms)`, each returning
(events, trace records), and `snapshot()`. FUNCTIONS is the one table of
functions; the runner (io.main) and the tests reach every engine through it.
A function's module is imported when the function is first used, so a
process that runs one function loads only its modules. Standard library only."""

from importlib import import_module

from .packdef import PackError


class Function:
    """One function's entry point: parse_pack(text), load_pack(directory),
    make_engine(pack), open(directory) = make_engine(load_pack(directory)),
    and restore(pack, snapshot), or None when the function has no restore
    (correlate: its snapshot omits each entity's last report)."""

    def __init__(self, name, module, has_restore):
        self.name = name
        self._module = module
        self._has_restore = has_restore

    @property
    def module(self):
        return import_module(self._module)

    @property
    def parse_pack(self):
        return self.module.parse_pack

    @property
    def load_pack(self):
        return self.module.load_pack

    @property
    def make_engine(self):
        return self.module.make_engine

    @property
    def restore(self):
        return self.module.restore if self._has_restore else None

    def open(self, directory):
        m = self.module
        return m.make_engine(m.load_pack(directory))


FUNCTIONS = {
    "correlate": Function("correlate", "goat_core.correlate", False),
    "filter": Function("filter", "goat_core.filter", True),
    "fuse": Function("fuse", "goat_core.fuse", True),
    "quality": Function("quality", "goat_core.quality", True),
}

__all__ = ["FUNCTIONS", "Function", "PackError"]
