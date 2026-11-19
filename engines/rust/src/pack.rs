//! Pack loading (spec: Pack).

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub struct FilterParams {
    pub accel_var: f64,
    pub default_ce_m: f64,
    pub vel_sigma_ms: f64,
    pub unknown_vel_ms: f64,
}

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

/// One named test with its parameters (spec: Tests).
#[derive(Debug, Clone, PartialEq)]
pub enum Test {
    Distance { max_m: f64 },
    Window { multiplier: f64, window_m: f64, err_min_m: f64, err_max_m: f64 },
    Mahalanobis { gate: f64 },
    Course { max_deg: f64, min_speed_ms: f64 },
    Speed { max_pct: f64, min_speed_ms: f64 },
    Altitude { max_m: f64 },
    Same { key: String },
}

impl Test {
    pub fn name(&self) -> &'static str {
        match self {
            Test::Distance { .. } => "distance",
            Test::Window { .. } => "window",
            Test::Mahalanobis { .. } => "mahalanobis",
            Test::Course { .. } => "course",
            Test::Speed { .. } => "speed",
            Test::Altitude { .. } => "altitude",
            Test::Same { .. } => "same",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Output {
    Priority,
    Latest,
}

/// The pack's `method` (spec: correlate.md Pack; correlate-assign.md).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Method {
    Confirm,
    Assign,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Pack {
    pub name: String,
    pub method: Method,
    pub version: String,
    pub filter: FilterParams,
    /// Present when the pack has the `maneuver` directive.
    pub maneuver: Option<Maneuver>,
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
}

impl Pack {
    /// The source's priority number; 100 for a source the pack does not list.
    pub fn priority_of(&self, source: &str) -> i64 {
        self.priority.iter().find(|(s, _)| s == source).map(|(_, n)| *n).unwrap_or(100)
    }
}

/// `load_pack(dir)`: reads `<dir>/pack.def`.
pub fn load_pack(dir: &Path) -> Result<Pack, String> {
    let text = std::fs::read_to_string(dir.join("pack.def")).map_err(|e| format!("{}: {}", dir.display(), e))?;
    parse_pack(&text)
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

/// `name=value` parameters; each named exactly once, no others.
struct Params(BTreeMap<String, String>);

impl Params {
    fn parse(args: &[&str], allowed: &[&str]) -> Result<Params, String> {
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

    fn num(&self, k: &str) -> Result<f64, String> {
        decimal(&self.0[k])
    }

    fn string(&self, k: &str) -> Result<String, String> {
        let v = &self.0[k];
        if v.is_empty() {
            return Err(format!("empty parameter: {:?}", k));
        }
        Ok(v.clone())
    }
}

fn parse_test(args: &[&str]) -> Result<Test, String> {
    let (name, rest) = args.split_first().ok_or("test line without a test name")?;
    let t = match *name {
        "distance" => {
            let p = Params::parse(rest, &["max_m"])?;
            Test::Distance { max_m: p.num("max_m")? }
        }
        "window" => {
            let p = Params::parse(rest, &["multiplier", "window_m", "err_min_m", "err_max_m"])?;
            Test::Window {
                multiplier: p.num("multiplier")?,
                window_m: p.num("window_m")?,
                err_min_m: p.num("err_min_m")?,
                err_max_m: p.num("err_max_m")?,
            }
        }
        "mahalanobis" => {
            let p = Params::parse(rest, &["gate"])?;
            Test::Mahalanobis { gate: p.num("gate")? }
        }
        "course" => {
            let p = Params::parse(rest, &["max_deg", "min_speed_ms"])?;
            Test::Course { max_deg: p.num("max_deg")?, min_speed_ms: p.num("min_speed_ms")? }
        }
        "speed" => {
            let p = Params::parse(rest, &["max_pct", "min_speed_ms"])?;
            Test::Speed { max_pct: p.num("max_pct")?, min_speed_ms: p.num("min_speed_ms")? }
        }
        "altitude" => {
            let p = Params::parse(rest, &["max_m"])?;
            Test::Altitude { max_m: p.num("max_m")? }
        }
        "same" => {
            let p = Params::parse(rest, &["key"])?;
            Test::Same { key: p.string("key")? }
        }
        other => return Err(format!("unknown test: {:?}", other)),
    };
    Ok(t)
}

fn one_arg<'a>(directive: &str, args: &[&'a str]) -> Result<&'a str, String> {
    match args {
        [a] => Ok(a),
        _ => Err(format!("{} takes one value", directive)),
    }
}

/// Parses the text of a `pack.def`.
pub fn parse_pack(text: &str) -> Result<Pack, String> {
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
    let mut method = Method::Confirm;
    let mut new_cost = None;
    let mut keep_bonus = None;
    let mut maneuver = None;
    let mut window = None;
    let mut hypotheses = None;

    for (lineno, raw) in text.lines().enumerate() {
        let line = raw.split('#').next().unwrap_or("");
        let words: Vec<&str> = line.split_whitespace().collect();
        let Some((directive, args)) = words.split_first() else { continue };
        let directive = *directive;
        let at = |e: String| format!("line {}: {}", lineno + 1, e);

        let repeats = matches!(directive, "gate" | "confirm" | "hold" | "priority");
        if !repeats && !seen.insert(directive.to_string()) {
            return Err(at(format!("repeated directive: {}", directive)));
        }
        seen.insert(directive.to_string());
        match directive {
            "method" => {
                method = match one_arg(directive, args).map_err(at)? {
                    "confirm" => Method::Confirm,
                    "assign" => Method::Assign,
                    v => return Err(at(format!("method must be confirm or assign, not {:?}", v))),
                }
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
            "window" => window = Some(positive(one_arg(directive, args).map_err(at)?).map_err(at)?),
            "hypotheses" => hypotheses = Some(positive(one_arg(directive, args).map_err(at)?).map_err(at)?),
            "gate" => gate.push(parse_test(args).map_err(at)?),
            "confirm" => confirm.push(parse_test(args).map_err(at)?),
            "hold" => hold.push(parse_test(args).map_err(at)?),
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

    let need = |what: &str| format!("missing required directive: {}", what);
    let filter = filter.ok_or_else(|| need("filter"))?;
    if let Some(m) = &maneuver {
        if !(m.accel_var > filter.accel_var) {
            return Err("maneuver accel_var must be above filter accel_var".to_string());
        }
    }
    let refused: &[&str] = match method {
        Method::Confirm => &["new_cost", "keep_bonus", "window", "hypotheses"],
        Method::Assign => &["confirm", "hold", "confirm_count", "hold_failures", "same_source", "output", "priority"],
    };
    if let Some(d) = refused.iter().find(|d| seen.contains(**d)) {
        return Err(format!("directive {} is not allowed with method {}", d, if method == Method::Assign { "assign" } else { "confirm" }));
    }
    if method == Method::Assign {
        // correlate-assign.md 0.2: new_cost above 0, keep_bonus 0 or above.
        if let Some(c) = new_cost {
            if !(c > 0.0) {
                return Err("new_cost must be above 0".to_string());
            }
        }
        // correlate-assign.md 0.4: hypotheses above 1 needs window above 1.
        let (window, hypotheses) = (window.unwrap_or(1), hypotheses.unwrap_or(1));
        if hypotheses > 1 && window == 1 {
            return Err("hypotheses above 1 needs window above 1".to_string());
        }
        if let Some(b) = keep_bonus {
            if !(b >= 0.0) {
                return Err("keep_bonus must be 0 or above".to_string());
            }
        }
        return Ok(Pack {
            name: name.ok_or_else(|| need("pack"))?,
            method,
            version: version.ok_or_else(|| need("version"))?,
            filter,
            maneuver,
            gate,
            confirm,
            hold,
            confirm_count: 0,
            hold_failures: 0,
            stale_ms: stale_ms.ok_or_else(|| need("stale_ms"))?,
            same_source_allow,
            output,
            priority,
            new_cost: new_cost.ok_or_else(|| need("new_cost"))?,
            keep_bonus: keep_bonus.ok_or_else(|| need("keep_bonus"))?,
            window,
            hypotheses,
        });
    }
    Ok(Pack {
        method,
        new_cost: 0.0,
        keep_bonus: 0.0,
        window: 1,
        hypotheses: 1,
        name: name.ok_or_else(|| need("pack"))?,
        version: version.ok_or_else(|| need("version"))?,
        filter,
        maneuver,
        gate,
        confirm,
        hold,
        confirm_count: confirm_count.ok_or_else(|| need("confirm_count"))?,
        hold_failures: hold_failures.ok_or_else(|| need("hold_failures"))?,
        stale_ms: stale_ms.ok_or_else(|| need("stale_ms"))?,
        same_source_allow,
        output,
        priority,
    })
}
