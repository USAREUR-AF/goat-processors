//! The MCP server: the runner's API offered to agents as tools
//! (docs/design/agentic-ai.md, section 4.5).
//!
//! Transport: JSON-RPC 2.0 over HTTP, `POST /mcp` on the API listeners, one
//! request per POST and the response in the reply (the MCP "Streamable HTTP"
//! transport without server-sent events). `goat-processors mcp` bridges a
//! stdio MCP client to it.
//!
//! **Authority.** A tool call runs as the same API request a CLI verb makes,
//! with the caller's identity and role, through `Server::handle`, so a tool
//! can do nothing the caller could not do with the CLI. Action tools also
//! need the site policy `agents.actions` to name the caller.
//!
//! **Data level.** Each tool has the level of the data it returns. A caller
//! receives data up to its level (`agents.local_level`, `agents.clients`);
//! a tool above it is refused.
//!
//! **Audit.** Every `tools/call`, allowed or refused, is written to the audit
//! log with the identity, the tool, the SHA-256 of its arguments and the result.

use std::collections::BTreeMap;

use goat_correlator::json::{self, Json};

use crate::api::{Identity, Server};
use crate::http::{Request, Response};

pub const PROTOCOL: &str = "2025-06-18";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Class {
    Read,
    Proposal,
    Source,
    Action,
}

impl Class {
    pub fn name(self) -> &'static str {
        match self {
            Class::Read => "read",
            Class::Proposal => "proposal",
            Class::Source => "source",
            Class::Action => "action",
        }
    }
}

/// Which data level a tool returns: the site's lowest, or its highest.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Level {
    Lowest,
    Highest,
}

pub struct Tool {
    pub name: &'static str,
    pub class: Class,
    pub level: Level,
    pub description: &'static str,
    /// (argument, type, description, required)
    pub args: &'static [(&'static str, &'static str, &'static str, bool)],
    /// The API route it calls: method and path, with `{arg}` filled from the arguments.
    pub method: &'static str,
    pub path: &'static str,
    /// The argument sent as the body, if any; `{json}` wraps the named arguments as an object.
    pub body: Option<&'static str>,
}

