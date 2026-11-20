"""The two scenario sets: tuning (public) and evaluation (held out).

| Set | Content | Seeds |
|---|---|---|
| tuning | the 21 named and 7 time scenarios, 500 random scenarios (the first 50 are the earlier random set) and the tuning half of every family | public: TUNING_ROOT below |
| evaluation | 500 random scenarios and the evaluation half of every family; names start `eval-` | private: `eval_root` in ~/re/bench-eval-seeds (mode 600), published after each release, then rotated |

Each family is a named generator with stated ground truth (FAMILIES). A
scenario's seed comes from its set's root, the family and its index, so the
two halves of a family are the same generator on unrelated seeds. Packs are
developed and tuned on the tuning set only; only the evaluation set gives the
numbers in the README and the comparison.
"""

import json
import math
import os

import scenarios as S
from scenarios import Obj, Member, Recorded, Scenario, Rng, radar, beacon, passive

HERE = os.path.dirname(os.path.abspath(__file__))
RECORDED_SHIPS = os.path.join(HERE, "data", "recorded-ships.json")

TUNING_ROOT = 20261120
EVAL_SEEDS = os.path.expanduser("~/re/bench-eval-seeds")
RANDOM_COUNT = 500
FAMILY_COUNT = 20       # scenarios per family per set (scale: SCALE_SIZES)
SCALE_SIZES = [50, 200, 1000]


def eval_root():
    """The evaluation root seed from ~/re/bench-eval-seeds, or None when it is not here."""
    try:
        with open(EVAL_SEEDS, encoding="utf-8") as f:
            return int(json.load(f)["eval_root"])
    except (OSError, ValueError, KeyError):
        return None


def _seed(root, tag):
    return Rng(root).fork(tag).u64()


def _g_turn(g, speed):
    """Turn rate (deg/s) of a level turn at g times gravity and `speed` m/s."""
    return math.degrees(g * 9.80665 / max(speed, 1.0))


def _sensors(r, n_min=2, n_max=3, **kw):
    makers = [radar, beacon, passive]
    n = r.integer(n_min, n_max)
    return [makers[i](**kw) for i in range(n)]


# ---------------------------------------------------------------------------
# Families. Each takes (rng, name) and returns a Scenario; `rng` is the
# scenario's own stream.


