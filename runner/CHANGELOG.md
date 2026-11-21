# goat-processors runner: release notes

One section per release, newest first. **Breaking** marks a change to
something `DEPLOY-CONTRACT.md` promises to keep within `0.x`: the commands,
their JSON outputs, the file paths, the config keys, and the fabric keys and
their value format. The release workflow puts a release's section on its
GitHub release page.

## 0.6.0

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