pub const TOOLS: &[Tool] = &[
    Tool { name: "status", class: Class::Read, level: Level::Highest, description: "The runner's state, pipeline and counters per source.", args: &[], method: "GET", path: "/v1/status", body: None },
    Tool { name: "health", class: Class::Read, level: Level::Lowest, description: "Whether the runner is running and ticking.", args: &[], method: "GET", path: "/v1/health", body: None },
    Tool { name: "pipeline", class: Class::Read, level: Level::Lowest, description: "Each function in the running pipeline and its pack.", args: &[], method: "GET", path: "/v1/pipeline", body: None },
    Tool { name: "packs", class: Class::Read, level: Level::Lowest, description: "Every installed pack, by function.", args: &[], method: "GET", path: "/v1/packs", body: None },
    Tool { name: "metrics", class: Class::Read, level: Level::Highest, description: "Reports per second, processing latency and counts per source.", args: &[], method: "GET", path: "/v1/metrics", body: None },
    Tool { name: "tracks", class: Class::Read, level: Level::Highest, description: "The system tracks of the latest tick: id, members, position, course, speed.", args: &[], method: "GET", path: "/v1/tracks", body: None },
    Tool {
        name: "explain",
        class: Class::Read,
        level: Level::Highest,
        description: "The events and trace records behind one system track: every test the runner ran on it or its members.",
        args: &[("track", "string", "a system track id, from the tracks tool", true)],
        method: "GET",
        path: "/v1/explain/{track}",
        body: None,
    },
    Tool {
        name: "replay",
        class: Class::Read,
        level: Level::Lowest,
        description: "Run the given replay file (a vector, or JSON lines of reports or steps) through a separate copy of the configured pipeline, and return its output lines.",
        args: &[("content", "string", "the replay file's text", true)],
        method: "POST",
        path: "/v1/replay",
        body: Some("content"),
    },
    Tool { name: "routes", class: Class::Read, level: Level::Lowest, description: "Every API route and the role it needs.", args: &[], method: "GET", path: "/v1/routes", body: None },
    Tool {
        name: "use_pack",
        class: Class::Action,
        level: Level::Lowest,
        description: "Select the pack one function runs, now. Needs the role operate and the site policy agents.actions.",
        args: &[("function", "string", "filter, correlate, fuse or quality", true), ("pack", "string", "a pack name, from the packs tool", true)],
        method: "PUT",
        path: "/v1/pipeline/{function}",
        body: Some("{json:pack}"),
    },
    Tool { name: "proposals", class: Class::Read, level: Level::Lowest, description: "Every settings proposal, pending and decided.", args: &[], method: "GET", path: "/v1/proposals", body: None },
    Tool {
        name: "propose",
        class: Class::Proposal,
        level: Level::Lowest,
        description: "Propose that one function run another installed pack, with a reason. Nothing changes until it is applied: by a person, or by the site policy after its gate.",
        args: &[("function", "string", "filter, correlate, fuse or quality", true), ("pack", "string", "a pack name, from the packs tool", true), ("reason", "string", "why, in a sentence or two", true)],
        method: "POST",
        path: "/v1/proposals",
        body: Some("{json:function,pack,reason}"),
    },
    Tool {
        name: "approve",
        class: Class::Action,
        level: Level::Lowest,
        description: "Apply a pending proposal. Needs the role operate and the site policy agents.actions.",
        args: &[("id", "string", "a proposal id, from the proposals tool", true)],
        method: "POST",
        path: "/v1/proposals/{id}/approve",
        body: None,
    },
    Tool {
        name: "reject",
        class: Class::Action,
        level: Level::Lowest,
        description: "Reject a pending proposal. Needs the role operate and the site policy agents.actions.",
        args: &[("id", "string", "a proposal id", true)],
        method: "POST",
        path: "/v1/proposals/{id}/reject",
        body: None,
    },
    Tool {
        name: "revert",
        class: Class::Action,
        level: Level::Lowest,
        description: "Restore the pack an applied proposal replaced. Needs the role operate and the site policy agents.actions.",
        args: &[("id", "string", "a proposal id", true)],
        method: "POST",
        path: "/v1/proposals/{id}/revert",
        body: None,
    },
    Tool {
        name: "publish",
        class: Class::Source,
        level: Level::Lowest,
        description: "Publish shared-model reports as this agent's source (agents.sources gives its source id). Each report needs track.source_id, uid, time_ms, lat, lon and provenance.model; the runner marks them agent-derived with your identity.",
        args: &[("reports", "string", "one report as a JSON object, a JSON array of reports, or JSON lines", true)],
        method: "POST",
        path: "/v1/source",
        body: Some("reports"),
    },
    Tool { name: "stop", class: Class::Action, level: Level::Lowest, description: "Pause processing. Needs the role operate and the site policy agents.actions.", args: &[], method: "POST", path: "/v1/stop", body: None },
    Tool { name: "start", class: Class::Action, level: Level::Lowest, description: "Resume processing. Needs the role operate and the site policy agents.actions.", args: &[], method: "POST", path: "/v1/start", body: None },
];

