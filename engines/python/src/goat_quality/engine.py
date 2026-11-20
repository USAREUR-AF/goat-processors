"""The names goat_quality.engine has always exported, now in goat_core.quality."""

from goat_core.quality import *  # noqa: F401,F403  (MEASURES below keeps its old shape)
from goat_core.model import REQUIRED  # noqa: F401,E402
from goat_core.quality import Engine, Pack, PackError, load_pack, make_engine, parse_pack  # noqa: F401
from goat_core.quality import MEASURES as _MEASURES

MEASURES = tuple((name, m.aggregate) for name, m in _MEASURES.items())
ENTITY_MEASURES = tuple(_MEASURES)
SOURCE_MEASURES = ENTITY_MEASURES + ("entities",)
from goat_core.estimate import (pos_update as _pos_update, predict_axis as _predict_axis,  # noqa: F401,E402
                                vel_update as _vel_update)
from goat_core.model import R, is_kind as _is, wrap180 as _wrap180  # noqa: F401,E402
from goat_core.quality import _Entity, _int, _mean, _median, _met, _num, _params  # noqa: F401,E402
