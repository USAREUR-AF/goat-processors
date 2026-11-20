//! Pack values shared by more than one function: the `filter` parameters
//! (correlate.md Track estimate, used by fuse and quality), `time_default`
//! (correlate.md Pack, Time quality, used by quality), and reading
//! `<dir>/pack.def`.

use std::path::Path;

/// Reads `<dir>/pack.def` (every function's `load_pack`).
pub fn read_pack_def(dir: &Path) -> Result<String, String> {
    std::fs::read_to_string(dir.join("pack.def")).map_err(|e| format!("{}: {}", dir.display(), e))
}

#[derive(Debug, Clone, PartialEq)]
pub struct FilterParams {
    pub accel_var: f64,
    pub default_ce_m: f64,
    pub vel_sigma_ms: f64,
    pub unknown_vel_ms: f64,
}

/// The state of a clock (spec: correlate.md Reports, Time quality).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TimeState {
    Coherent,
    Drifting,
    FreeRunning,
}

impl TimeState {
    /// One of `coherent`, `drifting`, `free-running`, compared byte for byte.
    pub fn parse(s: &str) -> Option<TimeState> {
        match s {
            "coherent" => Some(TimeState::Coherent),
            "drifting" => Some(TimeState::Drifting),
            "free-running" => Some(TimeState::FreeRunning),
            _ => None,
        }
    }

    /// The state as written in a report or a pack.
    pub fn name(self) -> &'static str {
        match self {
            TimeState::Coherent => "coherent",
            TimeState::Drifting => "drifting",
            TimeState::FreeRunning => "free-running",
        }
    }
}

/// One `time_default <source_id> error_ms=<ms> state=<state>` line (spec:
/// correlate.md Pack, Time quality); either key may be absent, not both.
#[derive(Debug, Clone, PartialEq)]
pub struct TimeDefault {
    pub error_ms: Option<f64>,
    pub state: Option<TimeState>,
}

/// The values of one `time_default` line (correlate.md 0.8 Pack): a source
/// id (a first token without `=`), then `error_ms` (a number 0 or above),
/// `state` (one of the three states) or both, each at most once. `number`
/// reads `error_ms` with the calling function's own number grammar. The
/// caller checks that no earlier line gave the same source id. Shared with
/// the quality function (quality.md 0.2 Pack).
pub fn parse_time_default(args: &[&str], number: fn(&str) -> Result<f64, String>) -> Result<(String, TimeDefault), String> {
    let (source, params) = match args.split_first() {
        Some((s, rest)) if !s.contains('=') => (*s, rest),
        _ => return Err("time_default needs a source id".to_string()),
    };
    let mut d = TimeDefault { error_ms: None, state: None };
    for a in params {
        let (k, v) = a.split_once('=').ok_or_else(|| format!("parameter without '=': {:?}", a))?;
        match k {
            "error_ms" if d.error_ms.is_none() => {
                let ms = number(v)?;
                if !(ms >= 0.0) {
                    return Err("time_default error_ms must be 0 or above".to_string());
                }
                d.error_ms = Some(ms);
            }
            "state" if d.state.is_none() => {
                d.state = Some(TimeState::parse(v).ok_or_else(|| format!("unknown time state: {:?}", v))?);
            }
            _ => return Err(format!("unknown or repeated time_default parameter: {:?}", k)),
        }
    }
    if d.error_ms.is_none() && d.state.is_none() {
        return Err("time_default needs error_ms, state or both".to_string());
    }
    Ok((source.to_string(), d))
}


#[cfg(test)]
mod tests {
    use super::*;

    fn number(s: &str) -> Result<f64, String> {
        s.parse::<f64>().map_err(|e| e.to_string())
    }

    #[test]
    fn time_default_grammar() {
        let (s, d) = parse_time_default(&["radar", "error_ms=250", "state=free-running"], number).unwrap();
        assert_eq!((s.as_str(), d.error_ms, d.state), ("radar", Some(250.0), Some(TimeState::FreeRunning)));
        let (_, d) = parse_time_default(&["radar", "state=coherent"], number).unwrap();
        assert_eq!((d.error_ms, d.state.map(TimeState::name)), (None, Some("coherent")));
        for bad in [
            &["error_ms=1"][..],
            &["radar"],
            &["radar", "error_ms=-1"],
            &["radar", "error_ms=1", "error_ms=2"],
            &["radar", "state=late"],
            &["radar", "noise"],
            &["radar", "other=1"],
            &[],
        ] {
            assert!(parse_time_default(bad, number).is_err(), "{:?}", bad);
        }
    }

    #[test]
    fn read_pack_def_names_the_directory() {
        let e = read_pack_def(Path::new("/nonexistent-goat-pack")).unwrap_err();
        assert!(e.starts_with("/nonexistent-goat-pack"), "{}", e);
    }
}
