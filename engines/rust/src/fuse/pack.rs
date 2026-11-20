//! Fuse pack loading (spec/fuse.md, Pack).

use std::collections::BTreeSet;
use std::path::Path;

use crate::model::pack::FilterParams;

/// The pack's `kinematics` method (spec/fuse.md, Kinematics).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Kinematics {
    InverseVariance,
    CovarianceIntersection,
    Best,
    Priority,
    Latest,
}

impl Kinematics {
    pub fn name(&self) -> &'static str {
        match self {
            Kinematics::InverseVariance => "inverse_variance",
            Kinematics::CovarianceIntersection => "covariance_intersection",
            Kinematics::Best => "best",
            Kinematics::Priority => "priority",
            Kinematics::Latest => "latest",
        }
    }

    fn parse(s: &str) -> Option<Kinematics> {
        [
            Kinematics::InverseVariance,
            Kinematics::CovarianceIntersection,
            Kinematics::Best,
            Kinematics::Priority,
            Kinematics::Latest,
        ]
        .into_iter()
        .find(|k| k.name() == s)
    }
}

/// An `attribute` line's rule (spec/fuse.md, Attributes).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Rule {
    Priority,
    Latest,
    Majority,
    Max,
    Min,
}

impl Rule {
    pub fn name(&self) -> &'static str {
        match self {
            Rule::Priority => "priority",
            Rule::Latest => "latest",
            Rule::Majority => "majority",
            Rule::Max => "max",
            Rule::Min => "min",
        }
    }

    fn parse(s: &str) -> Option<Rule> {
        [Rule::Priority, Rule::Latest, Rule::Majority, Rule::Max, Rule::Min].into_iter().find(|r| r.name() == s)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Pack {
    pub name: String,
    pub version: String,
    pub filter: FilterParams,
    pub kinematics: Kinematics,
    /// `(key, rule)` in pack order.
    pub attributes: Vec<(String, Rule)>,
    /// Source ids in rank order.
    pub sources: Vec<String>,
    pub stale_ms: i64,
}

impl Pack {
    /// Rank (spec/fuse.md, Kinematics): index of the source among the
    /// `source` lines, or `None` when the source is not listed.
    pub fn rank(&self, source: &str) -> Option<usize> {
        self.sources.iter().position(|s| s == source)
    }
}

/// `load_pack(dir)`: reads `<dir>/pack.def`.
pub fn load_pack(dir: &Path) -> Result<Pack, String> {
    let text = std::fs::read_to_string(dir.join("pack.def")).map_err(|e| format!("{}: {}", dir.display(), e))?;
    parse_pack(&text)
}

/// A **number**: optional `-`, digits, optionally `.` and digits, optionally
/// `e`/`E`, an optional sign and digits.
fn number(s: &str) -> Result<f64, String> {
    fn digits(b: &[u8], mut i: usize) -> Option<usize> {
        let start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        (i > start).then_some(i)
    }
    let b = s.as_bytes();
    let bad = || format!("not a number: {:?}", s);
    let mut i = if b.first() == Some(&b'-') { 1 } else { 0 };
    i = digits(b, i).ok_or_else(bad)?;
    if b.get(i) == Some(&b'.') {
        i = digits(b, i + 1).ok_or_else(bad)?;
    }
    if matches!(b.get(i), Some(b'e' | b'E')) {
        i += 1;
        if matches!(b.get(i), Some(b'+' | b'-')) {
            i += 1;
        }
        i = digits(b, i).ok_or_else(bad)?;
    }
    if i != b.len() {
        return Err(bad());
    }
    s.parse::<f64>().map_err(|_| bad())
}

/// An **integer**: one or more digits.
fn integer(s: &str) -> Result<i64, String> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("not an integer: {:?}", s));
    }
    s.parse::<i64>().map_err(|_| format!("integer out of range: {:?}", s))
}

/// `filter accel_var=<q> default_ce_m=<m> vel_sigma_ms=<m/s> unknown_vel_ms=<m/s>`.
fn filter(values: &[&str]) -> Result<FilterParams, String> {
    const NAMES: [&str; 4] = ["accel_var", "default_ce_m", "vel_sigma_ms", "unknown_vel_ms"];
    let mut got: [Option<f64>; 4] = [None; 4];
    for v in values {
        let (name, value) = v.split_once('=').ok_or_else(|| format!("filter: parameter without '=': {:?}", v))?;
        let i = NAMES.iter().position(|n| *n == name).ok_or_else(|| format!("filter: unknown parameter {:?}", name))?;
        if got[i].is_some() {
            return Err(format!("filter: repeated parameter {:?}", name));
        }
        got[i] = Some(number(value)?);
    }
    let mut p = [0.0; 4];
    for i in 0..4 {
        p[i] = got[i].ok_or_else(|| format!("filter: missing parameter {:?}", NAMES[i]))?;
    }
    let [accel_var, default_ce_m, vel_sigma_ms, unknown_vel_ms] = p;
    if !(accel_var >= 0.0) {
        return Err("filter: accel_var must be 0 or above".into());
    }
    if !(default_ce_m > 0.0 && vel_sigma_ms > 0.0 && unknown_vel_ms > 0.0) {
        return Err("filter: default_ce_m, vel_sigma_ms and unknown_vel_ms must be above 0".into());
    }
    Ok(FilterParams { accel_var, default_ce_m, vel_sigma_ms, unknown_vel_ms })
}

