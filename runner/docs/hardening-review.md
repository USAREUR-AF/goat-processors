# Hardening review of the runner

Review of the goat-processors runner 0.4.0 (main at fd60cd2), done on
2026-11-21 for brief step 4. It covers what a caller on the network, a
source of reports, a local user and a site administrator can do to the
running service, and how the package and the container image restrict it. Each
finding has a status: **Fixed** (fixed in the change that adds this file,
with a test), **Documented** (by design, and the docs now say how to deploy
safely), or **Open** (not fixed; the next step is named).

## What the runner exposes

| Surface | Who can reach it | What protects it |
|---|---|---|
| Fabric input and output (`fabric`) | the router the runner connects to, and every program the router lets publish on the input keys | mutual TLS to the router; the router's own access rules decide who publishes |
| UDP input (`inputs.udp`) | anyone who can send a datagram to the port | nothing in the protocol: the listen address is the only control |
| File input (`inputs.file`) | whoever can write the file | file permissions; root owns the config that names it |
| Local API (`api.listen`) | every user on the host (loopback only; `config check` refuses any other address) | read without a token; `operate` needs the token, which only root (or the container's user) can read |
| Mesh API (`api.mesh`) | every host on the mesh can open a connection | mutual TLS: a certificate the site CA signed, and its common name in `api.mesh.allow` |
| Metrics port (`api.metrics_listen`) | every host that reaches the address | serves only `GET /metrics`; `config check` refuses it on every address |
| Operator page (`/ui`) | browsers, through the local or mesh API | the API's roles, plus refusal of cross-site requests and of a foreign Host, and a content policy that lets the page load nothing |
| Model endpoints (`agents.endpoints`) | the runner calls out to them | data levels decide what each may see; TLS with the endpoint's CA |
| Policy gates (`agents.auto_approve[].gate`) | the runner runs the command root wrote in the config | the command is fixed in the config; the proposal reaches it only as two environment variables |

## Findings

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | One malformed report crashed the runner | High | Fixed |
| 2 | One report with an absurd longitude stopped the service loop | High | Fixed |
| 3 | Callers on the mesh or metrics port could shut out the local API | Medium | Fixed |
| 4 | A flood of reports could use up memory | Medium | Fixed |
| 5 | A hosted model endpoint was allowed over plain HTTP | Medium | Fixed |
| 6 | `doctor` needed the openssl command to check certificates | Low | Fixed |
| 7 | The engines' longitude wrap and JSON parser have no bound | High (engines) | Open: in the next spec round (proc-correlate) |
| 8 | UDP input accepts reports from anyone who reaches it | Medium | Documented |
| 9 | Output, record and audit files grow without limit | Medium | Fixed in 0.6.0 |
| 10 | No certificate revocation on the mesh API | Low | Fixed in 0.6.0 |
| 11 | The mesh role follows the certificate's common name alone | Low | Documented |
| 12 | In the container, anyone who can `docker exec` operates the runner | Low | Documented |
| 13 | A malformed line of a PEM file, the private key included, could be quoted in the log | Medium | Fixed in 0.6.0 |

**1. One malformed report crashed the runner (Fixed).** The engine's JSON
parser descends one function call per `[` or `{`. One UDP datagram of 60,000
open brackets overflowed the input thread's stack, and Rust aborts the whole
process on a stack overflow. The same body sent to `POST /mcp` (role `read`,
so any local user) or published on the fabric did the same. The runner now
parses all JSON through `runner/src/json.rs`, which refuses text nested more
than 64 levels before the engine's parser sees it. Tests: `json::tests`, and
`hostile_reports_are_refused_and_the_runner_stays_up` in `tests/api.rs`.
A fuzz run of 300,000 random short inputs found no panic in the parser.

**2. One report with an absurd longitude stopped the service loop (Fixed).**
The engines bring a longitude into (-180, 180] by subtracting or adding 360
until it fits (`wrap180`). For `lon: -1e308`, adding 360 leaves the value
unchanged, so the loop never ends. A report of `lat: 1e308, lon: -1e308` next
to any other track stopped the service loop: the runner stayed up but
answered nothing and published nothing. A value written `1e999` reads as
infinity and does the same. The service loop now refuses a report with a
number that is not finite, `lat` beyond 90 or `lon` beyond 360, counts it as
unreadable and names it in the journal. Replay files are checked the same
way. All 121 vectors still replay exactly. Test: the same test in
`tests/api.rs`. A probe of 30 other malformed reports (wrong types, missing
keys, extreme times, speeds and errors, a 60,000-character `uid`) found no
other hang or crash.

**3. Callers on the mesh or metrics port could shut out the local API
(Fixed).** The three listeners shared one budget of 32 connections, and a
connection was dropped only after 10 s with no byte at all. A host on the
mesh, with no certificate (the TLS handshake happens inside the slot) or on
the metrics port, could hold all 32 by sending a byte every few seconds; then
`health`, `doctor` and every operator verb on the host failed. Each listener
now has its own budget (local 16, mesh 32, metrics 4), and a whole request,
TLS handshake included, must arrive within 30 s. Tests:
`a_request_sent_a_byte_at_a_time_ends_at_the_deadline` in `http.rs`, and
`slow_callers_on_one_port_do_not_lock_out_the_local_api` in `tests/api.rs`.

**4. A flood of reports could use up memory (Fixed).** Inputs reached the
service loop through an unbounded queue. A source sending faster than the
pipeline runs grew it until the kernel or the container's memory limit killed
the runner; API calls waited in the same queue and timed out first. The queue
now holds 65,536 inputs. When it is full, the fabric and UDP inputs drop the
report and count it (`counters.dropped_backlog`, shown by `status`, warned by
`doctor`); the file input, the API and the agents wait instead. Test:
`a_full_input_queue_drops_and_counts_instead_of_growing`.

**5. A hosted model endpoint was allowed over plain HTTP (Fixed).** `config
check` accepted `kind: hosted` with an `http://` URL, which sends the tracks
the data level allows, and the endpoint's key, in the clear across networks
the site does not control. It now refuses it. Test:
`hosted_endpoint_over_plain_http_is_refused`.

**6. `doctor` needed the openssl command to check certificates (Fixed).**
`doctor` ran `openssl` to parse each certificate and read its end date, and
skipped both checks silently when the command was missing, as it is in the
container image. It now reads certificates with the libraries the service
uses. Test: `certificate_tests` in `doctor.rs`.

**7. The engines' longitude wrap and JSON parser have no bound (Open).** The
runner now guards both (findings 1 and 2), but the engines themselves, in
every language, still loop in `wrap180` on a huge or infinite value, and the
Rust parser still recurses without a limit. A program that uses an engine
directly, or `goat-processors replay` on a crafted file before this change,
meets the same problem. The spec leaves such values open (correlate.md,
Reports). Next: the engines' owner decides the spec change (a bounded wrap,
such as a remainder, and refusing non-finite `lat` and `lon`) and the
vectors that pin it. Reported through proc-coord.

