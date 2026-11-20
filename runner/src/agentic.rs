//! The runner's own agent features. The first is the "why?" explainer
//! (docs/design/agentic-ai.md, section 4.5): a plain-language explanation of
//! one system track, in which every sentence cites the trace records or
//! events it rests on.
//!
//! How it works:
//! 1. It reads the track's events and trace records through the API
//!    (`GET /v1/explain/{track}`), as the caller, so it sees what the caller may.
//! 2. It numbers them R1, R2, ... (the latest 200).
//! 3. It picks a model endpoint declared for the site's highest data level
//!    (the trace holds site data) and sends the numbered records with the
//!    instruction to cite them; an endpoint declared lower is refused.
//! 4. It keeps only the sentences whose citations all name records it sent,
//!    and returns each kept sentence with the records it cites. The sentences
//!    it removed are counted.

use std::collections::BTreeMap;

use goat_correlator::json::{self, Json};

use crate::api::{Identity, Server};
use crate::http::{Request, Response};

const MAX_RECORDS: usize = 200;

const SYSTEM_PROMPT: &str = "You explain decisions of a track correlation engine to an operator. \
You are given numbered records: events and trace records (each test the engine ran: what it compared, the value, the limit and whether it passed). \
Explain, in short plain sentences, why the system track has the members it has. \
End every sentence with the numbers of the records it rests on, in square brackets, for example [R3] or [R3, R7]. \
Use only the records given. Do not write a sentence you cannot cite.";

fn obj(pairs: Vec<(&str, Json)>) -> Json {
    Json::Obj(pairs.into_iter().map(|(k, v)| (k.to_string().into(), v)).collect())
}

/// MCP tools beyond the API routes.
pub fn extra_tools() -> Vec<Json> {
    vec![obj(vec![
        ("name", Json::Str("why".into())),
        (
            "description",
            Json::Str("A plain-language explanation of why one system track has its members; every sentence cites the trace records it rests on (class read, data level highest; uses a model endpoint)".into()),
        ),
        (
            "inputSchema",
            obj(vec![
                ("type", Json::Str("object".into())),
                (
                    "properties",
                    obj(vec![
                        ("track", obj(vec![("type", Json::Str("string".into())), ("description", Json::Str("a system track id".into()))])),
                        ("endpoint", obj(vec![("type", Json::Str("string".into())), ("description", Json::Str("a model endpoint name from agents.endpoints (optional)".into()))])),
                    ]),
                ),
                ("required", Json::Arr(vec![Json::Str("track".into())])),
            ]),
        ),
        ("annotations", obj(vec![("readOnlyHint", Json::Bool(true))])),
    ])]
}

/// Runs an extra tool, or None when `name` is not one.
pub fn call_extra(server: &Server, who: &Identity, name: &str, args: &Json) -> Option<(Result<Json, (i64, String)>, String)> {
    if name != "why" {
        return None;
    }
    let Some(track) = args.get("track").and_then(|t| t.as_str()) else {
        return Some((Err((-32602, "why: the argument \"track\" is required".into())), "missing argument".into()));
    };
    let endpoint = args.get("endpoint").and_then(|e| e.as_str());
    let resp = why(server, who, track, endpoint);
    let ok = resp.status == 200;
    let text = String::from_utf8_lossy(&resp.body).to_string();
    let outcome = format!("HTTP {}", resp.status);
    let content = Json::Arr(vec![obj(vec![("type", Json::Str("text".into())), ("text", Json::Str(text))])]);
    Some((Ok(obj(vec![("content", content), ("isError", Json::Bool(!ok))])), outcome))
}

/// One cited sentence.
pub struct Sentence {
    pub text: String,
    pub cites: Vec<usize>,
}

/// Splits an answer into sentences and keeps those whose citations all name
/// one of `n` records. Returns the kept sentences and how many were removed.
pub fn check_citations(answer: &str, n: usize) -> (Vec<Sentence>, usize) {
    let mut kept = Vec::new();
    let mut removed = 0;
    let mut current = String::new();
    let chars: Vec<char> = answer.chars().collect();
    let mut sentences = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        current.push(chars[i]);
        // A sentence ends at . ! ? followed by whitespace or the end, outside brackets.
        let depth = current.matches('[').count() as i64 - current.matches(']').count() as i64;
        if matches!(chars[i], '.' | '!' | '?' | '\n') && depth == 0 && (i + 1 == chars.len() || chars[i + 1].is_whitespace()) {
            sentences.push(std::mem::take(&mut current));
        }
        i += 1;
    }
    sentences.push(current);
    for s in sentences {
        let s = s.trim().to_string();
        if s.is_empty() {
            continue;
        }
        let mut cites = Vec::new();
        let mut valid = true;
        let mut rest = s.as_str();
        while let Some(open) = rest.find('[') {
            let Some(close) = rest[open..].find(']') else { break };
            for part in rest[open + 1..open + close].split(',') {
                match part.trim().strip_prefix('R').and_then(|d| d.parse::<usize>().ok()) {
                    Some(k) if k >= 1 && k <= n => cites.push(k),
                    _ => valid = false,
                }
            }
            rest = &rest[open + close + 1..];
        }
        if valid && !cites.is_empty() {
            cites.dedup();
            kept.push(Sentence { text: s, cites });
        } else {
            removed += 1;
        }
    }
    (kept, removed)
}

