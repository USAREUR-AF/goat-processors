#!/bin/sh
# install.sh: from Ubuntu Server 22.04 or 24.04 to a running, healthy goat-processors runner.
#
# It does the steps of runner/INSTALL.md, in the same order, and can be run
# again at any time: a step that is already done is skipped. It prints each
# step, stops at the first failure with what to do, and ends by running
# `goat-processors doctor`.
#
#   sudo sh install.sh --site SITE --router HOST:PORT --ca CA.pem --cert RUNNER.pem --key RUNNER.key
#
# Options (all optional when the step is already done):
#   --version V        release to install (default: the one this script came with)
#   --deb FILE         install this .deb instead of downloading the release
#   --allow-unsigned   with --deb: skip the signature check (test builds only)
#   --site SITE        this site's name, for the config file
#   --name NAME        this runner's name (default processors-1)
#   --router HOST:PORT the fabric router this runner connects to, over TLS
#   --ca FILE --cert FILE --key FILE
#                      the fabric certificates (CA, this runner's certificate, its key)
#   --config FILE      install this prepared config file instead of editing the shipped one
#   --no-start         stop after the config check; do not start the service
#
# goatbuilder will later install runners through the same contract
# (runner/DEPLOY-CONTRACT.md); until then this script is how a site does it.
set -eu

RELEASE=0.7.0
REPO=USAREUR-AF/goat-processors
WORKFLOW=.github/workflows/runner-release.yml
ETC=/etc/goat-processors
CONFIG=$ETC/runner.yaml

deb="" allow_unsigned=0 site="" name="" router="" ca="" cert="" key="" config="" start=1
while [ $# -gt 0 ]; do
  case "$1" in
    --version) RELEASE=$2; shift 2 ;;
    --deb) deb=$2; shift 2 ;;
    --allow-unsigned) allow_unsigned=1; shift ;;
    --site) site=$2; shift 2 ;;
    --name) name=$2; shift 2 ;;
    --router) router=$2; shift 2 ;;
    --ca) ca=$2; shift 2 ;;
    --cert) cert=$2; shift 2 ;;
    --key) key=$2; shift 2 ;;
    --config) config=$2; shift 2 ;;
    --no-start) start=0; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done

# Step numbers are those of INSTALL.md.
step() { n=$1; shift; printf '\n== step %s: %s\n' "$n" "$*"; }
ok() { printf '   ok: %s\n' "$*"; }
skip() { printf '   already done: %s\n' "$*"; }
fail() {
  printf '\n   FAILED: %s\n' "$1" >&2
  printf '   to fix: %s\n' "$2" >&2
  printf '   then run this script again with the same options.\n' >&2
  exit 1
}

step 1 "check this machine"
[ "$(id -u)" -eq 0 ] || fail "this script needs root" "run it with sudo: sudo sh $0 ..."
# shellcheck source=/dev/null
os_id=$(. /etc/os-release && echo "${ID:-}")
# shellcheck source=/dev/null
os_version=$(. /etc/os-release && echo "${VERSION_ID:-}")
if [ "$os_id" != ubuntu ] || { [ "$os_version" != 24.04 ] && [ "$os_version" != 22.04 ]; }; then
  printf '   warning: this is %s %s; the package is built and tested for Ubuntu 22.04 and 24.04\n' "$os_id" "$os_version"
fi
arch=$(dpkg --print-architecture)
case "$arch" in amd64|arm64) ok "Ubuntu $os_version, $arch" ;; *) fail "architecture $arch is not supported" "use an amd64 or arm64 machine" ;; esac
command -v systemctl >/dev/null || fail "systemd is not running here" "use a machine (or VM) that boots with systemd"

step 2 "get the release goat-processors $RELEASE"
# A release .deb next to this script is used before downloading one.
here=$(cd "$(dirname "$0")" && pwd)
if [ -z "$deb" ] && [ -f "$here/goat-processors_${RELEASE}_$arch.deb" ]; then
  deb=$here/goat-processors_${RELEASE}_$arch.deb
fi
installed=$(dpkg-query -W -f '${Status} ${Version}' goat-processors 2>/dev/null || true)
if [ "$installed" = "install ok installed $RELEASE" ]; then
  skip "goat-processors $RELEASE is installed"
  step 3 "check the release signature"
  printf '   skipped: the release is already installed\n'
