//! correlate.md Pack and correlate-assign.md Pack: `load_pack(dir)` and
//! `parse_pack(text)`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

pub use super::method::MethodKind;
pub(crate) use super::pair_tests::parse_test;
pub use super::pair_tests::Test;
pub use super::registry::Registry;
pub use crate::model::pack::{parse_time_default, FilterParams, TimeDefault, TimeState};

/// The `maneuver` directive (spec: correlate.md Two-model filter).
#[derive(Debug, Clone, PartialEq)]
pub struct Maneuver {
    /// `q2`, the maneuver model's acceleration variance.
    pub accel_var: f64,
    /// `a`, per second, quiet to maneuver.
    pub p_enter: f64,
    /// `b`, per second, maneuver to quiet.
    pub p_leave: f64,
}

/// The `bias` directive (spec: correlate-assign.md Sensor bias).
#[derive(Debug, Clone, PartialEq)]
pub struct Bias {
    /// `s`: the offset's standard deviation before any accepted pair, m.
    pub sigma_m: f64,
    /// `f`: the least standard deviation the offset's variance falls to, m.
    pub floor_m: f64,
    /// `g`: a pair is accepted while its `d²` is below this.
    pub gate: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Output {
    Priority,
    Latest,
}

#[derive(Debug, Clone)]
pub struct Pack {
    pub name: String,
    /// The `method` line's kind (`super::method`), `confirm` by default.
    pub method: MethodKind,
    pub version: String,
    pub filter: FilterParams,
    /// Present when the pack has the `maneuver` directive.
    pub maneuver: Option<Maneuver>,
    /// `restart gate=<g>` (spec: correlate.md Restart), with either method.
    pub restart: Option<f64>,
    pub gate: Vec<Test>,
    pub confirm: Vec<Test>,
    pub hold: Vec<Test>,
    pub confirm_count: u64,
    pub hold_failures: u64,
    pub stale_ms: i64,
    pub same_source_allow: bool,
    pub output: Output,
    /// `(source_id, priority)` in pack order.
    pub priority: Vec<(String, i64)>,
    /// `method assign` only: cost of a track's own *alone* entry.
    pub new_cost: f64,
    /// `method assign` only: subtracted from the entry of the current choice.
    pub keep_bonus: f64,
    /// `method assign` only: `window <n>`, ticks a history spans (default 1).
    pub window: usize,
    /// `method assign` only: `hypotheses <k>`, histories kept (default 1).
    pub hypotheses: usize,
    /// `method assign` only: `bias` (correlate-assign.md Sensor bias).
    pub bias: Option<Bias>,
    /// `method assign` only: `margin <m>` (correlate-assign.md Window).
    pub margin: Option<f64>,
    /// `time_default` lines by source id (correlate.md Pack), with either method.
    pub time_default: BTreeMap<String, TimeDefault>,
    /// `method assign` only: `time_offset sigma_ms=<t>`, the prior standard
    /// deviation of a pair's clock offset in ms (correlate-assign.md Sensor
    /// bias, Time offset).
    pub time_offset: Option<f64>,
}

impl Pack {
    /// The source's priority number; 100 for a source the pack does not list.
    pub fn priority_of(&self, source: &str) -> i64 {
        self.priority.iter().find(|(s, _)| s == source).map(|(_, n)| *n).unwrap_or(100)
    }
}

/// `load_pack(dir)`: reads `<dir>/pack.def`.
pub fn load_pack(dir: &Path) -> Result<Pack, String> {
    parse_pack(&crate::model::pack::read_pack_def(dir)?)
}

/// A decimal number: optional sign, digits, optional fraction.
fn decimal(s: &str) -> Result<f64, String> {
    let body = s.strip_prefix(['-', '+']).unwrap_or(s);
    let (int, frac) = match body.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (body, None),
    };
    let digits = |t: &str| !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit());
    let ok = match frac {
        None => digits(int),
        Some(f) => (digits(int) || int.is_empty()) && digits(f),
    };
    if !ok {
        return Err(format!("not a decimal number: {:?}", s));
    }
    s.parse::<f64>().map_err(|_| format!("not a decimal number: {:?}", s))
}

