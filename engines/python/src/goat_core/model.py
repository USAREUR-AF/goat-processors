"""The shared-model report and the local plane.

spec/correlate.md, Reports (and Time quality) and Frame; spec/filter.md,
spec/fuse.md and spec/quality.md take their required keys and their frame
from there. Pure functions and constants only."""

import math
from types import MappingProxyType

R = 6371008.8

TIME_STATES = ("coherent", "drifting", "free-running")
REQUIRED = (("track.source_id", "str"), ("uid", "str"), ("time_ms", "int"),
            ("lat", "num"), ("lon", "num"))
OPTIONAL = MappingProxyType({"hae": "num", "ce": "num", "course": "num", "speed_ms": "num",
                             "type": "str", "stale_ms": "int", "time_error_ms": "num",
                             "time_state": "str"})


def _is_str(v):
    return isinstance(v, str)


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


KIND_CHECK = MappingProxyType({"str": _is_str, "int": _is_int, "num": _is_num})
_REQUIRED_CHECKS = tuple((k, KIND_CHECK[kind]) for k, kind in REQUIRED)
_OPTIONAL_CHECKS = MappingProxyType({k: KIND_CHECK[kind] for k, kind in OPTIONAL.items()})


def is_kind(v, kind):
    """Reports: a value of the kind "str", "int" or "num" (an int is a num;
    a boolean and null are neither)."""
    return KIND_CHECK[kind](v)


def missing_key(report):
    """Reports: the first required key that is missing, in the table's order, or None."""
    get = report.get
    for k, check in _REQUIRED_CHECKS:
        if not check(get(k)):
            return k
    return None


def normalize(report):
    """Reports: a copy without the null keys and the optional keys of the
    wrong type (and a ce of 0 or below, a bad time_error_ms or time_state)."""
    out = {}
    checks = _OPTIONAL_CHECKS
    for k, v in report.items():
        if v is None:
            continue
        check = checks.get(k)
        if check is not None:
            if not check(v):
                continue
            if k == "ce" and v <= 0:
                continue
            if k == "time_error_ms" and (v < 0 or not math.isfinite(v)):
                continue
            if k == "time_state" and v not in TIME_STATES:
                continue
        out[k] = v
    return out


def environment(report):
    """Reports, type: the third '-'-separated element, or None."""
    t = report.get("type")
    if t is None:
        return None
    parts = str(t).split("-")
    return parts[2] if len(parts) >= 3 else None


def wrap180(x):
    """Frame: bring a longitude difference into (-180, 180]."""
    while x > 180.0:
        x -= 360.0
    while x <= -180.0:
        x += 360.0
    return x


def to_plane(ref, lat, lon):
    """Frame: (east, north) in meters of (lat, lon) from the reference ref."""
    lat0, lon0 = ref
    dlon = wrap180(lon - lon0)
    return (R * math.radians(dlon) * math.cos(math.radians(lat0)),
            R * math.radians(lat - lat0))


def to_deg(ref, east, north):
    """Frame: back to (lat, lon)."""
    lat0, lon0 = ref
    lat = lat0 + math.degrees(north / R)
    lon = lon0 + math.degrees(east / (R * math.cos(math.radians(lat0))))
    return lat, wrap180(lon)


def course_deg(east_v, north_v):
    """Output course in [0, 360) of a velocity (east, north)."""
    course = math.degrees(math.atan2(east_v, north_v))
    if course < 0:
        course += 360.0
    if course >= 360.0:
        course -= 360.0
    return course


def velocity(course, speed):
    """Track estimate: the measured velocity (east, north) from course (deg) and speed."""
    c = math.radians(course)
    return (speed * math.sin(c), speed * math.cos(c))
