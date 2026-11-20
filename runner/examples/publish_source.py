"""Agent as a source: publish reports to the runner as an agent (standard library only).

The site lists this agent's identity and source id in the runner's config:

    agents:
      sources:
        - {who: local, source_id: agent-example}

Then each report this agent publishes is processed like a sensor's, marked
agent-derived (provenance.kind = agent, provenance.agent = its identity), and
a system track that includes it carries agent_provenance.

    python3 -I runner/examples/publish_source.py --source-id agent-example --model my-model-1 < reports.jsonl
    python3 -I runner/examples/publish_source.py --source-id agent-example --model my-model-1 --demo 10

Each input line is a shared-model report (track.source_id is set for you).
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8470/mcp")
    ap.add_argument("--token-file")
    ap.add_argument("--source-id", required=True)
    ap.add_argument("--model", required=True, help="the model and version that produced the reports")
    ap.add_argument("--inputs", default="", help="what the agent worked from, for provenance.inputs")
    ap.add_argument("--demo", type=int, default=0, help="publish N reports of one object moving north, one a second")
    a = ap.parse_args()
    token = open(a.token_file).read().strip() if a.token_file else None
    mcp(a.url, token, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "publish-source-example", "version": "1"}})

    def reports():
        if a.demo:
            for i in range(a.demo):
                yield {"uid": "D1", "time_ms": int(time.time() * 1000), "lat": 1.0 + i * 1e-4, "lon": 1.0, "ce": 50.0, "type": "a-u-S"}
                if i + 1 < a.demo:
                    time.sleep(1)
        else:
            for line in sys.stdin:
                if line.strip():
                    yield json.loads(line)

    sent = 0
    for r in reports():
        r["track.source_id"] = a.source_id
        r["provenance.model"] = a.model
        if a.inputs:
            r["provenance.inputs"] = a.inputs
        res = mcp(a.url, token, "tools/call", {"name": "publish", "arguments": {"reports": json.dumps(r)}}, sent + 2)
        text = "".join(c.get("text", "") for c in res["content"])
        if res.get("isError"):
            print(f"refused: {text}", file=sys.stderr)
            return 1
        sent += 1
    print(f"published {sent} reports as {a.source_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
