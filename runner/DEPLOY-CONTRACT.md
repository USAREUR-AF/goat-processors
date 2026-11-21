# Deploy contract: goat-processors runner

This is what a deployment tool (goatbuilder, processing lane, build target
type `goat-processors`, host class) does to install a runner and to decide
that the install worked. `install.sh` follows the same contract by hand.
Status: Written, for release `runner-v0.1.0` and later `0.x` releases. `runner-v0.2.0` adds the HTTP API (`runner/openapi.yaml`); every step below is unchanged. `runner-v0.6.0` changes the fabric keys the runner publishes (below); every step is unchanged.

## Inputs

| Input | Form |
|---|---|
| release | a tag `runner-v<version>`; the tool pins one version |
| architecture | `amd64` or `arm64`, from `dpkg --print-architecture` |
| host | Ubuntu 24.04 with systemd, installed by the host-class OS baseline |
| config | one file, `runner.yaml`, written by the tool (README.md, Configure, lists every key) |
| certificates | three PEM files: site CA, runner certificate, runner key |

## Release files

Each GitHub Release of tag `runner-v<version>` carries:

| File | What |
|---|---|
| `goat-processors_<version>_amd64.deb`, `goat-processors_<version>_arm64.deb` | the package |
| `<file>.sigstore.json` for every file | the cosign keyless signature bundle |
| `install.sh` | the manual installer |
| `install-card.pdf` | the one-page install card |
| `SHA256SUMS` (and its `.sigstore.json`) | SHA-256 of every `.deb`, `install.sh` and `install-card.pdf` |

## Steps

| # | Step | Command | Success is |
|---|---|---|---|
| 1 | verify | `cosign verify-blob <deb> --bundle <deb>.sigstore.json --certificate-identity https://github.com/USAREUR-AF/goat-processors/.github/workflows/runner-release.yml@refs/tags/runner-v<version> --certificate-oidc-issuer https://token.actions.githubusercontent.com` | exit 0 |
| 2 | install | `apt-get install -y ./<deb>` | exit 0; `goat-processors version` prints `goat-processors <version>` |
| 3 | self test | `goat-processors selftest -o json` | exit 0; `failed` is `[]` |
| 4 | certificates | write the three files to `/etc/goat-processors/tls/{ca.pem,runner.pem,runner.key}`, owner `root`, group `goat-processors`, mode `0640` | |
| 5 | config | write `/etc/goat-processors/runner.yaml`, owner `root`, group `goat-processors`, mode `0640`; then `goat-processors config check -o json` | exit 0; `valid` is `true` |
| 6 | start | `systemctl enable --now goat-processors`; on a config change, `systemctl restart goat-processors` | `systemctl is-active goat-processors` prints `active` |
| 7 | health | after `3 × tick_ms + 2 s`: `goat-processors doctor -o json` | exit 0, and no entry with `level` `fail` |
| 8 | acceptance replay | `goat-processors replay /usr/share/goat-processors/packs/correlate-assign-time/vectors/56-assign-time-offset-fit.json` | exit 0; its output equals that vector's events step for step (`selftest` in step 3 checks this for every vector) |

Every step is idempotent: running it again on a host where it is done
changes nothing (step 6 restarts the service only when the config changed).

## Machine-readable outputs

| Command | Output |
|---|---|
| `goat-processors config check -o json` | `{"file", "valid", "problems": [string], "warnings": [string]}` (`warnings` 0.6.0 and later); exit 1 when not valid, never for a warning |
| `goat-processors doctor -o json` | `[{"check", "level": "ok"/"warn"/"fail", "detail", "fix"}]`; exit 1 when any `fail` |
| `goat-processors selftest -o json` | `{"packs_dir", "vectors", "passed", "failed": [string]}`; exit 1 on any failure |
| `GET http://127.0.0.1:8470/v1/health` (0.2.0 and later) | 200 `{"healthy": true}` when running and ticking; 503 with `detail` otherwise |
| `goat-processors status -o json` (0.2.0 and later) | the same object as the status file, from the running service |
| `/run/goat-processors/status.json` | `name`, `site`, `version`, `state`, `pipeline`, `counters` (`reports_in`, `reports_out`, `ticks`, `per_source`, `published`, `unreadable`, `output_errors`, `stopped`), `fabric_routers`, `last_tick_ms`, `written_ms` |

## What the runner publishes

Under `outputs.fabric.prefix`, default `volatile/<peer>/stream/processors/<name>`
(0.6.0 and later; `<peer>` is `outputs.fabric.peer`, default the site): five
fixed keys, `tracks`, `quality`, `events`, `status` and, when enabled,
`trace`, each value JSON lines (README.md, "What the runner publishes"). The
fabric's access rules must allow the runner's certificate to subscribe to its
input keys and to publish under its prefix: in goat, the peer's write grant
`volatile/<peer>/**` (goat ADR 1032), so `<peer>` is the certificate's name.
`install.sh` sets it from the certificate, on a first install and on an
update; doctor fails `output prefix` when `peer` is not set and the
certificate names another peer.

Up to 0.5.0 the default was `data/processed/<site>/<name>` with a key per
track (`tracks/<id>`), per quality subject and per function (events and
trace); with `layout: batch` it was `tracks` and `quality` as JSON lines and
still `events/<function>` and `trace/<function>`. README.md, "Moving from the
layout before 0.6.0", covers both. 0.6.0 keeps the first for one release
behind `layout: per-entity` and a `prefix` written out in full; 0.7.0
removes `layout: per-entity`.

Step 5 writes the config file; the package writes it only when it is absent
(0.6.0 and later) and never replaces it, so an update keeps it and asks
nothing.

## Compatibility

Within `0.x`, a later release keeps these commands, their JSON outputs, the
file paths, the config keys, and the fabric keys and their value format; it
may add keys and checks. A change to any of them is a new minor version and
is marked **Breaking** in the release notes: `runner/CHANGELOG.md`, whose
section for a release is also on its GitHub release page. 0.6.0 is such a
release: the fabric keys.
