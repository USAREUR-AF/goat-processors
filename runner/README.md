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
| HTTP API, the rest of the CLI verbs (`status`, `tracks`, `explain`, `pack use`, `start`, `stop`) | Designed |
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
| `outputs.file.path` | no | | append one JSON line per stage per step; must be under `/var/lib/goat-processors` |
| `outputs.file.trace` | no | `false` | include the trace in those lines |
| `record.path` | no | | append every ingest and tick (replay format); under `/var/lib/goat-processors` |
| `status_file` | no | `/run/goat-processors/status.json` | the status the service writes after each tick, read by `doctor` |

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
| its log | `journalctl -u goat-processors -f` |
| counters (reports in, per source, ticks) | `cat /run/goat-processors/status.json` |
| list packs | `goat-processors pack ls` |
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

## Troubleshoot

Run `goat-processors doctor` first. Each line is `ok`, `warn` or `FAIL`, and
each FAIL is followed by its fix. Doctor changes nothing.

| Doctor says | Meaning | Fix |
|---|---|---|
| `config` FAIL | the config file has a problem; the line says which | edit the file as it says, then `sudo goat-processors config check` |
| `config` FAIL: cannot read the file (permission denied) | doctor ran as a user who cannot read the config | `sudo goat-processors doctor` |
| `certificates: …` FAIL | a certificate file is missing, is not PEM, or has expired | place the files the site CA issued (INSTALL.md, step 5) |
| `fabric` FAIL: does not resolve | the router's name is unknown on this host | correct `fabric.connect`; check DNS or `/etc/hosts` |
| `fabric` FAIL: no TCP connection | nothing answers at the router's port | check the router runs, the mesh is up, and no firewall blocks the port |
| `fabric` FAIL: connected to no router | TCP works but the TLS handshake fails | check that the certificate is signed by the router's CA and has not expired; `journalctl -u goat-processors` shows the TLS error |
| `service` FAIL: systemd reports the service failed | it stopped | `journalctl -u goat-processors -n 50` says why; a config problem is printed there by the check that runs before start |
| `service` FAIL: the status is old | the service is not ticking | `sudo systemctl restart goat-processors` |
| `input` warn: no report read yet | nothing arrives on the input keys | compare `inputs.fabric.keys` with the keys the translators publish |
| `service` warn: unreadable inputs | samples on the input keys are not reports | see the first ones in the journal; correct the key expression or the publisher |
| `service` warn: the running pipeline differs | the config was edited but not applied | `sudo systemctl restart goat-processors` |

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
