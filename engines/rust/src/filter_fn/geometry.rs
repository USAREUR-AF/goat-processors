//! spec/filter.md, Geometry: distance, polygon, reference prediction.
//!
//! `R`, `rad`, `deg` and `wrap` are the correlate engine's own (src/filter.rs).

use crate::filter::{deg, rad, wrap180 as wrap, R};

/// Distance (haversine) from point 1 to point 2, in meters, in the spec's order.
pub fn distance(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    // 1.
    let p1 = rad(lat1);
    let p2 = rad(lat2);
    let dp = rad(lat2 - lat1);
    let dl = rad(wrap(lon2 - lon1));
    // 2.
    let s1 = (dp / 2.0).sin();
    let s2 = (dl / 2.0).sin();
    // 3. second term left to right: ((cos(p1) * cos(p2)) * s2) * s2
    let h = s1 * s1 + p1.cos() * p2.cos() * s2 * s2;
    // 4.
    (2.0 * R) * h.sqrt().min(1.0).asin()
}

/// Result of the polygon test.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Place {
    Boundary,
    Inside,
    Outside,
}

impl Place {
    pub fn name(self) -> &'static str {
        match self {
            Place::Boundary => "boundary",
            Place::Inside => "inside",
            Place::Outside => "outside",
        }
    }
}

/// Polygon: where the report (`lat`, `lon`) lies against `vertices`
/// (`(lat_i, lon_i)` in pack order), on the flat plane x = longitude,
/// y = latitude, every longitude taken to within 180 degrees of vertex 0.
pub fn polygon(vertices: &[(f64, f64)], lat: f64, lon: f64) -> Place {
    let lon0 = vertices[0].1;
    let pts: Vec<(f64, f64)> = vertices
        .iter()
        .enumerate()
        .map(|(i, &(lat_i, lon_i))| if i == 0 { (lon0, lat_i) } else { (lon0 + wrap(lon_i - lon0), lat_i) })
        .collect();
    let (px, py) = (lon0 + wrap(lon - lon0), lat);
    let n = pts.len();

    // 1. Boundary.
    for i in 0..n {
        let ((xi, yi), (xj, yj)) = (pts[i], pts[(i + 1) % n]);
        let c = (xj - xi) * (py - yi) - (yj - yi) * (px - xi);
        if c == 0.0 && xi.min(xj) <= px && px <= xi.max(xj) && yi.min(yj) <= py && py <= yi.max(yj) {
            return Place::Boundary;
        }
    }

    // 2. Crossings (even-odd rule).
    let mut inside = false;
    for i in 0..n {
        let ((xi, yi), (xj, yj)) = (pts[i], pts[(i + 1) % n]);
        if (yi > py) != (yj > py) {
            let xc = (xj - xi) * (py - yi) / (yj - yi) + xi;
            if px < xc {
                inside = !inside;
            }
        }
    }
    if inside {
        Place::Inside
    } else {
        Place::Outside
    }
}

/// Reference prediction: the position `(lat_p, lon_p)` of a reference stored
/// at `time_ms`, `lat`, `lon` with optional `course`, `speed_ms`, at time `t`.
pub fn predict(time_ms: i64, lat: f64, lon: f64, course: Option<f64>, speed_ms: Option<f64>, t: i64) -> (f64, f64) {
    // 1. May be negative.
    let dt = (t as i128 - time_ms as i128) as f64 / 1000.0;
    // 2.
    let (dn, de) = match (course, speed_ms) {
        (Some(c), Some(s)) => (s * rad(c).cos() * dt, s * rad(c).sin() * dt),
        _ => (0.0, 0.0),
    };
    // 3.
    let lat_p = lat + deg(dn / R);
    let lon_p = wrap(lon + deg(de / (R * rad(lat).cos())));
    (lat_p, lon_p)
}
