# Agentic AI with goat-processors

Status: Written. Section 5 gives the status of each interface it describes.
A worked example of each, runnable, is in
[runner/examples/README.md](../../runner/examples/README.md).

goat-processors decides, for every report, which object it belongs to, how
sources combine, and how good each source is. It does this with fixed,
written rules: the same input always gives the same output, and every test
it runs is recorded. This document is for anyone who wants an AI agent to
work alongside those rules: to feed them, to settle cases they find hard, to
tune them, or to explain and query what they decided. It describes the
places where an agent connects to the runner, what each kind of use costs,
and what to put in place for it. It forbids nothing. The choice of what to
build belongs to the builder and the site.

## 1. Words used here

| Word | Meaning |
|---|---|
| agent | a program that uses a language model (an AI model that reads and writes text) to decide what to do, often by calling tools |
| model endpoint | the address of a model the runner may send text to: a model on the site's own machines (local) or a model run by a provider (hosted) |
| MCP | Model Context Protocol: an open protocol by which an agent discovers and calls tools a server offers. The runner offers its API as MCP tools |
| tool | one operation an agent may call, such as "list the system tracks" or "propose a pack change" |
| runner | the goat-processors service on a site's machine (`runner/README.md`) |
| report | one message from one source about one object, in the shared model |
| system track | the runner's output for one object: the source tracks judged to describe it, and one estimate |
| pack | a named settings file for one function, in `packs/` |
| trace record | one line per test the runner ran: what it compared, the value, the limit, the result |
| hint | an input record that states an association or fusion decision about two tracks, with its author and reason (section 4.2) |
| data level | how sensitive the data in a request is, on the scale the site declares (section 3) |
| provenance | where a piece of data came from: for agent output, which agent, which model, and which inputs |
| fabric | the goat data network (Zenoh): programs publish values under keys and receive the keys they subscribe to |
| mesh | the site's network between hosts; the runner's mesh API listens on it with mutual TLS (`api.mesh`) |
| tick | the moment the runner makes its output for a time `now_ms`, once a second by default |
| record file | the file the runner writes every input and tick to (`record.path`), so a replay gives the same output |
| identity | who is calling: `local-admin` (a local caller with the token, that is, with `sudo`), `local` (without it), or the name in a mesh client certificate |
| role | what an identity may do through the API: `read`, or `operate` (also select packs, stop, start, decide proposals) |
| gate | a command that must exit 0 before a proposal applies under the site policy |
| audit log | the file of every change and every agent call, with its identity (`api.audit_file`) |

## 2. How an agent connects

An agent reaches the processors through the same interfaces a person or a
program uses, with its own identity. Its contribution enters the engines as
recorded input (a source report, a hint, a pack), so the engines stay exact,
recorded and reproducible, and the agent's part is traced, replayed and
audited like everything else.

| Extension point | Direction | What the agent does | Section |
|---|---|---|---|
| Agent as a source | input | publishes tracks, identities or annotations under its own identity; the runner processes them like any other source | 4.1 |
| Agent as an adjudicator | input | sends hints ("treat A and B as one object", "keep A and B apart") that the engines take as recorded input | 4.2 |
| Agent changing settings | control | proposes a pack or parameter change; a person approves it, or a site policy approves it within bounds after a gate | 4.3 |
| Agent in the loop at speed | input | sends source data, or hints, for every report or tick, from a local model (uses 4.1 and 4.2) | 4.4 |
| Agent reading and explaining | output | queries tracks, quality and trace through MCP read tools, and explains decisions | 4.5 |

Every agent use rests on four requirements (section 6): the agent's actions
carry its identity and are audited; agent-derived data is labeled; data goes
to a model only up to the level the site declares for it; and the data path
works when no agent is present.

## 3. Trade-offs, and the safeguard each needs

Any agent use sits somewhere on each dimension below. Moving along a
dimension changes what it costs and what to put in place. The tables say
both. They are a guide for the builder, not a gate. "Put in place" is the
builder's work, in the agent or around it, unless a cell names a runner
setting.

### 3.1 Latency

An agent's answer takes from a fraction of a second (a small local model) to
tens of seconds (a large hosted model with tool calls). The runner processes
a report in a few milliseconds or less, and ticks once a second by default.
Measured (`docs/performance.md`): the default correlate pack,
`correlate-assign-time`, runs 455 reports per second in the Python engine
(about 2 ms each); the Rust engine the runner uses runs correlate at 2,344
reports per second through its vector command, parsing included (two packs).
The runner itself has no throughput measurement yet.

