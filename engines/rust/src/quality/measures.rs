//! quality.md Entity measures and Source measures, the registration point
//! of a measure (`MEASURES`), and the `quality` event (Events).

use std::cell::OnceCell;

use super::*;

/// Spec Entity measures: a mean is `s / n`, `s` starting at 0.0 and adding
/// each sample in order.
pub(super) fn mean(values: &[f64]) -> f64 {
    let mut s = 0.0;
    for v in values {
        s += v;
    }
    s / values.len() as f64
}

/// Two numbers compared as binary64 values, except two integers, which are
/// compared exactly.
pub(super) fn compare_numbers(a: &Json, b: &Json) -> std::cmp::Ordering {
    match (a, b) {
        (Json::Int(x), Json::Int(y)) => x.cmp(y),
        _ => a.as_f64().unwrap_or(f64::NAN).total_cmp(&b.as_f64().unwrap_or(f64::NAN)),
    }
}

/// The largest of `values` (the first one among equals), or `Json::Null`
/// for none.
pub(super) fn largest(values: Vec<Json>) -> Json {
    values.into_iter().reduce(|best, v| if compare_numbers(&v, &best).is_gt() { v } else { best }).unwrap_or(Json::Null)
}

/// The smallest of `values` (the first one among equals), or `Json::Null`
/// for none.
pub(super) fn smallest(values: Vec<Json>) -> Json {
    values.into_iter().reduce(|best, v| if compare_numbers(&v, &best).is_lt() { v } else { best }).unwrap_or(Json::Null)
}

/// How a source measure aggregates its entities' values of the measure of
/// the same name (quality.md Source measures), entities in key order, null
/// values left out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Aggregate {
    /// The integer sum, 0 with no value.
    Sum,
    /// The largest value (the first among equals), null with none.
    Largest,
    /// The smallest value (the first among equals), null with none.
    Smallest,
    /// The mean of the values, null with none.
    Mean,
    /// The number of entities (a measure only a source has).
    Entities,
}

/// **The registration point of a quality measure.** One entry per measure
/// of quality.md, in the order of its tables: the name a rule's `measure=`
/// gives, the entity measure over the window (`None` when only a source has
/// it), and the source aggregate. A pack may name exactly these.
#[derive(Clone, Copy)]
pub struct Measure {
    pub name: &'static str,
    pub entity: Option<fn(&Window) -> Json>,
    pub source: Aggregate,
}

impl std::fmt::Debug for Measure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Measure({})", self.name)
    }
}

use Aggregate::{Entities, Largest, Mean, Smallest, Sum};

const fn measure(name: &'static str, entity: fn(&Window) -> Json, source: Aggregate) -> Measure {
    Measure { name, entity: Some(entity), source }
}

/// The measures of quality.md, tables "Entity measures" and "Source measures".
pub const MEASURES: &[Measure] = &[
    measure("reports", |w| Json::Int(w.reports()), Sum),
    measure("interval_last", |w| int_or_null(w.intervals().and_then(|v| v.last().copied())), Mean),
    measure("interval_mean", |w| num_or_null(w.intervals().map(|v| mean(&as_f64(v)))), Mean),
    measure("interval_max", |w| int_or_null(w.intervals().and_then(|v| v.iter().max().copied())), Largest),
    measure("age", |w| Json::Int(w.age_ms), Smallest),
    measure("latency_mean", |w| num_or_null(w.latencies().map(|v| mean(&as_f64(v)))), Mean),
    measure("latency_max", |w| int_or_null(w.latencies().and_then(|v| v.iter().max().copied())), Largest),
    measure(
        "lateness_mean",
        |w| num_or_null(w.lateness().map(|v| mean(&v.iter().map(|x| x.as_f64()).collect::<Vec<f64>>()))),
        Mean,
    ),
    measure("lateness_max", |w| w.lateness().map_or(Json::Null, |v| largest(lateness_json(v))), Largest),
    measure("lateness_min", |w| w.lateness().map_or(Json::Null, |v| smallest(lateness_json(v))), Smallest),
    measure("nis_mean", |w| num_or_null(w.nis().map(|v| mean(v))), Mean),
    measure("speed_err_mean", |w| num_or_null(w.speed_err().map(|v| mean(v))), Mean),
    measure("out_of_order", |w| Json::Int(w.count(|r| r.order == Order::OutOfOrder)), Sum),
    measure("duplicate", |w| Json::Int(w.count(|r| r.order == Order::Duplicate)), Sum),
    measure("source_out_of_order", |w| Json::Int(w.count(|r| r.source_out_of_order)), Sum),
    measure("missing_ce", |w| num_or_null(w.fraction_without(|r| r.ce)), Mean),
    measure("missing_vel", |w| num_or_null(w.fraction_without(|r| r.vel)), Mean),
    measure("missing_hae", |w| num_or_null(w.fraction_without(|r| r.hae)), Mean),
    measure("time_error_mean", |w| num_or_null(w.time_errors().map(|v| mean(v))), Mean),
    measure("time_error_max", |w| w.time_errors().map_or(Json::Null, |v| largest(v.iter().map(|x| Json::Num(*x)).collect())), Largest),
    measure("time_state_last", |w| int_or_null(w.time_states().and_then(|v| v.last().copied())), Largest),
    measure("time_state_worst", |w| int_or_null(w.time_states().and_then(|v| v.iter().max().copied())), Largest),
    measure("missing_time", |w| num_or_null(w.fraction_without(|r| r.time_state.is_some())), Mean),
    Measure { name: "entities", entity: None, source: Entities },
];

