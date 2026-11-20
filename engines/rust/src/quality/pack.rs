//! Quality pack: `pack.def` parsing and validation (spec/quality.md version
//! 0.2, Pack).

use std::collections::BTreeMap;
use std::path::Path;

use crate::model::pack::{parse_time_default, FilterParams, TimeDefault};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Entity,
    Source,
}

impl Scope {
    pub fn name(self) -> &'static str {
        match self {
            Scope::Entity => "entity",
            Scope::Source => "source",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Lt,
    Le,
    Gt,
    Ge,
}

impl Op {
    /// `v op limit`.
    pub fn holds(self, v: f64, limit: f64) -> bool {
        match self {
            Op::Lt => v < limit,
            Op::Le => v <= limit,
            Op::Gt => v > limit,
            Op::Ge => v >= limit,
        }
    }

    /// Spec Rules, Evaluation, Active: for `>`/`>=` clears when `v < clear`,
    /// for `<`/`<=` when `v > clear`.
    pub fn clears(self, v: f64, clear: f64) -> bool {
        match self {
            Op::Gt | Op::Ge => v < clear,
            Op::Lt | Op::Le => v > clear,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Action {
    Mark,
    /// Multiplies the forwarded `ce` by the factor.
    Downgrade(f64),
    Drop,
    Alert,
}

impl Action {
    pub fn name(self) -> &'static str {
        match self {
            Action::Mark => "mark",
            Action::Downgrade(_) => "downgrade",
            Action::Drop => "drop",
            Action::Alert => "alert",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Rule {
    pub name: String,
    pub scope: Scope,
    pub measure: String,
    pub op: Op,
    pub limit: f64,
    pub for_n: u64,
    pub clear: f64,
    pub action: Action,
}

#[derive(Debug, Clone, PartialEq)]
pub struct WindowParams {
    pub window_ms: i64,
    pub min_samples: i64,
    pub forget_ms: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Pack {
    pub name: String,
    pub version: String,
    pub filter: FilterParams,
    pub window: WindowParams,
    /// `time_default` lines by source id (Reports, Time quality).
    pub time_default: BTreeMap<String, TimeDefault>,
    /// Pack order.
    pub rules: Vec<Rule>,
}

/// `load_pack(dir)`: reads `dir/pack.def`.
pub fn load_pack(dir: &Path) -> Result<Pack, String> {
    let path = dir.join("pack.def");
    let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {}", path.display(), e))?;
    parse_pack(&text)
}

/// Values: a *number* is written `-?[0-9]+(\.[0-9]+)?`, read as the nearest
/// binary64; a number whose nearest binary64 is infinite is a load error.
fn number(s: &str) -> Result<f64, String> {
    let digits = |t: &str| !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit());
    let body = s.strip_prefix('-').unwrap_or(s);
    let ok = match body.split_once('.') {
        None => digits(body),
        Some((whole, frac)) => digits(whole) && digits(frac),
    };
    if !ok {
        return Err(format!("not a number: {:?}", s));
    }
    let value = s.parse::<f64>().map_err(|_| format!("not a number: {:?}", s))?;
    if value.is_infinite() {
        return Err(format!("number not finite: {:?}", s));
    }
    Ok(value)
}

/// Values: an *integer* is written `[0-9]+`.
fn integer(s: &str) -> Result<i64, String> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("not an integer: {:?}", s));
    }
    s.parse::<i64>().map_err(|_| format!("integer out of range: {:?}", s))
}

/// A rule name is one or more of `A-Z a-z 0-9 . _ -`.
fn valid_rule_name(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// `name=value` parameters of a `filter`, `window` or `rule` line: a
/// parameter without `=`, or a repeated or unknown one, is an error.
fn params<'a>(directive: &str, args: &[&'a str], allowed: &[&str]) -> Result<BTreeMap<&'a str, &'a str>, String> {
    let mut out = BTreeMap::new();
    for arg in args {
        let (k, v) = arg.split_once('=').ok_or_else(|| format!("{}: parameter without '=': {:?}", directive, arg))?;
        if !allowed.contains(&k) {
            return Err(format!("{}: unknown parameter {:?}", directive, k));
        }
        if out.insert(k, v).is_some() {
            return Err(format!("{}: repeated parameter {:?}", directive, k));
        }
    }
    Ok(out)
}

fn required<'a>(directive: &str, p: &BTreeMap<&str, &'a str>, key: &str) -> Result<&'a str, String> {
    p.get(key).copied().ok_or_else(|| format!("{}: missing parameter {:?}", directive, key))
}

