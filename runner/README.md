# goat-processors runner

The runner is a long-running program that applies the goat-processors
functions to live data. It reads shared-model reports from the goat fabric,
runs them through a declared pipeline (filter, then correlate, then fuse,
then quality), and publishes system tracks, quality marks and the trace back
to the fabric. It is built on the Rust engine (`engines/rust`), called
through its public operations only: `load_pack`, `ingest`, `tick` and
`snapshot`.

To install it on a machine, follow [INSTALL.md](INSTALL.md). This page
explains how the runner works, how to configure it, how to operate it, and
how to troubleshoot it.

## Words used here

| Word | Meaning |
|---|---|
| fabric | the goat data network. It runs Zenoh, a publish and subscribe protocol: a program *publishes* a value under a *key* such as `data/entity/track/site-a/radar-1/T1`, and every program *subscribed* to a matching *key expression* such as `data/entity/track/**` receives it (`*` matches one `/`-separated chunk, `**` matches any number of chunks) |
| router | a fabric server that other programs connect to. The runner connects to one router, as a *client* |
| locator | the address of a router: protocol, host and port, for example `tls/router.site-a:7447` |
| mTLS | mutual TLS: the router and the runner each prove who they are with a certificate signed by the site's certificate authority (CA) |
| report | one message from one source about one object, already translated into the shared model by goat-transformers: its time `time_ms`, position `lat` and `lon`, error `ce` and identity keys (`spec/correlate.md`, Reports) |
| function | one of filter, correlate, fuse and quality (the [repository README](../README.md) describes each) |
| pack | a named settings file for one function, a directory `packs/<function>-<name>/` holding a `pack.def` |
| pipeline | the functions the runner runs, in order, each with its pack |
| tick | the moment at which every function produces its output for a given time `now_ms`: system tracks, quality measures, expiries |
| system track | the runner's output for one object: the source tracks judged to describe it and one combined estimate |
| trace | one record for each test a function ran: what it compared, the value, the limit and the result |
| vector | a test case: inputs with the exact events, trace and final state every engine must produce |
| systemd | the Ubuntu service manager; it starts the runner at boot and restarts it if it fails |

## What exists

| Part | Status |
|---|---|
| Runner service: fabric input and output, UDP input, file input, record | Built. Tested: every scenario vector replays exactly; a recorded run replays to the same output; a live fabric test |
| Config file and `goat-processors config check` | Built. Tested: each kind of mistake is refused with what to fix |
| `goat-processors doctor` | Built |
| `goat-processors selftest` (replays every shipped vector) | Built |
| `.deb` for Ubuntu 24.04, amd64 and arm64; systemd unit with its own user and hardening | Built in CI |
| `install.sh` and [INSTALL.md](INSTALL.md) | Written. CI runs `install.sh` on a fresh Ubuntu 24.04 VM against a mutual-TLS router |
| Signed release (cosign, keyless) | Written: `.github/workflows/runner-release.yml`, run by a tag `runner-v<version>` |
| HTTP API ([openapi.yaml](openapi.yaml)): local with a root-only token, mesh with mutual TLS and an allow list; audit log | Built. Tested: every route, both roles, refusals audited, mTLS allow list |
| CLI verbs on the API: `status`, `health`, `pipeline`, `pack use`, `stop`, `start`, `metrics`, `tracks`, `explain`, `replay --api`, `audit` | Built. Tested: each verb against a running service |
| Agent interfaces ([docs/design/agentic-ai.md](../docs/design/agentic-ai.md), [examples/README.md](examples/README.md)): MCP server and `goat-processors mcp`; model endpoints with data levels; agent as a source; settings proposals with a site auto-approval policy; the `why` explainer; audit of every agent call | Built. Tests: `tests/agents.rs` |
| Agent as an adjudicator (association and fusion hints) | Designed |
| Visual UI (Fieldkit Processors) | Designed |
| Container image | Designed |

## How the runner works

```
 fabric keys ─┐                          ┌─> <prefix>/tracks/<id>
 UDP port ────┼─> filter ─> correlate ─> fuse ─> quality ─┼─> <prefix>/quality/<scope>/<subject>
 file ────────┘        (stages in the config)             ├─> <prefix>/events/<function>
                         tick every tick_ms               └─> <prefix>/trace/<function> (when enabled)
```

