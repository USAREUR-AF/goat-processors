//! The runner's one config file, `/etc/goat-processors/runner.yaml`.
//!
//! Reading has two passes. The first is the schema: every key is known, every
//! value has its type (`deny_unknown_fields`). The second checks meaning: the
//! pipeline order, pack names, key expressions, file paths, addresses. Every
//! problem is reported as `<where>: <what is wrong>. <what to do>`, and all of
//! them are reported at once.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use serde::Deserialize;

pub const DEFAULT_PATH: &str = "/etc/goat-processors/runner.yaml";
pub const DEFAULT_PACKS_DIR: &str = "/usr/share/goat-processors/packs";
/// The marker in the shipped config for a value each site must set.
pub const PLACEHOLDER: &str = "CHANGE-ME";
pub const DEFAULT_STATUS_FILE: &str = "/run/goat-processors/status.json";

/// The four functions, in the order the brief states them.
pub const FUNCTIONS: [&str; 4] = ["filter", "correlate", "fuse", "quality"];

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// Names this runner in its output keys. Letters, digits, `-` and `_`.
    pub name: String,
    /// The site this runner serves. Same characters as `name`.
    pub site: String,
    #[serde(default = "default_packs_dir")]
    pub packs_dir: PathBuf,
    /// Interval between ticks, milliseconds.
    #[serde(default = "default_tick_ms")]
    pub tick_ms: i64,
    /// `wall`: ticks follow this host's clock. `input`: ticks follow the
    /// latest `time_ms` the runner has read (for replaying old data).
    #[serde(default)]
    pub clock: Clock,
    #[serde(default)]
    pub fabric: Option<Fabric>,
    #[serde(default)]
    pub inputs: Inputs,
    pub pipeline: Vec<Stage>,
    #[serde(default)]
    pub outputs: Outputs,
    #[serde(default)]
    pub record: Option<Record>,
    #[serde(default = "default_status_file")]
    pub status_file: PathBuf,
    #[serde(default)]
    pub api: Api,
    #[serde(default)]
    pub agents: Agents,
}

