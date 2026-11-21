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
| CLI verbs on the API: `status`, `view`, `health`, `pipeline`, `pack use`, `stop`, `start`, `metrics`, `tracks`, `explain`, `replay --api`, `audit` | Built. Tested: each verb against a running service |
| Agent interfaces ([docs/design/agentic-ai.md](../docs/design/agentic-ai.md), [examples/README.md](examples/README.md)): MCP server and `goat-processors mcp`; model endpoints with data levels; agent as a source; settings proposals with a site auto-approval policy; the `why` explainer; audit of every agent call | Built. Tests: `tests/agents.rs` |
| Agent as an adjudicator (association and fusion hints) | Designed |
| Operator page, Fieldkit Processors ([below](#the-operator-page-fieldkit-processors), [fieldkit/](fieldkit/README.md)) | Built. Tested: a browser drives all eight actions against a running runner, signed in with a client certificate, and checks each change through the API (`fieldkit/e2e/`); the scope guard checks every action is a CLI verb; `tests/api.rs` checks the page's headers and the cross-site refusals |
| Container image for amd64 and arm64 ([below](#the-container-image), `packaging/container/Containerfile`) | Built. Tested: `packaging/ci-container-test.sh` runs it locked down against a mutual-TLS router with a scenario (CI on amd64 and arm64) |
| Container image published to `ghcr.io/usareur-af/goat-processors` and signed (cosign, keyless) | Written: `runner-release.yml`; first published by the next `runner-v` tag |
| Hardening review ([docs/hardening-review.md](docs/hardening-review.md)) | Written. Six findings fixed with tests (a crash and a stall from one report, API lockout, memory flood, hosted endpoint over plain HTTP, doctor without openssl); file growth and certificate revocation fixed in 0.6.0; one Open (the engines' unbounded wrap and parser, taken to the next spec round) |

## How the runner works

```
 fabric keys ─┐                          ┌─> <prefix>/tracks/<id>
 UDP port ────┼─> filter ─> correlate ─> fuse ─> quality ─┼─> <prefix>/quality/<scope>/<subject>
 file ────────┘        (stages in the config)             ├─> <prefix>/events/<function>
                         tick every tick_ms               └─> <prefix>/trace/<function> (when enabled)
```

**Reports.** Each input delivers reports. A fabric sample or a UDP datagram
holds one report as a JSON object, a JSON array of reports, or JSON lines.
Anything else is counted as unreadable and skipped, and so is JSON nested
more than 64 levels deep, and a report no real object could send: a number
that is not finite, `lat` beyond 90, or `lon` beyond 360 (`journalctl` names
the first ones). A report written with
nested objects (`{"track": {"source_id": "r1"}}`, as a JSON encoder that
cannot write a member name holding `.` produces it) is read with dotted keys
(`"track.source_id"`); a dotted key already present wins. Reports are passed to the
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
| `inputs.udp[].listen` | | | `<ip>:<port>` to receive reports on. UDP has no sender check: anyone who reaches the port can send reports. Bind it to `127.0.0.1` or to an interface that only trusted senders reach; prefer the fabric (mutual TLS) for reports from other hosts |
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
| `outputs.file.max_mb` | no | no limit | size limit in MiB: past it the file is renamed `<path>.1` (an older `.1` becomes `.2`, and so on) and a new file starts; a line is never split |
| `outputs.file.keep` | no | `1` | how many older copies to keep, 0 to 9; the oldest is removed |
| `record.path` | no | | append every ingest and tick (replay format); under `/var/lib/goat-processors` |
| `record.max_mb`, `record.keep` | no | no limit, `1` | as for `outputs.file`. A replay of a rotated record starts from that file's first line, so keep enough copies to cover the time you may need to replay |
| `status_file` | no | `/run/goat-processors/status.json` | the status the service writes after each tick, read by `doctor` |
| `api.enabled` | no | `true` | serve the API |
| `api.listen` | no | `127.0.0.1:8470` | the local listener; a loopback address only (it is plain HTTP) |
| `api.token_file` | no | `/run/goat-processors/api.token` | the token a local caller shows to change anything; the service writes a new one at each start, readable by root only |
| `api.audit_file` | no | `/var/lib/goat-processors/audit.jsonl` | every change and every refused request, one JSON line each |
| `api.audit_max_mb`, `api.audit_keep` | no | no limit, `1` | as for `outputs.file`. `goat-processors audit` reads the current file only |
| `api.mesh.listen` | no | | `<ip>:<port>` for callers on other hosts, over mutual TLS |
| `api.metrics_listen` | no | off | `<mesh ip>:<port>` that serves only `GET /metrics` (the Prometheus text), plain HTTP with no caller check, for an obs host's scraper. `config check` refuses an address that listens on every interface |
| `api.mesh.tls` | no | the `fabric.tls` files | `root_ca` (signs callers' certificates), `certificate`, `private_key` |
| `api.mesh.allow[]` | with `api.mesh` | | `{name: <certificate CN>, role: read or operate}`; a CN not listed is refused. Any certificate the site CA signs with that CN gets the role, so the site CA should give each person and program its own name. The list is read at start: to take access away, remove the name and restart the service, or revoke the certificate (`api.mesh.crl`) |
| `api.mesh.crl` | no | | the site CA's certificate revocation list (PEM). A client certificate it lists is refused at the TLS handshake. The service reads the file again when it changes, so a revocation needs no restart; a copy that does not read leaves the previous list in force |
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
| the same for a Prometheus scraper: reports per source, system tracks, system tracks with members from more than one source, source tracks per source, events per function and event, quality events per source, latency quantiles | `GET /v1/metrics/prometheus` (role read), or `GET /metrics` on `api.metrics_listen` |
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
| `<prefix>/tracks` | JSON lines: one system track per line, as above, each with `now_ms` and `track_number`: a number 1 to 65535 that the track keeps while it lives, for formats whose track identifier is a number (ASTERIX I062/040). A new track takes the next free number, wrapping after 65535. An empty value means no system track | on a tick, when the set differs from the last one published, or `heartbeat_ms` after it |
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
| JSON lines of reports | each report, with ticks from the input clock; nested objects read as dotted keys, as on the fabric |

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
Each listener handles a fixed number of connections at once (local 16, mesh
32, metrics 4), and a request must arrive whole within 30 s, so slow or many
callers on the mesh or metrics port cannot shut out the local API.
`pack use` takes effect at once and is written to the record file, so a
replay of the record makes the same change at the same step. It lasts until
the service restarts; to keep it, write the pack in the config file.

## The operator page (Fieldkit Processors)

A web page, served by the runner at `/ui` on each API listener, for a person
who would rather not type commands. It is one file built into the program: it
loads nothing from anywhere else and works with no internet. It is built with
goat's Fieldkit design system, Bleating Edge (large text and buttons, a
sunlight and a dark screen).

The page has exactly eight actions. Each is one CLI verb and one API route,
and shows the command it equals ("Same as"), so anything done on the page can
be done, scripted or checked from the command line:

| On the page | Same as | Who may |
|---|---|---|
| Now: the plan view of system tracks with their sources, the track list, quality per source, the pipeline, proposals waiting. It refreshes every 2 seconds | `goat-processors view` | read |
| Pick packs | `goat-processors pack use FUNCTION PACK` | operate |
| Pause | `goat-processors stop` | operate |
| Resume | `goat-processors start` | operate |
| Replay a file (on a copy of the pipeline; the live runner does not change) | `goat-processors replay FILE --api` | read |
| Explain a track (its events and trace records) | `goat-processors explain TRACK` | read |
| Approve, on a waiting proposal | `goat-processors proposal approve ID` | operate |
| Reject, on a waiting proposal | `goat-processors proposal reject ID` | operate |

Every change asks first, in plain words, then shows what happened. `revert`
stays a command only.

**Who you are on the page** is decided by the API, as for any caller (the
table above). The page holds no authority of its own:

| How you open it | You are | You may |
|---|---|---|
| `http://127.0.0.1:8470/ui` on the machine, or through an SSH tunnel (INSTALL.md, step 10) | `local` | look; the change buttons are off. A browser cannot show the root-only token |
| `https://<mesh address>:<port>/ui` (`api.mesh.listen`), with your client certificate installed in the browser | your certificate's name | what `api.mesh.allow` gives that name. `operate` turns the change buttons on |

To let a person change the runner from a browser, give the API a mesh
listener and allow their certificate (the keys are in Configure, above):

```yaml
api:
  listen: "127.0.0.1:8470"
  mesh:
    listen: "<this host's mesh address>:8471"
    allow:
      - {name: <their certificate's common name>, role: operate}
```

Then `sudo goat-processors config check && sudo systemctl restart
goat-processors`. They install their client certificate and key in their
browser (the site CA signed it; their goat administrator gives it to them),
add the site CA to the browser's trusted authorities so it trusts the
runner's own certificate, and open `https://<this host's mesh address>:8471/ui`. The browser asks which
certificate to use; "Signed in as" on the page shows the name the runner read.

The runner refuses a request that a page from another site starts in your
browser (by its `Sec-Fetch-Site` or `Origin`), so a page elsewhere cannot use
your certificate to change the runner. The page itself is sent with a policy
that lets it load nothing and call only the runner that served it.

For the full step-by-step viewer of one scenario (a plan with a time slider
and every record), replay a recorded file with `tools/explain`
(`../tools/explain/README.md`). The page's Explain shows the recent steps the
runner keeps in memory.

## The container image

The image holds the same files as the `.deb`, in the same places: the binary
`/usr/bin/goat-processors` (with the operator page built in), every pack and its
vectors, the example config, and the docs, NOTICE and LICENSE. It is built on a
distroless base image (Debian 13, glibc), runs as user 65532, and has no shell
and no package manager. Both base images are pinned by digest in the
Containerfile.

Each release from the next `runner-v` tag on publishes the image for amd64 and
arm64 as one tag, `ghcr.io/usareur-af/goat-processors:<version>`, signed with
cosign (keyless). The release notes name its digest. Check the signature
before you run it:

```sh
cosign verify ghcr.io/usareur-af/goat-processors:<version> \
  --certificate-identity-regexp '^https://github.com/USAREUR-AF/goat-processors/.github/workflows/runner-release.yml@refs/tags/runner-v' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Until then, build it from the repository root:
`docker build -f runner/packaging/container/Containerfile -t goat-processors .`

**What to mount.** The image's example config says CHANGE-ME, so the container
refuses to start until you mount your own. Put `runner.yaml` and its `tls/`
directory in one directory on the host, readable by user 65532 and nobody else:

```sh
sudo chown -R root:65532 /srv/goat-processors/etc
sudo chmod 0750 /srv/goat-processors/etc /srv/goat-processors/etc/tls
sudo chmod 0640 /srv/goat-processors/etc/runner.yaml /srv/goat-processors/etc/tls/*
```

**Run it locked down.** These are the flags the container proof uses: a
read-only root file system, no Linux capabilities, no new privileges, and
limits on memory and processes. The runner writes only to
`/run/goat-processors` (a tmpfs: its status and API token) and
`/var/lib/goat-processors` (a volume: `outputs.file`, `record`, the audit log
and proposals).

```sh
docker run -d --name goat-processors --restart unless-stopped --net host \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --memory 512m --pids-limit 256 \
  --tmpfs /run/goat-processors:rw,noexec,nosuid,nodev,size=1m,uid=65532,gid=65532,mode=0750 \
  -v goat-processors-state:/var/lib/goat-processors \
  -v /srv/goat-processors/etc:/etc/goat-processors:ro \
  ghcr.io/usareur-af/goat-processors:<version>
```

`--net host` gives the runner the host's network, as the `.deb` has: it
reaches the router, receives UDP, and its local API answers on the host's
`127.0.0.1:8470`. To keep it in its own network instead, leave out `--net host`
and publish only what other hosts use: the mesh listener (`api.mesh.listen`,
mutual TLS, for example `-p 8471:8471`) and any UDP input port
(`-p 5000:5000/udp`). Inside the container, set those listeners to
`0.0.0.0:<port>`. The local API stays on the container's own loopback (`config
check` refuses any other address), so you reach it with `docker exec` only. The metrics port (`api.metrics_listen`) has no
caller check and `config check` refuses it on every address, so a metrics port needs `--net host` and this host's mesh address.

**Operate it.** Every verb runs inside the container:
`docker exec goat-processors goat-processors status`, and the same for
`doctor`, `tracks`, `stop`, `start`, `audit` and the rest. The API token is in
the container's tmpfs, readable only by its user, so `docker exec` can change
things and a host user without access to Docker can only read. Anyone who can
run `docker exec` can operate the runner: give Docker access as you would give
`sudo`. The image's health check runs `goat-processors health`, so
`docker ps` shows `healthy` while the runner runs and ticks. Logs:
`docker logs goat-processors`.

**Upgrade** by pulling the next tag, checking its signature, and starting a new
container with the same mounts; the state volume keeps the audit log,
proposals and recorded files.

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
| `service` warn: unreadable inputs | samples on the input keys are not reports, or hold a value out of range | see the first ones with `sudo journalctl -u goat-processors`; correct the key expression or the publisher |
| `service` warn: reports dropped because the service was behind its inputs | reports arrived faster than the pipeline ran, and more than 65536 waited; the fabric and UDP inputs dropped the rest (`counters.dropped_backlog`) | check the host's load (`top`) and each source's rate (`goat-processors metrics`); a source that floods the input is the usual cause |
| `service` warn: the running pipeline differs | the config was edited but not applied, or an operator ran `pack use` | to keep the running packs, write them in the config; to return to the config, `sudo systemctl restart goat-processors` |
| `certificates: api.mesh.crl` FAIL: does not read | the file is missing or is not a PEM revocation list; the service keeps the list it last read (at start, it does not start) | copy the CA's current list there |
| `certificates: api.mesh.crl` warn: past its next update | the list still applies, but the CA has likely issued a newer one | copy the CA's current list there |
| `files` warn: a file has no size limit | an output, record or audit file without `max_mb` has passed 1 GiB | set its `max_mb` and `keep` in the config, then `sudo systemctl restart goat-processors` |
| `files` warn: the disk is 90% full or more | the disk holding a file the service writes is nearly full; when it is full, writes fail (`output_errors`) | free space there, or set `max_mb` on the files |
| `api` FAIL: the API does not answer | the service is not running, or failed to open its API port | `sudo journalctl -u goat-processors -n 50`; another program may hold port 8470 (`api.listen`) |
| `api` FAIL: not healthy: paused | an operator ran `goat-processors stop` | `sudo goat-processors start` |

## Build from source

```sh
cd runner
cargo build --release --locked     # target/release/goat-processors
cargo test --locked                 # every vector, config, doctor, service and fabric tests
cd .. && runner/packaging/build-deb.sh amd64 runner/target/release/goat-processors dist
docker build -f runner/packaging/container/Containerfile -t goat-processors .   # the image
runner/packaging/ci-container-test.sh goat-processors                          # its proof
```

Every third-party crate the runner uses is pinned in `runner/Cargo.lock` and
listed with its license in [THIRD-PARTY.md](THIRD-PARTY.md)
(`runner/packaging/third-party.py` writes it). CI runs `cargo audit` and
`cargo deny check` on them. The engines use none of them.
