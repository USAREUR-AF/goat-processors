# Build your own agent integration

This guide shows how to connect an AI agent to a goat-processors runner,
with one worked example per extension point. The design, its trade-offs and
the safeguard each use needs are in
[docs/design/agentic-ai.md](../../docs/design/agentic-ai.md). Each example
here is a short Python script that uses the standard library only, and CI
runs every one of them against a live runner (`runner/tests/agents.rs`,
`a8_every_guide_example_runs`).

## Words used here

| Word | Meaning |
|---|---|
| runner | the goat-processors service; `runner/README.md` |
| MCP | Model Context Protocol: an open protocol by which an agent lists and calls a server's tools |
| tool | one operation the runner offers an agent, such as `tracks` or `propose` |
| identity | who is calling: `local-admin` (a local caller with the token, that is, with `sudo`), `local` (a local caller without it), or the name in a mesh client certificate |
| role | what an identity may do through the API: `read` or `operate` (`runner/README.md`, The API, and who may use it) |
| data level | how sensitive data is, on the site's scale `agents.data_levels`; by default `public` then `site` |
| model endpoint | a model the runner itself may call, declared in `agents.endpoints` with the highest data level it may receive |

## How an agent connects

The runner serves MCP at `POST /mcp` on its API address (by default
`http://127.0.0.1:8470/mcp`), using JSON-RPC 2.0, one request per POST. An
agent on the same machine that speaks MCP over stdin and stdout runs
`goat-processors mcp` as its server instead; that command forwards each
message to the runner. For an MCP client configured with a command, for
example:

```json
{"mcpServers": {"goat-processors": {"command": "goat-processors", "args": ["mcp"]}}}
```

Every tool call:

- runs as the API request of the same name, with the caller's identity and
  role, so it can do nothing that identity could not do with the CLI;
- is refused when its data is above the caller's data level (local callers
  get `agents.local_level`, by default the highest; mesh callers get the
  level `agents.clients` gives their certificate name, by default the lowest);
- is written to the audit log (`api.audit_file`) with the identity, the
  tool, the SHA-256 of its arguments and the outcome.

| Class | Tools | What it needs |
|---|---|---|
| read | `status`, `health`, `pipeline`, `packs`, `metrics`, `tracks`, `explain`, `replay`, `routes`, `proposals`, `why` | the role `read` |
| proposal | `propose` | the role `read`; nothing changes until the proposal is applied |
| source | `publish` | the caller listed in `agents.sources` |
| action | `use_pack`, `stop`, `start`, `approve`, `reject`, `revert` | the role `operate`, and the caller named for that action in `agents.actions` |

## 1. Read and explain: the reference MCP client

`mcp_client.py` connects, lists the tools, and calls each one. It is the
smallest complete MCP client for the runner; start an integration from it.

```sh
python3 -I runner/examples/mcp_client.py
```

```
server goat-processors <version>, protocol 2025-06-18, 19 tools
ok    status     {"clock":"wall","counters":{...
ok    tracks     {"now_ms":1795164251800,"tracks":[{"course":0.0,"ev":"system",...
ok    explain    {"events":[{"event":{"entity":"radar-1/T1","ev":"new"},...
```

With `--actions` and the token it also calls the action tools, which the site
must allow in `agents.actions`:

```sh
sudo python3 -I runner/examples/mcp_client.py --actions --token-file /run/goat-processors/api.token
```

**The "why?" explainer** is the runner's own agent, built on these tools: it
reads one track's events and trace records, sends them to a model endpoint,
and keeps only the sentences that cite records it sent. It needs a model
endpoint declared for the site's highest data level:

```yaml
agents:
  endpoints:
    - {name: local, url: "http://127.0.0.1:8080/v1/chat/completions", kind: local, data_level: site}
```

```sh
goat-processors why s1
```

```
why s1: 2 sentences from model endpoint local (local), 200 records sent, 0 uncited sentences removed

The two tracks passed the statistical gate on every tick [R4, R9].
    R4 step 21 correlate: {"a":"adsb/T1","b":"radar-1/T1","limit":18.42,"pass":true,"test":"mahalanobis",...}
```

