"""The names goat_quality.engine has always exported, now in goat_core.quality."""

from goat_core.quality import *  # noqa: F401,F403  (MEASURES below keeps its old shape)
from goat_core.quality import Engine, Pack, PackError, load_pack, make_engine, parse_pack  # noqa: F401
from goat_core.quality import MEASURES as _MEASURES

MEASURES = tuple((name, m.aggregate) for name, m in _MEASURES.items())
ENTITY_MEASURES = tuple(_MEASURES)
SOURCE_MEASURES = ENTITY_MEASURES + ("entities",)
