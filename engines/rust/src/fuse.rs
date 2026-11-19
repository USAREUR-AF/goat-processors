//! Fuse, spec/fuse.md version 0.1: one estimate per group of entities that
//! `fuse.group` says describe one object.
//!
//! `fuse::load_pack`, then `fuse::Engine::new(pack)` with `ingest`, `tick`,
//! `snapshot`. Frame and the per-entity filter are correlate's
//! (`crate::filter`), as spec/fuse.md "Shared with correlate.md" cites.

use std::collections::BTreeMap;

use crate::filter::{deg, rad, Axis, Frame};
use crate::json::{obj, Json};
pub use crate::engine::StepResult;

pub mod attributes;
pub mod kinematics;
pub mod pack;

pub use pack::{load_pack, parse_pack, Kinematics, Pack, Rule};

const REQUIRED: [&str; 5] = ["track.source_id", "uid", "time_ms", "lat", "lon"];

#[derive(Debug, Clone)]
struct Entity {
    source: String,
    last_time_ms: i64,
    /// `fuse.group` of the last accepted report; `None` is its own unnamed group.
    group: Option<String>,
    east: Axis,
    north: Axis,
    /// The last normalised report.
    report: BTreeMap<String, Json>,
}

/// One member of a group at a tick, its filter predicted to `now_ms`.
pub struct Member<'a> {
    pub key: String,
    pub last_time_ms: i64,
    /// Index of its source among the pack's `source` lines; `None` when unlisted.
    pub rank: Option<usize>,
    pub east: Axis,
    pub north: Axis,
    pub report: &'a BTreeMap<String, Json>,
}

impl Member<'_> {
    /// Position variance, `var = ppe + ppn`.
    pub fn var(&self) -> f64 {
        self.east.pp + self.north.pp
    }
}

/// Reports: the required key that is missing, checked in table order.
fn missing_required(fields: &BTreeMap<String, Json>) -> Option<&'static str> {
    REQUIRED.into_iter().find(|key| {
        let v = fields.get(*key);
        match *key {
            "track.source_id" | "uid" => v.and_then(Json::as_str).is_none(),
            "time_ms" => v.and_then(Json::as_i64).is_none(),
            _ => v.and_then(Json::as_f64).is_none(),
        }
    })
}

/// The normalised report: every key removed that is `null`, an optional
/// correlate key of the wrong type, a `ce` of 0 or below, or an unusable
/// `fuse.group` (not a string, or empty).
fn normalise(fields: &BTreeMap<String, Json>) -> BTreeMap<String, Json> {
    fields
        .iter()
        .filter(|(key, value)| match key.as_str() {
            _ if **value == Json::Null => false,
            "hae" | "course" | "speed_ms" => value.as_f64().is_some(),
            "ce" => value.as_f64().is_some_and(|c| c > 0.0),
            "type" => value.as_str().is_some(),
            "stale_ms" => value.as_i64().is_some(),
            "fuse.group" => value.as_str().is_some_and(|g| !g.is_empty()),
            _ => true,
        })
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}

fn group_json(group: &Option<String>) -> Json {
    group.as_deref().map_or(Json::Null, Json::from)
}

fn rank_json(rank: Option<usize>) -> Json {
    rank.map_or(Json::Null, |r| Json::Int(r as i64))
}

pub struct Engine {
    pack: Pack,
    frame: Option<Frame>,
    entities: BTreeMap<String, Entity>,
}

impl Engine {
    pub fn new(pack: Pack) -> Engine {
        Engine { pack, frame: None, entities: BTreeMap::new() }
    }

    // ---- ingest (spec/fuse.md: Reports, Groups; correlate.md: Frame, Track estimate)

