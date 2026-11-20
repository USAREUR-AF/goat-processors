# Install a goat-processors runner

This page takes you from **a machine with Ubuntu Server 24.04 installed and
reachable by SSH** to **a healthy runner publishing tracks on the goat
fabric**. Each step says what to type, what you should see, and what to do
if you do not see it. It takes about fifteen minutes.

[README.md](README.md) explains how the runner works and every config key.
A one-page version of these steps, to print and keep at the machine, is
[docs/install-card.pdf](docs/install-card.pdf); the package installs it in
`/usr/share/doc/goat-processors/`, and each release carries it.

## Words used here

| Word | Meaning |
|---|---|
| runner | the goat-processors program running as a service on this machine. It reads track reports, correlates and measures them, and publishes the results |
| fabric | the goat data network (Zenoh). Programs publish values under keys and receive the keys they subscribe to |
| router | the fabric server at your site that the runner connects to. You need its name and port, for example `router.site-a:7447` |
| certificate authority (CA) | the site's authority that issues certificates. The router and the runner each show a certificate it signed (mutual TLS) |
| release | the files of one version: the package (`.deb`), its signature (`.sigstore.json`) and a checksum list (`SHA256SUMS`) |
| package, `.deb` | the file Ubuntu installs software from, with `apt` |
| signature | proof that the release was built by the goat-processors release workflow and not changed since. `cosign` checks it |
| service | a program systemd (the Ubuntu service manager) keeps running, and starts at boot |
| doctor | `goat-processors doctor`: checks the machine and the service and says what is wrong. It changes nothing |

In the commands below, `$` is the prompt: type what follows it. Lines without
`$` are what you should see.

## Before Ubuntu: the operating system and disk encryption

Install Ubuntu Server 24.04 the way goat installs every host of its machine
family (host class), including full-disk encryption (LUKS). That guidance is
in goatcore: `docs/design/os-baseline-and-luks.md` (every host class), and
`docs/adr/0900-ubuntu-lts-luks-x86.md` (x86 hosts). This page starts after
that: Ubuntu is installed, the machine is on the network, and you can log in
with SSH as a user who may use `sudo`.

## What you need

