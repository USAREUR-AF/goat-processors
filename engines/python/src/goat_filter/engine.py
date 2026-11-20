"""The names goat_filter.engine has always exported, now in goat_core.filter."""

from goat_core.filter import *  # noqa: F401,F403
from goat_core.filter import Engine, Pack, PackError, load_pack, make_engine, parse_pack  # noqa: F401
from goat_core.filter import CONDITIONS as _CONDITIONS

PARAMS = {name: [set(s) for s in kind.params] for name, kind in _CONDITIONS.items()}
