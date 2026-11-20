//! The JSON forms every function's Snapshot section shares: a filter axis as
//! `[p, v, pp, pv, vv]`, a two-axis filter, the reference point, optional
//! values as `null`. Each function's own `snapshot()` builds its document
//! from these (correlate.md, correlate-assign.md, filter.md, fuse.md and
//! quality.md, Snapshot).
//!
//! The engines have no restore: a snapshot is an observation of the state,
//! never read back.

use crate::model::{obj, Axis, Frame, Json, Model};

/// One filter axis: `[p, v, pp, pv, vv]`.
pub fn axis(a: &Axis) -> Json {
    Json::Arr(a.as_list().iter().map(|x| Json::Num(*x)).collect())
}

/// Both axes: `{"east": [...], "north": [...]}`.
pub fn model(m: &Model) -> Json {
    obj(vec![("east", axis(&m.east)), ("north", axis(&m.north))])
}

/// The reference point `[lat0, lon0]`, `null` before the first accepted report.
pub fn reference(frame: Option<Frame>) -> Json {
    frame.map_or(Json::Null, |f| Json::Arr(vec![f.lat0.into(), f.lon0.into()]))
}

/// An optional integer, `null` when absent.
pub fn opt_int(v: Option<i64>) -> Json {
    v.map(Json::Int).unwrap_or(Json::Null)
}

/// An optional number, `null` when absent.
pub fn opt_num(v: Option<f64>) -> Json {
    v.map(Json::Num).unwrap_or(Json::Null)
}

/// A list of strings.
pub fn names<'a>(items: impl IntoIterator<Item = &'a String>) -> Json {
    Json::Arr(items.into_iter().map(|s| Json::from(s.as_str())).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_forms() {
        let a = Axis { p: 1.0, v: 2.0, pp: 3.0, pv: 4.0, vv: 5.0 };
        assert_eq!(axis(&a).to_string(), "[1.0,2.0,3.0,4.0,5.0]");
        assert_eq!(model(&Model { east: a, north: a }).get("north"), Some(&axis(&a)));
        assert_eq!(reference(None), Json::Null);
        assert_eq!(reference(Some(Frame { lat0: 1.0, lon0: -2.0 })).to_string(), "[1.0,-2.0]");
        assert_eq!((opt_int(None), opt_int(Some(3))), (Json::Null, Json::Int(3)));
        assert_eq!((opt_num(None), opt_num(Some(0.5))), (Json::Null, Json::Num(0.5)));
        assert_eq!(names(&["x".to_string()]).to_string(), r#"["x"]"#);
    }
}