def formation(r, name):
    n = r.integer(2, 8)
    spacing = r.uniform(200.0, 1000.0)
    speed, heading = r.uniform(120, 260), r.uniform(0, 360)
    t0 = r.uniform(20, 50)
    lead = Obj("o1", east=r.uniform(-5000, 5000), north=r.uniform(-5000, 5000), speed=speed,
               heading=heading, alt=r.choice([3000.0, 6000.0]),
               moves=[(t0, t0 + 30, r.choice([3.0, -3.0]), 0.0)])
    objs = [lead]
    what = []
    for k in range(1, n):
        side = 1 if k % 2 else -1
        slot = (-spacing * ((k + 1) // 2), side * spacing * ((k + 1) // 2))
        kind = r.choice(["hold", "hold", "split", "join"])
        if kind == "split":
            ts = r.uniform(40, 80)
            out = r.uniform(3000, 8000)
            slots = [(0, slot[0], slot[1]), (ts, slot[0], slot[1]), (ts + 40, slot[0], slot[1] + side * out)]
        elif kind == "join":
            tj = r.uniform(20, 60)
            far = r.uniform(4000, 9000)
            slots = [(0, slot[0] - far, slot[1] + side * far), (tj, slot[0] - far, slot[1] + side * far),
                     (tj + 40, slot[0], slot[1])]
        else:
            slots = [(0, slot[0], slot[1])]
        what.append(kind)
        objs.append(Member("o%d" % (k + 1), "o1", slots))
    tests = "%d aircraft %.0f m apart; members %s" % (n, spacing, ", ".join(
        "%d %s" % (what.count(k), k) for k in ("hold", "split", "join") if what.count(k)))
    return Scenario(name, "formation", tests, objs, _sensors(r), duration_s=150, seed=r.u64())


def crossing(r, name):
    n = r.integer(2, 4)
    angle = r.uniform(3.0, 25.0)
    speed = r.uniform(100, 250)
    merge = r.chance(0.5)
    objs = []
    base = r.uniform(0, 360)
    for k in range(n):
        hd = base + (k - (n - 1) / 2.0) * angle
        # Start points chosen so the paths meet near the origin at t = 60 s.
        e0 = -speed * 60 * math.sin(math.radians(hd))
        n0 = -speed * 60 * math.cos(math.radians(hd))
        moves = []
        if merge:
            # Turn onto the common heading just before the meeting point: they then fly together.
            moves = [(50, 50 + abs(base - hd) / 2.0 + 0.1, -2.0 if hd > base else 2.0, 0.0)]
        objs.append(Obj("o%d" % (k + 1), east=e0 + r.uniform(-150, 150), north=n0 + r.uniform(-150, 150),
                        speed=speed * r.uniform(0.97, 1.03), heading=hd, alt=r.choice([3000.0, 3000.0, 3300.0]),
                        moves=moves))
    tests = "%d objects %s at %.0f deg apart" % (n, "merging onto one heading" if merge else "crossing", angle)
    return Scenario(name, "crossing", tests, objs, _sensors(r), duration_s=140, seed=r.u64())


def maneuver(r, name):
    kind = r.choice(["g-turn", "g-turn", "climb-dive", "stop-go"])
    objs, tests = [], ""
    if kind == "g-turn":
        g = r.uniform(3.0, 9.0)
        for k in range(r.integer(1, 3)):
            sp = r.uniform(180, 300)
            t0 = r.uniform(20, 60)
            rate = _g_turn(g, sp) * r.choice([1, -1])
            objs.append(Obj("o%d" % (k + 1), east=r.uniform(-8000, 8000), north=r.uniform(-8000, 8000), speed=sp,
                            heading=r.uniform(0, 360), alt=r.choice([2000.0, 5000.0]),
                            moves=[(t0, t0 + r.uniform(5, 15), rate, 0.0)]))
        tests = "level turns at %.1f g" % g
    elif kind == "climb-dive":
        for k in range(r.integer(1, 3)):
            t0 = r.uniform(20, 60)
            vz = r.choice([1, -1]) * r.uniform(50, 150)
            objs.append(Obj("o%d" % (k + 1), east=r.uniform(-8000, 8000), north=r.uniform(-8000, 8000),
                            speed=r.uniform(150, 280), heading=r.uniform(0, 360), alt=6000.0,
                            moves=[(t0, t0 + 20, r.uniform(-4, 4), 0.0)], climbs=[(t0, t0 + 25, vz)]))
        tests = "climbs and dives at 50 to 150 m/s with turns"
    else:
        for k in range(r.integer(2, 4)):
            stops = []
            t = r.uniform(10, 30)
            while t < 110:
                stops += [(t, t + 4, 0.0, -3.0), (t + 4 + r.uniform(5, 15), t + 8 + r.uniform(5, 15), 0.0, 3.0)]
                t += r.uniform(30, 45)
            objs.append(Obj("o%d" % (k + 1), east=r.uniform(-3000, 3000), north=r.uniform(-3000, 3000),
                            speed=r.uniform(6, 14), heading=r.uniform(0, 360), alt=0.0, env="S", moves=stops))
        tests = "surface traffic that stops and starts"
    return Scenario(name, "maneuver", kind + ": " + tests, objs, _sensors(r), duration_s=130, seed=r.u64())


def sensor_problems(r, name):
    objs = [Obj("o%d" % (k + 1), east=r.uniform(-15000, 15000), north=r.uniform(-15000, 15000),
                speed=r.uniform(80, 250), heading=r.uniform(0, 360), alt=r.choice([2000.0, 4000.0]),
                moves=[(r.uniform(20, 80), r.uniform(85, 110), r.choice([0.0, 3.0, -3.0]), 0.0)])
            for k in range(r.integer(2, 4))]
    problems = ["dropout", "intermittent", "long-latency", "out-of-order", "understated", "overstated",
                "biased", "clock-drift"]
    chosen = sorted(set(r.choice(problems) for _ in range(r.integer(2, 3))))
    sensors = []
    for i, make in enumerate([radar, beacon, passive][:r.integer(2, 3)]):
        kw = {}
        for p in chosen:
            if not r.chance(0.6 if p != "biased" else 0.7):
                continue
            if p == "dropout":
                t = r.uniform(30, 90)
                kw["outages"] = [(t, t + r.uniform(10, 30))]
            elif p == "intermittent":
                kw["outages"] = [(t, t + r.uniform(4, 9)) for t in range(10, 150, 15)]
            elif p == "long-latency":
                kw["latency_ms"] = r.integer(5000, 15000)
            elif p == "out-of-order":
                kw["delivery_spread_ms"] = r.integer(2000, 6000)
            elif p == "understated":
                kw["ce"], kw["ce_factor"] = "understated", r.choice([2.0, 3.0, 4.0])
            elif p == "overstated":
                kw["ce"], kw["ce_factor"] = "understated", r.choice([0.25, 0.5])
            elif p == "biased":
                kw["bias_m"] = (r.uniform(-400, 400), r.uniform(-400, 400))
            elif p == "clock-drift":
                kw["clock_drift_ms_min"] = r.choice([1, -1]) * r.uniform(10, 60)
        sensors.append(make(**kw))
    return Scenario(name, "sensor problems", "; ".join(chosen), objs, sensors, duration_s=150, seed=r.u64())


def scale(r, name, n):
    objs = []
    box = 30000.0 * math.sqrt(n / 50.0)
    for k in range(n):
        moves = []
        if r.chance(0.3):
            t0 = r.uniform(5, 40)
            moves = [(t0, t0 + 20, r.choice([3.0, -3.0]), 0.0)]
        env = "S" if r.chance(0.15) else "A"
        objs.append(Obj("o%d" % (k + 1), east=r.uniform(-box, box), north=r.uniform(-box, box),
                        speed=r.uniform(5, 15) if env == "S" else r.uniform(80, 280), heading=r.uniform(0, 360),
                        alt=0.0 if env == "S" else r.choice([1000.0, 3000.0, 6000.0, 9000.0]), env=env,
                        moves=moves))
    n_sensors = r.integer(3, 8)
    makers = [radar, beacon, passive]
    sensors = [makers[i % 3](source="%s%d" % (["radar", "beacon", "passive"][i % 3], i // 3 + 1))
               for i in range(n_sensors)]
    duration = 120 if n <= 50 else 60
    return Scenario(name, "scale", "%d objects, %d sensors, %d s" % (n, n_sensors, duration), objs, sensors,
                    duration_s=duration, seed=r.u64())


def clutter(r, name, level):
    objs = [Obj("o%d" % (k + 1), east=r.uniform(-10000, 10000), north=r.uniform(-10000, 10000),
                speed=r.uniform(80, 250), heading=r.uniform(0, 360)) for k in range(r.integer(2, 4))]
    sensors = [radar(false_tracks=level), beacon(), passive(false_tracks=level // 2)]
    return Scenario(name, "clutter", "%d false tracks on the radar, %d on the passive sensor" % (level, level // 2),
                    objs, sensors, duration_s=120, seed=r.u64())


def mixed_domains(r, name):
    objs = []
    k = 0
    for _ in range(r.integer(2, 4)):          # surface traffic
        k += 1
        objs.append(Obj("o%d" % k, east=r.uniform(-3000, 3000), north=r.uniform(-3000, 3000),
                        speed=r.uniform(4, 12), heading=r.uniform(0, 360), alt=0.0, env="S"))
    for _ in range(r.integer(1, 2)):          # slow, low helicopter near the surface traffic
        k += 1
        objs.append(Obj("o%d" % k, east=r.uniform(-2000, 2000), north=r.uniform(-2000, 2000),
                        speed=r.uniform(25, 60), heading=r.uniform(0, 360), alt=r.uniform(100, 300),
                        moves=[(r.uniform(20, 60), r.uniform(70, 100), r.choice([3.0, -3.0]), 0.0)]))
    for _ in range(r.integer(1, 2)):          # land vehicles on a coast road
        k += 1
        objs.append(Obj("o%d" % k, east=r.uniform(-4000, 4000), north=r.uniform(-4000, 4000),
                        speed=r.uniform(8, 25), heading=r.uniform(0, 360), alt=0.0, env="G"))
    k += 1
    objs.append(Obj("o%d" % k, east=r.uniform(-8000, 8000), north=r.uniform(-8000, 8000),
                    speed=r.uniform(150, 250), heading=r.uniform(0, 360), alt=3000.0))
    return Scenario(name, "mixed domains", "surface, a slow low helicopter, land vehicles and an aircraft",
                    objs, _sensors(r, 2, 3), duration_s=150, seed=r.u64())


def track_management(r, name):
    n = r.integer(2, 4)
    objs = [Obj("o%d" % (k + 1), east=r.uniform(-6000, 6000), north=r.uniform(-6000, 6000), speed=r.uniform(80, 250),
                heading=r.uniform(0, 360)) for k in range(n)]
    sensors, what = [], []
    for i, make in enumerate([radar, beacon, passive][:r.integer(2, 3)]):
        kw = {}
        if r.chance(0.5):
            kw["drops"] = [(r.uniform(30, 80), "o%d" % r.integer(1, n), r.uniform(3, 12))]
            kw["reuse_numbers"] = r.chance(0.6)
            what.append("drop" + (" and number reuse" if kw["reuse_numbers"] else ""))
        if r.chance(0.4) and n >= 2:
            kw["swaps"] = [(r.uniform(30, 100), "o1", "o2")]
            what.append("number swap")
        if i > 0 and r.chance(0.4):
            kw["start_s"] = r.uniform(30, 90)
            what.append("late-joining sensor")
        sensors.append(make(**kw))
    return Scenario(name, "track management", ", ".join(what) or "steady tracks", objs, sensors,
                    duration_s=150, seed=r.u64())


def recorded_ships(r, name, window):
    """Recorded ship motion (public AIS, tools/bench/recorded.py) with simulated sensors on top."""
    objs = [Recorded(o["oid"], [tuple(x) for x in o["samples"]], env="S") for o in window["objects"]]
    duration = int(max(o.end_s for o in objs)) + 1
    sensors = [radar(vel_sigma=1.0), beacon(period_ms=6000, jitter_ms=1000), passive()][:r.integer(2, 3)]
    return Scenario(name, "recorded ships", "%d vessels, recorded window %d (30 min)" % (len(objs), window["window"]),
                    objs, sensors, duration_s=duration, seed=r.u64())


FAMILIES = ["formation", "crossing", "maneuver", "sensor problems", "scale", "clutter", "mixed domains",
            "track management", "recorded ships"]
_GEN = {"formation": formation, "crossing": crossing, "maneuver": maneuver, "sensor problems": sensor_problems,
        "mixed domains": mixed_domains, "track management": track_management}
CLUTTER_LEVELS = [0, 5, 10, 20, 40]


def family_scenarios(root, prefix="", half=0):
    """Every family's scenarios for one set (`half`: which recorded windows, 0 tuning, 1 evaluation)."""
    out = []
    for fam in FAMILIES:
        slug = fam.replace(" ", "-")
        if fam == "recorded ships":
            if not os.path.exists(RECORDED_SHIPS):
                continue
            with open(RECORDED_SHIPS, encoding="utf-8") as f:
                wins = json.load(f)["windows"]
            for i, w in enumerate(wins[half::2]):
                name = "%s%s-%02d" % (prefix, slug, i + 1)
                out.append(recorded_ships(Rng(_seed(root, name.replace(prefix, "", 1))), name, w))
            continue
        if fam == "scale":
            for n in SCALE_SIZES:
                name = "%sscale-%04d" % (prefix, n)
                out.append(scale(Rng(_seed(root, name.replace(prefix, "", 1))), name, n))
            continue
        for i in range(FAMILY_COUNT):
            name = "%s%s-%02d" % (prefix, slug, i + 1)
            r = Rng(_seed(root, name.replace(prefix, "", 1)))
            if fam == "clutter":
                out.append(clutter(r, name, CLUTTER_LEVELS[i % len(CLUTTER_LEVELS)]))
            else:
                out.append(_GEN[fam](r, name))
    return out


def tuning_set():
    return S.named() + S.randomized(RANDOM_COUNT) + family_scenarios(TUNING_ROOT)


def evaluation_set(root=None):
    root = eval_root() if root is None else root
    if root is None:
        raise SystemExit("no evaluation seeds: %s is missing (proc-bench holds it; mode 600)" % EVAL_SEEDS)
    rnd = S.randomized(RANDOM_COUNT, seed=_seed(root, "random"))
    for sc in rnd:
        sc.name = "eval-" + sc.name
    return rnd + family_scenarios(root, prefix="eval-", half=1)


SETS = {"tuning": tuning_set, "evaluation": evaluation_set}