**Reports.** Each input delivers reports. A fabric sample or a UDP datagram
holds one report as a JSON object, a JSON array of reports, or JSON lines.
Anything else is counted as unreadable and skipped. Reports are passed to the
pipeline in the order they arrive.

**Stages.** A report goes through the stages in order. A stage passes it on
unless it stops it there:

| Function | Stops a report when it returns |
|---|---|
| filter | `drop` or `reject` |
| correlate | `reject` |
| fuse | `reject` |
| quality | `reject`, or `pass` with `withheld: true` (a `drop` action) |

When correlate runs before fuse, the runner sets each report's `fuse.group`
to the group or system track that holds its entity, as correlate's events
last stated, and removes the key when the entity is in none. Fuse then
combines the members of each system track by its own rules.

**The clock.** The functions read no clock: their only time is the time in
their input. The runner is the one place a clock enters, and the config names
it:

| `clock` | A tick happens | `now_ms` is |
|---|---|---|
| `wall` (default) | when this host's clock (UTC, milliseconds since 1970) passes a multiple of `tick_ms` | that multiple |
| `input` | when a report's `time_ms` passes a multiple of `tick_ms` | that multiple |

With `wall`, a tick that falls more than one interval behind (the host was
suspended, or its clock stepped forward) is made once, at the latest
multiple. A clock that steps back makes no tick until it passes the last
tick again. With `input`, more than 1000 ticks due at once (a gap in the
input) are made as one tick, at the latest multiple. The host clock must be
kept by NTP, as on every goat host.

**Record and replay.** With `record`, the runner writes every report it
ingests and every tick it makes, in order. `goat-processors replay` of that
file, with the same config, gives the same output, line for line: the run is
reproducible.

## Configure

The one config file is `/etc/goat-processors/runner.yaml`. The package
installs a commented starting point. Check it after every edit:

```sh
sudo goat-processors config check
```

It prints `valid`, or each problem with where it is and what to do, and
exits 1. The service runs the same check before it starts.

