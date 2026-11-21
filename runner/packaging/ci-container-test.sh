#!/bin/sh
# The container proof, run by CI on amd64 and on arm64 (and by hand, the same way):
#   1. the image reports its version and replays every pack vector (selftest);
#   2. with the example config (CHANGE-ME left in it) the container refuses to
#      run and says what to fix;
#   3. a fabric router (Zenoh, in a container) that requires mutual TLS;
#   4. the runner container, locked down: read-only root file system, no Linux
#      capabilities, no new privileges, its own user, limits on memory and
#      processes, writes only to a tmpfs and its state volume;
#   5. a scenario published on the fabric: two sources reporting one object;
#   6. the runner's tracks, quality marks and events read back from the
#      fabric; the image's health check turns healthy; the API verbs work
#      through `docker exec`; the state volume holds the output file.
#   runner/packaging/ci-container-test.sh <image>
# Needs docker, openssl, curl and python3. Uses host networking, and the
# ports below (change them with the environment variables of the same name).
set -eu
image=$1
ROUTER_PORT=${ROUTER_PORT:-17447}
REST_PORT=${REST_PORT:-18000}
API_PORT=${API_PORT:-18480}
want=$(sed -n 's/^version = "\(.*\)"/\1/p' "$(dirname "$0")/../Cargo.toml" | head -1)
work=$(mktemp -d)
certs=$work/certs
mkdir -p "$certs" "$work/etc/tls"
say() { printf '\n### %s\n' "$*"; }
cleanup() {
  docker rm -f ci-ctr-runner ci-ctr-router >/dev/null 2>&1 || true
  docker volume rm ci-ctr-state >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
cleanup_logs() { docker logs ci-ctr-runner 2>&1 | tail -40 || true; }

say "the image: version, and every pack vector replays"
got=$(docker run --rm "$image" version)
echo "$got"
test "$got" = "goat-processors $want" || { echo "the image says '$got', runner/Cargo.toml says $want"; exit 1; }
docker run --rm "$image" selftest | tail -1 | grep -q "replay exactly"

say "the example config is refused, with what to fix"
if out=$(docker run --rm "$image" 2>&1); then echo "the container ran with the example config"; exit 1; fi
printf '%s\n' "$out" | tail -5
printf '%s\n' "$out" | grep -q CHANGE-ME

say "certificates"
cd "$certs"
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 2 -subj "/CN=ci-ca" -out ca.pem \
  -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign 2>/dev/null
for who in router runner; do
  openssl ecparam -name prime256v1 -genkey -noout -out "$who.key"
  openssl req -new -key "$who.key" -subj "/CN=$who" -out "$who.csr" 2>/dev/null
  printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\nbasicConstraints=CA:FALSE\n' > "$who.ext"
  openssl x509 -req -in "$who.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -sha256 -extfile "$who.ext" -out "$who.pem" 2>/dev/null
done
cd - >/dev/null
# The runner's files, as a site lays them out: the config and its certificates
# in one directory, mounted read only. The container's user (65532) must be
# able to read them; here they are readable by all, which is fine for a test.
cp "$certs/ca.pem" "$certs/runner.pem" "$certs/runner.key" "$work/etc/tls/"
chmod 0755 "$work/etc" "$work/etc/tls"
chmod 0644 "$work/etc/tls/"*
chmod 0644 "$certs/"*

say "fabric router with mutual TLS, and its REST interface for the test"
cat > "$work/router.json5" <<EOF
{
  mode: "router",
  listen: { endpoints: ["tls/localhost:$ROUTER_PORT"] },
  scouting: { multicast: { enabled: false } },
  transport: { link: { tls: {
    root_ca_certificate: "/certs/ca.pem",
    listen_certificate: "/certs/router.pem",
    listen_private_key: "/certs/router.key",
    enable_mtls: true,
  } } },
  plugins: { rest: { http_port: $REST_PORT } },
}
EOF
chmod 0644 "$work/router.json5"
docker run -d --name ci-ctr-router --net host -v "$certs:/certs:ro" -v "$work/router.json5:/router.json5:ro" \
  eclipse/zenoh:1.9.0 -c /router.json5 >/dev/null
for _ in $(seq 30); do curl -fs "http://localhost:$REST_PORT/@/local/router" 2>/dev/null | grep -q "/router" && break; sleep 1; done
curl -fs "http://localhost:$REST_PORT/@/local/router" 2>/dev/null | grep -q "/router" || { docker logs ci-ctr-router; exit 1; }

say "the runner container, locked down"
cat > "$work/etc/runner.yaml" <<EOF
name: processors-1
site: ci
packs_dir: /usr/share/goat-processors/packs
tick_ms: 1000
fabric:
  mode: client
  connect:
    - tls/localhost:$ROUTER_PORT
  tls:
    root_ca: /etc/goat-processors/tls/ca.pem
    certificate: /etc/goat-processors/tls/runner.pem
    private_key: /etc/goat-processors/tls/runner.key
inputs:
  fabric:
    keys:
      - data/entity/track/**
pipeline:
  - function: correlate
    pack: correlate-assign-time
  - function: quality
    pack: quality-feed
outputs:
  fabric:
    trace: false
  file:
    path: /var/lib/goat-processors/out.jsonl
api:
  listen: "127.0.0.1:$API_PORT"
EOF
chmod 0644 "$work/etc/runner.yaml"
docker volume create ci-ctr-state >/dev/null
docker run -d --name ci-ctr-runner --net host \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --memory 512m --pids-limit 256 \
  --tmpfs /run/goat-processors:rw,noexec,nosuid,nodev,size=1m,uid=65532,gid=65532,mode=0750 \
  -v ci-ctr-state:/var/lib/goat-processors \
  -v "$work/etc:/etc/goat-processors:ro" \
  "$image" >/dev/null
for _ in $(seq 30); do docker exec ci-ctr-runner goat-processors health >/dev/null 2>&1 && break; sleep 1; done
docker exec ci-ctr-runner goat-processors health || { cleanup_logs; exit 1; }
docker inspect -f 'user {{.Config.User}}, read-only {{.HostConfig.ReadonlyRootfs}}, cap-drop {{.HostConfig.CapDrop}}, security {{.HostConfig.SecurityOpt}}' ci-ctr-runner

say "a scenario on the fabric: radar-1 and adsb report one object, once a second for 12 s"
curl -sN -H 'Accept: text/event-stream' "http://localhost:$REST_PORT/volatile/**" > "$work/out.sse" &
sse=$!
sleep 1
i=0
while [ $i -lt 12 ]; do
  now=$(date +%s%3N)
  for src in radar-1 adsb; do
    lat=$(awk -v i=$i -v s=$src 'BEGIN { printf "%.6f", 1.0 + i * 0.0001 + (s == "adsb" ? 0.00005 : 0) }')
    curl -fs -X PUT -H 'Content-Type: application/json' "http://localhost:$REST_PORT/data/entity/track/ci/$src/T1" \
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
    # Each key is one batch: JSON lines, one object per line. The REST
    # interface gives the value as text, or as base64 for some encodings.
    text = value if isinstance(value, str) else json.dumps(value)
    items = []
    for t in (text, None):
        if t is None:
            try:
                t = base64.b64decode(text).decode()
            except ValueError:
                break
        try:
            items = [json.loads(l) for l in t.splitlines() if l.strip()]
            break
        except ValueError:
            continue
    # volatile/<peer>/stream/processors/<name>/<kind>: a fixed set of kinds
    parts = key.split("/")
    kind = parts[5] if len(parts) == 6 and parts[2:4] == ["stream", "processors"] else "OTHER " + key
    seen[kind] = seen.get(kind, 0) + 1
    for v in items:
        if isinstance(v, dict) and v.get("members") == ["adsb/T1", "radar-1/T1"]:
            joined = True
print("published, by kind:", seen)
assert seen.get("tracks"), "no system track published"
assert seen.get("quality"), "no quality mark published"
assert seen.get("events"), "no events published"
assert joined, "the two sources were not joined in one system track"
assert set(seen) <= {"tracks", "quality", "events", "trace", "status"}, "a key outside the fixed set: %s" % sorted(seen)
PY

say "the API through docker exec: whoever can exec into the container operates it"
docker exec ci-ctr-runner goat-processors status | grep -q "processors-1 at ci"
docker exec ci-ctr-runner goat-processors tracks | grep -q "adsb/T1 radar-1/T1"
docker exec ci-ctr-runner goat-processors stop | grep -q paused
if docker exec ci-ctr-runner goat-processors health >/dev/null 2>&1; then echo "health passed while stopped"; exit 1; fi
docker exec ci-ctr-runner goat-processors start | grep -q running
docker exec ci-ctr-runner goat-processors audit | grep -q '"path":"/v1/stop"'

say "doctor, inside the container"
docker exec ci-ctr-runner goat-processors doctor

say "the image's health check"
for _ in $(seq 30); do
  h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ci-ctr-runner)
  [ "$h" = healthy ] && break
  sleep 1
done
echo "health: $h"
test "$h" = healthy || { docker inspect -f '{{json .State.Health}}' ci-ctr-runner; exit 1; }

say "the state volume holds the output file; the root file system is read only and nothing is privileged"
docker cp ci-ctr-runner:/var/lib/goat-processors/out.jsonl "$work/out.jsonl"
lines=$(python3 -c 'import json,sys; print(sum(1 for l in open(sys.argv[1]) if json.loads(l)))' "$work/out.jsonl")
echo "out.jsonl: $lines lines"
test "$lines" -gt 0
docker exec ci-ctr-runner goat-processors status -o json \
  | python3 -c 'import json,sys; c=json.load(sys.stdin)["counters"]; print(c); assert c["reports_in"] >= 24, c'
test "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.Privileged}} {{.Config.User}}' ci-ctr-runner)" = "true false 65532:65532"

say "PASSED: the container proof"
