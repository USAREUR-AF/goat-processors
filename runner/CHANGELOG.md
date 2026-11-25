# goat-processors runner: release notes

One section per release, newest first. **Breaking** marks a change to
something `DEPLOY-CONTRACT.md` promises to keep within `0.x`: the commands,
their JSON outputs, the file paths, the config keys, and the fabric keys and
their value format. The release workflow puts a release's section on its
GitHub release page.

## Unreleased

- **Each system track says `mono`**: 1 when its members come from one source,
  0 when from more than one, for formats that carry it (ASTERIX I062/080 MON).
  The metrics `system_tracks_multi_source` and `source_tracks` now read a
  member's source as the part before its first `/`, as the rest of the runner
  does, so a uid with a `/` in it no longer counts as a source of its own.
- **Single-source tracks are in the output.** A source track that correlate
  put in no group (an object only one sensor reports) was left out of the
  `tracks` key, `GET /v1/tracks`, the operator page, `explain` and the track
  metrics when the pipeline ends in fuse, although fuse makes a track of it.
  It is now a system track whose `group` is its one member (`radar-1/T2`).
  A site whose correlate pack forms groups sees more tracks than before.


## 0.8.0

- **From 0.6.x, also Breaking: the `quality` value** (0.7.0); **from 0.5.0 or
  earlier, also the fabric keys** (0.6). Read those sections of
  `runner/CHANGELOG.md` before updating.
- **Breaking (sites with more than 1000 system tracks): `GET /v1/tracks`
  returns pages.** At most `limit` tracks (default 1000, at most 10 000) of
  the latest tick, in byte order of the id, with `total` and `next`. An
  unchanged client that reads the list in one reply gets the first 1000 and
  HTTP 200, with no error. Ask again with `after=<next>&at=<now_ms of the
  first page>` until `next` is null (a 409 means a newer tick replaced the
  list: start again), and check that you received `total` tracks.
  `goat-processors tracks` and the MCP tool `tracks` do this.
  `GET /v1/proposals` returns the newest `limit` (older ones are in
  `agents.proposals_file`); `GET /v1/view` at most 10 000 tracks, with
  `tracks_total`.
- **Each certificate name on the mesh listener has a rate limit**, a token
  bucket: up to `api.rate_burst` requests in a quick run after being idle
  (default 40), then `api.rate_per_s` a second on average (default 20). Past
  it every route answers 429 with `retry_after_ms` and a `Retry-After`
  header; the first refusal of each second for each certificate is audited,
  and all are counted in `counters.api_rate_limited`. A program on the mesh
  that polls faster gets 429s it did not get before. Callers on the local
  listener are not limited.
- `config check` (and doctor) warn on every file that can grow without
  limit: `outputs.file` or `record` without `max_mb`, the audit log without
  `api.audit_max_mb` while the API is on, and `outputs.file.trace`. The
  shipped config sets `api.audit_max_mb: 64` and `api.audit_keep: 9`.
  The package never rewrites a kept config, so after the update doctor's
  last line on it is `running, with warnings` (its exit code is unchanged:
  doctor fails only on a FAIL). To clear it, add these lines at the end of
  the config, or put the two indented lines in its `api:` section if it has
  one:

  ```yaml
  api:
    audit_max_mb: 64
    audit_keep: 9
  ```
- **The decision store's bounds are settings, and it can spill to disk.**
  `store.max_records` (default 200 000, as before) and `store.max_age_s`
  (off by default, so `explain`, `why` and the page reach back as far as
  before; when set, steps older than that many seconds of input also leave
  memory). `store.spill` (off by default) writes the steps leaving memory
  to a size-limited file (`max_mb` required, `keep`, `max_age_s` for older
  copies, host clock) from a thread of its own, and `explain` (CLI, API,
  MCP) also reads it, at most 256 MiB a call; its reply adds `spill_events`
  and `spill_records` (items it holds from the spill), `spill_read_bytes`
  and `spill_read_stopped`. New status counters `store_spilled_steps`,
  `store_spill_dropped` and `store_spill_errors`. README.md, Output volume,
  has the measured fill rate and reach.

## 0.7.0

- **From 0.5.0 or earlier, also Breaking: the fabric keys** (0.6). Read the
  0.6.0 notes in `runner/CHANGELOG.md` and INSTALL.md, "Updating from 0.5.0
  or earlier", before updating.
- **Breaking: the `quality` value.** The `quality` key goes out when a mark is
  set or cleared, else every `heartbeat_ms` (5 s), instead of on every tick,
  and each value is the whole quality picture: every subject's latest
  measures, the `action-start` of every mark in force, and the `action-end`
  of each mark cleared since the last value. A reader treats each value as
  the whole picture and compares it with the last one: a mark is new when
  its `action-start` was not in the previous value, and it ended with its
  `action-end`. A measure can be up to `heartbeat_ms` old. At 50 and 200
  objects the fabric bytes per input report fell from about 1200 to about
  445.
