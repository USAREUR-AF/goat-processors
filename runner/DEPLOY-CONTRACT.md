# Deploy contract: goat-processors runner

This is what a deployment tool (goatbuilder, processing lane, build target
type `goat-processors`, host class) does to install a runner and to decide
that the install worked. `install.sh` follows the same contract by hand.
Status: Written, for release `runner-v0.1.0` and later `0.x` releases.

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
| `SHA256SUMS` (and its `.sigstore.json`) | SHA-256 of every `.deb` and `install.sh` |

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
| `goat-processors config check -o json` | `{"file", "valid", "problems": [string]}`; exit 1 when not valid |
| `goat-processors doctor -o json` | `[{"check", "level": "ok"/"warn"/"fail", "detail", "fix"}]`; exit 1 when any `fail` |
| `goat-processors selftest -o json` | `{"packs_dir", "vectors", "passed", "failed": [string]}`; exit 1 on any failure |
| `/run/goat-processors/status.json` | `name`, `site`, `version`, `state`, `pipeline`, `counters` (`reports_in`, `reports_out`, `ticks`, `per_source`, `published`, `unreadable`, `output_errors`, `stopped`), `fabric_routers`, `last_tick_ms`, `written_ms` |

## What the runner publishes

Under `outputs.fabric.prefix`, default `data/processed/<site>/<name>`:
`tracks/<id>`, `quality/<scope>/<subject>`, `events/<function>` and, when
enabled, `trace/<function>` (README.md, Operate). The fabric's access rules
must allow the runner's certificate to subscribe to its input keys and to
publish under its prefix.

## Compatibility

Within `0.x`, a later release keeps these commands, their JSON outputs, the
file paths and the config keys; it may add keys and checks. A change to any
of them is a new minor version and is listed in the release notes.
