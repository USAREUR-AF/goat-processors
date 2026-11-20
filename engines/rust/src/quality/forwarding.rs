//! quality.md Forwarding: the `pass` event, with the report as forwarded.

use super::*;

impl Engine {
    /// Spec Forwarding: the `pass` event.
    pub(super) fn forward(&self, key: &str, source: &str, fields: &BTreeMap<String, Json>, valid_ce: Option<f64>) -> Json {
        let actions: Vec<&Rule> =
            self.pack.rules.iter().filter(|r| r.action != Action::Alert && self.in_force(r, key, source)).collect();
        let names = Json::Arr(actions.iter().map(|r| r.name.as_str().into()).collect());
        let mut pass = vec![("ev", "pass".into()), ("entity", key.into()), ("rules", names)];

        if actions.iter().any(|r| r.action == Action::Drop) {
            pass.push(("withheld", true.into()));
            return obj(pass);
        }

        let mut report = fields.clone();
        let downgrades: Vec<f64> =
            actions.iter().filter_map(|r| if let Action::Downgrade(f) = r.action { Some(f) } else { None }).collect();
        if !downgrades.is_empty() {
            let mut x = valid_ce.unwrap_or(self.pack.filter.default_ce_m);
            for factor in downgrades {
                x *= factor;
            }
            // An overflow to infinity is forwarded as the largest finite
            // binary64.
            if x.is_infinite() {
                x = f64::MAX;
            }
            report.insert("ce".into(), Json::Num(x));
        }
        let marks: Vec<&str> = actions.iter().filter(|r| r.action == Action::Mark).map(|r| r.name.as_str()).collect();
        if !marks.is_empty() {
            let mut list: Vec<Json> = match fields.get("quality.marks") {
                Some(Json::Arr(items)) if items.iter().all(|i| matches!(i, Json::Str(_))) => items.clone(),
                _ => Vec::new(),
            };
            for name in marks {
                if !list.iter().any(|m| m.as_str() == Some(name)) {
                    list.push(name.into());
                }
            }
            report.insert("quality.marks".into(), Json::Arr(list));
        }
        pass.push(("withheld", false.into()));
        pass.push(("report", Json::Obj(report)));
        obj(pass)
    }

    // ---- Tick --------------------------------------------------------------
}