    pub fn ingest(&mut self, report: &Json) -> StepResult {
        let mut out = StepResult::default();
        let empty = BTreeMap::new();
        let fields = report.as_object().unwrap_or(&empty);

        // Reports: a missing required key rejects.
        if let Some(key) = missing_required(fields) {
            out.events.push(obj(vec![("ev", "reject".into()), ("reason", format!("missing:{}", key).into())]));
            return out;
        }
        let source = fields["track.source_id"].as_str().unwrap();
        let uid = fields["uid"].as_str().unwrap();
        let time_ms = fields["time_ms"].as_i64().unwrap();
        let (lat, lon) = (fields["lat"].as_f64().unwrap(), fields["lon"].as_f64().unwrap());
        let key = format!("{}/{}", source, uid);

        // Reports: earlier than the entity's last accepted report is ignored.
        if let Some(e) = self.entities.get(&key) {
            if time_ms < e.last_time_ms {
                out.events.push(obj(vec![
                    ("ev", "stale-report".into()),
                    ("entity", key.as_str().into()),
                    ("time_ms", time_ms.into()),
                    ("last_time_ms", e.last_time_ms.into()),
                ]));
                return out;
            }
        }

        let report = normalise(fields);
        let group = report.get("fuse.group").and_then(Json::as_str).map(str::to_string);

        // Frame: the reference is the first accepted report.
        let frame = *self.frame.get_or_insert(Frame { lat0: lat, lon0: lon });
        let (ze, zn) = frame.to_plane(lat, lon);

        // Track estimate: first report, or predict and update.
        let f = &self.pack.filter;
        let ce = report.get("ce").and_then(Json::as_f64).unwrap_or(f.default_ce_m);
        let vel = match (report.get("course").and_then(Json::as_f64), report.get("speed_ms").and_then(Json::as_f64)) {
            (Some(c), Some(s)) => Some((s * rad(c).sin(), s * rad(c).cos())),
            _ => None,
        };

        match self.entities.get_mut(&key) {
            None => {
                let east = Axis::first(ze, vel.map(|v| v.0), ce, f.vel_sigma_ms, f.unknown_vel_ms);
                let north = Axis::first(zn, vel.map(|v| v.1), ce, f.vel_sigma_ms, f.unknown_vel_ms);
                // Groups: a first report gives `new` with the entity's group.
                out.events.push(obj(vec![("ev", "new".into()), ("entity", key.as_str().into()), ("group", group_json(&group))]));
                let entity = Entity { source: source.to_string(), last_time_ms: time_ms, group, east, north, report };
                self.entities.insert(key, entity);
            }
            Some(e) => {
                let dt = (time_ms - e.last_time_ms) as f64 / 1000.0;
                let (r_pos, r_vel) = (ce * ce, f.vel_sigma_ms * f.vel_sigma_ms);
                let mut east = e.east.predict(dt, f.accel_var).update_position(ze, r_pos).0;
                let mut north = e.north.predict(dt, f.accel_var).update_position(zn, r_pos).0;
                if let Some((ve, vn)) = vel {
                    east = east.update_velocity(ve, r_vel).0;
                    north = north.update_velocity(vn, r_vel).0;
                }
                e.east = east;
                e.north = north;
                e.last_time_ms = time_ms;
                e.report = report;
                // Groups: a move is applied after the filter update.
                if e.group != group {
                    out.events.push(obj(vec![
                        ("ev", "move".into()),
                        ("entity", key.as_str().into()),
                        ("from", group_json(&e.group)),
                        ("to", group_json(&group)),
                    ]));
                    e.group = group;
                }
            }
        }
        out
    }

    // ---- tick (spec/fuse.md: On each tick, Fused event, Kinematics, Attributes, Trace)

    pub fn tick(&mut self, now_ms: i64) -> StepResult {
        let mut out = StepResult::default();
        self.drop_stale(now_ms, &mut out);
        for (group, keys) in self.groups_in_output_order() {
            self.fuse_group(&group, &keys, now_ms, &mut out);
        }
        out
    }

    /// Step 1, staleness, entities in key order.
    fn drop_stale(&mut self, now_ms: i64, out: &mut StepResult) {
        let pack_stale_ms = self.pack.stale_ms;
        let stale: Vec<String> = self
            .entities
            .iter()
            .filter(|(_, e)| {
                let report_stale = e.report.get("stale_ms").and_then(Json::as_i64).is_some_and(|s| now_ms >= s);
                now_ms - e.last_time_ms > pack_stale_ms || report_stale
            })
            .map(|(k, _)| k.clone())
            .collect();
        for key in stale {
            let e = self.entities.remove(&key).unwrap();
            out.events.push(obj(vec![("ev", "drop".into()), ("entity", key.as_str().into()), ("group", group_json(&e.group))]));
        }
    }

    /// Output order of groups: named groups in byte order of their name, then
    /// the unnamed groups in key order of their one member. Members in key order.
    fn groups_in_output_order(&self) -> Vec<(Option<String>, Vec<String>)> {
        let mut named: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let mut unnamed: Vec<(Option<String>, Vec<String>)> = Vec::new();
        for (key, e) in &self.entities {
            match &e.group {
                Some(g) => named.entry(g.clone()).or_default().push(key.clone()),
                None => unnamed.push((None, vec![key.clone()])),
            }
        }
        named.into_iter().map(|(g, keys)| (Some(g), keys)).chain(unnamed).collect()
    }

