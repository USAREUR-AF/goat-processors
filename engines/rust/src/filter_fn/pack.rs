//! spec/filter.md, Pack: `load_pack(dir)` and `parse_pack(text)`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

/// A rule's action, and the pack's `default`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Action {
    Keep,
    Drop,
}

impl Action {
    pub fn name(self) -> &'static str {
        match self {
            Action::Keep => "keep",
            Action::Drop => "drop",
        }
    }

    fn parse(s: &str) -> Result<Action, String> {
        match s {
            "keep" => Ok(Action::Keep),
            "drop" => Ok(Action::Drop),
            _ => Err(format!("action is not keep or drop: {:?}", s)),
        }
    }
}

/// A `[min, max]` range; `None` is no bound on that side.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Range {
    pub min: Option<f64>,
    pub max: Option<f64>,
}

impl Range {
    /// Both bounds inclusive.
    pub fn holds(&self, v: f64) -> bool {
        self.min.is_none_or(|m| m <= v) && self.max.is_none_or(|m| v <= m)
    }
}

/// A condition with its parameters (spec: Conditions; Pack, parameter sets).
#[derive(Debug, Clone, PartialEq)]
pub enum Condition {
    Circle { lat: f64, lon: f64, radius_m: f64 },
    /// `(lat, lon)` in pack order.
    Polygon { vertices: Vec<(f64, f64)> },
    Near { reference: String, radius_m: f64, max_age_ms: i64 },
    Env { items: Vec<String> },
    Affiliation { items: Vec<String> },
    Source { items: Vec<String> },
    Uid { items: Vec<String> },
    /// `key` form eq; `number` is the text read as a pack number, when it is one.
    KeyEq { name: String, text: String, number: Option<f64> },
    KeyIn { name: String, items: Vec<String> },
    KeyRange { name: String, range: Range },
    Has { name: String },
    Speed { range: Range },
    Altitude { range: Range },
    Interval { min_ms: i64 },
    Order,
}

impl Condition {
    /// The trace `test`: the name as written (`key` for every form of `key`).
    pub fn name(&self) -> &'static str {
        match self {
            Condition::Circle { .. } => "circle",
            Condition::Polygon { .. } => "polygon",
            Condition::Near { .. } => "near",
            Condition::Env { .. } => "env",
            Condition::Affiliation { .. } => "affiliation",
            Condition::Source { .. } => "source",
            Condition::Uid { .. } => "uid",
            Condition::KeyEq { .. } | Condition::KeyIn { .. } | Condition::KeyRange { .. } => "key",
            Condition::Has { .. } => "has",
            Condition::Speed { .. } => "speed",
            Condition::Altitude { .. } => "altitude",
            Condition::Interval { .. } => "interval",
            Condition::Order => "order",
        }
    }
}

/// One `when` line.
#[derive(Debug, Clone, PartialEq)]
pub struct When {
    pub negated: bool,
    pub condition: Condition,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Rule {
    pub name: String,
    pub action: Action,
    pub conditions: Vec<When>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Pack {
    pub name: String,
    pub version: String,
    pub default: Action,
    pub forget_ms: i64,
    pub rules: Vec<Rule>,
}

/// `load_pack(dir)`: reads `<dir>/pack.def`.
pub fn load_pack(dir: &Path) -> Result<Pack, String> {
    let text = std::fs::read_to_string(dir.join("pack.def")).map_err(|e| format!("{}: {}", dir.display(), e))?;
    parse_pack(&text)
}

// ---- Values

/// number: `-?[0-9]+(\.[0-9]+)?`, read as the nearest binary64.
pub fn number(s: &str) -> Result<f64, String> {
    let digits = |t: &str| !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit());
    let body = s.strip_prefix('-').unwrap_or(s);
    let ok = match body.split_once('.') {
        Some((int, frac)) => digits(int) && digits(frac),
        None => digits(body),
    };
    if !ok {
        return Err(format!("not a number: {:?}", s));
    }
    s.parse::<f64>().map_err(|_| format!("not a number: {:?}", s))
}

/// integer: `[0-9]+`, at most 9223372036854775807.
fn integer(s: &str) -> Result<i64, String> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("not an integer: {:?}", s));
    }
    s.parse::<i64>().map_err(|_| format!("integer out of range: {:?}", s))
}

fn positive_integer(s: &str) -> Result<i64, String> {
    let n = integer(s)?;
    if n > 0 {
        Ok(n)
    } else {
        Err(format!("not above 0: {:?}", s))
    }
}

fn lat(s: &str) -> Result<f64, String> {
    let v = number(s)?;
    if (-90.0..=90.0).contains(&v) {
        Ok(v)
    } else {
        Err(format!("lat out of range: {:?}", s))
    }
}