| Where the agent's answer is needed | Cost | Put in place |
|---|---|---|
| minutes later (a shift summary, a tuning proposal) | none on the data path | nothing beyond section 6 |
| seconds later (an operator asks why two tracks merged) | the operator waits | stream the answer; cite the trace so it can be checked without waiting for prose |
| within one tick (a hint for the next tick's assignment) | a model call per tick, on the critical path | a local model; a deadline per call; a fallback: when no answer arrives by the deadline, the tick proceeds without it (section 4.4) |
| per report | a model call per report, at the report rate | as for "within one tick", plus batching, and a measured worst-case latency under load before deployment |

### 3.2 Volume

| Calls to the model | Cost | Put in place |
|---|---|---|
| per question, per shift, per alert | small | nothing beyond section 6 |
| per new track pair, per ambiguous case | grows with the number of tracks | select the cases first with the engine's own measures (for example a pair whose cost is within the margin of another assignment) and send only those |
| per report or per tick | grows with the report rate (thousands per second at a busy site) | a local model sized for the rate; back-pressure: when the model falls behind, drop or sample requests, and count what was dropped |

### 3.3 Kind of problem

| Problem | What an agent adds | Put in place |
|---|---|---|
| unstructured or messy input: a sample of a new feed, logs, documents, an operator's question | reading and summarizing what has no schema | review of the agent's output by a person or a test before it is used |
| judgment over ambiguous cases: two tracks that may be one object, a source that may be failing | context the rules do not have: an analyst's notes, other intelligence, a pattern over hours | hints with author and reason (section 4.2), so the decision is traced and can be reviewed |
| an exact computation the specs define: gating, assignment, fusion | an alternative method | publish it as a source (4.1) or as hints (4.2) and compare it with the engine on the benchmark (`tools/bench/`) before relying on it |

### 3.4 Effect

| What the agent's output changes | Cost if it is wrong | Put in place |
|---|---|---|
| nothing (it reads and explains) | a wrong explanation | every statement cites the trace record it rests on, so a reader can check it (section 4.5) |
| a proposal | a reviewer's time | the proposal states what it changes and the benchmark result |
| settings, applied by a policy | the site's picture degrades until reverted | bounds per parameter, a gate that must pass, a one-step revert, the audit log (section 4.3) |
| the picture: tracks, identities, associations | others act on agent-derived data | the agent's own identity and key prefix, provenance on every record, so every reader can tell agent-derived data apart (sections 4.1, 4.2) |

### 3.5 Determinism

A model may answer the same question differently twice. The runner keeps
its output reproducible by recording what the agent contributed, not by
making the agent repeatable.

| Agent contribution | How the run stays reproducible |
|---|---|
| hints and source reports | they are runner input: the record file holds them, and a replay of the record gives the same output, byte for byte, without calling the model again |
| an adopted settings change | it becomes a pack in git, with its vectors; from then on it is ordinary data |
| an explanation or a summary | it is advice, not runner output; store it with the trace records it cites if it must be kept |

### 3.6 Data level

What the agent sends to its model decides where the model may run. The site
declares its data levels, least sensitive first, in `agents.data_levels`
(default: `public`, then `site`), and for each model endpoint the highest
level it may receive (`agents.endpoints[].data_level`). The runner refuses a
call that would send data above that level to that endpoint.

| Data the model sees | A hosted model | A local model |
|---|---|---|
| public or synthetic: the repository, the specs, the benchmark scenarios, the docs | usable | usable |
| a site's live or recorded tracks, sources, positions, logs | usable where the site has approved that data for that provider, and declared it as the endpoint's level | usable |
| anything at a site with no connection out | not reachable | usable |

The same levels apply to callers, including an MCP client outside the site.
A local caller receives up to `agents.local_level` (default: the highest
level). A mesh caller receives the level `agents.clients` gives its
certificate name, and the lowest level when it is not listed. A tool whose
data is above the caller's level is refused.

Each tool's data is at either the lowest level (packs, pipeline, health,
routes, replay of data the caller sent) or the highest (status, metrics,
tracks, explain, why). A site that declares more than two levels therefore
sees a caller or endpoint at a middle level treated as at the lowest for
tools.

### 3.7 Locality