    /// Step 2 for one group: predict, combine, decide attributes, give `fused`.
    fn fuse_group(&self, group: &Option<String>, keys: &[String], now_ms: i64, out: &mut StepResult) {
        let q = self.pack.filter.accel_var;
        let unlisted_rank = self.pack.sources.len();
        let g = group_json(group);

        // 2.1 Predict every member's filter to now_ms.
        let members: Vec<Member> = keys
            .iter()
            .map(|key| {
                let e = &self.entities[key];
                let dt = (now_ms - e.last_time_ms) as f64 / 1000.0;
                Member {
                    key: key.clone(),
                    last_time_ms: e.last_time_ms,
                    rank: self.pack.rank(&e.source),
                    east: e.east.predict(dt, q),
                    north: e.north.predict(dt, q),
                    report: &e.report,
                }
            })
            .collect();

        // 2.2 Combine by the pack's kinematics method; trace `intersect` then `kinematics`.
        let combined = kinematics::combine(self.pack.kinematics, &g, &members, unlisted_rank);
        out.trace.extend(combined.trace);
        let from = combined.from.map(|i| members[i].key.as_str());
        let kin_candidates = members
            .iter()
            .map(|m| {
                obj(vec![
                    ("member", m.key.as_str().into()),
                    ("var", m.var().into()),
                    ("time_ms", m.last_time_ms.into()),
                    ("rank", rank_json(m.rank)),
                ])
            })
            .collect();
        out.trace.push(obj(vec![
            ("stage", "kinematics".into()),
            ("group", g.clone()),
            ("method", self.pack.kinematics.name().into()),
            ("candidates", Json::Arr(kin_candidates)),
            ("winner", from.map_or(Json::Null, Json::from)),
        ]));

        // 2.3 Decide every attribute, in pack order.
        let mut attrs = BTreeMap::new();
        for (key, rule) in &self.pack.attributes {
            let cands = attributes::candidates(&members, key, *rule);
            let won = attributes::winner(*rule, &cands, &members, unlisted_rank).map(|i| &cands[i]);
            let trace_cands = cands
                .iter()
                .map(|c| {
                    let m = &members[c.member];
                    obj(vec![
                        ("member", m.key.as_str().into()),
                        ("value", c.value.clone()),
                        ("time_ms", m.last_time_ms.into()),
                        ("rank", rank_json(m.rank)),
                    ])
                })
                .collect();
            out.trace.push(obj(vec![
                ("stage", "attribute".into()),
                ("group", g.clone()),
                ("key", key.as_str().into()),
                ("rule", rule.name().into()),
                ("candidates", Json::Arr(trace_cands)),
                ("winner", won.map_or(Json::Null, |c| members[c.member].key.as_str().into())),
                ("value", won.map_or(Json::Null, |c| c.value.clone())),
            ]));
            if let Some(c) = won {
                let value = obj(vec![("value", c.value.clone()), ("from", members[c.member].key.as_str().into())]);
                attrs.insert(key.clone(), value);
            }
        }

        // 2.4 The fused event.
        let est = combined.estimate;
        let frame = self.frame.expect("a group implies an accepted report");
        let (lat, lon) = frame.to_degrees(est.east.p, est.north.p);
        let mut course = deg(est.east.v.atan2(est.north.v));
        if course < 0.0 {
            course += 360.0;
        } else if course >= 360.0 {
            course -= 360.0;
        }
        let mut event = vec![
            ("ev", Json::from("fused")),
            ("group", g),
            ("members", Json::Arr(members.iter().map(|m| m.key.as_str().into()).collect())),
            ("from", from.map_or(Json::Null, Json::from)),
            ("lat", lat.into()),
            ("lon", lon.into()),
            ("course", course.into()),
            ("speed_ms", est.east.v.hypot(est.north.v).into()),
            ("ce", ((est.east.pp + est.north.pp) / 2.0).sqrt().into()),
            ("attributes", Json::Obj(attrs)),
        ];
        if let Some((hae, hae_from)) = self.height(&members, combined.from) {
            event.push(("hae", hae.into()));
            event.push(("hae_from", hae_from.into()));
        }
        out.events.push(obj(event));
    }

    /// Fused event, Height: from the kinematics member for `best`, `priority`,
    /// `latest`; otherwise the member with the greatest `last_time_ms` whose
    /// last report has `hae`, ties to key order.
    fn height<'m>(&self, members: &'m [Member], from: Option<usize>) -> Option<(f64, &'m str)> {
        let hae = |m: &'m Member| m.report.get("hae").and_then(Json::as_f64).map(|h| (h, m.key.as_str()));
        match from {
            Some(i) => hae(&members[i]),
            None => {
                let mut chosen: Option<&Member> = None;
                for m in members.iter().filter(|m| hae(m).is_some()) {
                    if chosen.is_none_or(|c| m.last_time_ms > c.last_time_ms) {
                        chosen = Some(m);
                    }
                }
                chosen.and_then(hae)
            }
        }
    }

    // ---- snapshot (spec/fuse.md: Snapshot)

    pub fn snapshot(&self) -> Json {
        let reference = self.frame.map_or(Json::Null, |f| Json::Arr(vec![f.lat0.into(), f.lon0.into()]));
        let entities = self
            .entities
            .iter()
            .map(|(key, e)| {
                let axis = |a: &Axis| Json::Arr(a.as_list().iter().map(|x| Json::Num(*x)).collect());
                let filter = obj(vec![("east", axis(&e.east)), ("north", axis(&e.north))]);
                let entity = obj(vec![
                    ("last_time_ms", e.last_time_ms.into()),
                    ("group", group_json(&e.group)),
                    ("filter", filter),
                    ("report", Json::Obj(e.report.clone())),
                ]);
                (key.clone(), entity)
            })
            .collect();
        obj(vec![("ref", reference), ("entities", Json::Obj(entities))])
    }
}