fn lon(s: &str) -> Result<f64, String> {
    let v = number(s)?;
    if (-180.0..=180.0).contains(&v) {
        Ok(v)
    } else {
        Err(format!("lon out of range: {:?}", s))
    }
}

fn radius(s: &str) -> Result<f64, String> {
    let v = number(s)?;
    if v >= 0.0 {
        Ok(v)
    } else {
        Err(format!("radius_m below 0: {:?}", s))
    }
}

/// vertices: `<lat>,<lon>;<lat>,<lon>;...`, at least three pairs.
fn vertices(s: &str) -> Result<Vec<(f64, f64)>, String> {
    let pairs = s
        .split(';')
        .map(|p| match p.split(',').collect::<Vec<_>>()[..] {
            [a, b] => Ok((lat(a)?, lon(b)?)),
            _ => Err(format!("bad vertex: {:?}", p)),
        })
        .collect::<Result<Vec<_>, _>>()?;
    if pairs.len() < 3 {
        return Err(format!("polygon needs at least three vertices: {:?}", s));
    }
    Ok(pairs)
}

/// in: one or more non-empty items separated by `,`.
fn list(s: &str) -> Result<Vec<String>, String> {
    let items: Vec<String> = s.split(',').map(str::to_string).collect();
    if items.iter().any(String::is_empty) {
        return Err(format!("empty list item: {:?}", s));
    }
    Ok(items)
}

/// reference, name, eq: a non-empty token.
fn token(s: &str) -> Result<String, String> {
    if s.is_empty() {
        Err("empty token".to_string())
    } else {
        Ok(s.to_string())
    }
}

// ---- when

/// A `when` line's `name=value` parameters: each given once, each `=`.
struct Params(BTreeMap<String, String>);

impl Params {
    fn parse(args: &[&str]) -> Result<Params, String> {
        let mut map = BTreeMap::new();
        for a in args {
            let (k, v) = a.split_once('=').ok_or_else(|| format!("parameter without '=': {:?}", a))?;
            if map.insert(k.to_string(), v.to_string()).is_some() {
                return Err(format!("parameter given twice: {}", k));
            }
        }
        Ok(Params(map))
    }

    /// The parameter names given, as one set.
    fn names(&self) -> BTreeSet<&str> {
        self.0.keys().map(String::as_str).collect()
    }

    /// The set of names must be exactly `allowed`.
    fn exactly(&self, allowed: &[&str]) -> Result<(), String> {
        let want: BTreeSet<&str> = allowed.iter().copied().collect();
        if self.names() == want {
            Ok(())
        } else {
            Err(format!("parameters {:?}, want {:?}", self.names(), want))
        }
    }

    fn get(&self, k: &str) -> &str {
        &self.0[k]
    }

    fn opt(&self, k: &str) -> Option<&str> {
        self.0.get(k).map(String::as_str)
    }

    /// `min` and/or `max`, numbers, `min <= max` when both are given.
    fn range(&self) -> Result<Range, String> {
        let min = self.opt("min").map(number).transpose()?;
        let max = self.opt("max").map(number).transpose()?;
        if let (Some(a), Some(b)) = (min, max) {
            if a > b {
                return Err(format!("min {} above max {}", a, b));
            }
        }
        Ok(Range { min, max })
    }
}

