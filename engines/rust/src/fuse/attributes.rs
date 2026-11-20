//! Deciding one attribute for a group (spec/fuse.md, Attributes).

use std::cmp::Ordering;

use crate::model::Json;

use super::pack::Rule;
use super::Member;

/// A candidate: a member (index into the group's members) and its value.
pub struct Candidate<'a> {
    pub member: usize,
    pub value: &'a Json,
}

/// A value usable by `rule`: a string, a number or a boolean for `priority`,
/// `latest` and `majority`; a number (not a boolean) for `max` and `min`.
fn usable(rule: Rule, value: &Json) -> bool {
    match rule {
        Rule::Priority | Rule::Latest | Rule::Majority => {
            matches!(value, Json::Str(_) | Json::Num(_) | Json::Int(_) | Json::Bool(_))
        }
        Rule::Max | Rule::Min => matches!(value, Json::Num(_) | Json::Int(_)),
    }
}

/// The candidates: members in key order whose last report holds `key` with a usable value.
pub fn candidates<'a>(members: &'a [Member], key: &str, rule: Rule) -> Vec<Candidate<'a>> {
    members
        .iter()
        .enumerate()
        .filter_map(|(i, m)| m.report.get(key).filter(|v| usable(rule, v)).map(|value| Candidate { member: i, value }))
        .collect()
}

/// Equality for `majority`: same bytes, same numeric value, or the same boolean;
/// never across kinds.
fn equal(a: &Json, b: &Json) -> bool {
    match (a, b) {
        (Json::Int(x), Json::Int(y)) => x == y,
        (Json::Num(_) | Json::Int(_), Json::Num(_) | Json::Int(_)) => a.as_f64() == b.as_f64(),
        (Json::Str(x), Json::Str(y)) => x == y,
        (Json::Bool(x), Json::Bool(y)) => x == y,
        _ => false,
    }
}

/// Numeric order for `max` and `min`: two integers exactly, otherwise as binary64.
fn compare_numbers(a: &Json, b: &Json) -> Ordering {
    match (a, b) {
        (Json::Int(x), Json::Int(y)) => x.cmp(y),
        _ => a.as_f64().unwrap().partial_cmp(&b.as_f64().unwrap()).unwrap_or(Ordering::Equal),
    }
}

/// The index into `cands` of the winner, or `None` with no candidates.
pub fn winner(rule: Rule, cands: &[Candidate], members: &[Member], unlisted_rank: usize) -> Option<usize> {
    if cands.is_empty() {
        return None;
    }
    // A later candidate replaces the choice only when strictly better: ties to key order.
    let first_best = |better: &dyn Fn(&Candidate, &Candidate) -> bool| {
        let mut chosen = 0;
        for i in 1..cands.len() {
            if better(&cands[i], &cands[chosen]) {
                chosen = i;
            }
        }
        chosen
    };
    let member = |c: &Candidate| &members[c.member];
    Some(match rule {
        Rule::Priority => {
            let rank = |c: &Candidate| member(c).rank.unwrap_or(unlisted_rank);
            first_best(&|a, b| rank(a) < rank(b))
        }
        Rule::Latest => first_best(&|a, b| member(a).last_time_ms > member(b).last_time_ms),
        Rule::Max => first_best(&|a, b| compare_numbers(a.value, b.value) == Ordering::Greater),
        Rule::Min => first_best(&|a, b| compare_numbers(a.value, b.value) == Ordering::Less),
        Rule::Majority => {
            // Distinct values in order of their first holder: (first holder, count).
            let mut tallies: Vec<(usize, usize)> = Vec::new();
            for (i, c) in cands.iter().enumerate() {
                match tallies.iter_mut().find(|(first, _)| equal(cands[*first].value, c.value)) {
                    Some((_, count)) => *count += 1,
                    None => tallies.push((i, 1)),
                }
            }
            // Most holders; between equal counts the value whose first holder comes first.
            let mut best = tallies[0];
            for &t in &tallies[1..] {
                if t.1 > best.1 {
                    best = t;
                }
            }
            best.0
        }
    })
}