fn parse_filter(args: &[&str]) -> Result<FilterParams, String> {
    let p = params("filter", args, &["accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"])?;
    let get = |k: &str| required("filter", &p, k).and_then(number);
    let f = FilterParams {
        accel_var: get("accel_var")?,
        default_ce_m: get("default_ce_m")?,
        vel_sigma_ms: get("vel_sigma_ms")?,
        unknown_vel_ms: get("unknown_vel_ms")?,
    };
    if f.accel_var < 0.0 {
        return Err("filter: accel_var below 0".into());
    }
    if f.default_ce_m <= 0.0 || f.vel_sigma_ms <= 0.0 || f.unknown_vel_ms <= 0.0 {
        return Err("filter: default_ce_m, vel_sigma_ms and unknown_vel_ms must be above 0".into());
    }
    Ok(f)
}

fn parse_window(args: &[&str]) -> Result<WindowParams, String> {
    let p = params("window", args, &["window_ms", "min_samples", "forget_ms"])?;
    let get = |k: &str| -> Result<i64, String> {
        let n = required("window", &p, k).and_then(integer)?;
        if n < 1 {
            return Err(format!("window: {} below 1", k));
        }
        Ok(n)
    };
    Ok(WindowParams { window_ms: get("window_ms")?, min_samples: get("min_samples")?, forget_ms: get("forget_ms")? })
}

fn parse_rule(args: &[&str], earlier: &[Rule]) -> Result<Rule, String> {
    let (name, rest) = args.split_first().ok_or("rule: no name")?;
    if !valid_rule_name(name) {
        return Err(format!("rule: bad name {:?}", name));
    }
    if earlier.iter().any(|r| r.name == *name) {
        return Err(format!("rule: name {:?} used by an earlier rule", name));
    }
    let d = format!("rule {}", name);
    let p = params(&d, rest, &["scope", "measure", "op", "limit", "for", "clear", "action", "factor"])?;
    let get = |k: &str| required(&d, &p, k);

    let scope = match get("scope")? {
        "entity" => Scope::Entity,
        "source" => Scope::Source,
        s => return Err(format!("{}: bad scope {:?}", d, s)),
    };
    let measure = get("measure")?;
    if super::measures::find(measure, scope).is_none() {
        return Err(format!("{}: measure {:?} is not a {} measure", d, measure, scope.name()));
    }
    let op = match get("op")? {
        "<" => Op::Lt,
        "<=" => Op::Le,
        ">" => Op::Gt,
        ">=" => Op::Ge,
        s => return Err(format!("{}: bad op {:?}", d, s)),
    };
    let limit = number(get("limit")?)?;
    let clear = number(get("clear")?)?;
    let for_n = integer(get("for")?)?;
    if for_n < 1 {
        return Err(format!("{}: for below 1", d));
    }
    let clear_wrong_side = match op {
        Op::Gt | Op::Ge => clear > limit,
        Op::Lt | Op::Le => clear < limit,
    };
    if clear_wrong_side {
        return Err(format!("{}: clear on the wrong side of limit", d));
    }
    let factor = p.get("factor").copied();
    let action = match (get("action")?, factor) {
        ("downgrade", None) => return Err(format!("{}: downgrade without factor", d)),
        ("downgrade", Some(f)) => {
            let f = number(f)?;
            if f < 1.0 {
                return Err(format!("{}: factor below 1", d));
            }
            Action::Downgrade(f)
        }
        (_, Some(_)) => return Err(format!("{}: factor with an action other than downgrade", d)),
        ("mark", None) => Action::Mark,
        ("drop", None) => Action::Drop,
        ("alert", None) => Action::Alert,
        (a, None) => return Err(format!("{}: bad action {:?}", d, a)),
    };
    Ok(Rule { name: name.to_string(), scope, measure: measure.to_string(), op, limit, for_n: for_n as u64, clear, action })
}