/// `parse_pack(text)`: the text of a `pack.def`.
pub fn parse_pack(text: &str) -> Result<Pack, String> {
    let mut name = None;
    let mut version = None;
    let mut filter_params = None;
    let mut kinematics = None;
    let mut stale_ms = None;
    let mut attributes: Vec<(String, Rule)> = Vec::new();
    let mut sources: Vec<String> = Vec::new();
    let mut seen_sources = BTreeSet::new();

    fn once<T>(slot: &mut Option<T>, directive: &str, value: T) -> Result<(), String> {
        if slot.is_some() {
            return Err(format!("{}: repeated", directive));
        }
        *slot = Some(value);
        Ok(())
    }
    fn one<'a>(directive: &str, values: &[&'a str]) -> Result<&'a str, String> {
        match values {
            [v] => Ok(v),
            _ => Err(format!("{}: needs exactly one value, has {}", directive, values.len())),
        }
    }

    for (n, raw) in text.split('\n').enumerate() {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let line = line.split('#').next().unwrap_or("");
        let words: Vec<&str> = line.split([' ', '\t']).filter(|w| !w.is_empty()).collect();
        let Some((&directive, values)) = words.split_first() else { continue };
        let at = |e: String| format!("line {}: {}", n + 1, e);
        match directive {
            "pack" => once(&mut name, directive, one(directive, values).map_err(at)?.to_string()).map_err(at)?,
            "version" => once(&mut version, directive, one(directive, values).map_err(at)?.to_string()).map_err(at)?,
            "filter" => once(&mut filter_params, directive, filter(values).map_err(at)?).map_err(at)?,
            "kinematics" => {
                let v = one(directive, values).map_err(at)?;
                let k = Kinematics::parse(v).ok_or_else(|| at(format!("unknown kinematics method {:?}", v)))?;
                once(&mut kinematics, directive, k).map_err(at)?
            }
            "stale_ms" => once(&mut stale_ms, directive, integer(one(directive, values).map_err(at)?).map_err(at)?).map_err(at)?,
            "attribute" => {
                let [key, param] = values else {
                    return Err(at(format!("attribute: needs a key and rule=<rule>, has {} values", values.len())));
                };
                if key.contains('=') {
                    return Err(at(format!("attribute: key holds '=': {:?}", key)));
                }
                let (pname, pvalue) = param.split_once('=').ok_or_else(|| at(format!("attribute: parameter without '=': {:?}", param)))?;
                if pname != "rule" {
                    return Err(at(format!("attribute: unknown parameter {:?}", pname)));
                }
                let rule = Rule::parse(pvalue).ok_or_else(|| at(format!("attribute: unknown rule {:?}", pvalue)))?;
                if attributes.iter().any(|(k, _)| k == key) {
                    return Err(at(format!("attribute: repeated key {:?}", key)));
                }
                attributes.push((key.to_string(), rule));
            }
            "source" => {
                let v = one(directive, values).map_err(at)?;
                if !seen_sources.insert(v.to_string()) {
                    return Err(at(format!("source: repeated {:?}", v)));
                }
                sources.push(v.to_string());
            }
            _ => return Err(at(format!("unknown directive {:?}", directive))),
        }
    }

    let missing = |d: &str| format!("missing directive {}", d);
    Ok(Pack {
        name: name.ok_or_else(|| missing("pack"))?,
        version: version.ok_or_else(|| missing("version"))?,
        filter: filter_params.ok_or_else(|| missing("filter"))?,
        kinematics: kinematics.ok_or_else(|| missing("kinematics"))?,
        attributes,
        sources,
        stale_ms: stale_ms.ok_or_else(|| missing("stale_ms"))?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const OK: &str = "pack f\nversion 0.1.0\nfilter accel_var=1 default_ce_m=10 vel_sigma_ms=5 unknown_vel_ms=100\nkinematics best\nstale_ms 100\n";

    #[test]
    fn directives() {
        let p = parse_pack(&format!("{}attribute type rule=majority\nsource a\nsource b\r\n", OK)).unwrap();
        assert_eq!((p.kinematics, p.rank("b"), p.rank("c")), (Kinematics::Best, Some(1), None));
        assert_eq!(p.attributes, vec![("type".to_string(), Rule::Majority)]);
        for k in ["inverse_variance", "covariance_intersection", "best", "priority", "latest"] {
            assert_eq!(Kinematics::parse(k).unwrap().name(), k);
        }
        for bad in [
            format!("{}source a\nsource a\n", OK),
            format!("{}attribute a rule=majority\nattribute a rule=max\n", OK),
            format!("{}attribute a=b rule=max\n", OK),
            format!("{}attribute a rul=max\n", OK),
            format!("{}attribute a rule=mode\n", OK),
            format!("{}attribute a\n", OK),
            format!("{}attribute a rulemax\n", OK),
            format!("{}kinematics best\n", OK),
            format!("{}colour red\n", OK),
            OK.replace("best", "median"),
            OK.replace("stale_ms 100", "stale_ms -1"),
            OK.replace("stale_ms 100", "stale_ms 1 2"),
            OK.replace("accel_var=1", "accel_var=-1"),
            OK.replace("accel_var=1", "accel_var=1 accel_var=2"),
            OK.replace("accel_var=1", "accel=1"),
            OK.replace("accel_var=1", "accel_var"),
            OK.replace("default_ce_m=10", "default_ce_m=0"),
            OK.replace(" default_ce_m=10", ""),
            OK.replace("accel_var=1", "accel_var=1e"),
            OK.replace("pack f\n", ""),
        ] {
            assert!(parse_pack(&bad).is_err(), "{:?}", bad);
        }
        assert_eq!(number("-1.5e+3").unwrap(), -1500.0);
        assert!(number("1.").is_err() && number("e3").is_err() && number("1e3x").is_err());
    }
}