| Item | Example | From |
|---|---|---|
| the machine's address and your login | `ops@10.20.0.15` | whoever installed Ubuntu |
| the router's name and port | `router.site-a:7447` | the site's fabric administrator |
| the site name to use | `site-a` | the site's fabric administrator |
| three certificate files, PEM | `ca.pem`, `runner.pem`, `runner.key` | the site's certificate authority, issued for this runner |
| the release version | `0.1.0` | the [releases page](https://github.com/USAREUR-AF/goat-processors/releases) (tags `runner-v…`) |

## Two ways

- **Step by step**, below. You see and check each step.
- **One script**, `install.sh`, which does steps 1 to 8 for you on the machine (step 2 downloads the release when no `.deb` is next to it). It is
  idempotent: it can be run again at any time, and skips each step that is
  already done. It prints each step, stops at the first failure with the
  fix, and ends by running doctor:

  ```
  $ sudo sh install.sh --site site-a --router router.site-a:7447 \
        --ca ca.pem --cert runner.pem --key runner.key
  ```

  Get `install.sh` with the release files (step 2). goatbuilder will later
  install runners through the same contract ([DEPLOY-CONTRACT.md](DEPLOY-CONTRACT.md));
  until then this script is how a site does it in one command.

## 1. Log in to the machine

On your own computer:

```
$ ssh ops@10.20.0.15
```

You should see a prompt on the machine, such as `ops@runner-1:~$`. Check
that it is Ubuntu 24.04 and which architecture it is:

```
$ . /etc/os-release && echo $VERSION_ID && dpkg --print-architecture
24.04
amd64
```

The second line is `amd64` (most PCs and servers) or `arm64` (ARM boards).
Use it wherever this page writes `amd64`.

**If not:** a version other than 24.04 is not supported; reinstall from the
guidance above. If SSH does not connect, check the address and that the
machine is on.

## 2. Get the release

Make a directory and download the four files of the release (replace
`0.1.0` and `amd64` with yours):

```
$ mkdir ~/goat-processors && cd ~/goat-processors
$ V=0.1.0 A=amd64
$ B=https://github.com/USAREUR-AF/goat-processors/releases/download/runner-v$V
$ for f in goat-processors_${V}_$A.deb goat-processors_${V}_$A.deb.sigstore.json install.sh SHA256SUMS; do curl -fLO $B/$f; done
$ ls
goat-processors_0.1.0_amd64.deb  goat-processors_0.1.0_amd64.deb.sigstore.json  install.sh  SHA256SUMS
```

**If not:** if `curl` reports 404, check the version on the releases page.
If the machine has no internet access, download the files on another
computer and copy them over with `scp`. If the repository is private to
you, download with the GitHub command-line tool on a computer where you are
signed in: `gh release download runner-v0.1.0 -R USAREUR-AF/goat-processors`.

## 3. Check the release signature

First the checksum: it proves the files are complete.

```
$ sha256sum -c --ignore-missing SHA256SUMS
goat-processors_0.1.0_amd64.deb: OK
install.sh: OK
```

Then the signature: it proves the release workflow built them. Install
`cosign`, the signature checker, once (use `arm64` in both names on an ARM
machine):

```
$ curl -fLO https://github.com/sigstore/cosign/releases/download/v3.1.4/cosign_3.1.4_amd64.deb
$ sudo apt install ./cosign_3.1.4_amd64.deb
$ cosign verify-blob goat-processors_${V}_$A.deb --bundle goat-processors_${V}_$A.deb.sigstore.json \
    --certificate-identity-regexp '^https://github.com/USAREUR-AF/goat-processors/.github/workflows/runner-release.yml@refs/tags/runner-v' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
Verified OK
```

**If not:** a checksum line `FAILED`, or a signature error, means the file
is damaged or is not the release. Do not install it. Download it again; if
it still fails, tell the goat-processors maintainers.

## 4. Install the package

```
$ sudo apt install ./goat-processors_${V}_$A.deb
...
goat-processors: edit /etc/goat-processors/runner.yaml, then run
  sudo goat-processors config check && sudo systemctl enable --now goat-processors
$ goat-processors version
goat-processors 0.1.0
$ goat-processors selftest
121 of 121 vectors under /usr/share/goat-processors/packs replay exactly
```

The package added the program, the service (not started yet), its own user
`goat-processors`, the config file, and every pack. `selftest` runs the
program against every test case shipped with the packs. The count depends
on the release; what matters is that the two numbers are equal.

**If not:** if `apt` reports missing dependencies, run `sudo apt-get install -f`.
If `selftest` prints `FAIL` lines, do not go on: send its output to the
goat-processors maintainers.

## 5. Place the fabric certificates

Copy the three files from the site's certificate authority to the machine
(from your computer: `scp ca.pem runner.pem runner.key ops@10.20.0.15:goat-processors/`).
Then put them where the runner reads them, readable by the service and not
by other users:

```
$ sudo install -m 0640 -g goat-processors ca.pem runner.pem runner.key /etc/goat-processors/tls/
$ sudo ls -l /etc/goat-processors/tls
-rw-r----- 1 root goat-processors  ... ca.pem
-rw-r----- 1 root goat-processors  ... runner.key
-rw-r----- 1 root goat-processors  ... runner.pem
```

The names must be exactly `ca.pem`, `runner.pem` and `runner.key`; those
are the names the config file uses.

**If not:** if a file has another name, rename it in the `install` command,
for example `sudo install -m 0640 -g goat-processors site-ca.crt /etc/goat-processors/tls/ca.pem`.
Each file must be PEM: its first line starts with `-----BEGIN`.

## 6. Edit the config file

The runner has one config file. Open it:

```
$ sudo nano /etc/goat-processors/runner.yaml
```

Change the two lines that hold `CHANGE-ME`:

| Line | Set it to |
|---|---|
| `site: CHANGE-ME` | your site name, for example `site: site-a` |
| `- tls/CHANGE-ME-router:7447` | your router, for example `- tls/router.site-a:7447` |

Leave the rest as it is for a first install. Save with `Ctrl+O`, `Enter`,
and leave with `Ctrl+X`. Then check the file:

```
$ sudo goat-processors config check
/etc/goat-processors/runner.yaml: valid
  correlate  /usr/share/goat-processors/packs/correlate-assign-time
  quality    /usr/share/goat-processors/packs/quality-feed
```

**If not:** the check prints `NOT valid` and one line per problem, each with
where it is and what to do. Edit the file as it says and run the check
again. A line about `CHANGE-ME` means a placeholder is left. README.md,
Configure, explains every key.

## 7. Start the service

```
$ sudo systemctl enable --now goat-processors
$ systemctl is-active goat-processors
active
```

`enable` makes it start at every boot; `--now` starts it now.

**If not:** `failed` or `activating` means it stopped. Its log says why:

```
$ journalctl -u goat-processors -n 30 --no-pager
```

A config problem appears there exactly as in step 6.

## 8. Run doctor

Wait five seconds, then:

```
$ sudo goat-processors doctor
ok    config                     /etc/goat-processors/runner.yaml is valid
ok    pack                       correlate pack correlate-assign-time loads from ...
ok    pack                       quality pack quality-feed loads from ...
ok    certificates: root_ca      /etc/goat-processors/tls/ca.pem is present
ok    certificates: certificate  /etc/goat-processors/tls/runner.pem is present
ok    certificates: private_key  /etc/goat-processors/tls/runner.key is present
ok    fabric                     tls/router.site-a:7447: TCP port open (the TLS handshake is tested by the service)
ok    service                    systemd reports the service active
ok    service                    ticking; status written 412 ms ago
ok    fabric                     the service is connected to 1 router(s)
ok    input                      1840 reports read, 1840 passed every stage

healthy
```

The runner is installed and healthy when the last line is `healthy`.
`running, with warnings` is also a working runner: read each `warn` line.
`input warn: no report read yet` just after a start is normal at a quiet
site.

**If not:** each `FAIL` line is followed by `fix:` with what to do.
README.md, Troubleshoot, lists every doctor line. After a fix, run doctor
again.

## 9. See it work

The runner's counters, rewritten every second:

```
$ cat /run/goat-processors/status.json
```

`reports_in` grows as reports arrive, `per_source` counts them by source,
and `published` counts what the runner published. The system tracks are on
the fabric under `data/processed/<site>/<name>/tracks/`. Any fabric tool at
the site can subscribe to `data/processed/site-a/**` to see them.

To see the pipeline work without the fabric, replay a test case:

```
$ goat-processors replay /usr/share/goat-processors/packs/correlate-assign-time/vectors/56-assign-time-offset-fit.json | head -3
```

Each line is one step: the report or tick that went in, and the events that
came out.

## 10. The visual UI

The visual UI (Fieldkit Processors) is not in this release; its status is
Designed (README.md, What exists). Until it is, `goat-processors doctor` and
the status file in step 9 are the view of the runner.

## Update, stop, remove

| Task | Command |
|---|---|
| update to a new release | steps 2 to 4 with the new version; the service restarts on the new version, and your config is kept |
| apply a config change | `sudo goat-processors config check && sudo systemctl restart goat-processors` |
| stop | `sudo systemctl stop goat-processors` |
| remove (keeps the config and certificates) | `sudo apt remove goat-processors` |
| remove everything but the certificates | `sudo apt purge goat-processors` |
