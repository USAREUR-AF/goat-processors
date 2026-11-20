//! fuse.md Snapshot.

use super::*;

impl Engine {
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
                (key.into(), entity)
            })
            .collect();
        obj(vec![("ref", reference), ("entities", Json::Obj(entities))])
    }
}