fn integer(s: &str) -> Result<i64, String> {
    let body = s.strip_prefix(['-', '+']).unwrap_or(s);
    if body.is_empty() || !body.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("not an integer: {:?}", s));
    }
    s.parse::<i64>().map_err(|_| format!("not an integer: {:?}", s))
}

fn count(s: &str) -> Result<u64, String> {
    let n = integer(s)?;
    u64::try_from(n).map_err(|_| format!("negative count: {:?}", s))
}

/// An integer 1 or above (`window`, `hypotheses`).
fn positive(s: &str) -> Result<usize, String> {
    match count(s)? {
        0 => Err(format!("must be 1 or above: {:?}", s)),
        n => usize::try_from(n).map_err(|_| format!("too large: {:?}", s)),
    }
}

fn semver(s: &str) -> Result<String, String> {
    let core = s.split(['-', '+']).next().unwrap_or("");
    let parts: Vec<&str> = core.split('.').collect();
    if parts.len() != 3 || !parts.iter().all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())) {
        return Err(format!("not a semver: {:?}", s));
    }
    Ok(s.to_string())
}

/// `name=value` parameters of a test line; each named exactly once, no others.
pub struct Params(BTreeMap<String, String>);

impl Params {
    pub(crate) fn parse(args: &[&str], allowed: &[&str]) -> Result<Params, String> {
        let mut m = BTreeMap::new();
        for a in args {
            let (k, v) = a.split_once('=').ok_or_else(|| format!("parameter without '=': {:?}", a))?;
            if !allowed.contains(&k) {
                return Err(format!("unknown parameter: {:?}", k));
            }
            if m.insert(k.to_string(), v.to_string()).is_some() {
                return Err(format!("repeated parameter: {:?}", k));
            }
        }
        for k in allowed {
            if !m.contains_key(*k) {
                return Err(format!("missing parameter: {:?}", k));
            }
        }
        Ok(Params(m))
    }

    /// A decimal parameter. `k` is one of the kind's declared parameters.
    pub fn num(&self, k: &str) -> Result<f64, String> {
        decimal(&self.0[k])
    }

    /// A non-empty string parameter. `k` is one of the kind's declared parameters.
    pub fn string(&self, k: &str) -> Result<String, String> {
        let v = &self.0[k];
        if v.is_empty() {
            return Err(format!("empty parameter: {:?}", k));
        }
        Ok(v.clone())
    }
}

fn one_arg<'a>(directive: &str, args: &[&'a str]) -> Result<&'a str, String> {
    match args {
        [a] => Ok(a),
        _ => Err(format!("{} takes one value", directive)),
    }
}

/// Parses the text of a `pack.def` with the spec's tests and methods.
pub fn parse_pack(text: &str) -> Result<Pack, String> {
    parse_pack_with(text, &Registry::builtin())
}

/// Every value a `pack.def` gave, before the method checks and completes it.
pub(crate) struct Draft {
    pub(crate) name: Option<String>,
    pub(crate) version: Option<String>,
    pub(crate) filter: FilterParams,
    pub(crate) maneuver: Option<Maneuver>,
    pub(crate) restart: Option<f64>,
    pub(crate) gate: Vec<Test>,
    pub(crate) confirm: Vec<Test>,
    pub(crate) hold: Vec<Test>,
    pub(crate) confirm_count: Option<u64>,
    pub(crate) hold_failures: Option<u64>,
    pub(crate) stale_ms: Option<i64>,
    pub(crate) same_source_allow: bool,
    pub(crate) output: Output,
    pub(crate) priority: Vec<(String, i64)>,
    pub(crate) method: MethodKind,
    pub(crate) new_cost: Option<f64>,
    pub(crate) keep_bonus: Option<f64>,
    pub(crate) window: Option<usize>,
    pub(crate) hypotheses: Option<usize>,
    pub(crate) bias: Option<Bias>,
    pub(crate) margin: Option<f64>,
    pub(crate) time_default: BTreeMap<String, TimeDefault>,
    pub(crate) time_offset: Option<f64>,
}

fn need(what: &str) -> String {
    format!("missing required directive: {}", what)
}

