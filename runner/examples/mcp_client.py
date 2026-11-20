"""A reference MCP client for the goat-processors runner (standard library only).

It connects to the runner's MCP endpoint, lists the tools, and calls each one:
every read tool, then the action tools when --actions is given. It prints one
line per call, and exits 1 when a read tool fails.

    python3 -I runner/examples/mcp_client.py                       # local, read role
    sudo python3 -I runner/examples/mcp_client.py --token-file /run/goat-processors/api.token --actions

The same calls work from any MCP client: point it at http://127.0.0.1:8470/mcp
(Streamable HTTP), or run `goat-processors mcp` as a stdio server.
"""
import argparse
import json
import sys
import urllib.request


class Client:
    def __init__(self, url, token=None):
        self.url, self.token, self.next_id = url, token, 1

    def rpc(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        notify = method.startswith("notifications/")
        if not notify:
            msg["id"] = self.next_id
            self.next_id += 1
        req = urllib.request.Request(self.url, data=json.dumps(msg).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "Accept": "application/json"})
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read()
        if notify:
            return None
        reply = json.loads(body)
        if "error" in reply:
            raise RuntimeError(f"{method}: {reply['error']['message']}")
        return reply["result"]

    def call(self, name, **arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})
        text = "".join(c.get("text", "") for c in result["content"])
        return result.get("isError", False), text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8470/mcp")
    ap.add_argument("--token-file")
    ap.add_argument("--actions", action="store_true", help="also call the action tools")
    ap.add_argument("--json", action="store_true", help="print one JSON object per call")
    a = ap.parse_args()
    token = open(a.token_file).read().strip() if a.token_file else None
    c = Client(a.url, token)

    init = c.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": "goat-processors-reference-client", "version": "1"}})
    c.rpc("notifications/initialized")
    tools = c.rpc("tools/list")["tools"]
    print(f"server {init['serverInfo']['name']} {init['serverInfo']['version']}, protocol {init['protocolVersion']}, {len(tools)} tools")

    # Arguments for the tools that need them, taken from the runner itself.
    _, tracks = c.call("tracks")
    track_ids = [t.get("system") or t.get("group") for t in json.loads(tracks).get("tracks", [])] if tracks.startswith("{") else []
    _, pipeline = c.call("pipeline")
    stages = json.loads(pipeline) if pipeline.startswith("[") else []
    vector = {"name": "x", "pack": "correlate-gnn", "steps": [{"tick": 1000}], "snapshot": {}}
    args = {
        "explain": {"track": track_ids[0] if track_ids else "none"},
        "why": {"track": track_ids[0] if track_ids else "none"},
        "replay": {"content": json.dumps(vector)},
        # The action calls re-select the pack the last stage runs. Selecting a
        # pack restarts that stage empty, so the last stage (usually quality)
        # is used rather than correlate, whose system tracks the read tools show.
        "use_pack": {"function": stages[-1]["function"], "pack": stages[-1]["pack"]} if stages else {},
    }
    failed = 0
    proposed = []  # proposal ids, for approve, reject and revert
    for t in tools:
        name = t["name"]
        read_only = t.get("annotations", {}).get("readOnlyHint", False)
        if not read_only and not a.actions:
            continue
        if name == "propose":
            # Propose the pack the last stage runs already.
            arguments = {"function": stages[-1]["function"], "pack": stages[-1]["pack"], "reason": "reference client check"} if stages else {}
            for _ in range(2):  # one to approve and revert, one to reject
                is_error, text = c.call(name, **arguments)
                if not is_error:
                    proposed.append(json.loads(text)["id"])
        elif name in ("approve", "revert") and proposed:
            is_error, text = c.call(name, id=proposed[0])
        elif name == "reject" and len(proposed) > 1:
            is_error, text = c.call(name, id=proposed[1])
        else:
            is_error, text = c.call(name, **args.get(name, {}))
        if a.json:
            print(json.dumps({"tool": name, "error": is_error, "text": text}))
        else:
            print(f"{'ERROR' if is_error else 'ok   '} {name:<10} {text[:100]}")
        if is_error and read_only:
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
