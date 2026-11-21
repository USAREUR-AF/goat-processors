#!/bin/sh
# The upgrade proof, run by CI as root on a fresh Ubuntu 24.04 VM:
#   1. the previous release's .deb installed, and its config edited as
#      INSTALL.md step 6 says, with a certificate whose name is not the site;
#   2. the new .deb installed by apt with stdin closed: apt must ask nothing,
#      keep the config byte for byte, and print the note that the keys move;
#   3. doctor fails `output prefix` on the kept config (peer not set);
#   4. install.sh adds the peer from the certificate, and doctor's
#      `output prefix` is then ok; a second run changes nothing;
#   5. a purge removes the config and keeps the certificates; a new install
#      writes the config from the template.
#   runner/packaging/ci-upgrade-test.sh <previous .deb> <new .deb>
set -eu
old=$1 new=$2
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
cfg=/etc/goat-processors/runner.yaml
say() { printf '\n### %s\n' "$*"; }
die() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

say "certificates (the runner's is named cert-name, the site is site-a)"
cd "$work"
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 30 -subj "/CN=ci-ca" -out ca.pem
openssl ecparam -name prime256v1 -genkey -noout -out runner.key
openssl req -new -key runner.key -subj "/CN=cert-name" -out runner.csr
openssl x509 -req -in runner.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -sha256 -out runner.pem
chmod 0644 ./*.pem ./*.key
cd - >/dev/null

say "the previous release, edited as INSTALL.md step 6 says"
apt-get install -y -q "$old" >/dev/null
dpkg-query -W goat-processors
sed -i -e 's/^site: CHANGE-ME/site: site-a/' -e 's#tls/CHANGE-ME:7447#tls/localhost:7447#' "$cfg"
install -m 0640 -g goat-processors "$work/ca.pem" "$work/runner.pem" "$work/runner.key" /etc/goat-processors/tls/
cp "$cfg" "$work/before.yaml"

say "the new release, with stdin closed: a dpkg question about the config would fail here"
apt-get install -y "$new" </dev/null >"$work/apt.log" 2>&1 || { cat "$work/apt.log"; die "apt install of the new release failed"; }
cat "$work/apt.log"
if grep -qi "configuration file" "$work/apt.log"; then die "apt asked about the config file"; fi
cmp -s "$work/before.yaml" "$cfg" || die "the edited config was changed"
grep -q "publishes on new fabric keys" "$work/apt.log" || die "no note that the fabric keys move"
if grep -q "edit $cfg" "$work/apt.log"; then die "the edited config was taken for an unedited one"; fi
[ "$(stat -c '%U:%G %a' "$cfg")" = "root:goat-processors 640" ] || die "config owner or mode: $(stat -c '%U:%G %a' "$cfg")"

say "doctor on the kept config: output prefix fails (no peer, the certificate names another)"
goat-processors doctor >"$work/doctor.txt" || true
cat "$work/doctor.txt"
grep -q '^FAIL  output prefix .*cert-name' "$work/doctor.txt" || die "doctor did not fail output prefix"

say "install.sh adds the peer; a second run changes nothing"
for run in 1 2; do
  sh "$here/../install.sh" --deb "$new" --allow-unsigned --site site-a --router localhost:7447 \
    --ca "$work/ca.pem" --cert "$work/runner.pem" --key "$work/runner.key" --no-start | tee "$work/install-$run.txt"
done
grep -q "output peer cert-name" "$work/install-1.txt" || die "install.sh did not add the peer"
grep -q "already done: output peer is cert-name" "$work/install-2.txt" || die "the second run did not find the peer"
[ "$(grep -c '^    peer: cert-name$' "$cfg")" = 1 ] || die "the config does not hold the peer once"
goat-processors config check -c "$cfg"
goat-processors doctor | grep '^ok    output prefix .*volatile/cert-name/' || die "doctor's output prefix is not ok after install.sh"

say "purge, then a new install"
apt-get purge -y -q goat-processors >/dev/null
[ ! -e "$cfg" ] || die "purge left the config"
[ -f /etc/goat-processors/tls/runner.pem ] || die "purge removed the certificates"
apt-get install -y -q "$new" </dev/null >/dev/null
grep -v '^[[:space:]]*#' "$cfg" | grep -q CHANGE-ME || die "a new install did not write the template"
say "PASSED: the upgrade proof"