/// SHA-256 of a text, as hex.
pub fn digest(text: &str) -> String {
    ring::digest::digest(&ring::digest::SHA256, text.as_bytes()).as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

fn obj(pairs: Vec<(&str, Json)>) -> Json {
    Json::Obj(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

fn s(v: &str) -> Json {
    Json::Str(v.into())
}

fn tool_json(t: &Tool) -> Json {
    let mut props = BTreeMap::new();
    let mut required = Vec::new();
    for (name, ty, desc, req) in t.args {
        props.insert(name.to_string(), obj(vec![("type", s(ty)), ("description", s(desc))]));
        if *req {
            required.push(s(name));
        }
    }
    obj(vec![
        ("name", s(t.name)),
        ("description", s(&format!("{} (class {}, data level {})", t.description, t.class.name(), if t.level == Level::Lowest { "lowest" } else { "highest" }))),
        ("inputSchema", obj(vec![("type", s("object")), ("properties", Json::Obj(props)), ("required", Json::Arr(required))])),
        ("annotations", obj(vec![("readOnlyHint", Json::Bool(t.class == Class::Read)), ("destructiveHint", Json::Bool(false))])),
    ])
}

fn rpc_result(id: &Json, result: Json) -> Response {
    Response::json(200, obj(vec![("jsonrpc", s("2.0")), ("id", id.clone()), ("result", result)]).to_string())
}

fn rpc_error(id: &Json, code: i64, message: &str) -> Response {
    Response::json(200, obj(vec![("jsonrpc", s("2.0")), ("id", id.clone()), ("error", obj(vec![("code", Json::Int(code)), ("message", s(message))]))]).to_string())
}

fn tool_result(text: String, is_error: bool) -> Json {
    obj(vec![("content", Json::Arr(vec![obj(vec![("type", s("text")), ("text", Json::Str(text))])])), ("isError", Json::Bool(is_error))])
}

/// Answers one JSON-RPC message posted to /mcp.
pub fn handle(server: &Server, req: &Request, who: &Identity) -> Response {
    let text = String::from_utf8_lossy(&req.body);
    let msg = match json::parse(&text) {
        Ok(m) => m,
        Err(e) => return rpc_error(&Json::Null, -32700, &format!("parse error: {e}")),
    };
    let id = msg.get("id").cloned().unwrap_or(Json::Null);
    let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
    let params = msg.get("params").cloned().unwrap_or(Json::Obj(BTreeMap::new()));
    match method {
        "initialize" => rpc_result(
            &id,
            obj(vec![
                ("protocolVersion", s(PROTOCOL)),
                ("capabilities", obj(vec![("tools", obj(vec![("listChanged", Json::Bool(false))]))])),
                ("serverInfo", obj(vec![("name", s("goat-processors")), ("version", s(env!("CARGO_PKG_VERSION")))])),
                (
                    "instructions",
                    s("Tools of a goat-processors runner. Read tools return the runner's state, tracks and the trace behind a decision; action tools change the running pipeline and need the site policy. Every call is audited under your identity."),
                ),
            ]),
        ),
        m if m.starts_with("notifications/") => Response { status: 202, content_type: "application/json", body: Vec::new() },
        "ping" => rpc_result(&id, obj(vec![])),
        "tools/list" => rpc_result(&id, obj(vec![("tools", Json::Arr(TOOLS.iter().map(tool_json).chain(crate::agentic::extra_tools()).collect()))])),
        "tools/call" => {
            let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("").to_string();
            let args = params.get("arguments").cloned().unwrap_or(Json::Obj(BTreeMap::new()));
            let (result, outcome) = call_tool(server, who, &name, &args);
            server.audit_agent(who, &name, &digest(&args.to_string()), &outcome);
            match result {
                Ok(r) => rpc_result(&id, r),
                Err((code, m)) => rpc_error(&id, code, &m),
            }
        }
        "" => rpc_error(&id, -32600, "not a JSON-RPC request: no method"),
        other => rpc_error(&id, -32601, &format!("no method {other:?}")),
    }
}

/// Runs one tool. Returns the tool result (or a JSON-RPC error) and the
/// outcome written to the audit log.
fn call_tool(server: &Server, who: &Identity, name: &str, args: &Json) -> (Result<Json, (i64, String)>, String) {
    if let Some(r) = crate::agentic::call_extra(server, who, name, args) {
        return r;
    }
    let Some(t) = TOOLS.iter().find(|t| t.name == name) else {
        return (Err((-32602, format!("no tool {name:?}; tools/list lists them"))), "unknown tool".into());
    };
    let agents = &server.config().agents;
    // Data level: what the tool returns, against what the caller may receive.
    let caller = agents.level_of(&who.name, who.via);
    let tool_level = if t.level == Level::Lowest { agents.lowest() } else { agents.highest() };
    if agents.rank(tool_level) > agents.rank(&caller) {
        let m = format!("refused: {name} returns {tool_level} data and {} may receive up to {caller}", who.name);
        return (Ok(tool_result(m.clone(), true)), m);
    }
    // Site policy for action tools.
    if t.class == Class::Action && !agents.actions.iter().any(|g| g.who == who.name && g.actions.iter().any(|a| a == name)) {
        let m = format!("refused: the site policy (agents.actions) does not let {} call {name}", who.name);
        return (Ok(tool_result(m.clone(), true)), m);
    }
    // The same API request the CLI makes, with the caller's identity.
    let mut path = t.path.to_string();
    for (a, _, _, required) in t.args {
        let v = args.get(a).and_then(|v| v.as_str()).map(str::to_string);
        if *required && v.is_none() {
            return (Err((-32602, format!("{name}: the argument {a:?} is required (a string)"))), "missing argument".into());
        }
        path = path.replace(&format!("{{{a}}}"), &crate::http::encode(&v.unwrap_or_default()));
    }
    let body = match t.body {
        None => Vec::new(),
        Some(spec) if spec.starts_with("{json:") => {
            let keys: Vec<&str> = spec.trim_start_matches("{json:").trim_end_matches('}').split(',').collect();
            let m: BTreeMap<String, Json> = keys.iter().filter_map(|k| args.get(k).map(|v| (k.to_string(), v.clone()))).collect();
            Json::Obj(m).to_string().into_bytes()
        }
        Some(arg) => args.get(arg).and_then(|v| v.as_str()).unwrap_or("").as_bytes().to_vec(),
    };
    let req = Request { method: t.method.into(), path, query: BTreeMap::new(), headers: BTreeMap::new(), body };
    let resp = server.handle(&req, who.clone());
    let text = String::from_utf8_lossy(&resp.body).to_string();
    let ok = (200..300).contains(&resp.status);
    (Ok(tool_result(text, !ok)), format!("HTTP {}", resp.status))
}