- The store behind `explain`, `why` and the operator page keeps at most
  200 000 trace records also when one step returns more; what it leaves out
  is counted in the status counter `trace_not_kept`. New status counters
  `trace_records` and `trace_max_step` count the trace the pipeline returns.
- A volume test (`runner/tests/volume.rs`, budget `runner/volume/budget.json`)
  measures fabric values and bytes per key, peak memory and disk at 50, 200
  and 1000 objects; CI runs 50 and 200 on every pull request. README.md,
  "Output volume", has the figures and every output's bound.

## 0.6.1

The first published 0.6 release: the same runner as 0.6.0, with everything
listed under 0.6.0 in `runner/CHANGELOG.md`.

- **Breaking, as in 0.6.0: the fabric keys.** Updating from 0.5.0 or
  earlier moves the runner's output to new keys; readers of the old keys get
  nothing until they move. Read the 0.6.0 notes in `runner/CHANGELOG.md`, README.md "Moving from
  the layout before 0.6.0", and INSTALL.md "Updating from 0.5.0 or earlier"
  before updating.
- The tag `runner-v0.6.0` has no release: the release workflow failed before
  publishing (the glibc check of the `.deb` files ran in a job that had no
  copy of the repository). Nothing was signed or published for it, and no
  `.deb` exists. The container image tags `0.6.0-amd64` and `0.6.0-arm64`
  in `ghcr.io/usareur-af/goat-processors` were pushed but never indexed or
  signed: **do not use them**; use the signed `0.6.1` image.
- The release workflow runs that check in the job that signs the release,
  after the `.deb` files are downloaded. A new CI check
  (`packaging/check-workflows.py`) fails a pull request when a workflow step
  runs a repository script in a job without a checkout, or reads `dist/`
  before anything fills it.

## 0.6.0 (tag only, never released; see 0.6.1)

- **Breaking: the fabric keys.** The runner publishes on five fixed keys,
  `tracks`, `quality`, `events`, `status` and `trace`, under the new default
  prefix `volatile/<peer>/stream/processors/<name>`. Each value is JSON lines,
  and is dropped rather than waited for on a congested link. Readers of the
  0.5.0 keys get nothing until they move. Before updating, read README.md,
  "Moving from the layout before 0.6.0" (two cases: the default layout, and
  `layout: batch`), and INSTALL.md, "Updating from 0.5.0 or earlier".
- New config keys: `outputs.fabric.peer` (default the site),
  `events_per_source_per_s`, `trace_entities`, `trace_for_s`,
  `trace_max_bytes_per_s`. `layout` defaults to `batch`; `per-entity` stays
  for this release with a warning, and 0.7.0 removes it.
- `config check` refuses an input key that subscribes to the whole fabric,
  and prints warnings (`-o json`: a new `warnings` list). Doctor shows the
  warnings, and fails `output prefix` when neither `peer` nor `prefix` is set and the
  certificate names another peer. The service logs the same at start.
- The package no longer ships `/etc/goat-processors/runner.yaml` as a dpkg
  conffile: it writes it from `/usr/share/goat-processors/runner.yaml` on a
  first install only, so an update asks nothing and keeps the edited config.
  An update from 0.5.0 prints a note that the fabric keys move. `apt purge`
  removes the config, as before.
- `install.sh` sets `peer` from the certificate's name on a first install
  and on an update. The container image has no `install.sh`: set `peer` in
  the mounted config (README.md, "The container image").
- TLS errors (at start and when the revocation list is read again) name the
  file and the kind of problem, never any of its content: before, a
  malformed PEM line, which for the private key is key material, could be
  quoted in the log.
- The `.deb` is built on Ubuntu 22.04, so it runs on 22.04 hosts (glibc
  2.35, NVIDIA Jetson Linux 36) as well as 24.04; a release check fails if a
  binary needs a newer glibc. `install.sh` accepts 22.04. (0.3.2 is the same
  fix for the 0.3 line.)
- Size limits and rotation for the output, record and audit files
  (`max_mb`, `keep`); doctor warns on a large unlimited file and a nearly
  full disk. Hardening review finding 9.
- An optional certificate revocation list for the mesh API (`api.mesh.crl`),
  read again when it changes. Hardening review finding 10.
- Explain pages: `explain TRACK --html PAGE` and `replay FILE --html PAGE`
  write a run, step by step, as one offline HTML file.

## Earlier releases

The release pages on GitHub (tags `runner-v0.1.0` to `runner-v0.5.0`) and the
pull requests they name: 0.5.0 container image and hardening review (#46);
0.4.0 operator page (#45); 0.3.1 quality metrics label (#44); 0.3.0 agent
interfaces, batched fabric output, Prometheus metrics (#28, #37, #38); 0.2.0
HTTP API and CLI verbs (#26); 0.1.0 service, config, doctor, `.deb`, install
process (#21).