**8. UDP input accepts reports from anyone who reaches it (Documented).** UDP
has no sender check, so the listen address is the only control. The README's
config table now says to bind it to `127.0.0.1` or an interface that only
trusted senders reach, and to prefer the fabric for reports from other hosts.

**9. Output, record and audit files grow without limit (Fixed in 0.6.0).**
`outputs.file`, `record` and `api.audit_file` were appended to forever, and
a full disk stopped the writes (`output_errors`). Each now takes an
optional size limit (`max_mb`) and a number of older copies to keep
(`keep`, 0 to 9): past the limit the file is renamed `<path>.1` and a new
one starts, never splitting a line. Without a limit a file grows as before,
and the shipped config sets no limit (there is no size that fits every site),
so set `max_mb` on any file you enable;
`doctor` warns when such a file passes 1 GiB, and when the disk holding a
file is 90% full (where the host has `df`). Tests: `rotate::tests` and
`file_size_limits_are_checked` in `tests/api.rs`.

**10. No certificate revocation on the mesh API (Fixed in 0.6.0).** The
mesh listener checked that the site CA signed a certificate but read no
revocation list, so taking access away meant editing `api.mesh.allow` and
restarting. `api.mesh.crl` now names the CA's revocation list: a client
certificate it lists is refused at the handshake. The service reads the file
again when it changes, so a revocation takes effect on the next connection
without a restart, and a copy that does not read leaves the previous list
in force. `doctor` checks the list reads and warns when it is past its next
update. Test: `mesh_api_refuses_a_revoked_certificate_without_a_restart`.

**11. The mesh role follows the certificate's common name alone
(Documented).** Any certificate the site CA signs with the common name `ops`
gets the role given to `ops`. That is the intended design: the site CA's
issuing rules are the control. The README's config table (`api.mesh.allow`)
now says the site CA should give each person and program its own name.

**12. In the container, anyone who can `docker exec` operates the runner
(Documented).** The token is in the container's own tmpfs, readable by its
user, so `docker exec` can change the pipeline. Access to Docker on the host
is already root-equivalent. The README's container section says to give
Docker access as you would give `sudo`.

**13. A malformed line of a PEM file could be quoted in the log (Fixed in
0.6.0).** The TLS setup of the mesh API passed on the PEM parser's own
message, which quotes the line it could not read. A key file with a broken
BEGIN line or bad base64 put that line, key material, into the error the
service writes to the journal at start, and when the revocation list was read
again. Found by CodeQL (rust/cleartext-logging). Errors now name the file and
the kind of problem only, and the revocation list reload logs only the list's
path. Test: `http::tests::a_bad_key_file_is_named_but_none_of_its_content_is_said`.

## Checked and sound

- **The API token** is 32 bytes from `/dev/urandom`, written mode 0600 in a
  directory only the service can write, created anew at every start, and
  compared in constant time.
- **Mutual TLS** (rustls with ring, safe default protocol versions only):
  the mesh listener refuses a client without a certificate the site CA
  signed, before any request is read.
- **Requests**: one per connection, headers at most 16 KiB, body at most
  16 MiB with `Content-Length` only (chunked bodies refused), and now the
  30 s deadline (finding 3).
- **Browsers**: cross-site requests (`Sec-Fetch-Site`, `Origin`) and foreign
  `Host` names are refused and audited; the page is sent with a content
  policy that lets it load nothing and call only its own origin, and it may
  not be framed. Tested by `operator_page_view_and_browser_rules` and the
  browser test.
- **Provenance**: reports from the fabric, UDP and files cannot claim to be
  checked agent reports (`provenance.checked` is removed, nested or not).
- **The systemd unit** scores 1.4 ("OK") in `systemd-analyze security`. The
  remaining points are the network access the service needs (`AF_INET`,
  `AF_INET6`, `AF_UNIX`, `AF_NETLINK`; no `PrivateNetwork`, no
  `IPAddressDeny`), `@resources` in the system call filter, the host's root
  directory, and a umask that lets the service group read its files.
- **The container image** runs as user 65532 with no shell or package
  manager. The proof (`packaging/ci-container-test.sh`, CI on amd64 and
  arm64) runs it with a read-only root file system, no Linux capabilities,
  no new privileges, and limits on memory and processes.
- **Supply chain**: every crate pinned in `Cargo.lock`, `cargo audit` and
  `cargo deny` in CI, every GitHub Action pinned by commit, both base images
  pinned by digest, the `.deb` files and the image signed with cosign
  (keyless) by the release workflow, and build paths removed from the binary.
