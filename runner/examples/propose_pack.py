"""Agent changing settings: propose a pack, and follow the proposal (standard library only).

A proposal changes nothing until it is applied: by a person
(`sudo goat-processors proposal approve ID`), or by the site's policy once its
gate passes:

    agents:
      auto_approve:
        - {who: local, function: quality, packs: [quality-feed, quality-time], gate: [goat-processors, selftest]}

    python3 -I runner/examples/propose_pack.py quality quality-time --reason "sources now report their clock state"
"""
import argparse
import json
import sys
import time
import urllib.request


def mcp(url, token, method, params, msg_id=1):
    msg = {"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params}
    req = urllib.request.Request(url, data=json.dumps(msg).encode(), method="POST", headers={"Content-Type": "application/json"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=60) as r:
        reply = json.loads(r.read())
    if "error" in reply:
        raise RuntimeError(reply["error"]["message"])
    return reply["result"]


def tool(url, token, name, **arguments):
    res = mcp(url, token, "tools/call", {"name": name, "arguments": arguments}, 2)
    return res.get("isError", False), "".join(c.get("text", "") for c in res["content"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("function")
    ap.add_argument("pack")
    ap.add_argument("--reason", required=True)
    ap.add_argument("--url", default="http://127.0.0.1:8470/mcp")
    ap.add_argument("--token-file")
    ap.add_argument("--wait", type=float, default=30, help="seconds to follow a proposal whose gate is running")
    a = ap.parse_args()
    token = open(a.token_file).read().strip() if a.token_file else None
    mcp(a.url, token, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "propose-pack-example", "version": "1"}})
    err, text = tool(a.url, token, "propose", function=a.function, pack=a.pack, reason=a.reason)
    if err:
        print(f"refused: {text}", file=sys.stderr)
        return 1
    p = json.loads(text)
    deadline = time.time() + a.wait
    while p["state"] == "gating" and time.time() < deadline:
        time.sleep(0.5)
        _, listing = tool(a.url, token, "proposals")
        p = next(x for x in json.loads(listing) if x["id"] == p["id"])
    print(f"proposal {p['id']}: {p['function']} {p['previous_pack']} -> {p['pack']}: {p['state']}"
          + (f", decided by {p['decided_by']}" if p.get("decided_by") else ""))
    if p["state"] in ("pending", "gate-failed"):
        print(f"it waits for a person: sudo goat-processors proposal approve {p['id']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