/// The agent interfaces (docs/design/agentic-ai.md). Every part is optional;
/// with all of them on and no agent connected the runner's output is the same.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Agents {
    /// Serve the MCP endpoint (`POST /mcp`) on the API listeners.
    #[serde(default = "default_true")]
    pub mcp: bool,
    /// The site's data levels, from the least to the most sensitive.
    #[serde(default = "default_levels")]
    pub data_levels: Vec<String>,
    /// The highest level a local caller may receive. Default: the highest level.
    #[serde(default)]
    pub local_level: Option<String>,
    /// The highest level each mesh identity may receive. An identity not
    /// listed receives the lowest level only.
    #[serde(default)]
    pub clients: Vec<ClientLevel>,
    /// The model endpoints the runner's own agent features may call.
    #[serde(default)]
    pub endpoints: Vec<Endpoint>,
    /// Which identities may call which MCP action tools.
    #[serde(default)]
    pub actions: Vec<ActionGrant>,
    /// Proposals an identity may have applied without a person, within bounds,
    /// once a gate passes.
    #[serde(default)]
    pub auto_approve: Vec<AutoApprove>,
    /// Which identity may publish reports as which source (`POST /v1/source`).
    #[serde(default)]
    pub sources: Vec<AgentSource>,
    /// Where pending and decided proposals are kept.
    #[serde(default = "default_proposals_file")]
    pub proposals_file: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AgentSource {
    /// The publishing identity: `local-admin`, `local`, or a mesh certificate name.
    pub who: String,
    /// The `track.source_id` its reports must carry, for example `agent-vision`.
    pub source_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AutoApprove {
    /// The proposing identity.
    pub who: String,
    /// The function whose pack it may change.
    pub function: String,
    /// The packs it may select: the bounds.
    pub packs: Vec<String>,
    /// A command that must exit 0 before the change applies, for example
    /// `[goat-processors, selftest]` or the site's benchmark gate. It runs
    /// with the proposal in GOAT_PROPOSAL_FUNCTION and GOAT_PROPOSAL_PACK.
    pub gate: Vec<String>,
    /// Seconds the gate may run.
    #[serde(default = "default_gate_s")]
    pub gate_timeout_s: u64,
}

impl Default for Agents {
    fn default() -> Self {
        Agents {
            mcp: true,
            data_levels: default_levels(),
            local_level: None,
            clients: vec![],
            endpoints: vec![],
            actions: vec![],
            auto_approve: vec![],
            sources: vec![],
            proposals_file: default_proposals_file(),
        }
    }
}

impl Agents {
    /// The rank of a level on the site's scale.
    pub fn rank(&self, level: &str) -> Option<usize> {
        self.data_levels.iter().position(|l| l == level)
    }
    pub fn lowest(&self) -> &str {
        self.data_levels.first().map(String::as_str).unwrap_or("public")
    }
    pub fn highest(&self) -> &str {
        self.data_levels.last().map(String::as_str).unwrap_or("site")
    }
    /// The highest level an identity may receive.
    pub fn level_of(&self, who: &str, via: &str) -> String {
        if via == "local" {
            return self.local_level.clone().unwrap_or_else(|| self.highest().to_string());
        }
        self.clients.iter().find(|c| c.name == who).map(|c| c.data_level.clone()).unwrap_or_else(|| self.lowest().to_string())
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientLevel {
    pub name: String,
    pub data_level: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Endpoint {
    pub name: String,
    /// An OpenAI-compatible chat completions URL, for example
    /// `http://127.0.0.1:8080/v1/chat/completions`.
    pub url: String,
    /// `local` (on machines the site controls) or `hosted` (run by a provider).
    pub kind: String,
    /// The highest data level this endpoint may receive.
    pub data_level: String,
    #[serde(default)]
    pub model: Option<String>,
    /// A file holding the API key the endpoint expects, if any.
    #[serde(default)]
    pub key_file: Option<PathBuf>,
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: u64,
    /// For https: a CA certificate (PEM) to trust besides the public ones.
    #[serde(default)]
    pub ca_file: Option<PathBuf>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActionGrant {
    /// An identity: `local-admin`, or a mesh certificate name.
    pub who: String,
    /// Action tools it may call: `use_pack`, `stop`, `start`, `approve`.
    pub actions: Vec<String>,
}

/// The HTTP API (runner/openapi.yaml). The local listener is plain HTTP on
/// the loopback interface; the mesh listener requires mutual TLS.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Api {
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// Loopback address and port of the local listener.
    #[serde(default = "default_api_listen")]
    pub listen: String,
    /// The file holding the token a local caller shows to change anything.
    /// The service writes it at start, readable by root only.
    #[serde(default = "default_token_file")]
    pub token_file: PathBuf,
    /// Every request that changes something, and every refused request, is
    /// appended here as one JSON line.
    #[serde(default = "default_audit_file")]
    pub audit_file: PathBuf,
    #[serde(default)]
    pub mesh: Option<ApiMesh>,
}

impl Default for Api {
    fn default() -> Self {
        Api { enabled: true, listen: default_api_listen(), token_file: default_token_file(), audit_file: default_audit_file(), mesh: None }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApiMesh {
    /// Address and port to listen on, for example `0.0.0.0:8471`.
    pub listen: String,
    /// The server certificate and the CA that signs client certificates.
    /// Default: the fabric's `tls` section.
    #[serde(default)]
    pub tls: Option<Tls>,
    /// Who may call: the common name (CN) of a client certificate, and its role.
    pub allow: Vec<Allow>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Allow {
    pub name: String,
    pub role: Role,
}

/// What a caller may do. `read`: every GET route and replay. `operate`: also
/// select packs, stop and start.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Read,
    Operate,
}

impl Role {
    pub fn name(self) -> &'static str {
        match self {
            Role::Read => "read",
            Role::Operate => "operate",
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Clock {
    #[default]
    Wall,
    Input,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fabric {
    /// `client` (connects to routers; the usual case) or `peer`.
    #[serde(default = "default_mode")]
    pub mode: String,
    /// Locators to connect to, for example `tls/router.site-a:7447`.
    #[serde(default)]
    pub connect: Vec<String>,
    /// Locators to listen on (peer mode). Usually empty.
    #[serde(default)]
    pub listen: Vec<String>,
    #[serde(default)]
    pub tls: Option<Tls>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tls {
    /// The certificate authority that signed the routers' certificates (PEM).
    pub root_ca: PathBuf,
    /// This runner's client certificate (PEM), for mutual TLS.
    pub certificate: PathBuf,
    /// The private key of `certificate` (PEM).
    pub private_key: PathBuf,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Inputs {
    #[serde(default)]
    pub fabric: Option<FabricInput>,
    #[serde(default)]
    pub udp: Vec<UdpInput>,
    #[serde(default)]
    pub file: Option<FileInput>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FabricInput {
    /// Key expressions to subscribe to.
    pub keys: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UdpInput {
    /// Address and port to listen on, for example `0.0.0.0:6000`.
    pub listen: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileInput {
    pub path: PathBuf,
    /// 1 plays the file at the pace its report times give; 10 plays it ten
    /// times faster; 0 reads it as fast as possible.
    #[serde(default = "default_speed")]
    pub speed: f64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Stage {
    pub function: String,
    /// A pack directory name under `packs_dir`, for example
    /// `correlate-assign-time`, or a path to a pack directory.
    pub pack: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Outputs {
    #[serde(default)]
    pub fabric: Option<FabricOutput>,
    #[serde(default)]
    pub file: Option<FileOutput>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FabricOutput {
    /// Key prefix for everything the runner publishes. Default
    /// `data/processed/<site>/<name>`.
    #[serde(default)]
    pub prefix: Option<String>,
    /// Also publish every trace record. Off by default: the trace is large.
    #[serde(default)]
    pub trace: bool,
    /// How tracks and quality reach the fabric. `per-entity` (default): one
    /// key per system track and per quality subject, every tick. `batch`: one
    /// key `<prefix>/tracks` and one key `<prefix>/quality`, each carrying the
    /// whole set in one value, published on a tick only when the set changed
    /// or `heartbeat_ms` has passed since the last publish.
    #[serde(default)]
    pub layout: Layout,
    /// With `layout: batch`, the longest time between two publishes of an
    /// unchanged set, in input-clock milliseconds. Default 5000.
    #[serde(default = "default_heartbeat_ms")]
    pub heartbeat_ms: u64,
}

fn default_heartbeat_ms() -> u64 {
    5000
}

impl Default for FabricOutput {
    fn default() -> Self {
        FabricOutput { prefix: None, trace: false, layout: Layout::PerEntity, heartbeat_ms: default_heartbeat_ms() }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Layout {
    #[default]
    PerEntity,
    Batch,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileOutput {
    /// Appends one JSON line per stage per step.
    pub path: PathBuf,
    #[serde(default)]
    pub trace: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    /// Appends every input and every tick, in the replay format, so that
    /// `goat-processors replay` reproduces the run exactly.
    pub path: PathBuf,
}

fn default_packs_dir() -> PathBuf {
    PathBuf::from(DEFAULT_PACKS_DIR)
}
fn default_tick_ms() -> i64 {
    1000
}
fn default_mode() -> String {
    "client".into()
}
fn default_speed() -> f64 {
    1.0
}
fn default_proposals_file() -> PathBuf {
    PathBuf::from("/var/lib/goat-processors/proposals.json")
}
fn default_gate_s() -> u64 {
    600
}
fn default_levels() -> Vec<String> {
    vec!["public".into(), "site".into()]
}
fn default_timeout_ms() -> u64 {
    30_000
}
fn default_true() -> bool {
    true
}
fn default_api_listen() -> String {
    "127.0.0.1:8470".into()
}
fn default_token_file() -> PathBuf {
    PathBuf::from("/run/goat-processors/api.token")
}
fn default_audit_file() -> PathBuf {
    PathBuf::from("/var/lib/goat-processors/audit.jsonl")
}
fn default_status_file() -> PathBuf {
    PathBuf::from(DEFAULT_STATUS_FILE)
}

impl Config {
    /// The output prefix, with its default.
    pub fn output_prefix(&self) -> String {
        self.outputs
            .fabric
            .as_ref()
            .and_then(|f| f.prefix.clone())
            .unwrap_or_else(|| format!("data/processed/{}/{}", self.site, self.name))
    }

    /// The directory of a stage's pack.
    pub fn pack_dir(&self, stage: &Stage) -> PathBuf {
        if stage.pack.contains('/') {
            PathBuf::from(&stage.pack)
        } else {
            self.packs_dir.join(&stage.pack)
        }
    }
}

/// Reads and checks a config file.
pub fn load(path: &Path) -> Result<Config, Vec<String>> {
    let text = std::fs::read_to_string(path).map_err(|e| {
        vec![format!(
            "{}: cannot read the file ({e}). Check the path, and that the runner's user can read it.",
            path.display()
        )]
    })?;
    parse(&text)
}

/// Parses and checks config text.
pub fn parse(text: &str) -> Result<Config, Vec<String>> {
    let config: Config = serde_norway::from_str(text).map_err(|e| vec![schema_error(&e)])?;
    let mut problems: Vec<String> = text
        .lines()
        .enumerate()
        .filter(|(_, l)| !l.trim_start().starts_with('#') && l.contains(PLACEHOLDER))
        .map(|(n, l)| format!("line {}: `{}` still holds the placeholder {PLACEHOLDER}. Replace it with this site's value (INSTALL.md, step 6).", n + 1, l.trim()))
        .collect();
    problems.extend(check(&config));
    if problems.is_empty() {
        Ok(config)
    } else {
        Err(problems)
    }
}

fn schema_error(e: &serde_norway::Error) -> String {
    let at = match e.location() {
        Some(l) => format!("line {}, column {}", l.line(), l.column()),
        None => "the file".into(),
    };
    let msg = e.to_string();
    let fix = if msg.contains("unknown field") {
        "Remove the key or correct its spelling; the keys each section accepts are in runner/README.md, Configure."
    } else if msg.contains("missing field") {
        "Add the key; runner/README.md, Configure, lists the required keys."
    } else if msg.contains("unknown variant") {
        "Use one of the values the message lists."
    } else {
        "Correct the value's type or the YAML syntax at that place."
    };
    format!("{at}: {msg}. {fix}")
}

/// Every meaning check. Returns the problems found, empty when the config is good.
pub fn check(c: &Config) -> Vec<String> {
    let mut p = Vec::new();
    for (key, value) in [("name", &c.name), ("site", &c.site)] {
        if value.is_empty() || !value.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_') {
            p.push(format!(
                "{key}: {value:?} is not a valid name. Use only letters, digits, `-` and `_`, at least one character."
            ));
        }
    }
    if c.tick_ms < 10 || c.tick_ms > 600_000 {
        p.push(format!("tick_ms: {} is out of range. Use a value from 10 to 600000 (1000 is one tick a second).", c.tick_ms));
    }

    // Pipeline: known functions, each at most once, in the stated order, packs that load.
    if c.pipeline.is_empty() {
        p.push("pipeline: the list is empty. Add at least one stage, for example `- {function: correlate, pack: correlate-assign-time}`.".into());
    }
    let mut last_index: Option<usize> = None;
    for (i, stage) in c.pipeline.iter().enumerate() {
        let at = format!("pipeline[{i}]");
        let Some(index) = FUNCTIONS.iter().position(|f| *f == stage.function) else {
            p.push(format!(
                "{at}.function: {:?} is not a function. Use one of filter, correlate, fuse, quality.",
                stage.function
            ));
            continue;
        };
        if let Some(last) = last_index {
            if index == last {
                p.push(format!("{at}.function: {} appears twice. Keep one stage per function.", stage.function));
            } else if index < last {
                p.push(format!(
                    "{at}.function: {} comes after {}. Stages run in the order filter, correlate, fuse, quality; reorder the list.",
                    stage.function, FUNCTIONS[last]
                ));
            }
        }
        last_index = Some(last_index.map_or(index, |l| l.max(index)));
        let dir = c.pack_dir(stage);
        let base = dir.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !stage.pack.contains('/') && !base.starts_with(&format!("{}-", stage.function)) {
            p.push(format!(
                "{at}.pack: {:?} is not a {} pack. Name a pack whose directory starts with `{}-`; `goat-processors pack ls` lists them.",
                stage.pack, stage.function, stage.function
            ));
            continue;
        }
        if let Err(e) = crate::pipeline::load_stage(&stage.function, &dir) {
            p.push(format!(
                "{at}.pack: {:?} does not load from {} ({e}). Check the name with `goat-processors pack ls`, or the pack's pack.def.",
                stage.pack,
                dir.display()
            ));
        }
    }

    // Fabric.
    let needs_fabric = c.inputs.fabric.is_some() || c.outputs.fabric.is_some();
    match &c.fabric {
        None if needs_fabric => p.push(
            "fabric: missing, but inputs.fabric or outputs.fabric uses it. Add a fabric section with `connect`, or remove the fabric input and output.".into(),
        ),
        None => {}
        Some(f) => {
            if f.mode != "client" && f.mode != "peer" {
                p.push(format!("fabric.mode: {:?} is not a mode. Use `client` or `peer`.", f.mode));
            }
            if f.mode == "client" && f.connect.is_empty() {
                p.push("fabric.connect: empty in client mode. Add the router locator, for example `tls/router.site-a:7447`.".into());
            }
            for (i, loc) in f.connect.iter().chain(f.listen.iter()).enumerate() {
                if let Err(e) = parse_locator(loc) {
                    p.push(format!("fabric locator {i} ({loc:?}): {e}. Write it as `tls/<host>:<port>` or `tcp/<host>:<port>`."));
                } else if loc.starts_with("tls/") && f.tls.is_none() {
                    p.push(format!("fabric: {loc:?} uses TLS but there is no fabric.tls section. Add root_ca, certificate and private_key."));
                }
            }
            if let Some(t) = &f.tls {
                for (k, path) in [("root_ca", &t.root_ca), ("certificate", &t.certificate), ("private_key", &t.private_key)] {
                    if !path.is_absolute() {
                        p.push(format!("fabric.tls.{k}: {} is not an absolute path. Give the full path, for example /etc/goat-processors/tls/{k}.pem.", path.display()));
                    }
                }
            }
        }
    }

    // API.
    if c.api.enabled {
        match c.api.listen.parse::<SocketAddr>() {
            Err(_) => p.push(format!("api.listen: {:?} is not an address. Write it as `127.0.0.1:8470`.", c.api.listen)),
            Ok(a) if !a.ip().is_loopback() => p.push(format!(
                "api.listen: {} is not a loopback address. The local API is plain HTTP; use 127.0.0.1, and api.mesh for access from other hosts (mutual TLS).",
                c.api.listen
            )),
            Ok(_) => {}
        }
        if let Some(m) = &c.api.mesh {
            if m.listen.parse::<SocketAddr>().is_err() {
                p.push(format!("api.mesh.listen: {:?} is not an address. Write it as `<ip>:<port>`, for example `0.0.0.0:8471`.", m.listen));
            }
            if m.tls.is_none() && c.fabric.as_ref().and_then(|f| f.tls.as_ref()).is_none() {
                p.push("api.mesh: no certificates. Add api.mesh.tls (root_ca, certificate, private_key), or a fabric.tls section it can use.".into());
            }
            if m.allow.is_empty() {
                p.push("api.mesh.allow: empty, so no one could call. Add `- {name: <certificate CN>, role: read}`.".into());
            }
            for (i, a) in m.allow.iter().enumerate() {
                if a.name.is_empty() {
                    p.push(format!("api.mesh.allow[{i}].name: empty. Give the common name (CN) of the caller's certificate."));
                }
            }
        }
    }

    // Agents.
    let ag = &c.agents;
    if ag.data_levels.is_empty() {
        p.push("agents.data_levels: empty. List the site's levels from the least to the most sensitive, for example [public, site].".into());
    }
    let level_ok = |l: &str| ag.rank(l).is_some();
    let levels = ag.data_levels.join(", ");
    if let Some(l) = &ag.local_level {
        if !level_ok(l) {
            p.push(format!("agents.local_level: {l:?} is not one of agents.data_levels ({levels}). Use one of them."));
        }
    }
    for (i, cl) in ag.clients.iter().enumerate() {
        if !level_ok(&cl.data_level) {
            p.push(format!("agents.clients[{i}].data_level: {:?} is not one of agents.data_levels ({levels}). Use one of them.", cl.data_level));
        }
    }
    for (i, e) in ag.endpoints.iter().enumerate() {
        if !level_ok(&e.data_level) {
            p.push(format!("agents.endpoints[{i}].data_level: {:?} is not one of agents.data_levels ({levels}). Use one of them.", e.data_level));
        }
        if e.kind != "local" && e.kind != "hosted" {
            p.push(format!("agents.endpoints[{i}].kind: {:?} is not a kind. Use `local` (a machine the site controls) or `hosted` (a provider).", e.kind));
        }
        if !(e.url.starts_with("http://") || e.url.starts_with("https://")) {
            p.push(format!("agents.endpoints[{i}].url: {:?} is not an http or https URL.", e.url));
        }
    }
    for (i, r) in ag.auto_approve.iter().enumerate() {
        if !FUNCTIONS.contains(&r.function.as_str()) {
            p.push(format!("agents.auto_approve[{i}].function: {:?} is not a function. Use filter, correlate, fuse or quality.", r.function));
        }
        if r.gate.is_empty() {
            p.push(format!("agents.auto_approve[{i}].gate: empty. Name the command that must pass, for example [goat-processors, selftest]."));
        }
        for pk in &r.packs {
            if !pk.starts_with(&format!("{}-", r.function)) {
                p.push(format!("agents.auto_approve[{i}].packs: {pk:?} is not a {} pack.", r.function));
            }
        }
    }
    for (i, g) in ag.actions.iter().enumerate() {
        for a in &g.actions {
            if !["use_pack", "stop", "start", "approve", "reject", "revert"].contains(&a.as_str()) {
                p.push(format!("agents.actions[{i}].actions: {a:?} is not an action tool. Use use_pack, stop, start, approve, reject or revert."));
            }
        }
    }

    // Inputs.
    let has_input = c.inputs.fabric.is_some() || !c.inputs.udp.is_empty() || c.inputs.file.is_some();
    if !has_input {
        p.push("inputs: none. Add inputs.fabric (keys to subscribe to), inputs.udp or inputs.file.".into());
    }
    let prefix = c.output_prefix();
    if let Err(e) = check_key(&prefix, false) {
        p.push(format!("outputs.fabric.prefix: {prefix:?} {e}. Use `/`-separated words with no wildcards."));
    }
    if let Some(fi) = &c.inputs.fabric {
        if fi.keys.is_empty() {
            p.push("inputs.fabric.keys: empty. Add a key expression, for example `data/entity/track/**`.".into());
        }
        for (i, k) in fi.keys.iter().enumerate() {
            if let Err(e) = check_key(k, true) {
                p.push(format!("inputs.fabric.keys[{i}]: {k:?} {e}. Write a key expression such as `data/entity/track/**`."));
            } else if c.outputs.fabric.is_some() && key_intersects(k, &format!("{prefix}/x")) {
                p.push(format!(
                    "inputs.fabric.keys[{i}]: {k:?} also matches the runner's own output prefix {prefix:?}, so the runner would read what it publishes. Narrow the key, or change outputs.fabric.prefix."
                ));
            }
        }
    }
    for (i, u) in c.inputs.udp.iter().enumerate() {
        if u.listen.parse::<SocketAddr>().is_err() {
            p.push(format!("inputs.udp[{i}].listen: {:?} is not an address. Write it as `<ip>:<port>`, for example `0.0.0.0:6000`.", u.listen));
        }
    }
    if let Some(f) = &c.inputs.file {
        if !(f.speed >= 0.0 && f.speed.is_finite()) {
            p.push(format!("inputs.file.speed: {} is not 0 or above. Use 1 for real time, a larger number to play faster, 0 for as fast as possible.", f.speed));
        }
        if c.clock == Clock::Wall {
            p.push("inputs.file: a file input needs `clock: input`, so that ticks follow the file's report times. Set `clock: input`.".into());
        }
    }
    p
}

/// A fabric locator: `<proto>/<host>:<port>`.
pub fn parse_locator(loc: &str) -> Result<(String, String, u16), String> {
    let (proto, rest) = loc.split_once('/').ok_or("no protocol")?;
    if proto != "tls" && proto != "tcp" && proto != "quic" {
        return Err(format!("protocol {proto:?} is not tls, tcp or quic"));
    }
    let rest = rest.split('#').next().unwrap_or(rest);
    let (host, port) = rest.rsplit_once(':').ok_or("no port")?;
    let port: u16 = port.parse().map_err(|_| format!("port {port:?} is not a number"))?;
    let host = host.trim_start_matches('[').trim_end_matches(']');
    if host.is_empty() {
        return Err("no host".into());
    }
    Ok((proto.to_string(), host.to_string(), port))
}

/// A key or key expression: non-empty `/`-separated chunks; wildcards only
/// when `wild`, and only as a whole chunk (`*` or `**`).
pub fn check_key(k: &str, wild: bool) -> Result<(), String> {
    if k.is_empty() || k.starts_with('/') || k.ends_with('/') {
        return Err("is empty or starts or ends with `/`".into());
    }
    for chunk in k.split('/') {
        if chunk.is_empty() {
            return Err("has an empty chunk (`//`)".into());
        }
        if chunk == "*" || chunk == "**" {
            if !wild {
                return Err("has a wildcard".into());
            }
            continue;
        }
        if chunk.contains(['*', '$', '?', '#']) {
            return Err(format!("has a reserved character in chunk {chunk:?}"));
        }
    }
    Ok(())
}

/// Whether a key expression (with `*` and `**` chunks) matches a plain key.
pub fn key_intersects(expr: &str, key: &str) -> bool {
    fn m(e: &[&str], k: &[&str]) -> bool {
        match (e.first(), k.first()) {
            (None, None) => true,
            (Some(&"**"), _) => m(&e[1..], k) || (!k.is_empty() && m(e, &k[1..])),
            (Some(&"*"), Some(_)) => m(&e[1..], &k[1..]),
            (Some(a), Some(b)) => a == b && m(&e[1..], &k[1..]),
            _ => false,
        }
    }
    let e: Vec<&str> = expr.split('/').collect();
    let k: Vec<&str> = key.split('/').collect();
    m(&e, &k)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_matching() {
        assert!(key_intersects("data/**", "data/processed/a/b/x"));
        assert!(key_intersects("data/*/track/**", "data/entity/track/s/1"));
        assert!(!key_intersects("data/entity/track/**", "data/processed/a/b/x"));
        assert!(key_intersects("**", "a"));
    }

    #[test]
    fn locators() {
        assert_eq!(parse_locator("tls/router:7447").unwrap().2, 7447);
        assert!(parse_locator("router:7447").is_err());
        assert!(parse_locator("tcp/router").is_err());
        assert_eq!(parse_locator("tcp/[::1]:7447").unwrap().1, "::1");
    }
}