else
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  if [ -n "$deb" ]; then
    [ -f "$deb" ] || fail "$deb does not exist" "give the path of the .deb with --deb"
    cp "$deb" "$work/"
    debfile=$work/$(basename "$deb")
    # The signature bundle and the checksums, when they sit next to it.
    [ ! -f "$deb.sigstore.json" ] || cp "$deb.sigstore.json" "$work/"
    [ ! -f "$(dirname "$deb")/SHA256SUMS" ] || cp "$(dirname "$deb")/SHA256SUMS" "$work/"
    ok "using $deb"
  else
    command -v curl >/dev/null || { apt-get update -q && apt-get install -y -q curl; }
    base=https://github.com/$REPO/releases/download/runner-v$RELEASE
    debfile=$work/goat-processors_${RELEASE}_$arch.deb
    for f in "$(basename "$debfile")" "$(basename "$debfile").sigstore.json" SHA256SUMS; do
      curl -fsSL -o "$work/$f" "$base/$f" || fail "cannot download $base/$f" "check this machine's internet access, or copy the release files here and use --deb"
    done
    ok "downloaded $(basename "$debfile")"
  fi

  step 3 "check the release signature"
  if [ -f "$work/SHA256SUMS" ]; then
    (cd "$work" && grep " $(basename "$debfile")\$" SHA256SUMS | sha256sum -c --quiet -) \
      || fail "the .deb does not match SHA256SUMS" "download it again; if it still differs, do not install it and tell the release owner"
    ok "checksum matches SHA256SUMS"
  fi
  if [ -f "$debfile.sigstore.json" ]; then
    bundle=$debfile.sigstore.json
    command -v cosign >/dev/null || fail "cosign, the signature checker, is not installed" \
      "install it as INSTALL.md, step 3, shows (two commands), or check on another machine and use --deb"
    cosign verify-blob "$debfile" --bundle "$bundle" \
      --certificate-identity-regexp "^https://github.com/$REPO/$WORKFLOW@refs/tags/runner-v" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null 2>&1 \
      || fail "the signature does not verify: this .deb was not built by the goat-processors release workflow" "do not install it; download the release again from github.com/$REPO/releases"
    ok "signed by the goat-processors release workflow"
  elif [ "$allow_unsigned" -eq 1 ]; then
    printf '   warning: no signature checked (--allow-unsigned); use this only for test builds\n'
  else
    fail "there is no signature bundle (.sigstore.json) next to the .deb" "copy the .deb together with its .sigstore.json, or for a test build add --allow-unsigned"
  fi

  step 4 "install the package"
  apt-get install -y -q "$debfile" >/dev/null || fail "apt could not install the package" "read apt's message above; run: sudo apt-get install -f"
  ok "$(goat-processors version)"
fi

step 4 "check the installed program against its test cases"
goat-processors selftest >/dev/null || fail "goat-processors selftest found a difference" "run: goat-processors selftest, and send its output to the goat-processors maintainers"
ok "$(goat-processors selftest | tail -1)"