The endpoint is any server that answers OpenAI-compatible chat completions:
a model on the site's machines (`kind: local`), or a provider's
(`kind: hosted`, `https://...`, with `key_file`). The runner refuses to send
data above an endpoint's `data_level` to it.

## 2. Agent as a source: `publish_source.py`

An agent that derives tracks, identities or annotations publishes them as a
source of its own. The runner processes them like a sensor's, marks them
agent-derived, and carries the agent's identity and model onto every system
track that includes them.

The site allows the agent's identity to publish as one source id:

```yaml
agents:
  sources:
    - {who: local, source_id: agent-example}
```

```sh
python3 -I runner/examples/publish_source.py --source-id agent-example --model my-model-1 --demo 3
published 3 reports as agent-example
```

Each report is a shared-model report (`spec/correlate.md`, Reports) plus
`provenance.model` and, if useful, `provenance.inputs`. The runner adds
`provenance.kind: agent`, `provenance.agent: <identity>` and
`provenance.checked: true`. A system track with an agent member then reads:

```json
{"ev": "system", "system": "s1", "members": ["adsb/T1", "agent-example/D1", "radar-1/T1"],
 "agent_provenance": {"agent-example/D1": {"agent": "local", "checked": true, "model": "my-model-1"}}, ...}
```

The quality function measures the agent's source like any other, so a
quality rule can mark, downgrade or drop it.

An agent may instead publish on the fabric under its own key prefix. Then
the runner cannot check who wrote the provenance keys: it keeps them as
written, marks them `checked: false`, and relies on the site's fabric access
rules for that prefix. Publish through the API when the label must be
trusted (docs/design/agentic-ai.md, section 4.1).

## 3. Agent changing settings: `propose_pack.py`

An agent proposes that a function run another installed pack, with a reason.
Nothing changes until the proposal is applied: by a person
(`sudo goat-processors proposal approve <id>`), or by the site's policy, which
names the proposer, the function, the packs it may choose (its bounds), and a
gate command that must pass first:

```yaml
agents:
  auto_approve:
    - {who: local, function: quality, packs: [quality-feed, quality-time], gate: [goat-processors, selftest]}
```

```sh
python3 -I runner/examples/propose_pack.py quality quality-time --reason "sources now report their clock state"
proposal p1: quality quality-feed -> quality-time: applied, decided by policy
```

A proposal outside the policy waits:

```
proposal p2: quality quality-time -> quality-edge: pending
it waits for a person: sudo goat-processors proposal approve p2
```

`sudo goat-processors proposal revert p1` restores the pack it replaced.
Every proposal and decision is in `goat-processors proposals`, the proposals
file (`agents.proposals_file`) and the audit log. An applied change is
written to the record file, so a replay makes it at the same step.

A gate is a command and its arguments, written as a list (not one shell
string): `[goat-processors, selftest]`, or the site's own benchmark run on
its recorded scenarios. It runs with `GOAT_PROPOSAL_FUNCTION` and
`GOAT_PROPOSAL_PACK` set, and passes when it exits 0.

## 4. Agent as an adjudicator: hints

An agent or an analyst settles a hard case with a hint, "treat A and B as
one object" or "keep A and B apart", taken by the engine as recorded input.
Status: Designed. The hint record is added to the correlate and fuse
specifications first (`spec/`), with vectors; the runner's hint route, MCP
tool and example follow.

## 5. Agent in the loop at speed

Sections 2 and 4 at full rate, from a model on the site's machines. Measure
the model's latency under load before relying on it, give each call a
deadline, and let the runner proceed without the agent's answer when it is
late: a late report or hint applies at the next tick, and the record file
shows exactly when. docs/design/agentic-ai.md, sections 3.1 and 3.2, gives
the costs.

## What the runner guarantees, whatever the agent does

| Guarantee | How |
|---|---|
| every agent action carries its identity and is audited | identity from the token or certificate; one audit line per call |
| agent-derived data is labeled | `provenance.kind: agent` on its reports; `agent_provenance` on the tracks they join |
| data goes to a model only up to the declared level | `agents.endpoints[].data_level`, `agents.local_level`, `agents.clients` |
| the data path works with no agent | every interface is optional; with all of them on and no agent connected, the output is byte-identical (`a9_outputs_are_byte_identical_with_agent_interfaces_on_and_no_agent`) |
