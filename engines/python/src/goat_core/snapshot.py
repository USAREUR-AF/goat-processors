"""snapshot(): the whole state of each engine, as each specification's
Snapshot section lists it. Pure functions of the engine object; the key
order of every object is the one the events file keeps.

spec/correlate.md, spec/correlate-assign.md, spec/filter.md, spec/fuse.md
and spec/quality.md, Snapshot."""

from .estimate import MODELS


def track_estimate(e):
    """The snapshot fields of a correlate entity's track estimate."""
    out = {"filter": {"east": list(e.east), "north": list(e.north)}}
    if e.models is not None:
        out["models"] = {MODELS[j]: {"east": list(m[0]), "north": list(m[1])} for j, m in enumerate(e.models)}
        out["mode"] = list(e.mode)
    if e.time_err > 0:
        out["time"] = {"var_east": e.t_var[0], "var_north": e.t_var[1]}
    return out


def confirm(eng):
    """spec/correlate.md, Snapshot (method confirm)."""
    return {
        "ref": list(eng.ref) if eng.ref else None,
        "entities": {k: dict({"last_time_ms": e.last_time_ms, "group": e.group,
                              "hold_failures": e.hold_failures}, **track_estimate(e))
                     for k, e in sorted(eng.entities.items())},
        "groups": {g: list(eng.groups[g]) for g in eng.group_order},
        "counts": dict(sorted(eng.counts.items())),
        "next_group": eng.next_group,
    }


def assign(eng):
    """spec/correlate-assign.md, Snapshot."""
    pack = eng.pack
    out = {
        "ref": list(eng.ref) if eng.ref else None,
        "entities": {k: dict({"last_time_ms": e.last_time_ms, "system": e.system}, **track_estimate(e))
                     for k, e in sorted(eng.entities.items())},
        "systems": eng.committed.snap(),
        "next_system": eng.committed.next,
        "reported": sorted(eng.reported),
    }
    if pack.restart is not None:
        out["restarted"] = sorted(eng.restarted)
    if pack.bias is not None:
        out["bias"] = {k: dict({"east": v[0][0], "weight_east": v[0][2], "north": v[1][0],
                                "weight_north": v[1][2], "var": v[0][1], "pairs": v[2]},
                               **({"time_offset_ms": v[3] * 1000.0, "sums": list(v[4])}
                                  if pack.time_offset is not None else {}))
                       for k, v in sorted(eng.bias.items())}
    if pack.window > 1:
        out["retiring"] = sorted(eng.retiring)
        out["histories"] = [
            {"total": h.total(),
             "records": [{"cost": r.cost, "choices": [list(x) for x in r.choices],
                          "events": [dict(e) for e in r.events],
                          "systems": r.members.snap(), "next_system": r.members.next}
                         for r in h.records]}
            for h in eng.histories]
    return out


def filter_(eng):
    """spec/filter.md, Snapshot."""
    fields = ("time_ms", "lat", "lon", "course", "speed_ms", "stale_ms", "kept_ms")
    return {"entities": {k: {f: s[f] for f in fields} for k, s in sorted(eng.entities.items())}}


def fuse(eng):
    """spec/fuse.md, Snapshot."""
    return {
        "ref": list(eng.ref) if eng.ref else None,
        "entities": {k: {"last_time_ms": e.last_time_ms, "group": e.group,
                         "filter": {"east": list(e.east), "north": list(e.north)},
                         "report": dict(sorted(e.report.items()))}
                     for k, e in sorted(eng.entities.items())},
    }


def quality(eng):
    """spec/quality.md, Snapshot."""
    return {
        "ref": list(eng.ref) if eng.ref else None,
        "last_tick": eng.last_tick,
        "entities": {k: {"source": e.source, "last_time_ms": e.last_time_ms,
                         "last_pos": list(e.last_pos),
                         "filter": {"east": list(e.east), "north": list(e.north)},
                         "window": [dict(x) for x in e.window]}
                     for k, e in sorted(eng.entities.items())},
        "rules": {name: {s: dict(st) for s, st in sorted(states.items())}
                  for name, states in eng.rules.items()},
    }