/// Parses the words after `when`.
fn parse_when(args: &[&str]) -> Result<When, String> {
    let (negated, args) = match args.split_first() {
        Some((&"not", rest)) => (true, rest),
        _ => (false, args),
    };
    let (name, params) = args.split_first().ok_or("when without a condition")?;
    let p = Params::parse(params)?;
    let ranged = |extra: &[&str]| -> Result<(), String> {
        // `extra` plus one of: min; max; min and max.
        for bounds in [&["min"][..], &["max"], &["min", "max"]] {
            let want: Vec<&str> = extra.iter().chain(bounds).copied().collect();
            if p.exactly(&want).is_ok() {
                return Ok(());
            }
        }
        Err(format!("parameters {:?}, want {:?} with min and/or max", p.names(), extra))
    };
    let condition = match *name {
        "circle" => {
            p.exactly(&["lat", "lon", "radius_m"])?;
            Condition::Circle { lat: lat(p.get("lat"))?, lon: lon(p.get("lon"))?, radius_m: radius(p.get("radius_m"))? }
        }
        "polygon" => {
            p.exactly(&["vertices"])?;
            Condition::Polygon { vertices: vertices(p.get("vertices"))? }
        }
        "near" => {
            p.exactly(&["reference", "radius_m", "max_age_ms"])?;
            Condition::Near {
                reference: token(p.get("reference"))?,
                radius_m: radius(p.get("radius_m"))?,
                max_age_ms: integer(p.get("max_age_ms"))?,
            }
        }
        "env" | "affiliation" | "source" | "uid" => {
            p.exactly(&["in"])?;
            let items = list(p.get("in"))?;
            match *name {
                "env" => Condition::Env { items },
                "affiliation" => Condition::Affiliation { items },
                "source" => Condition::Source { items },
                _ => Condition::Uid { items },
            }
        }
        "key" => {
            if p.exactly(&["name", "eq"]).is_ok() {
                let text = token(p.get("eq"))?;
                Condition::KeyEq { name: token(p.get("name"))?, number: number(&text).ok(), text }
            } else if p.exactly(&["name", "in"]).is_ok() {
                Condition::KeyIn { name: token(p.get("name"))?, items: list(p.get("in"))? }
            } else {
                ranged(&["name"])?;
                Condition::KeyRange { name: token(p.get("name"))?, range: p.range()? }
            }
        }
        "has" => {
            p.exactly(&["name"])?;
            Condition::Has { name: token(p.get("name"))? }
        }
        "speed" | "altitude" => {
            ranged(&[])?;
            let range = p.range()?;
            if *name == "speed" {
                Condition::Speed { range }
            } else {
                Condition::Altitude { range }
            }
        }
        "interval" => {
            p.exactly(&["min_ms"])?;
            Condition::Interval { min_ms: positive_integer(p.get("min_ms"))? }
        }
        "order" => {
            p.exactly(&[])?;
            Condition::Order
        }
        other => return Err(format!("unknown condition: {:?}", other)),
    };
    Ok(When { negated, condition })
}

// ---- pack.def

/// `parse_pack(text)`: the pack, or the first load error.
pub fn parse_pack(text: &str) -> Result<Pack, String> {
    let mut seen: BTreeSet<&str> = BTreeSet::new();
    let mut name = None;
    let mut version = None;
    let mut default = None;
    let mut forget_ms = None;
    let mut rules: Vec<Rule> = Vec::new();

    for (lineno, raw) in text.lines().enumerate() {
        let at = |e: String| format!("line {}: {}", lineno + 1, e);
        // `#` starts a comment; blank lines are ignored.
        let line = raw.split('#').next().unwrap_or("");
        let words: Vec<&str> = line.split([' ', '\t']).filter(|w| !w.is_empty()).collect();
        let Some((&directive, args)) = words.split_first() else { continue };

        match directive {
            "pack" | "version" | "default" | "forget_ms" => {
                if !seen.insert(directive) {
                    return Err(at(format!("repeated directive: {}", directive)));
                }
                let [arg] = args else {
                    return Err(at(format!("{} takes one argument", directive)));
                };
                match directive {
                    "pack" => name = Some(arg.to_string()),
                    // One token; the spec gives `version` no further grammar and
                    // lists no load error for its form (load vector 03: `version 1`).
                    "version" => version = Some(arg.to_string()),
                    "default" => default = Some(Action::parse(arg).map_err(at)?),
                    _ => forget_ms = Some(positive_integer(arg).map_err(at)?),
                }
            }
            "rule" => {
                let [rule_name, action] = args else {
                    return Err(at("rule takes a name and an action".to_string()));
                };
                if let Some(prev) = rules.last() {
                    if prev.conditions.is_empty() {
                        return Err(at(format!("rule {} has no when line", prev.name)));
                    }
                }
                if *rule_name == "default" {
                    return Err(at("a rule cannot be named default".to_string()));
                }
                if rules.iter().any(|r| r.name == *rule_name) {
                    return Err(at(format!("two rules named {}", rule_name)));
                }
                let action = Action::parse(action).map_err(at)?;
                rules.push(Rule { name: rule_name.to_string(), action, conditions: Vec::new() });
            }
            "when" => {
                let rule = rules.last_mut().ok_or_else(|| at("when before the first rule".to_string()))?;
                rule.conditions.push(parse_when(args).map_err(at)?);
            }
            other => return Err(at(format!("unknown directive: {}", other))),
        }
    }
    if let Some(last) = rules.last() {
        if last.conditions.is_empty() {
            return Err(format!("rule {} has no when line", last.name));
        }
    }
    Ok(Pack {
        name: name.ok_or("missing directive: pack")?,
        version: version.ok_or("missing directive: version")?,
        default: default.ok_or("missing directive: default")?,
        forget_ms: forget_ms.ok_or("missing directive: forget_ms")?,
        rules,
    })
}