| Key | Required | Default | Meaning |
|---|---|---|---|
| `name` | yes | | this runner's name; letters, digits, `-`, `_` |
| `site` | yes | | the site it serves; same characters |
| `packs_dir` | no | `/usr/share/goat-processors/packs` | where pack names are looked up |
| `tick_ms` | no | `1000` | interval between ticks, 10 to 600000 |
| `clock` | no | `wall` | `wall` or `input` (above) |
| `fabric.mode` | no | `client` | `client` (connects to a router) or `peer` |
| `fabric.connect` | in client mode | | router locators, for example `tls/router.site-a:7447` |
| `fabric.listen` | no | none | locators to listen on (peer mode only) |
| `fabric.tls.root_ca` | for `tls/` locators | | the site CA certificate, PEM, absolute path |
| `fabric.tls.certificate` | for `tls/` locators | | this runner's certificate, PEM |
| `fabric.tls.private_key` | for `tls/` locators | | its private key, PEM |
| `inputs.fabric.keys` | one input is required | | key expressions to subscribe to, for example `data/entity/track/**` |
| `inputs.udp[].listen` | | | `<ip>:<port>` to receive reports on |
| `inputs.file.path` | | | a file to play once at start (replay formats below); needs `clock: input` |
| `inputs.file.speed` | no | `1` | `1` real time, `10` ten times faster, `0` as fast as possible |
| `pipeline[].function` | yes | | `filter`, `correlate`, `fuse` or `quality`; each at most once, in that order |
| `pipeline[].pack` | yes | | a pack name under `packs_dir` (`goat-processors pack ls`), or a path to a pack directory |
| `outputs.fabric.prefix` | no | `data/processed/<site>/<name>` | key prefix of everything the runner publishes |
| `outputs.fabric.trace` | no | `false` | also publish every trace record (large) |
| `outputs.fabric.layout` | no | `per-entity` | `per-entity`: one key per system track and per quality subject, every tick. `batch`: the fixed keys `<prefix>/tracks` and `<prefix>/quality`, each one value holding the whole set (below) |
| `outputs.fabric.heartbeat_ms` | no | `5000` | with `layout: batch`, the longest time between two publishes of an unchanged set, input-clock milliseconds |
| `outputs.file.path` | no | | append one JSON line per stage per step; must be under `/var/lib/goat-processors` |
| `outputs.file.trace` | no | `false` | include the trace in those lines |
| `record.path` | no | | append every ingest and tick (replay format); under `/var/lib/goat-processors` |
| `status_file` | no | `/run/goat-processors/status.json` | the status the service writes after each tick, read by `doctor` |
| `api.enabled` | no | `true` | serve the API |
| `api.listen` | no | `127.0.0.1:8470` | the local listener; a loopback address only (it is plain HTTP) |
| `api.token_file` | no | `/run/goat-processors/api.token` | the token a local caller shows to change anything; the service writes a new one at each start, readable by root only |
| `api.audit_file` | no | `/var/lib/goat-processors/audit.jsonl` | every change and every refused request, one JSON line each |
| `api.mesh.listen` | no | | `<ip>:<port>` for callers on other hosts, over mutual TLS |
| `api.mesh.tls` | no | the `fabric.tls` files | `root_ca` (signs callers' certificates), `certificate`, `private_key` |
| `api.mesh.allow[]` | with `api.mesh` | | `{name: <certificate CN>, role: read or operate}`; a CN not listed is refused |
| `agents.mcp` | no | `true` | serve the MCP endpoint, `POST /mcp` (examples/README.md) |
| `agents.data_levels` | no | `[public, site]` | the site's data levels, least sensitive first |
| `agents.local_level` | no | the highest level | the highest level a local caller may receive |
| `agents.clients[]` | no | | `{name: <certificate CN>, data_level}`; a mesh caller not listed receives the lowest level |
| `agents.endpoints[]` | no | | model endpoints the runner may call: `{name, url, kind: local or hosted, data_level, model, key_file, timeout_ms, ca_file}` |
| `agents.actions[]` | no | | `{who, actions: [use_pack, stop, start, approve, reject, revert]}`: which identities may call MCP action tools |
| `agents.sources[]` | no | | `{who, source_id}`: which identity may publish reports as which source |
| `agents.auto_approve[]` | no | | `{who, function, packs, gate, gate_timeout_s}`: proposals applied without a person once `gate` exits 0 |
| `agents.proposals_file` | no | `/var/lib/goat-processors/proposals.json` | pending and decided proposals |

The config check refuses an input key expression that also matches the output
prefix, since the runner would then read what it publishes. It also refuses
any value still set to the placeholder `CHANGE-ME`.

**Choosing packs.** The shipped config runs `correlate-assign-time` and
`quality-feed`. The [repository README](../README.md#methods-and-packs)
compares the correlate packs. Add a filter stage first to restrict the area or
thin a feed, and a fuse stage after correlate to combine attributes such as
identity by source priority.

## Operate

| Task | Command |
|---|---|
| start, and start at boot | `sudo systemctl enable --now goat-processors` |
| stop | `sudo systemctl stop goat-processors` |
| apply an edited config | `sudo goat-processors config check && sudo systemctl restart goat-processors` |
| is it healthy | `goat-processors doctor` (`-o json` for scripts) |
| its log (needs `sudo`) | `sudo journalctl -u goat-processors -f` |
| state, pipeline, counters per source | `goat-processors status` |
| is it running and ticking (exit 0 or 1) | `goat-processors health` |
| reports per second, processing latency | `goat-processors metrics` |
| the same for a Prometheus scraper: reports per source, system tracks, system tracks with members from more than one source, source tracks per source, events per function and event, quality events per source, latency quantiles | `GET /v1/metrics/prometheus` (role read) |
| the system tracks now | `goat-processors tracks` |
| what led to one system track | `goat-processors explain <id>` (the id from `tracks`) |
| list packs | `goat-processors pack ls` |
| run another pack for one function, now | `sudo goat-processors pack use <function> <pack>` |
| pause, and resume, processing | `sudo goat-processors stop`, `sudo goat-processors start` |
| who changed what | `sudo goat-processors audit` |
| explain one track in plain words, from a model | `goat-processors why <id>` (needs `agents.endpoints`) |
| settings proposals | `goat-processors proposals`; `goat-processors propose <function> <pack> --reason TEXT`; `sudo goat-processors proposal approve|reject|revert <id>` |
| connect an agent on this host | `goat-processors mcp` (an MCP server on stdin and stdout) |
| check the program against its test cases | `goat-processors selftest` |
| run a file through a pipeline, offline | `goat-processors replay FILE -c /etc/goat-processors/runner.yaml` |

**What the runner publishes**, under the prefix (default
`data/processed/<site>/<name>`), each value one JSON object:

| Key | Value | When |
|---|---|---|
| `<prefix>/tracks/<id>` | one system track: `system` (or `group`), `members`, `lat`, `lon`, `course`, `speed_ms`, `hae` when known, and `now_ms`. From fuse when the pipeline has it, otherwise from correlate | every tick, one per system track |
| `<prefix>/quality/<scope>/<subject>` | a quality measure event, or an `action-start` / `action-end`; `scope` is `entity` or `source` | every tick |
| `<prefix>/events/<function>` | `{stage, now_ms, events}`: every event one function returned for one call | each call with events |
| `<prefix>/trace/<function>` | `{stage, now_ms, trace}` | with `outputs.fabric.trace: true` |

With `outputs.fabric.layout: batch` the key set is fixed and does not grow
with the number of tracks:

| Key | Value | When |
|---|---|---|
| `<prefix>/tracks` | JSON lines: one system track per line, as above, each with `now_ms`. An empty value means no system track | on a tick, when the set differs from the last one published, or `heartbeat_ms` after it |
| `<prefix>/quality` | JSON lines: one quality event per line, each with `now_ms` | the same rule |
| `<prefix>/events/<function>`, `<prefix>/trace/<function>` | as above | as above |

JSON lines let a reader split the value with newline framing (for example
`goat-xf-pipe-zenoh --in-frame newline`), and the runner's own fabric input
reads it as a list of reports. For live data, put the prefix in the volatile
class, for example `volatile/<slot>/stream/processors/<site>`, so the routers
route it and never store it.

The events are described in each function's specification under `spec/`.

**Replay files.** `goat-processors replay` and `inputs.file` read any of:

| Form | Read as |
|---|---|
| a vector (`packs/*/vectors/*.json`) | its steps, exactly; the pipeline is the vector's own pack unless `-c` or `--pack` gives one |
| JSON lines of `{"ingest": <report>}` and `{"tick": <now_ms>}` | these steps, in order (what `record` writes) |
| JSON lines of reports | each report, with ticks from the input clock |

`replay` prints one JSON line per stage per step, `{step, call, now_ms, stage,
events}`, with `trace` when given `--trace`. `--pack correlate=correlate-gnn`
(repeatable) sets the pipeline on the command line.

**Files the runner uses**

| Path | What |
|---|---|
| `/usr/bin/goat-processors` | the program |
| `/etc/goat-processors/runner.yaml` | the config (root writes, the service reads) |
| `/etc/goat-processors/tls/` | the fabric certificates |
| `/usr/share/goat-processors/packs/` | every pack, with its vectors |
| `/run/goat-processors/status.json` | the service's status, rewritten each tick |
| `/var/lib/goat-processors/` | the only directory the service may write |
| `/usr/lib/systemd/system/goat-processors.service` | the systemd unit |

**Hardening.** The service runs as its own user `goat-processors`, with no
login, no capabilities and no new privileges. It sees the file system read
only except `/var/lib/goat-processors` and `/run/goat-processors`, has no
access to home directories or devices, and may open only network sockets.
`systemd-analyze security goat-processors` lists every setting.

## The API, and who may use it

Every verb in the table above that reads or changes the running service is
one route of the runner's HTTP API ([openapi.yaml](openapi.yaml) documents
each). Programs call the API; people use the verbs, which print the same
answer as a table, or as the API's JSON with `-o json`.

| Caller | How it is identified | Role |
|---|---|---|
| a command on this host, run with `sudo` | it shows the token in `api.token_file`, which only root can read | `operate`: every route |
| a command on this host, without `sudo` | no token | `read`: every route that changes nothing |
| a program on another host | its client certificate, over mutual TLS on `api.mesh.listen` | the role `api.mesh.allow` gives its certificate's name; a name not listed is refused |

`operate` adds `pack use`, `stop`, `start` and `audit`. Each change, and each
refused request, is written to `api.audit_file` with who made it.
`pack use` takes effect at once and is written to the record file, so a
replay of the record makes the same change at the same step. It lasts until
the service restarts; to keep it, write the pack in the config file.

## Troubleshoot

Run `sudo goat-processors doctor` first (`sudo`, so that it can read the config and the certificates). Each line is `ok`, `warn` or `FAIL`, and
each FAIL is followed by its fix. Doctor changes nothing.

| Doctor says | Meaning | Fix |
|---|---|---|
| `config` FAIL | the config file has a problem; the line says which | edit the file as it says, then `sudo goat-processors config check` |
| `config` FAIL: cannot read the file (permission denied) | doctor ran as a user who cannot read the config | `sudo goat-processors doctor` |
| `certificates: …` FAIL: cannot be read, or is not PEM | the file is missing or is not in PEM form | place the files the site CA issued (INSTALL.md, step 5) |
| `certificates: …` FAIL: the service user cannot read | the file or its directory has the wrong group or mode, for example after a purge and reinstall | `sudo install -m 0640 -g goat-processors <file> /etc/goat-processors/tls/<name>` (INSTALL.md, step 5), or run `install.sh` again |
| `certificates: …` FAIL: does not parse, or has expired | the file is damaged, or its validity has ended | ask the site's CA for the file again |
| `fabric` FAIL: does not resolve | the router's name is unknown on this host | correct `fabric.connect`; check DNS or `/etc/hosts` |
| `fabric` FAIL: no TCP connection | nothing answers at the router's port | check the router runs, the mesh is up, and no firewall blocks the port |
| `fabric` FAIL: connected to no router | TCP works but the TLS handshake fails. The journal then says `Unable to connect to any of [tls/…]`, which can also mean the service cannot read its own key | check the certificate lines of doctor; check that the certificate is signed by the router's CA; `sudo journalctl -u goat-processors -n 50` shows the TLS error |
| `service` FAIL: systemd reports the service failed | it stopped | `sudo journalctl -u goat-processors -n 50` says why; a config problem is printed there by the check that runs before start |
| `service` FAIL: systemd reports the service activating | it failed and systemd is restarting it every 5 s | `sudo journalctl -u goat-processors -n 50` says why |
| `service` FAIL: no status at /run/goat-processors/status.json | the service has not completed a tick since it started: it is not running, or is failing at start | `sudo journalctl -u goat-processors -n 50`; then `sudo systemctl restart goat-processors` |
| `service` FAIL: the status is old | the service is not ticking | `sudo systemctl restart goat-processors` |
| `input` warn: no report read yet | nothing arrives on the input keys | compare `inputs.fabric.keys` with the keys the translators publish |
| `service` warn: unreadable inputs | samples on the input keys are not reports | see the first ones with `sudo journalctl -u goat-processors`; correct the key expression or the publisher |
| `service` warn: the running pipeline differs | the config was edited but not applied, or an operator ran `pack use` | to keep the running packs, write them in the config; to return to the config, `sudo systemctl restart goat-processors` |
| `api` FAIL: the API does not answer | the service is not running, or failed to open its API port | `sudo journalctl -u goat-processors -n 50`; another program may hold port 8470 (`api.listen`) |
| `api` FAIL: not healthy: paused | an operator ran `goat-processors stop` | `sudo goat-processors start` |

## Build from source

```sh
cd runner
cargo build --release --locked     # target/release/goat-processors
cargo test --locked                 # every vector, config, doctor, service and fabric tests
cd .. && runner/packaging/build-deb.sh amd64 runner/target/release/goat-processors dist
```

Every third-party crate the runner uses is pinned in `runner/Cargo.lock` and
listed with its license in [THIRD-PARTY.md](THIRD-PARTY.md)
(`runner/packaging/third-party.py` writes it). CI runs `cargo audit` and
`cargo deny check` on them. The engines use none of them.
