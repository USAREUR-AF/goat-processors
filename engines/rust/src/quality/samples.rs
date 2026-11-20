//! quality.md Order, Input clock and Samples: a report's order against its
//! entity, the input clock, and the record of samples it appends to its
//! entity's window (Window).

use super::*;

/// Spec Order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Order {
    First,
    Advance,
    Duplicate,
    OutOfOrder,
}

impl Order {
    pub(super) fn name(self) -> &'static str {
        match self {
            Order::First => "first",
            Order::Advance => "advance",
            Order::Duplicate => "duplicate",
            Order::OutOfOrder => "out-of-order",
        }
    }
}

/// Spec Samples: a millisecond value that is an integer, or a binary64 when
/// the input clock is the mean of two middle values (the input clock and the
/// `lateness` sample).
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) enum Ms {
    Int(i64),
    Float(f64),
}

impl Ms {
    pub(super) fn as_f64(self) -> f64 {
        match self {
            Ms::Int(v) => v as f64,
            Ms::Float(v) => v,
        }
    }

    pub(super) fn to_json(self) -> Json {
        match self {
            Ms::Int(v) => Json::Int(v),
            Ms::Float(v) => Json::Num(v),
        }
    }

    /// Two values compared as binary64 values, except two integers, which
    /// are compared exactly (as `measures::compare_numbers` on their JSON).
    pub(super) fn compare(&self, other: &Ms) -> std::cmp::Ordering {
        match (self, other) {
            (Ms::Int(a), Ms::Int(b)) => a.cmp(b),
            _ => self.as_f64().total_cmp(&other.as_f64()),
        }
    }

    /// `self - t`, ms: an integer when `self` is one, else a binary64.
    pub(super) fn minus(self, t: i64) -> Ms {
        match self {
            Ms::Int(v) => Ms::Int(v - t),
            Ms::Float(v) => Ms::Float(v - t as f64),
        }
    }
}

/// Spec Reports, Time quality: the code of a time state for measures.
/// Higher is worse.
pub(super) fn time_state_code(state: TimeState) -> i64 {
    match state {
        TimeState::Coherent => 0,
        TimeState::Drifting => 1,
        TimeState::FreeRunning => 2,
    }
}

/// Spec Samples: a report's record, appended to its entity's window.
#[derive(Debug, Clone)]
pub(super) struct Record {
    pub(super) wt: i64,
    pub(super) time_ms: i64,
    pub(super) order: Order,
    pub(super) interval: Option<i64>,
    pub(super) latency: Option<i64>,
    pub(super) lateness: Option<Ms>,
    pub(super) time_error: Option<f64>,
    pub(super) time_state: Option<TimeState>,
    pub(super) source_out_of_order: bool,
    pub(super) nis: Option<f64>,
    pub(super) speed_err: Option<f64>,
    pub(super) ce: bool,
    pub(super) vel: bool,
    pub(super) hae: bool,
}

/// Spec Input clock: the median of the latest times of the sources other
/// than `source`, None with no other source; and the source latest of
/// `source`, None when it has no entity. A source's latest time is the
/// greatest `last` among the entities whose source it is.
pub(super) fn input_clock(entities: &BTreeMap<String, Entity>, source: &str) -> (Option<Ms>, Option<i64>) {
    let mut latest: BTreeMap<&str, i64> = BTreeMap::new();
    for entity in entities.values() {
        let l = latest.entry(entity.source.as_str()).or_insert(entity.last_time_ms);
        *l = (*l).max(entity.last_time_ms);
    }
    let source_latest = latest.remove(source);

    let mut others: Vec<i64> = latest.into_values().collect();
    others.sort();
    let count = others.len();
    let clock = if count == 0 {
        None
    } else if count % 2 == 1 {
        Some(Ms::Int(others[count / 2]))
    } else {
        let (a, b) = (others[count / 2 - 1] as f64, others[count / 2] as f64);
        Some(Ms::Float((a + b) / 2.0))
    };
    (clock, source_latest)
}