/// Parses the text of a `pack.def` with the tests and methods of `registry`.
pub fn parse_pack_with(text: &str, registry: &Registry) -> Result<Pack, String> {
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut name = None;
    let mut version = None;
    let mut filter = None;
    let mut gate = Vec::new();
    let mut confirm = Vec::new();
    let mut hold = Vec::new();
    let mut confirm_count = None;
    let mut hold_failures = None;
    let mut stale_ms = None;
    let mut same_source_allow = false;
    let mut output = Output::Priority;
    let mut priority: Vec<(String, i64)> = Vec::new();
    let mut method = registry.method("confirm").expect("the confirm method is registered");
    let mut new_cost = None;
    let mut keep_bonus = None;
    let mut maneuver = None;
    let mut window = None;
    let mut hypotheses = None;
    let mut restart = None;
    let mut bias = None;
    let mut margin = None;
    let mut time_default: BTreeMap<String, TimeDefault> = BTreeMap::new();
    let mut time_offset = None;

    for (lineno, raw) in text.lines().enumerate() {
        let line = raw.split('#').next().unwrap_or("");
        let words: Vec<&str> = line.split_whitespace().collect();
        let Some((directive, args)) = words.split_first() else { continue };
        let directive = *directive;
        let at = |e: String| format!("line {}: {}", lineno + 1, e);

        let repeats = matches!(directive, "gate" | "confirm" | "hold" | "priority" | "time_default");
        if !repeats && !seen.insert(directive.to_string()) {
            return Err(at(format!("repeated directive: {}", directive)));
        }
        seen.insert(directive.to_string());
        match directive {
            "method" => {
                let v = one_arg(directive, args).map_err(at)?;
                method = registry.method(v).ok_or_else(|| at(format!("unknown method: {:?}", v)))?;
            }
            "new_cost" => new_cost = Some(decimal(one_arg(directive, args).map_err(at)?).map_err(at)?),
            "keep_bonus" => keep_bonus = Some(decimal(one_arg(directive, args).map_err(at)?).map_err(at)?),
            "pack" => name = Some(one_arg(directive, args).map_err(at)?.to_string()),
            "version" => version = Some(semver(one_arg(directive, args).map_err(at)?).map_err(at)?),
            "filter" => {
                let p = Params::parse(args, &["accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"]).map_err(at)?;
                let f = FilterParams {
                    accel_var: p.num("accel_var").map_err(at)?,
                    default_ce_m: p.num("default_ce_m").map_err(at)?,
                    vel_sigma_ms: p.num("vel_sigma_ms").map_err(at)?,
                    unknown_vel_ms: p.num("unknown_vel_ms").map_err(at)?,
                };
                // correlate.md 0.4: three above 0, accel_var 0 or above.
                for (k, v) in [("default_ce_m", f.default_ce_m), ("vel_sigma_ms", f.vel_sigma_ms), ("unknown_vel_ms", f.unknown_vel_ms)] {
                    if !(v > 0.0) {
                        return Err(at(format!("filter {} must be above 0", k)));
                    }
                }
                if !(f.accel_var >= 0.0) {
                    return Err(at("filter accel_var must be 0 or above".to_string()));
                }
                filter = Some(f);
            }
            "maneuver" => {
                let p = Params::parse(args, &["accel_var", "p_enter", "p_leave"]).map_err(at)?;
                let m = Maneuver { accel_var: p.num("accel_var").map_err(at)?, p_enter: p.num("p_enter").map_err(at)?, p_leave: p.num("p_leave").map_err(at)? };
                // p_enter and p_leave above 0 with a sum below 1; accel_var is
                // checked against filter's once the whole file is read.
                if !(m.p_enter > 0.0 && m.p_leave > 0.0 && m.p_enter + m.p_leave < 1.0) {
                    return Err(at("maneuver p_enter and p_leave must be above 0 with a sum below 1".to_string()));
                }
                maneuver = Some(m);
            }
            "restart" => {
                // correlate.md 0.7 Restart: exactly `gate`, above 0.
                let p = Params::parse(args, &["gate"]).map_err(at)?;
                let g = p.num("gate").map_err(at)?;
                if !(g > 0.0) {
                    return Err(at("restart gate must be above 0".to_string()));
                }
                restart = Some(g);
            }
            "bias" => {
                // correlate-assign.md 0.5 Sensor bias: sigma_m and gate above 0,
                // floor_m above 0 and at most sigma_m.
                let p = Params::parse(args, &["sigma_m", "floor_m", "gate"]).map_err(at)?;
                let b = Bias { sigma_m: p.num("sigma_m").map_err(at)?, floor_m: p.num("floor_m").map_err(at)?, gate: p.num("gate").map_err(at)? };
                if !(b.sigma_m > 0.0 && b.gate > 0.0 && b.floor_m > 0.0 && b.floor_m <= b.sigma_m) {
                    return Err(at("bias needs sigma_m and gate above 0, floor_m above 0 and at most sigma_m".to_string()));
                }
                bias = Some(b);
            }
            "time_default" => {
                let (source, d) = parse_time_default(args, decimal).map_err(at)?;
                if time_default.insert(source, d).is_some() {
                    return Err(at("a second time_default for the same source".to_string()));
                }
            }
            "time_offset" => {
                // correlate-assign.md 0.6 Sensor bias, Time offset: exactly
                // `sigma_ms`, above 0; it needs `bias` (checked at the end).
                let p = Params::parse(args, &["sigma_ms"]).map_err(at)?;
                let t = p.num("sigma_ms").map_err(at)?;
                if !(t > 0.0) {
                    return Err(at("time_offset sigma_ms must be above 0".to_string()));
                }
                time_offset = Some(t);
            }
            "margin" => {
                // correlate-assign.md 0.5 Window: one number above 0.
                let m = decimal(one_arg(directive, args).map_err(at)?).map_err(at)?;
                if !(m > 0.0) {
                    return Err(at("margin must be above 0".to_string()));
                }
                margin = Some(m);
            }
            "window" => window = Some(positive(one_arg(directive, args).map_err(at)?).map_err(at)?),
            "hypotheses" => hypotheses = Some(positive(one_arg(directive, args).map_err(at)?).map_err(at)?),
            "gate" => gate.push(parse_test(args, &registry.tests).map_err(at)?),
            "confirm" => confirm.push(parse_test(args, &registry.tests).map_err(at)?),
            "hold" => hold.push(parse_test(args, &registry.tests).map_err(at)?),
            "confirm_count" => confirm_count = Some(count(one_arg(directive, args).map_err(at)?).map_err(at)?),
            "hold_failures" => hold_failures = Some(count(one_arg(directive, args).map_err(at)?).map_err(at)?),
            "stale_ms" => stale_ms = Some(integer(one_arg(directive, args).map_err(at)?).map_err(at)?),
            "same_source" => {
                same_source_allow = match one_arg(directive, args).map_err(at)? {
                    "forbid" => false,
                    "allow" => true,
                    v => return Err(at(format!("same_source must be forbid or allow, not {:?}", v))),
                }
            }
            "output" => {
                output = match one_arg(directive, args).map_err(at)? {
                    "priority" => Output::Priority,
                    "latest" => Output::Latest,
                    v => return Err(at(format!("output must be priority or latest, not {:?}", v))),
                }
            }
            "priority" => match args {
                [source, n] => priority.push((source.to_string(), integer(n).map_err(at)?)),
                _ => return Err(at("priority takes <source_id> <n>".to_string())),
            },
            other => return Err(at(format!("unknown directive: {:?}", other))),
        }
    }

    let filter = filter.ok_or_else(|| need("filter"))?;
    if let Some(m) = &maneuver {
        if !(m.accel_var > filter.accel_var) {
            return Err("maneuver accel_var must be above filter accel_var".to_string());
        }
    }
    if let Some(d) = method.refuses.iter().find(|d| seen.contains(**d)) {
        return Err(format!("directive {} is not allowed with method {}", d, method.name));
    }
    (method.finish)(Draft {
        name,
        version,
        filter,
        maneuver,
        restart,
        gate,
        confirm,
        hold,
        confirm_count,
        hold_failures,
        stale_ms,
        same_source_allow,
        output,
        priority,
        method,
        new_cost,
        keep_bonus,
        window,
        hypotheses,
        bias,
        margin,
        time_default,
        time_offset,
    })
}

