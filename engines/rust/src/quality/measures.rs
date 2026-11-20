//! quality.md Entity measures and Source measures, and the `quality` event
//! (Events).

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

impl Engine {
    /// Spec Entity measures, over the entity's window `W`.
    pub(super) fn entity_measures(&self, entity: &Entity, now_ms: i64) -> Measures {
        let w = &entity.window;
        let k = self.pack.window.min_samples;
        let reports = w.len() as i64;
        // A statistic: null when fewer than `k` records hold the sample.
        let enough = |n: usize| n as i64 >= k;
        let ints = |pick: fn(&Record) -> Option<i64>| -> Option<Vec<i64>> {
            let v: Vec<i64> = w.iter().filter_map(pick).collect();
            if enough(v.len()) {
                Some(v)
            } else {
                None
            }
        };
        let floats = |pick: fn(&Record) -> Option<f64>| -> Option<Vec<f64>> {
            let v: Vec<f64> = w.iter().filter_map(pick).collect();
            if enough(v.len()) {
                Some(v)
            } else {
                None
            }
        };
        let as_f64 = |v: &Vec<i64>| v.iter().map(|x| *x as f64).collect::<Vec<f64>>();
        let fraction = |flag: fn(&Record) -> bool| -> Option<f64> {
            if reports < k {
                return None;
            }
            let without = w.iter().filter(|r| !flag(r)).count();
            Some(without as f64 / reports as f64)
        };
        let count_order = |o: Order| w.iter().filter(|r| r.order == o).count() as i64;

        let intervals = ints(|r| r.interval);
        let latencies = ints(|r| r.latency);
        let lateness: Option<Vec<Ms>> = {
            let v: Vec<Ms> = w.iter().filter_map(|r| r.lateness).collect();
            if enough(v.len()) {
                Some(v)
            } else {
                None
            }
        };
        let nis = floats(|r| r.nis);
        let speed_err = floats(|r| r.speed_err);
        let time_errors = floats(|r| r.time_error);
        let time_states = ints(|r| r.time_state.map(time_state_code));
        let lateness_json = |v: &Vec<Ms>| v.iter().map(|x| x.to_json()).collect::<Vec<Json>>();

        let mut m = Measures::new();
        m.insert("reports", Json::Int(reports));
        m.insert("interval_last", int_or_null(intervals.as_ref().and_then(|v| v.last().copied())));
        m.insert("interval_mean", num_or_null(intervals.as_ref().map(|v| mean(&as_f64(v)))));
        m.insert("interval_max", int_or_null(intervals.as_ref().and_then(|v| v.iter().max().copied())));
        m.insert("age", Json::Int(now_ms - entity.last_time_ms));
        m.insert("latency_mean", num_or_null(latencies.as_ref().map(|v| mean(&as_f64(v)))));
        m.insert("latency_max", int_or_null(latencies.as_ref().and_then(|v| v.iter().max().copied())));
        let lateness_f64 = lateness.as_ref().map(|v| v.iter().map(|x| x.as_f64()).collect::<Vec<f64>>());
        m.insert("lateness_mean", num_or_null(lateness_f64.as_ref().map(|v| mean(v))));
        m.insert("lateness_max", lateness.as_ref().map_or(Json::Null, |v| largest(lateness_json(v))));
        m.insert("lateness_min", lateness.as_ref().map_or(Json::Null, |v| smallest(lateness_json(v))));
        m.insert("nis_mean", num_or_null(nis.as_ref().map(|v| mean(v))));
        m.insert("speed_err_mean", num_or_null(speed_err.as_ref().map(|v| mean(v))));
        m.insert("out_of_order", Json::Int(count_order(Order::OutOfOrder)));
        m.insert("duplicate", Json::Int(count_order(Order::Duplicate)));
        m.insert("source_out_of_order", Json::Int(w.iter().filter(|r| r.source_out_of_order).count() as i64));
        m.insert("missing_ce", num_or_null(fraction(|r| r.ce)));
        m.insert("missing_vel", num_or_null(fraction(|r| r.vel)));
        m.insert("missing_hae", num_or_null(fraction(|r| r.hae)));
        m.insert("time_error_mean", num_or_null(time_errors.as_ref().map(|v| mean(v))));
        m.insert("time_error_max", time_errors.as_ref().map_or(Json::Null, |v| largest(v.iter().map(|x| Json::Num(*x)).collect())));
        m.insert("time_state_last", int_or_null(time_states.as_ref().and_then(|v| v.last().copied())));
        m.insert("time_state_worst", int_or_null(time_states.as_ref().and_then(|v| v.iter().max().copied())));
        m.insert("missing_time", num_or_null(fraction(|r| r.time_state.is_some())));
        m
    }
}

/// Spec Source measures: aggregates of the source's entities' measures,
/// taken in entity key order.
pub(super) fn source_measures(members: &[&Measures]) -> Measures {
    let present = |name: &str| -> Vec<&Json> { members.iter().map(|m| &m[name]).filter(|v| **v != Json::Null).collect() };
    let ints = |name: &str| -> Vec<i64> { present(name).into_iter().filter_map(Json::as_i64).collect() };
    let sum = |name: &str| Json::Int(ints(name).iter().sum());
    let mean_of = |name: &str| {
        let values: Vec<f64> = present(name).into_iter().filter_map(Json::as_f64).collect();
        if values.is_empty() {
            Json::Null
        } else {
            Json::Num(mean(&values))
        }
    };
    let owned = |name: &str| -> Vec<Json> { present(name).into_iter().cloned().collect() };

    let mut m = Measures::new();
    for name in ENTITY_MEASURES {
        let value = match name {
            "reports" | "out_of_order" | "duplicate" | "source_out_of_order" => sum(name),
            "interval_max" | "latency_max" | "lateness_max" | "time_error_max" | "time_state_last" | "time_state_worst" => {
                largest(owned(name))
            }
            "lateness_min" | "age" => smallest(owned(name)),
            _ => mean_of(name),
        };
        m.insert(name, value);
    }
    m.insert(SOURCE_ONLY_MEASURE, Json::Int(members.len() as i64));
    m
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