| The agent reads | Where it runs | Why |
|---|---|---|
| live tracks or the trace | on the site, against the runner's local API or the mesh API | the data is there, and section 3.6 usually keeps it there |
| recorded runs, the benchmark, specs, code | anywhere with access to those files | nothing live is needed |
| both (tuning against a site's recordings) | on the site, or wherever the recording's data level allows | the recording carries the site's data level |

### 3.8 Hosting

| Model hosted by | Cost | Put in place |
|---|---|---|
| a provider | the data leaves the site; availability depends on the link and the provider | the endpoint's declared data level; a fallback when it is unreachable (every agent feature is optional) |
| the site, on its own machines | hardware, and the site operates the model | size it for the latency and volume of section 3.1 and 3.2 |
| a partner or a central site | data leaves the site, to a party the site trusts | as for a provider: the partner's endpoint is one more entry in `agents.endpoints`, with its own declared level |

## 4. Extension points

### 4.1 Agent as a source

An agent publishes what it derives as a source of its own: tracks,
identities, or annotations on existing tracks. The runner treats it as one
more input, so correlation, fusion and quality apply to it as to any sensor.

**How.** There are two paths. They differ in who vouches for the label.

| | Through the API (`POST /v1/source`, MCP tool `publish`) | On the fabric (the agent's own key prefix) |
|---|---|---|
| Who may publish | an identity `agents.sources` lists, as the one source id it gives it | whoever the site's fabric access rules let publish under that key prefix |
| What the agent sends | shared-model reports with that `track.source_id`, and `provenance.model` (and, if useful, `provenance.inputs`) | shared-model reports, and every provenance key below it wants to carry |
| What the runner adds | `provenance.kind: agent`, `provenance.agent: <caller identity>`, `provenance.checked: true` | nothing; it removes any `provenance.checked` claim |
| What a reader can trust | the runner checked the identity and wrote the label | the label as the publisher wrote it; the fabric's access rules are what stop one publisher posing as another, and a publisher that leaves the keys out is not labeled |

Use the API path when the label must be trusted.

| Key | Content |
|---|---|
| `provenance.kind` | `agent` |
| `provenance.agent` | the agent's identity |
| `provenance.model` | the model and version it used |
| `provenance.inputs` | a digest of, or references to, the inputs it worked from |
| `provenance.checked` | `true` only on a report the runner received through the API |

The runner carries these keys to its output: each output line of an ingest
step shows the report's provenance, and a system track with an agent-derived
member carries `agent_provenance` (member to agent, model, inputs, checked).
Quality measures the agent's source like any other, and a quality rule can
mark, downgrade or drop it.

### 4.2 Agent as an adjudicator

An agent, or an analyst, settles a hard case by sending a hint: "treat A and
B as one object" or "keep A and B apart", with its author and reason. The
engine takes the hint as an input record, decides with it as its
specification states, and traces it like any other input.

**How** (Designed). A hint is posted to the runner's hint route, or called as the MCP
hint tool, or published on the fabric under the agent's prefix. The runner
records it in the record file at the step it arrives, so a replay gives the
same decisions. The hint record and its effect on each method (`confirm`,
`assign`, fuse groups) are defined in the correlate and fuse specifications
(`spec/correlate.md`, `spec/correlate-assign.md`, `spec/fuse.md`), with
vectors, as for any other input. This suits low-volume, high-ambiguity
cases and decisions made after the fact.

### 4.3 Agent changing settings

An agent proposes a change to a pack or a parameter. By default a person
approves it. A site may declare an auto-approval policy: which parameters an
agent may change, within which bounds, and which gate must pass. Every
change is logged and can be reverted in one step.

**How.** The agent calls the `propose` tool with the function, the pack and its reason.
The runner holds it as a pending proposal. A person approves or rejects it
with `goat-processors proposal approve <id>`. Under a site
policy, a proposal inside its bounds is applied once its gate passes, for
example `goat-processors selftest`, or the site's benchmark run on its
own recorded scenarios; the gate is any command that exits 0 to pass.
(`tools/bench/` will offer separate tuning and evaluation sets for this; it
does not yet.)
Parameters are changed as packs: a pack is the unit of settings, so a new
parameter value is a new pack, and the policy's list of packs is its bounds. An applied change becomes a pack selection like
`goat-processors pack use`, written to the record file and the audit log;
`goat-processors proposal revert <id>` restores the previous pack.

### 4.4 Agent in the loop at speed

An agent may contribute per report or per tick through the source and hint
interfaces, with a local model. The engine's output is then exact given the
recorded hints and source reports, whatever the model would answer on
another run.

**How.** Today through 4.1; through 4.2 once hints are built (section 5,
A4). Run it at full rate, with the safeguards of sections 3.1 and 3.2: a local model, a deadline per call, a fallback that proceeds
without the agent's answer, and a count of answers that missed their
deadline. A late report or hint applies at the tick after it arrives; the record
file shows exactly when.

### 4.5 Agent reading and explaining, through MCP

The runner offers its API to agents as MCP tools, under the caller's
identity, the data-level check and the audit log.

| Tool class | Tools | Who may call |
|---|---|---|
| read | `status`, `health`, `pipeline`, `packs`, `metrics`, `tracks`, `explain`, `replay`, `routes`, `proposals`, `why` | the role `read` |
| proposal | `propose` (a pack for a function); a hint tool (section 4.2, Designed) | the role `read`: enough, because a proposal changes nothing until a person or the site policy applies it |
| source | `publish` | an identity listed in `agents.sources` |
| action | `use_pack`, `stop`, `start`, `approve`, `reject`, `revert` | the role `operate`, and a site policy (`agents.actions`) that names the identity and the action |

An MCP tool has the same authority as the CLI for the same identity: both
pass through the same roles (`runner/README.md`, The API, and who may use it).

The reference agent is the **"why?" explainer**: given a system track, it
reads the events and trace records behind it (`GET /v1/explain/{track}`)
and writes a plain explanation in which every sentence cites the trace
record it rests on. A sentence without a citation, or citing a record that
does not exist, is removed before the answer is shown. It needs a model
endpoint declared for the site's highest data level (`agents.endpoints`),
because the trace holds site data; with none, `goat-processors why` answers
"no model endpoint is configured (agents.endpoints)", and with only a lower
one it answers "refused: this call sends site data, and no endpoint is
declared for it".

## 5. What the runner provides

| # | Interface | Status |
|---|---|---|
| | HTTP API with roles, mesh mutual TLS and an audit log; `explain`, `tracks`, `replay` (`runner/openapi.yaml`) | Built (runner 0.2.0) |
| A1 | MCP server (`POST /mcp`, `goat-processors mcp`): read, proposal, source and action tools; reference client `runner/examples/mcp_client.py` | Built. Tests: `runner/tests/agents.rs`, a1_* |
| A2 | Model endpoints (`agents.endpoints`: local or hosted, http or https) with their declared data level, refused above it; caller levels (`agents.local_level`, `agents.clients`) | Built. Tests: a2_data_level_refusals, a2_hosted_endpoint_over_https |
| A3 | Agent as a source (`POST /v1/source`, tool `publish`, `agents.sources`): its own identity and source id, provenance on the output and on the tracks it joins | Built. Test: a3_agent_as_a_source |
| A4 | Agent as an adjudicator: hint route, MCP tool, recorded input | Designed; the hint record is added to the specifications first |
| A5 | Settings proposals: approval through the CLI, a site auto-approval policy (`agents.auto_approve`: proposer, function, packs, gate), one-step revert | Built. Test: a5_proposals_policy_approval_and_revert |
| A6 | Audit of every agent call: identity, tool, SHA-256 of the inputs, outcome | Built; checked in every test above |
| A7 | The "why?" explainer (`goat-processors why`, `GET /v1/why/{track}`, tool `why`), the reference agent | Built. Test: a7_every_sentence_cites_a_record_that_exists |
| A8 | "Build your own agent integration" guide with a runnable example per interface | Built: `runner/examples/README.md`. Test: a8_every_guide_example_runs |
| A9 | Outputs byte-identical with every agent interface enabled and no agent connected | Built. Test: a9_outputs_are_byte_identical_with_agent_interfaces_on_and_no_agent |

No model is bundled and none is required. Every test uses a deterministic
stub model.

## 6. Requirements every agent use builds on

These four keep any agent use safe to build on. Each is a property the
runner's interfaces provide; a builder gets it by using them.

| Requirement | How it is met |
|---|---|
| Every agent action carries its identity and is audited | the agent calls with its own certificate or token; the runner writes each call to the audit log with identity, tool, a digest of the inputs, and the result |
| Agent-derived data is labeled | agent output enters as a source or a hint with its provenance keys, under its own identity; the runner carries them to its output and trace, and marks `checked: true` on what it received through the API, where it checked the identity (section 4.1) |
| Data goes to a model only up to the site's declared level | each model endpoint has a declared level in the config; the runner refuses a call above it |
| The data path works with no agent present | every agent interface is optional; with all of them enabled and no agent connected, the runner's output is the same, byte for byte (A9) |