step 5 "place the fabric certificates"
tls=$ETC/tls
for pair in "ca:$ca:ca.pem:0640" "cert:$cert:runner.pem:0640" "key:$key:runner.key:0640"; do
  what=${pair%%:*}; rest=${pair#*:}; src=${rest%%:*}; rest=${rest#*:}; dst=${rest%%:*}; mode=${rest#*:}
  if [ -n "$src" ]; then
    [ -f "$src" ] || fail "--$what $src does not exist" "give the path of the PEM file the site's certificate authority issued"
    if [ -f "$tls/$dst" ] && cmp -s "$src" "$tls/$dst"; then skip "$tls/$dst"; else
      install -m "$mode" -o root -g goat-processors "$src" "$tls/$dst"; ok "$tls/$dst"
    fi
  elif [ -f "$tls/$dst" ]; then
    skip "$tls/$dst is in place"
  else
    printf '   not given: --%s (the config may not use TLS; doctor will say)\n' "$what"
    continue
  fi
  # The service reads each file through its group. A purge and reinstall can
  # leave a file with the old, now unknown group; this sets it every time.
  if [ "$(stat -c '%U:%G %a' "$tls/$dst")" != "root:goat-processors 640" ]; then
    chown root:goat-processors "$tls/$dst" && chmod "$mode" "$tls/$dst"
    ok "$tls/$dst: owner root, group goat-processors, mode $mode set"
  fi
done
chown root:goat-processors "$tls" && chmod 0750 "$tls"

step 6 "write the config file $CONFIG"
if [ -n "$config" ]; then
  [ -f "$config" ] || fail "--config $config does not exist" "give the path of a prepared runner.yaml"
  if cmp -s "$config" "$CONFIG"; then skip "$CONFIG is $config"; else
    install -m 0640 -o root -g goat-processors "$config" "$CONFIG"; ok "installed $config"
  fi
elif grep -v '^[[:space:]]*#' "$CONFIG" | grep -q CHANGE-ME; then
  [ -n "$site" ] || fail "the config still has CHANGE-ME values and --site is not given" "add --site SITE and --router HOST:PORT, or edit $CONFIG by hand (INSTALL.md, step 6)"
  [ -n "$router" ] || fail "--router is not given" "add --router HOST:PORT, the fabric router this runner connects to"
  sed -i -e "s/^site: CHANGE-ME/site: $site/" -e "s#tls/CHANGE-ME:7447#tls/$router#" "$CONFIG"
  [ -z "$name" ] || sed -i "s/^name: .*/name: $name/" "$CONFIG"
  ok "site $site, router tls/$router"
else
  skip "$CONFIG has no CHANGE-ME values left"
fi
# The runner publishes under volatile/<peer>/, and the fabric lets it write
# only under the name in its certificate. Use that name as the peer, on a
# first install and on a config kept from an earlier release alike.
cn=$(openssl x509 -in "$tls/runner.pem" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^ *commonName *= *//p' | head -n 1)
cfg_site=$(sed -n 's/^site: *//p' "$CONFIG" | head -n 1)
cfg_peer=$(sed -n 's/^    peer: *//p' "$CONFIG" | head -n 1)
if [ -z "$cn" ]; then
  skip "output peer: the certificate's name cannot be read (openssl missing?); doctor checks it"
elif [ -n "$cfg_peer" ]; then
  if [ "$cfg_peer" = "$cn" ]; then skip "output peer is $cn, the certificate's name"; else
    printf '   NOTE: %s\n' "output peer is $cfg_peer but the certificate's name is $cn; kept as you set it (doctor warns)"
  fi
elif grep -q '^outputs:' "$CONFIG" && grep -q '^  fabric:' "$CONFIG" && grep -q '^    prefix:' "$CONFIG"; then
  skip "outputs.fabric.prefix is set, so the peer is not used"
elif [ "$cn" = "$cfg_site" ]; then
  skip "output peer is the site, $cn, the certificate's name"
elif grep -q '^    # peer: ' "$CONFIG"; then
  sed -i "s|^    # peer: .*|    peer: $cn|" "$CONFIG"
  ok "output peer $cn (the certificate's name)"
elif grep -q '^outputs: *$' "$CONFIG"; then
  # A config kept from 0.5.0 or earlier: add the line under outputs: fabric:.
  awk -v cn="$cn" '{ print } /^outputs: *$/ { o = 1; next } o && /^  fabric: *$/ { print "    peer: " cn; o = 0 } /^[^ #]/ { o = 0 }' "$CONFIG" > "$CONFIG.new"
  if grep -q "^    peer: $cn\$" "$CONFIG.new"; then
    cat "$CONFIG.new" > "$CONFIG"; rm -f "$CONFIG.new"
    ok "output peer $cn (the certificate's name), added under outputs: fabric:"
  else
    rm -f "$CONFIG.new"
    fail "cannot add the output peer to $CONFIG" "add the line '    peer: $cn' under 'outputs:' / '  fabric:' in $CONFIG (INSTALL.md, step 6), then run this script again"
  fi
else
  fail "the certificate's name is $cn, not the site $cfg_site, and $CONFIG has no place for the output peer this script can find" "add '    peer: $cn' under 'outputs:' / '  fabric:' in $CONFIG (INSTALL.md, step 6), then run this script again"
fi
out=$(goat-processors config check -c "$CONFIG") || fail "the config file is not valid:
$out" "edit $CONFIG as each line says, then run this script again"
ok "goat-processors config check: valid"

if [ "$start" -eq 0 ]; then
  printf '\n--no-start: the service is not started. Start it with: sudo systemctl enable --now goat-processors\n'
  exit 0
fi

step 7 "start the service"
systemctl enable --quiet goat-processors
if systemctl is-active --quiet goat-processors; then
  systemctl restart goat-processors; ok "restarted, to read the current config"
else
  systemctl start goat-processors || fail "the service did not start" "run: journalctl -u goat-processors -n 50"
  ok "started"
fi
# Give it three ticks to connect and write its status.
sleep 5

step 8 "doctor"
goat-processors doctor || fail "doctor reports a problem" "fix each FAIL line above (INSTALL.md, Troubleshoot, has each one)"
printf '\nThe runner is installed and healthy. Next: INSTALL.md, step 9 (see it work).\n'