/// Spec Samples, `nis`: the report's plane position `z` against the entity's
/// prediction, with `r = ce²`: per axis `d = z - p` and `s = pp + r`, and
/// `value = de²/se + dn²/sn`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Nis {
    pub(super) value: f64,
    pub(super) de: f64,
    pub(super) dn: f64,
    pub(super) se: f64,
    pub(super) sn: f64,
}

/// `Nis` of a report. Pure.
pub(super) fn nis((e, n): (f64, f64), (pe, pn): (&Axis, &Axis), ce: f64) -> Nis {
    let r = ce * ce;
    let de = e - pe.p;
    let dn = n - pn.p;
    let se = pe.pp + r;
    let sn = pn.pp + r;
    Nis { value: de * de / se + dn * dn / sn, de, dn, se, sn }
}

/// Spec Samples, `speed_err`: `(implied, |implied - speed|)`, the implied
/// speed from the last position to this one over `dt` seconds. Pure.
pub(super) fn speed_err((e, n): (f64, f64), (lpe, lpn): (f64, f64), dt: f64, speed: f64) -> (f64, f64) {
    let implied = (e - lpe).hypot(n - lpn) / dt;
    (implied, (implied - speed).abs())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entity(source: &str, last: i64) -> Entity {
        let a = Axis { p: 0.0, v: 0.0, pp: 1.0, pv: 0.0, vv: 1.0 };
        Entity { source: source.into(), last_time_ms: last, last_pos: (0.0, 0.0), east: a, north: a, window: Vec::new() }
    }

    fn entities(list: &[(&str, &str, i64)]) -> BTreeMap<String, Entity> {
        list.iter().map(|(k, s, t)| (k.to_string(), entity(s, *t))).collect()
    }

    #[test]
    fn input_clock_is_the_median_of_the_other_sources_latest() {
        let e = entities(&[("a/1", "a", 100), ("a/2", "a", 300), ("b/1", "b", 200), ("c/1", "c", 50), ("d/1", "d", 400)]);
        // Others of a: b 200, c 50, d 400: median 200. a's latest is 300.
        assert_eq!(input_clock(&e, "a"), (Some(Ms::Int(200)), Some(300)));
        // Others of b: a 300, c 50, d 400.
        assert_eq!(input_clock(&e, "b").0, Some(Ms::Int(300)));
        let two = entities(&[("a/1", "a", 100), ("b/1", "b", 201)]);
        assert_eq!(input_clock(&two, "z"), (Some(Ms::Float(150.5)), None));
        assert_eq!(input_clock(&entities(&[("a/1", "a", 1)]), "a"), (None, Some(1)));
    }

    #[test]
    fn ms_and_order_forms() {
        assert_eq!(Ms::Int(5).minus(7), Ms::Int(-2));
        assert_eq!(Ms::Float(5.5).minus(1).to_json(), Json::Num(4.5));
        assert_eq!(Ms::Int(3).as_f64(), 3.0);
        let names: Vec<&str> = [Order::First, Order::Advance, Order::Duplicate, Order::OutOfOrder].iter().map(|o| o.name()).collect();
        assert_eq!(names, ["first", "advance", "duplicate", "out-of-order"]);
        assert_eq!([TimeState::Coherent, TimeState::Drifting, TimeState::FreeRunning].map(time_state_code), [0, 1, 2]);
    }

    #[test]
    fn nis_and_speed_err() {
        let p = Axis { p: 1.0, v: 0.0, pp: 3.0, pv: 0.0, vv: 1.0 };
        let n = nis((3.0, 1.0), (&p, &p), 1.0);
        assert_eq!((n.value, n.de, n.dn, n.se, n.sn), (1.0, 2.0, 0.0, 4.0, 4.0));
        assert_eq!(speed_err((3.0, 4.0), (0.0, 0.0), 2.0, 2.0), (2.5, 0.5));
    }
}