/// `method confirm`: `confirm_count`, `hold_failures` and `stale_ms` are
/// required; the assign directives take their defaults.
pub(crate) fn finish_confirm(d: Draft) -> Result<Pack, String> {
    Ok(Pack {
        method: d.method,
        new_cost: 0.0,
        keep_bonus: 0.0,
        window: 1,
        hypotheses: 1,
        bias: None,
        margin: None,
        time_default: d.time_default,
        time_offset: None,
        name: d.name.ok_or_else(|| need("pack"))?,
        version: d.version.ok_or_else(|| need("version"))?,
        filter: d.filter,
        maneuver: d.maneuver,
        restart: d.restart,
        gate: d.gate,
        confirm: d.confirm,
        hold: d.hold,
        confirm_count: d.confirm_count.ok_or_else(|| need("confirm_count"))?,
        hold_failures: d.hold_failures.ok_or_else(|| need("hold_failures"))?,
        stale_ms: d.stale_ms.ok_or_else(|| need("stale_ms"))?,
        same_source_allow: d.same_source_allow,
        output: d.output,
        priority: d.priority,
    })
}

/// `method assign` (correlate-assign.md Pack): `new_cost` above 0,
/// `keep_bonus` 0 or above, both required; `hypotheses` above 1 needs
/// `window` above 1; `margin` needs `hypotheses` above 1; `time_offset`
/// needs `bias`.
pub(crate) fn finish_assign(d: Draft) -> Result<Pack, String> {
    // correlate-assign.md 0.2: new_cost above 0, keep_bonus 0 or above.
    if let Some(c) = d.new_cost {
        if !(c > 0.0) {
            return Err("new_cost must be above 0".to_string());
        }
    }
    // correlate-assign.md 0.4: hypotheses above 1 needs window above 1.
    let (window, hypotheses) = (d.window.unwrap_or(1), d.hypotheses.unwrap_or(1));
    if hypotheses > 1 && window == 1 {
        return Err("hypotheses above 1 needs window above 1".to_string());
    }
    // correlate-assign.md 0.5: margin needs hypotheses above 1.
    if d.margin.is_some() && hypotheses == 1 {
        return Err("margin needs hypotheses above 1".to_string());
    }
    // correlate-assign.md 0.6: time_offset needs bias.
    if d.time_offset.is_some() && d.bias.is_none() {
        return Err("time_offset needs bias".to_string());
    }
    if let Some(b) = d.keep_bonus {
        if !(b >= 0.0) {
            return Err("keep_bonus must be 0 or above".to_string());
        }
    }
    Ok(Pack {
        name: d.name.ok_or_else(|| need("pack"))?,
        method: d.method,
        version: d.version.ok_or_else(|| need("version"))?,
        filter: d.filter,
        maneuver: d.maneuver,
        restart: d.restart,
        gate: d.gate,
        confirm: d.confirm,
        hold: d.hold,
        confirm_count: 0,
        hold_failures: 0,
        stale_ms: d.stale_ms.ok_or_else(|| need("stale_ms"))?,
        same_source_allow: d.same_source_allow,
        output: d.output,
        priority: d.priority,
        new_cost: d.new_cost.ok_or_else(|| need("new_cost"))?,
        keep_bonus: d.keep_bonus.ok_or_else(|| need("keep_bonus"))?,
        window,
        hypotheses,
        bias: d.bias,
        margin: d.margin,
        time_default: d.time_default,
        time_offset: d.time_offset,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = "pack p\nversion 0.1.0\nfilter accel_var=1 default_ce_m=50 vel_sigma_ms=5 unknown_vel_ms=100\nstale_ms 1000\n";

    fn confirm(extra: &str) -> Result<Pack, String> {
        parse_pack(&format!("{}confirm_count 2\nhold_failures 1\n{}", BASE, extra))
    }

    fn assign(extra: &str) -> Result<Pack, String> {
        parse_pack(&format!("{}method assign\nnew_cost 9\nkeep_bonus 1\n{}", BASE, extra))
    }

    #[test]
    fn the_method_line_picks_a_registered_method() {
        assert_eq!(confirm("").unwrap().method.name, "confirm");
        let p = assign("gate mahalanobis gate=9 # comment\n").unwrap();
        assert_eq!((p.method.name, p.window, p.hypotheses, p.gate.len()), ("assign", 1, 1, 1));
        assert_eq!(p.gate[0].name(), "mahalanobis");
        assert!(assign("method assign\n").unwrap_err().contains("repeated"));
        assert!(parse_pack(&format!("{}method vote\n", BASE)).unwrap_err().contains("unknown method"));
    }

    #[test]
    fn each_method_refuses_the_others_directives() {
        assert!(confirm("new_cost 3\n").unwrap_err().contains("not allowed with method confirm"));
        assert!(assign("hold mahalanobis gate=9\n").unwrap_err().contains("not allowed with method assign"));
        assert!(assign("priority radar 1\n").is_err());
    }

    #[test]
    fn assign_checks() {
        assert!(assign("hypotheses 2\n").unwrap_err().contains("needs window"));
        assert!(assign("window 2\nmargin 1\n").unwrap_err().contains("margin needs"));
        assert!(assign("time_offset sigma_ms=10\n").unwrap_err().contains("needs bias"));
        let p = assign("window 3\nhypotheses 2\nmargin 0.5\nbias sigma_m=5 floor_m=1 gate=9\ntime_offset sigma_ms=10\n").unwrap();
        assert_eq!((p.window, p.hypotheses, p.margin, p.time_offset), (3, 2, Some(0.5), Some(10.0)));
        assert!(parse_pack(&format!("{}method assign\nnew_cost 0\nkeep_bonus 1\n", BASE)).is_err());
        assert!(parse_pack(&format!("{}method assign\nnew_cost 1\nkeep_bonus -1\n", BASE)).is_err());
        assert!(parse_pack(&format!("{}method assign\nnew_cost 1\n", BASE)).unwrap_err().contains("keep_bonus"));
    }

    #[test]
    fn values_and_parameters() {
        assert!(confirm("gate distance max_m=1 max_m=2\n").unwrap_err().contains("repeated parameter"));
        assert!(confirm("gate distance\n").unwrap_err().contains("missing parameter"));
        assert!(confirm("gate distance max=1\n").unwrap_err().contains("unknown parameter"));
        assert!(confirm("gate distance max_m\n").unwrap_err().contains("without '='"));
        assert!(confirm("gate distance max_m=1e3\n").is_err());
        assert!(confirm("gate same key=\n").unwrap_err().contains("empty"));
        assert!(confirm("gate\n").unwrap_err().contains("without a test name"));
        assert!(parse_pack(&BASE.replace("0.1.0", "1.0")).unwrap_err().contains("semver"));
        let p = confirm("output latest\nsame_source allow\npriority radar 3\nmaneuver accel_var=9 p_enter=0.1 p_leave=0.2\nrestart gate=13.8\ntime_default radar error_ms=5\n").unwrap();
        assert_eq!((p.output, p.same_source_allow, p.priority_of("radar"), p.priority_of("x")), (Output::Latest, true, 3, 100));
        assert_eq!((p.restart, p.maneuver.map(|m| m.accel_var)), (Some(13.8), Some(9.0)));
        assert!(confirm("maneuver accel_var=0.5 p_enter=0.1 p_leave=0.2\n").unwrap_err().contains("above filter"));
        assert!(confirm("restart gate=0\n").is_err());
        assert!(confirm("output newest\n").is_err());
        assert!(confirm("hold_failures 2\n").unwrap_err().contains("repeated"));
        assert!(parse_pack("pack p\n").unwrap_err().contains("filter"));
    }

    #[test]
    fn load_pack_reads_the_directory() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../packs/correlate-gnn");
        assert_eq!(load_pack(&dir).unwrap().name, "correlate-gnn");
        assert!(load_pack(std::path::Path::new("/nonexistent")).is_err());
    }
}