/// The single value of `pack` or `version`.
fn one_value(directive: &str, args: &[&str]) -> Result<String, String> {
    match args {
        [v] => Ok(v.to_string()),
        _ => Err(format!("{}: needs exactly one value", directive)),
    }
}

/// Pack, steps 1 and 2: the lines of a `pack.def`. Lines end at LF; one CR
/// at the end of a line is removed; a final LF does not start another line.
/// A line that then holds a control character (U+0000 to U+001F other than
/// tab, or U+007F, so also any other CR) is a load error.
fn pack_lines(text: &str) -> Result<Vec<&str>, String> {
    let mut lines: Vec<&str> = text.split('\n').collect();
    if text.ends_with('\n') {
        lines.pop();
    }
    let mut out = Vec::with_capacity(lines.len());
    for (lineno, raw) in lines.into_iter().enumerate() {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let control = |c: char| (c < '\u{20}' && c != '\t') || c == '\u{7f}';
        if line.chars().any(control) {
            return Err(format!("line {}: control character", lineno + 1));
        }
        out.push(line);
    }
    Ok(out)
}

/// Parses the text of a `pack.def` (spec Pack): steps 1 and 2 in
/// `pack_lines`; 3. `#` starts a comment; 4. a line left empty is ignored;
/// 5. tokens are separated by runs of space and tab, and by nothing else.
pub fn parse_pack(text: &str) -> Result<Pack, String> {
    let mut name = None;
    let mut version = None;
    let mut filter = None;
    let mut window = None;
    let mut time_default: BTreeMap<String, TimeDefault> = BTreeMap::new();
    let mut rules: Vec<Rule> = Vec::new();

    for (lineno, raw) in pack_lines(text)?.into_iter().enumerate() {
        let line = raw.split('#').next().unwrap_or("");
        let tokens: Vec<&str> = line.split([' ', '\t']).filter(|t| !t.is_empty()).collect();
        let Some((directive, args)) = tokens.split_first() else { continue };
        let at = |e: String| format!("line {}: {}", lineno + 1, e);
        let once = |seen: bool| if seen { Err(at(format!("{} repeated", directive))) } else { Ok(()) };
        match *directive {
            "pack" => {
                once(name.is_some())?;
                name = Some(one_value(directive, args).map_err(at)?);
            }
            "version" => {
                once(version.is_some())?;
                version = Some(one_value(directive, args).map_err(at)?);
            }
            "filter" => {
                once(filter.is_some())?;
                filter = Some(parse_filter(args).map_err(at)?);
            }
            "window" => {
                once(window.is_some())?;
                window = Some(parse_window(args).map_err(at)?);
            }
            "time_default" => {
                // The grammar of correlate.md Pack, with `error_ms` a number
                // of this section's grammar; at most once per source id.
                let (source, d) = parse_time_default(args, number).map_err(at)?;
                if time_default.insert(source, d).is_some() {
                    return Err(at("a second time_default for the same source".to_string()));
                }
            }
            "rule" => {
                let rule = parse_rule(args, &rules).map_err(at)?;
                rules.push(rule);
            }
            other => return Err(at(format!("unknown directive {:?}", other))),
        }
    }

    Ok(Pack {
        name: name.ok_or("missing directive pack")?,
        version: version.ok_or("missing directive version")?,
        filter: filter.ok_or("missing directive filter")?,
        window: window.ok_or("missing directive window")?,
        time_default,
        rules,
    })
}
