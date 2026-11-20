#!/bin/sh
# The install proof, run by CI as root on a fresh Ubuntu 24.04 VM:
#   1. a certificate authority, a router certificate and a runner certificate;
#   2. a fabric router (Zenoh, in a container) that requires mutual TLS;
#   3. install.sh with the .deb, twice (the second run must change nothing);
#   4. a scenario published on the fabric: two sources reporting one object;
#   5. the runner's tracks and quality marks read back from the fabric, and doctor healthy.
#   runner/packaging/ci-install-test.sh <path to the .deb>
set -eu
deb=$1
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
certs=$work/certs
mkdir -p "$certs"
say() { printf '\n### %s\n' "$*"; }

say "certificates"
cd "$certs"
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 30 -subj "/CN=ci-ca" -out ca.pem \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign
for who in router runner; do
  openssl ecparam -name prime256v1 -genkey -noout -out "$who.key"
  openssl req -new -key "$who.key" -subj "/CN=$who" -out "$who.csr"
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\nbasicConstraints=CA:FALSE\n' > "$who.ext"
  openssl x509 -req -in "$who.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -days 30 -sha256 -extfile "$who.ext" -out "$who.pem"
done
chmod 0644 ./*.pem ./*.key
cd - >/dev/null

say "fabric router with mutual TLS, and its REST interface for the test"
cat > "$work/router.json5" <<'EOF'
{
  mode: "router",
  listen: { endpoints: ["tls/localhost:7447"] },
  scouting: { multicast: { enabled: false } },
  transport: { link: { tls: {
    root_ca_certificate: "/certs/ca.pem",
    listen_certificate: "/certs/router.pem",
    listen_private_key: "/certs/router.key",
    enable_mtls: true,
  } } },
  plugins: { rest: { http_port: 8000 } },
}
EOF
docker run -d --name ci-router --net host -v "$certs:/certs:ro" -v "$work/router.json5:/router.json5:ro" \
  eclipse/zenoh:1.9.0 -c /router.json5 >/dev/null
for _ in $(seq 30); do curl -fs http://localhost:8000/@/local/router >/dev/null 2>&1 && break; sleep 1; done
curl -fs http://localhost:8000/@/local/router >/dev/null || { docker logs ci-router; exit 1; }

say "install.sh, first run"
sh "$here/../install.sh" --deb "$deb" --allow-unsigned --site ci --router localhost:7447 \
  --ca "$certs/ca.pem" --cert "$certs/runner.pem" --key "$certs/runner.key"

say "install.sh, second run: every step already done, the runner still healthy"
out=$(sh "$here/../install.sh" --deb "$deb" --allow-unsigned --site ci --router localhost:7447 \
  --ca "$certs/ca.pem" --cert "$certs/runner.pem" --key "$certs/runner.key")
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -q "already done: /etc/goat-processors/tls/ca.pem"
printf '%s\n' "$out" | grep -q "already done: /etc/goat-processors/runner.yaml has no CHANGE-ME values left"

say "a scenario on the fabric: radar-1 and adsb report one object, once a second for 12 s"
curl -sN -H 'Accept: text/event-stream' 'http://localhost:8000/data/processed/**' > "$work/out.sse" &
sse=$!
sleep 1
i=0
while [ $i -lt 12 ]; do
  now=$(date +%s%3N)
  for src in radar-1 adsb; do
    lat=$(awk -v i=$i -v s=$src 'BEGIN { printf "%.6f", 1.0 + i * 0.0001 + (s == "adsb" ? 0.00005 : 0) }')
    curl -fs -X PUT -H 'Content-Type: application/json' "http://localhost:8000/data/entity/track/ci/$src/T1" \
      -d "{\"track.source_id\":\"$src\",\"uid\":\"T1\",\"time_ms\":$now,\"lat\":$lat,\"lon\":1.0,\"ce\":30.0,\"course\":0.0,\"speed_ms\":11.0,\"type\":\"a-f-S\"}"
  done
  i=$((i + 1))
  sleep 1
done
sleep 3
kill $sse || true

say "what the runner published"
python3 - "$work/out.sse" <<'PY'
import base64, json, sys
seen = {}
joined = False
for line in open(sys.argv[1]):
    if not line.startswith("data:"):
        continue
    try:
        d = json.loads(line[5:])
    except ValueError:
        continue
    key, value = d.get("key", ""), d.get("value")
    if isinstance(value, str):
        # The REST interface gives JSON as text, other encodings as base64.
        try:
            value = json.loads(value)
        except ValueError:
            try:
                value = json.loads(base64.b64decode(value))
            except ValueError:
                pass
    kind = "/".join(key.split("/")[4:5])
    seen[kind] = seen.get(kind, 0) + 1
    if kind == "tracks" and isinstance(value, dict) and value.get("members") == ["adsb/T1", "radar-1/T1"]:
        joined = True
print("published, by kind:", seen)
assert seen.get("tracks"), "no system track published"
assert seen.get("quality"), "no quality mark published"
assert seen.get("events"), "no events published"
assert joined, "the two sources were not joined in one system track"
PY

say "doctor"
goat-processors doctor
goat-processors doctor -o json | python3 -c 'import json,sys; f=json.load(sys.stdin); bad=[x for x in f if x["level"]!="ok"]; print(bad); sys.exit(1 if any(x["level"]=="fail" for x in bad) else 0)'
python3 -c 'import json; s=json.load(open("/run/goat-processors/status.json")); c=s["counters"]; print(c); assert c["reports_in"] >= 24 and c["per_source"]["adsb"] >= 12 and s["fabric_routers"] == 1'

say "a key the service cannot read: doctor names it, install.sh repairs it"
chgrp root /etc/goat-processors/tls/runner.key
systemctl restart goat-processors
if goat-processors doctor > "$work/doctor.txt"; then cat "$work/doctor.txt"; echo "doctor passed with an unreadable key"; exit 1; fi
grep -q "the service user goat-processors cannot read /etc/goat-processors/tls/runner.key" "$work/doctor.txt" || { cat "$work/doctor.txt"; exit 1; }
sh "$here/../install.sh" --deb "$deb" --allow-unsigned --site ci --router localhost:7447 \
  --ca "$certs/ca.pem" --cert "$certs/runner.pem" --key "$certs/runner.key" | grep "group goat-processors, mode 0640 set"

say "the service runs hardened"
systemd-analyze security goat-processors --no-pager | tail -1

docker rm -f ci-router >/dev/null
echo "install proof: PASS"