/// The "why?" explanation of one track, as the API answers it.
pub fn why(server: &Server, who: &Identity, track: &str, endpoint: Option<&str>) -> Response {
    let agents = &server.config().agents;
    let level = agents.highest().to_string();
    if agents.rank(&agents.level_of(&who.name, who.via)) < agents.rank(&level) {
        return crate::api::error(403, &format!("refused: the explanation holds {level} data and {} may receive up to {}", who.name, agents.level_of(&who.name, who.via)), "the site's agents.clients sets each identity's level");
    }
    let ep = match crate::model::choose(agents, &level, endpoint) {
        Ok(e) => e.clone(),
        Err(e) => return crate::api::error(if e.starts_with("refused") { 403 } else { 409 }, &e, "agents.endpoints declares each endpoint's data level"),
    };
    let req = Request { method: "GET".into(), path: format!("/v1/explain/{}", crate::http::encode(track)), query: BTreeMap::new(), headers: BTreeMap::new(), body: Vec::new() };
    let resp = server.handle(&req, who.clone());
    if resp.status != 200 {
        return resp;
    }
    let ex = match json::parse(&String::from_utf8_lossy(&resp.body)) {
        Ok(v) => v,
        Err(e) => return crate::api::error(500, &e, ""),
    };
    let mut records: Vec<Json> = Vec::new();
    for key in ["events", "trace"] {
        if let Some(Json::Arr(v)) = ex.get(key) {
            records.extend(v.iter().cloned());
        }
    }
    records.sort_by_key(|r| r.get("step").and_then(|s| s.as_i64()).unwrap_or(0));
    let records: Vec<Json> = records[records.len().saturating_sub(MAX_RECORDS)..].to_vec();
    if records.is_empty() {
        return crate::api::error(409, "no events or trace records name this track among the recent steps", "goat-processors explain shows what the runner holds");
    }
    let mut user = format!("System track {track}: {}\n\nRecords:\n", ex.get("track").map(|t| t.to_string()).unwrap_or_default());
    for (i, r) in records.iter().enumerate() {
        user.push_str(&format!("R{} {}\n", i + 1, r));
    }
    let answer = match crate::model::chat(&ep, SYSTEM_PROMPT, &user) {
        Ok(a) => a,
        Err(e) => return crate::api::error(502, &e, "check the model endpoint, or name another with endpoint"),
    };
    let (kept, removed) = check_citations(&answer, records.len());
    let sentences: Vec<Json> = kept
        .iter()
        .map(|s| {
            obj(vec![
                ("text", Json::Str(s.text.clone())),
                ("cites", Json::Arr(s.cites.iter().map(|c| Json::Str(format!("R{c}"))).collect())),
                ("records", Json::Arr(s.cites.iter().map(|c| records[c - 1].clone()).collect())),
            ])
        })
        .collect();
    let body = obj(vec![
        ("track", Json::Str(track.into())),
        ("endpoint", Json::Str(ep.name.clone())),
        ("endpoint_kind", Json::Str(ep.kind.clone())),
        ("model", ep.model.clone().map(Json::Str).unwrap_or(Json::Null)),
        ("data_level", Json::Str(level)),
        ("records_sent", Json::Int(records.len() as i64)),
        ("sentences", Json::Arr(sentences)),
        ("sentences_removed", Json::Int(removed as i64)),
        ("provenance", obj(vec![("kind", Json::Str("agent".into())), ("agent", Json::Str("goat-processors why".into())), ("inputs", Json::Str(crate::mcp::digest(&user)))])),
    ]);
    server.audit_agent(who, "why", &crate::mcp::digest(&user), &format!("endpoint {} ({}), {} sentences kept, {removed} removed", ep.name, ep.kind, kept.len()));
    Response::json(200, body.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_only_cited_sentences() {
        let a = "The two tracks passed the gate [R1, R2]. They agree in course [R3]. This has no citation. This cites a missing record [R9]. Mixed [R1, R12].";
        let (kept, removed) = check_citations(a, 3);
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0].cites, vec![1, 2]);
        assert_eq!(removed, 3);
        assert_eq!(check_citations("Ends here [R1]", 1).0.len(), 1);
    }
}
