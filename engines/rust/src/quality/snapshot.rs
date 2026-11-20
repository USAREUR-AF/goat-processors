//! quality.md Snapshot.

use super::*;

impl Engine {
    /// Spec Snapshot.
    pub fn snapshot(&self) -> Json {
        let reference = match self.frame {
            Some(fr) => Json::Arr(vec![Json::Num(fr.lat0), Json::Num(fr.lon0)]),
            None => Json::Null,
        };
        let axis = |a: &Axis| Json::Arr(a.as_list().iter().map(|x| Json::Num(*x)).collect());
        let entities = self
            .entities
            .iter()
            .map(|(k, e)| {
                let window = e
                    .window
                    .iter()
                    .map(|r| {
                        obj(vec![
                            ("wt", Json::Int(r.wt)),
                            ("time_ms", Json::Int(r.time_ms)),
                            ("order", r.order.name().into()),
                            ("interval", int_or_null(r.interval)),
                            ("latency", int_or_null(r.latency)),
                            ("lateness", r.lateness.map_or(Json::Null, Ms::to_json)),
                            ("source_out_of_order", r.source_out_of_order.into()),
                            ("time_error", num_or_null(r.time_error)),
                            ("time_state", r.time_state.map_or(Json::Null, |s| s.name().into())),
                            ("nis", num_or_null(r.nis)),
                            ("speed_err", num_or_null(r.speed_err)),
                            ("ce", r.ce.into()),
                            ("vel", r.vel.into()),
                            ("hae", r.hae.into()),
                        ])
                    })
                    .collect();
                let value = obj(vec![
                    ("source", e.source.as_str().into()),
                    ("last_time_ms", Json::Int(e.last_time_ms)),
                    ("last_pos", Json::Arr(vec![Json::Num(e.last_pos.0), Json::Num(e.last_pos.1)])),
                    ("filter", obj(vec![("east", axis(&e.east)), ("north", axis(&e.north))])),
                    ("window", Json::Arr(window)),
                ]);
                (k.clone(), value)
            })
            .collect();
        let rules = self
            .rules
            .iter()
            .map(|(name, states)| {
                let states = states
                    .iter()
                    .map(|(s, st)| (s.clone(), obj(vec![("count", Json::Int(st.count as i64)), ("active", st.active.into())])))
                    .collect();
                (name.clone(), Json::Obj(states))
            })
            .collect();
        obj(vec![
            ("ref", reference),
            ("last_tick", int_or_null(self.last_tick)),
            ("entities", Json::Obj(entities)),
            ("rules", Json::Obj(rules)),
        ])
    }
}
