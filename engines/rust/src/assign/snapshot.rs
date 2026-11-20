//! correlate-assign.md Snapshot.

use super::system_name;
use crate::correlate::{filter_json, Engine};
use crate::model::{obj, Json};

impl Engine {

    // ---- Snapshot

    pub(crate) fn snapshot_assign(&self) -> Json {
        let entities = self
            .entities
            .iter()
            .map(|(k, e)| {
                let mut pairs = vec![("last_time_ms", e.last_time_ms.into()), ("system", e.system.map_or(Json::Null, |s| system_name(s).into()))];
                pairs.extend(filter_json(e));
                (k.clone(), obj(pairs))
            })
            .collect();
        let mut pairs = vec![
            ("ref", self.reference_json()),
            ("entities", Json::Obj(entities)),
            ("systems", self.committed.systems_json()),
            ("next_system", Json::Int(self.committed.next_system as i64)),
            ("reported", Json::Arr(self.reported.iter().map(|k| k.as_str().into()).collect())),
        ];
        if self.pack.restart.is_some() {
            pairs.push(("restarted", Json::Arr(self.restarted.iter().map(|k| k.as_str().into()).collect())));
        }
        if self.pack.bias.is_some() {
            pairs.push(("bias", Json::Obj(self.bias.iter().map(|(k, b)| (k.clone(), b.json(self.pack.time_offset.is_some()))).collect())));
        }
        if self.pack.window > 1 {
            let histories = self
                .histories
                .iter()
                .map(|h| {
                    let records = h
                        .records
                        .iter()
                        .map(|r| {
                            obj(vec![
                                ("cost", r.cost.into()),
                                ("choices", Json::Arr(r.choices.iter().map(|(a, c)| Json::Arr(vec![a.as_str().into(), c.as_str().into()])).collect())),
                                ("events", Json::Arr(r.events.clone())),
                                ("systems", r.membership.systems_json()),
                                ("next_system", Json::Int(r.membership.next_system as i64)),
                            ])
                        })
                        .collect();
                    obj(vec![("total", h.total().into()), ("records", Json::Arr(records))])
                })
                .collect();
            pairs.push(("retiring", Json::Arr(self.retiring.iter().map(|k| k.as_str().into()).collect())));
            pairs.push(("histories", Json::Arr(histories)));
        }
        obj(pairs)
    }
}
