#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""start.py: a running runner for the browser test of the operator page.

Makes a test CA, a server certificate and two client certificates (`ops`,
allowed to operate; `viewer`, allowed to read), writes a runner config with
the local listener and the mesh listener, starts `goat-processors run`, feeds
it two sources reporting three objects over UDP, and files two settings
proposals. It runs until it is stopped. Playwright starts it (webServer in
playwright.config.mjs) and stops it when the tests end.

Usage: start.py --bin PATH --packs DIR --dir DIR --api PORT --mesh PORT --udp PORT
"""
from __future__ import annotations

import argparse
import json
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


def openssl(*args: str, cwd: Path) -> None:
    subprocess.run(["openssl", *args], cwd=cwd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def certificates(d: Path) -> None:
    openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ca.key", cwd=d)
    openssl("req", "-x509", "-new", "-key", "ca.key", "-sha256", "-days", "2", "-subj", "/CN=fieldkit-test-ca", "-out", "ca.pem",
            "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign", cwd=d)
    for who in ("server", "ops", "viewer"):
        openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", f"{who}.key", cwd=d)
        openssl("req", "-new", "-key", f"{who}.key", "-subj", f"/CN={who}", "-out", f"{who}.csr", cwd=d)
        (d / f"{who}.ext").write_text("subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\n")
        openssl("x509", "-req", "-in", f"{who}.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "2",
                "-sha256", "-extfile", f"{who}.ext", "-out", f"{who}.pem", cwd=d)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--packs", required=True)
    ap.add_argument("--dir", required=True)
    ap.add_argument("--api", type=int, required=True)
    ap.add_argument("--mesh", type=int, required=True)
    ap.add_argument("--udp", type=int, required=True)
    a = ap.parse_args()
    d = Path(a.dir).resolve()
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    certificates(d)
    cfg = d / "runner.yaml"
    cfg.write_text(f"""name: fieldkit-test
site: test
packs_dir: {Path(a.packs).resolve()}
tick_ms: 500
inputs:
  udp:
    - listen: "127.0.0.1:{a.udp}"
pipeline:
  - {{function: correlate, pack: correlate-assign-time}}
  - {{function: quality, pack: quality-feed}}
outputs:
  file:
    path: {d}/out.jsonl
    trace: true
record:
  path: {d}/record.jsonl
status_file: {d}/status.json
api:
  listen: "127.0.0.1:{a.api}"
  token_file: {d}/api.token
  audit_file: {d}/audit.jsonl
  mesh:
    listen: "127.0.0.1:{a.mesh}"
    tls:
      root_ca: {d}/ca.pem
      certificate: {d}/server.pem
      private_key: {d}/server.key
    allow:
      - {{name: ops, role: operate}}
      - {{name: viewer, role: read}}
agents:
  proposals_file: {d}/proposals.jsonl
""")
    check = subprocess.run([a.bin, "config", "check", "-c", str(cfg)], capture_output=True, text=True)
    if check.returncode != 0:
        print(check.stdout + check.stderr, file=sys.stderr)
        return 1
    runner = subprocess.Popen([a.bin, "run", "-c", str(cfg)], stderr=open(d / "runner.log", "w"))
    api = f"http://127.0.0.1:{a.api}"
    for _ in range(100):
        try:
            with urllib.request.urlopen(api + "/v1/status", timeout=1):
                break
        except OSError:
            time.sleep(0.1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def feed(i: int) -> None:
        t = int(time.time() * 1000)
        # Three objects. A and B are each seen by two sources; C by one.
        for uid, lat0, lon0, srcs in (("A", 1.0, 1.0, ("radar-1", "adsb")), ("B", 1.01, 1.004, ("radar-1", "adsb")), ("C", 0.995, 1.008, ("radar-1",))):
            for k, src in enumerate(srcs):
                r = {"track.source_id": src, "uid": uid, "time_ms": t, "lat": lat0 + k * 5e-5 + i * 2e-5, "lon": lon0,
                     "ce": 30.0, "course": 0.0, "speed_ms": 11.0, "type": "a-f-S"}
                sock.sendto(json.dumps(r).encode(), ("127.0.0.1", a.udp))

    for i in range(6):
        feed(i)
        time.sleep(0.5)
    for pack, reason in (("correlate-gnn", "try the nearest-neighbor rules"), ("correlate-assign", "try assignment without time terms")):
        subprocess.run([a.bin, "propose", "correlate", pack, "--reason", reason, "-c", str(cfg)], check=True, stdout=subprocess.DEVNULL)
    i = 6
    try:
        while runner.poll() is None:
            feed(i)
            i += 1
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        runner.terminate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