/// The measure named `name` that a rule of `scope` may read.
pub fn find(name: &str, scope: Scope) -> Option<&'static Measure> {
    MEASURES.iter().find(|m| m.name == name && (m.entity.is_some() || scope == Scope::Source))
}

fn as_f64(v: &[i64]) -> Vec<f64> {
    v.iter().map(|x| *x as f64).collect()
}

fn lateness_json(v: &[Ms]) -> Vec<Json> {
    v.iter().map(|x| x.to_json()).collect()
}

/// An entity's window `W` as the measures read it, with `k = min_samples`.
/// A statistic's samples are gathered once, when a measure first asks.
pub struct Window<'a> {
    records: &'a [Record],
    k: i64,
    /// `now_ms - last`.
    age_ms: i64,
    intervals: OnceCell<Option<Vec<i64>>>,
    latencies: OnceCell<Option<Vec<i64>>>,
    lateness: OnceCell<Option<Vec<Ms>>>,
    nis: OnceCell<Option<Vec<f64>>>,
    speed_err: OnceCell<Option<Vec<f64>>>,
    time_errors: OnceCell<Option<Vec<f64>>>,
    time_states: OnceCell<Option<Vec<i64>>>,
}

impl<'a> Window<'a> {
    fn new(records: &'a [Record], k: i64, age_ms: i64) -> Window<'a> {
        Window {
            records,
            k,
            age_ms,
            intervals: OnceCell::new(),
            latencies: OnceCell::new(),
            lateness: OnceCell::new(),
            nis: OnceCell::new(),
            speed_err: OnceCell::new(),
            time_errors: OnceCell::new(),
            time_states: OnceCell::new(),
        }
    }

    fn reports(&self) -> i64 {
        self.records.len() as i64
    }

    /// The samples `pick` gives, in window order; `None` (a null statistic)
    /// when fewer than `k` records hold one.
    fn samples<T>(&self, pick: impl Fn(&Record) -> Option<T>) -> Option<Vec<T>> {
        let v: Vec<T> = self.records.iter().filter_map(pick).collect();
        if v.len() as i64 >= self.k {
            Some(v)
        } else {
            None
        }
    }

    fn intervals(&self) -> Option<&Vec<i64>> {
        self.intervals.get_or_init(|| self.samples(|r| r.interval)).as_ref()
    }

    fn latencies(&self) -> Option<&Vec<i64>> {
        self.latencies.get_or_init(|| self.samples(|r| r.latency)).as_ref()
    }

    fn lateness(&self) -> Option<&Vec<Ms>> {
        self.lateness.get_or_init(|| self.samples(|r| r.lateness)).as_ref()
    }

    fn nis(&self) -> Option<&Vec<f64>> {
        self.nis.get_or_init(|| self.samples(|r| r.nis)).as_ref()
    }

    fn speed_err(&self) -> Option<&Vec<f64>> {
        self.speed_err.get_or_init(|| self.samples(|r| r.speed_err)).as_ref()
    }

    fn time_errors(&self) -> Option<&Vec<f64>> {
        self.time_errors.get_or_init(|| self.samples(|r| r.time_error)).as_ref()
    }

    fn time_states(&self) -> Option<&Vec<i64>> {
        self.time_states.get_or_init(|| self.samples(|r| r.time_state.map(time_state_code))).as_ref()
    }

    fn count(&self, flag: impl Fn(&Record) -> bool) -> i64 {
        self.records.iter().filter(|r| flag(r)).count() as i64
    }

    /// The fraction of records without `flag`; null when fewer than `k` records.
    fn fraction_without(&self, flag: impl Fn(&Record) -> bool) -> Option<f64> {
        let reports = self.reports();
        if reports < self.k {
            return None;
        }
        let without = self.records.iter().filter(|r| !flag(r)).count();
        Some(without as f64 / reports as f64)
    }
}

/// Spec Entity measures, over the entity's window `W` with `k =
/// min_samples`: every registered entity measure. Pure.
pub(super) fn entity_measures(entity: &Entity, now_ms: i64, k: i64) -> Measures {
    let w = Window::new(&entity.window, k, now_ms - entity.last_time_ms);
    MEASURES.iter().filter_map(|m| m.entity.map(|f| (m.name, f(&w)))).collect()
}

/// Spec Source measures: every registered measure's aggregate of the
/// source's entities' measures, taken in entity key order. Pure.
pub(super) fn source_measures(members: &[&Measures]) -> Measures {
    let present = |name: &str| -> Vec<&Json> { members.iter().map(|m| &m[name]).filter(|v| **v != Json::Null).collect() };
    let owned = |name: &str| -> Vec<Json> { present(name).into_iter().cloned().collect() };
    MEASURES
        .iter()
        .map(|m| {
            let value = match m.source {
                Sum => Json::Int(present(m.name).into_iter().filter_map(Json::as_i64).sum()),
                Largest => largest(owned(m.name)),
                Smallest => smallest(owned(m.name)),
                Mean => {
                    let values: Vec<f64> = present(m.name).into_iter().filter_map(Json::as_f64).collect();
                    if values.is_empty() {
                        Json::Null
                    } else {
                        Json::Num(mean(&values))
                    }
                }
                Entities => Json::Int(members.len() as i64),
            };
            (m.name, value)
        })
        .collect()
}

/// Spec Events: `quality`.
pub(super) fn quality_event(scope: Scope, subject: &str, measures: &Measures) -> Json {
    let measures = measures.iter().map(|(k, v)| (k.to_string(), v.clone())).collect();
    obj(vec![
        ("ev", "quality".into()),
        ("scope", scope.name().into()),
        ("subject", subject.into()),
        ("measures", Json::Obj(measures)),
    ])
}
